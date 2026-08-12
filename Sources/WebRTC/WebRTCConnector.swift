import Core
import AVFAudio
import Foundation
import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor @Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	@MainActor package struct TerminalObserver {
		let cancelSignaling: () -> Void
		let closeData: () -> Void
		let closePeer: () -> Void
		let disableAudio: () -> Void

		package init(cancelSignaling: @escaping () -> Void, closeData: @escaping () -> Void, closePeer: @escaping () -> Void, disableAudio: @escaping () -> Void) {
			self.cancelSignaling = cancelSignaling
			self.closeData = closeData
			self.closePeer = closePeer
			self.disableAudio = disableAudio
		}

		static let none = Self(cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {})
	}

	public enum WebRTCError: Error {
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<WebRTCInboundEvent, Error>
	public private(set) var status = RealtimeAPI.Status.disconnected
	@_spi(AirbridgeQualification) public let qualificationEvents: AsyncThrowingStream<WebRTCConnectorQualificationEvent, Error>

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	private let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	private let stream: AsyncThrowingStream<WebRTCInboundEvent, Error>.Continuation
	private let qualificationStream: AsyncThrowingStream<WebRTCConnectorQualificationEvent, Error>.Continuation
	private let signalingClient: WebRTCSignalingClient
	private let inboundEventDecoder = WebRTCInboundEventDecoder()
	private let lifecycle = WebRTCLifecycle()
	private let generation: Int
	private let terminalObserver: TerminalObserver
	private var preReadyInboundEvents: [WebRTCInboundEvent] = []

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel, signalingClient: WebRTCSignalingClient, terminalObserver: TerminalObserver) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		self.signalingClient = signalingClient
		self.terminalObserver = terminalObserver
		generation = lifecycle.begin()
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCInboundEvent.self)
		(qualificationEvents, qualificationStream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorQualificationEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
	}

	package func connect(using signaling: WebRTCSignalingRequest) async throws {
		guard connection.connectionState == .new else { return }

		do {
			let localSDP = try await makeOffer()
			let remoteSDP = try await fetchRemoteSDP(using: signaling, localSdp: localSDP)
			try await apply(answer: remoteSDP)
		} catch {
			disconnect()
			throw error
		}
	}

	@_spi(AirbridgeQualification) public func makeOffer() async throws -> String {
		guard connection.connectionState == .new else { throw WebRTCTransportFailure.cancelled }
		guard AVAudioApplication.shared.recordPermission == .granted else {
			disconnect()
			throw WebRTCError.missingAudioPermission
		}
		let sdp: LKRTCSessionDescription
		do {
			sdp = try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil))
		} catch {
			throw WebRTCError.failedToCreateSDPOffer(error)
		}
		guard lifecycle.isCurrent(generation) else { throw WebRTCTransportFailure.cancelled }

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }
		guard lifecycle.isCurrent(generation), let localSDP = connection.localDescription?.sdp else {
			throw WebRTCTransportFailure.cancelled
		}
		return localSDP
	}

	@_spi(AirbridgeQualification) public func apply(answer: String) async throws {
		guard lifecycle.isCurrent(generation) else { throw WebRTCTransportFailure.cancelled }
		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
		guard lifecycle.isCurrent(generation) else { throw WebRTCTransportFailure.cancelled }
		Self.configureAudioSession()
	}

	package func installSignalingTask(_ task: Task<String, Error>) -> Bool {
		lifecycle.installSignalingTask(task, for: generation)
	}

	public func send(event: ClientEvent) throws {
		guard lifecycle.isCurrent(generation) else { throw WebRTCTransportFailure.cancelled }
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	public func disconnect() {
		finish()
	}

	private func finish(_ error: (any Error)? = nil) {
		guard lifecycle.markTerminal(generation) else { return }
		status = .disconnected
		terminalObserver.cancelSignaling()
		lifecycle.cancelSignalingTask()
		dataChannel.close()
		terminalObserver.closeData()
		connection.close()
		terminalObserver.closePeer()
		audioTrack.isEnabled = false
		terminalObserver.disableAudio()
		Self.deactivateAudioSession()
		preReadyInboundEvents.removeAll()
		if error == nil {
			qualificationStream.yield(.terminal)
		}
		qualificationStream.finish(throwing: error)
		stream.finish(throwing: error)
	}

	public func toggleMute() {
		guard lifecycle.isCurrent(generation) else { return }
		audioTrack.isEnabled.toggle()
	}
}

