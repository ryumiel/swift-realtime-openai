import AVFAudio
import Foundation
import LiveKitWebRTC

/// Fixed-format, bounded PCM retained only for a qualification-only RTP sender.
@_spi(AirbridgeQualification) public struct WebRTCConnectorQualificationSyntheticAudio: Equatable, Sendable {
	public static let sampleRate = 24_000
	public static let minimumByteCount = 4_800
	public static let maximumByteCount = 240_000

	package let pcm16LittleEndian: Data

	public init(pcm16Mono24kHz: Data) throws {
		guard pcm16Mono24kHz.count.isMultiple(of: 2),
			(Self.minimumByteCount...Self.maximumByteCount).contains(pcm16Mono24kHz.count)
		else { throw WebRTCTransportFailure.invalidRequest }
		pcm16LittleEndian = pcm16Mono24kHz
	}
}

/// Capped, content-free progress from the qualification-only RTP source.
@_spi(AirbridgeQualification) public struct WebRTCConnectorQualificationSyntheticAudioEvidence: Equatable, Sendable {
	public let started: Bool
	public let renderedFrameCount: Int
	public let totalFrameCount: Int

	public var isComplete: Bool {
		started && totalFrameCount > 0 && renderedFrameCount >= totalFrameCount
	}
}

/// Replaces the physical input node in LiveKit's manual-rendering audio graph.
/// The render callback owns the sample cursor and performs no allocation.
final class WebRTCQualificationSyntheticAudioSource: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
	private static let outputSampleRate = 48_000.0
	private let renderer: Renderer
	private let decodedAudioCounter = WebRTCQualificationDecodedAudioCounter()
	private let sourceFormat: AVAudioFormat
	private weak var configuredEngine: AVAudioEngine?
	private var sourceNode: AVAudioSourceNode?
	private var sinkNode: AVAudioSinkNode?

	init(audio: WebRTCConnectorQualificationSyntheticAudio) throws {
		guard let sourceFormat = AVAudioFormat(
			commonFormat: .pcmFormatFloat32,
			sampleRate: Self.outputSampleRate,
			channels: 1,
			interleaved: false
		) else { throw WebRTCTransportFailure.invalidRequest }
		self.sourceFormat = sourceFormat
		renderer = Renderer(pcm16LittleEndian: audio.pcm16LittleEndian)
		super.init()
	}

	func start() {
		renderer.start()
	}

	func evidence() -> WebRTCConnectorQualificationSyntheticAudioEvidence {
		renderer.evidence()
	}

	func decodedAudioEvidence() -> WebRTCConnectorQualificationAudioEvidence {
		decodedAudioCounter.evidence()
	}

	func stop() {
		renderer.stop()
	}

	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		engine: AVAudioEngine,
		configureInputFromSource source: AVAudioNode?,
		toDestination destination: AVAudioNode,
		format _: AVAudioFormat,
		context _: [AnyHashable: Any]
	) -> Int {
		guard source == nil, engine.isInManualRenderingMode else { return -1 }
		if let sourceNode {
			engine.disconnectNodeOutput(sourceNode)
			engine.detach(sourceNode)
		}
		let renderer = renderer
		let sourceNode = AVAudioSourceNode(format: sourceFormat) {
			_, _, frameCount, outputData in
			renderer.render(frameCount: frameCount, outputData: outputData)
		}
		engine.attach(sourceNode)
		engine.connect(sourceNode, to: destination, format: sourceFormat)
		self.sourceNode = sourceNode
		configuredEngine = engine
		return 0
	}

	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		engine: AVAudioEngine,
		configureOutputFromSource source: AVAudioNode,
		toDestination destination: AVAudioNode?,
		format: AVAudioFormat,
		context _: [AnyHashable: Any]
	) -> Int {
		guard destination == nil, engine.isInManualRenderingMode else { return -1 }
		if let sinkNode {
			engine.disconnectNodeInput(sinkNode)
			engine.detach(sinkNode)
		}
		let decodedAudioCounter = decodedAudioCounter
		let sinkNode = AVAudioSinkNode { _, frameCount, audioData in
			decodedAudioCounter.observe(frameCount: frameCount, audioData: audioData)
			return noErr
		}
		engine.attach(sinkNode)
		engine.connect(source, to: sinkNode, format: format)
		self.sinkNode = sinkNode
		configuredEngine = engine
		return 0
	}

	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		didReceiveSpeechActivityEvent _: LKRTCSpeechActivityEvent
	) {}

	func audioDeviceModuleDidUpdateDevices(_: LKRTCAudioDeviceModule) {}
	func audioDeviceModule(_: LKRTCAudioDeviceModule, didCreateEngine _: AVAudioEngine) -> Int { 0 }
	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		willEnableEngine _: AVAudioEngine,
		isPlayoutEnabled _: Bool,
		isRecordingEnabled _: Bool
	) -> Int { 0 }
	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		willStartEngine _: AVAudioEngine,
		isPlayoutEnabled _: Bool,
		isRecordingEnabled _: Bool
	) -> Int { 0 }
	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		didStopEngine _: AVAudioEngine,
		isPlayoutEnabled _: Bool,
		isRecordingEnabled _: Bool
	) -> Int { 0 }
	func audioDeviceModule(
		_: LKRTCAudioDeviceModule,
		didDisableEngine _: AVAudioEngine,
		isPlayoutEnabled _: Bool,
		isRecordingEnabled _: Bool
	) -> Int { 0 }
	func audioDeviceModule(_: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
		if let sourceNode {
			engine.disconnectNodeOutput(sourceNode)
			engine.detach(sourceNode)
		}
		if let sinkNode {
			engine.disconnectNodeInput(sinkNode)
			engine.detach(sinkNode)
		}
		sourceNode = nil
		sinkNode = nil
		configuredEngine = nil
		return 0
	}

	private final class Renderer: @unchecked Sendable {
		private let lock = NSLock()
		private let samples: [Float]
		private var started = false
		private var cursor = 0

		init(pcm16LittleEndian: Data) {
			var samples = [Float]()
			samples.reserveCapacity(pcm16LittleEndian.count)
			var index = pcm16LittleEndian.startIndex
			while index < pcm16LittleEndian.endIndex {
				let next = pcm16LittleEndian.index(after: index)
				let bits = UInt16(pcm16LittleEndian[index])
					| UInt16(pcm16LittleEndian[next]) << 8
				let value = Float(Int16(bitPattern: bits)) / 32_768
				// The fixed source is 24 kHz; duplicate into the 48 kHz RTP clock.
				samples.append(value)
				samples.append(value)
				index = pcm16LittleEndian.index(next, offsetBy: 1)
			}
			self.samples = samples
		}

		func start() {
			lock.lock()
			started = true
			cursor = 0
			lock.unlock()
		}

		func stop() {
			lock.lock()
			started = false
			lock.unlock()
		}

		func evidence() -> WebRTCConnectorQualificationSyntheticAudioEvidence {
			lock.lock()
			defer { lock.unlock() }
			return .init(
				started: started,
				renderedFrameCount: min(cursor, samples.count),
				totalFrameCount: samples.count
			)
		}

		func render(
			frameCount: AVAudioFrameCount,
			outputData: UnsafeMutablePointer<AudioBufferList>
		) -> OSStatus {
			let frameCount = Int(frameCount)
			guard frameCount >= 0 else { return kAudio_ParamError }
			let buffers = UnsafeMutableAudioBufferListPointer(outputData)
			guard buffers.count == 1,
				let destination = buffers[0].mData?.assumingMemoryBound(to: Float.self)
			else { return kAudio_ParamError }

			lock.lock()
			let canRender = started
			let available = canRender ? max(0, samples.count - cursor) : 0
			let copied = min(frameCount, available)
			if copied > 0 {
				samples.withUnsafeBufferPointer { source in
					destination.update(from: source.baseAddress!.advanced(by: cursor), count: copied)
				}
				cursor += copied
			}
			lock.unlock()

			if copied < frameCount {
				destination.advanced(by: copied).update(repeating: 0, count: frameCount - copied)
			}
			buffers[0].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
			return noErr
		}
	}
}