extension WebRTCConnector {
	public static func create(connectingTo signaling: WebRTCSignalingRequest, session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession()) async throws -> WebRTCConnector {
		let connector = try create(session: session)
		try await connector.connect(using: signaling)
		return connector
	}

	package static func create(session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession(), terminalObserver: TerminalObserver = .none) throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel, signalingClient: WebRTCSignalingClient(session: session), terminalObserver: terminalObserver)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	static func configureAudioSession() {
		#if !os(macOS)
		do {
			let audioSession = AVAudioSession.sharedInstance()
			#if os(tvOS)
			try audioSession.setCategory(.playAndRecord, options: [])
			#else
			try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
			#endif
			try audioSession.setMode(.videoChat)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {}
		#endif
	}

	static func deactivateAudioSession() {
		#if !os(macOS)
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		#endif
	}

	private func fetchRemoteSDP(using signaling: WebRTCSignalingRequest, localSdp: String) async throws -> String {
		let task = Task { [signalingClient] in
			try await signalingClient.answer(for: signaling.makeRequest(localSDP: localSdp)).sdp
		}
		guard installSignalingTask(task) else {
			task.cancel()
			throw WebRTCTransportFailure.cancelled
		}
		defer { lifecycle.clearSignalingTask(for: generation) }
		return try await withTaskCancellationHandler {
			let sdp = try await task.value
			guard lifecycle.isCurrent(generation) else { throw WebRTCTransportFailure.cancelled }
			return sdp
		} onCancel: {
			task.cancel()
		}
	}
}

// LiveKit's delegate protocols predate actor annotations. The imported callbacks enter
// nonisolated and capture only scalar/Data values; each explicitly hops to MainActor.
extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	nonisolated public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		let terminal = newState == .closed || newState == .disconnected
		Task { @MainActor [weak self, terminal] in self?.receivePeerState(terminal: terminal) }
	}

	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
		let terminal = newState == .failed || newState == .closed || newState == .disconnected
		Task { @MainActor [weak self, terminal] in self?.receivePeerState(terminal: terminal) }
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	nonisolated public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		let data = buffer.data
		Task { @MainActor [weak self, data] in self?.receiveInbound(data) }
	}

	nonisolated public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		let isOpen = dataChannel.readyState == .open
		let isTerminal = dataChannel.readyState == .closing || dataChannel.readyState == .closed
		Task { @MainActor [weak self, isOpen, isTerminal] in self?.receiveDataChannelState(isOpen: isOpen, isTerminal: isTerminal) }
	}
}

extension WebRTCConnector {
	private func receivePeerState(terminal: Bool) {
		guard lifecycle.isCurrent(generation) else { return }
		if terminal { finish() }
	}

	package func receiveInbound(_ data: Data) {
		guard lifecycle.isCurrent(generation) else { return }
		do {
			let inboundEvent = try inboundEventDecoder.decode(data)
			if inboundEvent == .providerError {
				finish(WebRTCTransportFailure.providerError)
				return
			}
			guard lifecycle.isCurrent(generation) else { return }
			guard status == .connected else {
				guard preReadyInboundEvents.isEmpty else {
					finish(WebRTCTransportFailure.malformedEvent)
					return
				}
				preReadyInboundEvents = [inboundEvent]
				return
			}
			yieldInbound(inboundEvent)
		}
		catch let failure as WebRTCTransportFailure {
			finish(failure)
		} catch {
			finish(WebRTCTransportFailure.malformedEvent)
		}
	}

	private func receiveDataChannelState(isOpen: Bool, isTerminal: Bool) {
		guard lifecycle.isCurrent(generation) else { return }
		if isOpen {
			guard lifecycle.isCurrent(generation) else { return }
			guard status != .connected else { return }
			status = .connected
			qualificationStream.yield(.connected)
			let bufferedEvents = preReadyInboundEvents
			preReadyInboundEvents.removeAll()
			bufferedEvents.forEach(yieldInbound)
		} else if isTerminal {
			finish()
		}
	}

	private func yieldInbound(_ event: WebRTCInboundEvent) {
		qualificationStream.yield(.inbound(event))
		stream.yield(event)
	}
}