/// Counts only capped, content-free facts from decoded PCM delivered by the
/// manual audio graph. It never retains sample buffers or individual values.
package final class WebRTCQualificationDecodedAudioCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var decodedFrameCount: UInt64 = 0
	private var nonZeroDecodedByteCount: UInt64 = 0
	private var limitExceeded = false

	package init() {}

	package func observe(
		frameCount: AVAudioFrameCount,
		audioData: UnsafePointer<AudioBufferList>
	) {
		var observedNonZeroBytes: UInt64 = 0
		let mutableAudioData = UnsafeMutablePointer(mutating: audioData)
		for buffer in UnsafeMutableAudioBufferListPointer(mutableAudioData) {
			guard let data = buffer.mData else { continue }
			let bytes = UnsafeRawBufferPointer(
				start: data,
				count: Int(buffer.mDataByteSize)
			)
			for byte in bytes where byte != 0 {
				observedNonZeroBytes += 1
			}
		}
		observe(
			frameCount: UInt64(frameCount),
			nonZeroByteCount: observedNonZeroBytes
		)
	}

	package func observe(frameCount: UInt64, nonZeroByteCount: UInt64) {
		lock.lock()
		defer { lock.unlock() }
		Self.addCapped(
			frameCount,
			to: &decodedFrameCount,
			limit: WebRTCConnectorQualificationAudioEvidence.maximumDecodedFrameCount,
			limitExceeded: &limitExceeded
		)
		Self.addCapped(
			nonZeroByteCount,
			to: &nonZeroDecodedByteCount,
			limit: WebRTCConnectorQualificationAudioEvidence.maximumNonZeroDecodedByteCount,
			limitExceeded: &limitExceeded
		)
	}

	package func evidence() -> WebRTCConnectorQualificationAudioEvidence {
		lock.lock()
		defer { lock.unlock() }
		return .init(
			receivedByteCount: 0,
			receivedSampleCount: 0,
			decodedFrameCount: decodedFrameCount,
			nonZeroDecodedByteCount: nonZeroDecodedByteCount,
			limitExceeded: limitExceeded
		)
	}

	private static func addCapped(
		_ value: UInt64,
		to total: inout UInt64,
		limit: UInt64,
		limitExceeded: inout Bool
	) {
		let remaining = limit - total
		if value > remaining {
			total = limit
			limitExceeded = true
		} else {
			total += value
		}
	}
}
