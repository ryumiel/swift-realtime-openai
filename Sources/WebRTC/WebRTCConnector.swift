import Core
import AVFAudio
import Foundation
import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor @Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	private enum DeliveryMode { case ordinary, qualification }
	private final class TerminalGate: @unchecked Sendable {
		private let lock = NSLock()
		private enum State {
			case open(acceptedIngress: Int)
			case closing(
				failure: WebRTCTransportFailure?,
				acceptedFailureSelected: Bool,
				acceptedIngress: Int,
				task: Task<Void, Never>?,
				waiter: CheckedContinuation<WebRTCTransportFailure?, Never>?
			)
			case settled(WebRTCTransportFailure?)
		}
		private var state: State = .open(acceptedIngress: 0)
		private var openTransitionPending = false

		func acceptIngress(
			_ data: Data,
			with continuation: AsyncThrowingStream<Data, Error>.Continuation,
			connector: WebRTCConnector
		) {
			lock.withLock {
				guard case let .open(acceptedIngress) = state else { return }
				switch continuation.yield(data) {
				case .enqueued:
					state = .open(acceptedIngress: acceptedIngress + 1)
					return
				case .dropped, .terminated:
					_ = requestLocked(.ingressOverloaded, acceptedFailureSelected: false, connector: connector)
				@unknown default:
					_ = requestLocked(.ingressOverloaded, acceptedFailureSelected: false, connector: connector)
				}
			}
		}

		func request(_ failure: WebRTCTransportFailure?, connector: WebRTCConnector) -> Task<Void, Never>? {
			lock.withLock { requestLocked(failure, acceptedFailureSelected: false, connector: connector) }
		}

		func acceptOpenTransition() -> Bool {
			lock.withLock {
				guard !openTransitionPending else { return false }
				guard case let .open(acceptedIngress) = state else { return false }
				openTransitionPending = true
				state = .open(acceptedIngress: acceptedIngress + 1)
				return true
			}
		}

		func openTransitionDidDrain() {
			var resume: (CheckedContinuation<WebRTCTransportFailure?, Never>, WebRTCTransportFailure?)?
			lock.withLock {
				guard openTransitionPending else { return }
				openTransitionPending = false
				switch state {
				case let .open(acceptedIngress):
					state = .open(acceptedIngress: max(0, acceptedIngress - 1))
				case let .closing(failure, acceptedFailureSelected, acceptedIngress, task, waiter):
					let remaining = max(0, acceptedIngress - 1)
					state = .closing(
						failure: failure,
						acceptedFailureSelected: acceptedFailureSelected,
						acceptedIngress: remaining,
						task: task,
						waiter: remaining == 0 ? nil : waiter
					)
					if remaining == 0, let waiter { resume = (waiter, failure) }
				case .settled:
					break
				}
			}
			resume?.0.resume(returning: resume?.1)
		}

		func shouldProcessAcceptedIngress() -> Bool {
			lock.withLock {
				switch state {
				case .open:
					return true
				case let .closing(_, acceptedFailureSelected, _, _, _):
					return !acceptedFailureSelected
				case .settled:
					return false
				}
			}
		}

		func requestFromAcceptedIngress(_ failure: WebRTCTransportFailure, connector: WebRTCConnector) -> Task<Void, Never>? {
			lock.withLock {
				switch state {
				case let .closing(_, acceptedFailureSelected, acceptedIngress, task, waiter):
					guard !acceptedFailureSelected else { return task }
					state = .closing(
						failure: failure,
						acceptedFailureSelected: true,
						acceptedIngress: acceptedIngress,
						task: task,
						waiter: waiter
					)
					return task
				case .open:
					return requestLocked(failure, acceptedFailureSelected: true, connector: connector)
				case .settled:
					return nil
				}
			}
		}

		func acceptedIngressDidDrain() {
			var resume: (CheckedContinuation<WebRTCTransportFailure?, Never>, WebRTCTransportFailure?)?
			lock.withLock {
				switch state {
				case let .open(acceptedIngress):
					state = .open(acceptedIngress: max(0, acceptedIngress - 1))
				case let .closing(failure, acceptedFailureSelected, acceptedIngress, task, waiter):
					let remaining = max(0, acceptedIngress - 1)
					state = .closing(
						failure: failure,
						acceptedFailureSelected: acceptedFailureSelected,
						acceptedIngress: remaining,
						task: task,
						waiter: remaining == 0 ? nil : waiter
					)
					if remaining == 0, let waiter { resume = (waiter, failure) }
				case .settled:
					break
				}
			}
			resume?.0.resume(returning: resume?.1)
		}

		func markSettled() {
			lock.withLock {
				if case let .closing(failure, _, _, _, _) = state { state = .settled(failure) }
			}
		}

		private func failureAfterAcceptedIngressDrains() async -> WebRTCTransportFailure? {
			await withCheckedContinuation { continuation in
				var immediate: WebRTCTransportFailure??
				lock.withLock {
					switch state {
					case let .closing(failure, acceptedFailureSelected, 0, task, _):
						state = .closing(failure: failure, acceptedFailureSelected: acceptedFailureSelected, acceptedIngress: 0, task: task, waiter: nil)
						immediate = .some(failure)
					case let .closing(failure, acceptedFailureSelected, acceptedIngress, task, nil):
						state = .closing(
							failure: failure,
							acceptedFailureSelected: acceptedFailureSelected,
							acceptedIngress: acceptedIngress,
							task: task,
							waiter: continuation
						)
					case .closing:
						preconditionFailure("Terminal settlement waiter installed twice")
					case .open, .settled:
						preconditionFailure("Terminal settlement started outside closing state")
					}
				}
				if let immediate { continuation.resume(returning: immediate) }
			}
		}

		private func requestLocked(
			_ failure: WebRTCTransportFailure?,
			acceptedFailureSelected: Bool,
			connector: WebRTCConnector
		) -> Task<Void, Never>? {
			switch state {
			case let .open(acceptedIngress):
				let gate = self
				state = .closing(failure: failure, acceptedFailureSelected: acceptedFailureSelected, acceptedIngress: acceptedIngress, task: nil, waiter: nil)
				let task = Task { @MainActor [connector, gate] in
					let selectedFailure = await gate.failureAfterAcceptedIngressDrains()
					await connector.completeTerminal(selectedFailure)
				}
				state = .closing(
					failure: failure,
					acceptedFailureSelected: acceptedFailureSelected,
					acceptedIngress: acceptedIngress,
					task: task,
					waiter: nil
				)
				return task
			case let .closing(_, _, _, task?, _):
				return task
			case .closing:
				preconditionFailure("Terminal settlement task was not installed")
			case .settled:
				return nil
			}
		}
	}
	@MainActor package struct TerminalObserver {
		let cancelSignaling: () -> Void
		let closeData: () -> Void
		let closePeer: () -> Void
		let disableAudio: () -> Void
		let beforeDrainInbound: () async -> Void
		let beforeOpenTransition: () async -> Void
		let makePreReadyRetentionToken: () -> AnyObject?
		let didDrainInbound: () -> Void
		let didRetireAcceptedIngress: () -> Void
		let didSettle: () -> Void

		package init(
			cancelSignaling: @escaping () -> Void,
			closeData: @escaping () -> Void,
			closePeer: @escaping () -> Void,
			disableAudio: @escaping () -> Void,
			beforeDrainInbound: @escaping () async -> Void = {},
			beforeOpenTransition: @escaping () async -> Void = {},
			makePreReadyRetentionToken: @escaping () -> AnyObject? = { nil },
			didDrainInbound: @escaping () -> Void = {},
			didRetireAcceptedIngress: @escaping () -> Void = {},
			didSettle: @escaping () -> Void = {}
		) {
			self.cancelSignaling = cancelSignaling
			self.closeData = closeData
			self.closePeer = closePeer
			self.disableAudio = disableAudio
			self.beforeDrainInbound = beforeDrainInbound
			self.beforeOpenTransition = beforeOpenTransition
			self.makePreReadyRetentionToken = makePreReadyRetentionToken
			self.didDrainInbound = didDrainInbound
			self.didRetireAcceptedIngress = didRetireAcceptedIngress
			self.didSettle = didSettle
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
	private let deliveryMode: DeliveryMode
	private let ingressEvents: AsyncThrowingStream<Data, Error>
	nonisolated private let ingressStream: AsyncThrowingStream<Data, Error>.Continuation
	private var ingressDrainTask: Task<Void, Never>?
	nonisolated private let terminalGate = TerminalGate()
	private struct PreReadyInboundEvent {
		let event: WebRTCInboundEvent
		let retentionToken: AnyObject?
	}
	private var preReadyInboundEvents: [PreReadyInboundEvent] = []

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel, signalingClient: WebRTCSignalingClient, terminalObserver: TerminalObserver, deliveryMode: DeliveryMode) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		self.signalingClient = signalingClient
		self.terminalObserver = terminalObserver
		self.deliveryMode = deliveryMode
		generation = lifecycle.begin()
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCInboundEvent.self, bufferingPolicy: .bufferingOldest(0))
		(qualificationEvents, qualificationStream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorQualificationEvent.self, bufferingPolicy: .bufferingOldest(2))
		(ingressEvents, ingressStream) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(1))

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
		let ingressEvents = ingressEvents
		ingressDrainTask = Task { [weak self, ingressEvents] in
			do {
				for try await data in ingressEvents {
					guard !Task.isCancelled else { return }
					await self?.drainInbound(data)
				}
			} catch {}
		}
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
		try await Self.waitForLocalICEGathering(
			isCurrent: { self.lifecycle.isCurrent(self.generation) },
			isComplete: { self.connection.iceGatheringState == .complete }
		)
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
		requestTerminal()
	}

	@_spi(AirbridgeQualification) public func closeAndSettle() async {
		await requestTerminal()?.value
		guard deliveryMode == .qualification else { return }
		var iterator = qualificationEvents.makeAsyncIterator()
		do {
			while try await iterator.next() != nil {}
		} catch {}
	}

	@discardableResult
	private func requestTerminal(_ failure: WebRTCTransportFailure? = nil) -> Task<Void, Never>? {
		terminalGate.request(failure, connector: self)
	}

	private func completeTerminal(_ requestedFailure: WebRTCTransportFailure?) async {
		let failure = requestedFailure
		guard lifecycle.markTerminal(generation) else {
			terminalGate.markSettled()
			return
		}
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
		ingressStream.finish(throwing: failure)
		let drain = ingressDrainTask
		ingressDrainTask = nil
		drain?.cancel()
		if failure == nil, deliveryMode == .qualification {
			switch qualificationStream.yield(.terminal) {
			case .dropped, .terminated:
				qualificationStream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
			case .enqueued:
				qualificationStream.finish()
			@unknown default:
				qualificationStream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
			}
		} else {
			qualificationStream.finish(throwing: failure)
		}
		stream.finish(throwing: failure)
		await drain?.value
		terminalGate.markSettled()
		terminalObserver.didSettle()
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
		try create(session: session, terminalObserver: terminalObserver, deliveryMode: .ordinary)
	}

	@_spi(AirbridgeQualification) public static func createQualification(session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession()) throws -> WebRTCConnector {
		try create(session: session, terminalObserver: .none, deliveryMode: .qualification)
	}

	package static func createQualification(session: any WebRTCSignalingSession, terminalObserver: TerminalObserver) throws -> WebRTCConnector {
		try create(session: session, terminalObserver: terminalObserver, deliveryMode: .qualification)
	}

	private static func create(session: any WebRTCSignalingSession, terminalObserver: TerminalObserver, deliveryMode: DeliveryMode) throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel, signalingClient: WebRTCSignalingClient(session: session), terminalObserver: terminalObserver, deliveryMode: deliveryMode)
	}
}

	extension WebRTCConnector {
	/// Keep the non-trickle SDP exchange self-contained. `localDescription` gains
	/// host candidates asynchronously after `setLocalDescription`; submitting its
	/// initial snapshot can leave the remote peer with no usable candidate.
	package static func waitForLocalICEGathering(
		maximumChecks: Int = 50,
		isCurrent: @escaping @MainActor () -> Bool,
		isComplete: @escaping @MainActor () -> Bool,
		sleep: @escaping @MainActor () async throws -> Void = {
			try await Task.sleep(for: .milliseconds(100))
		}
	) async throws {
		for _ in 0..<maximumChecks {
			guard isCurrent() else {
				throw WebRTCTransportFailure.cancelled
			}
			guard !isComplete() else { return }
			try await sleep()
		}
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
		if terminal { _ = terminalGate.request(nil, connector: self) }
	}

	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
		let terminal = newState == .failed || newState == .closed || newState == .disconnected
		if terminal { _ = terminalGate.request(nil, connector: self) }
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	nonisolated public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		receiveInbound(buffer.data)
	}

	nonisolated public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		let isOpen = dataChannel.readyState == .open
		let isTerminal = dataChannel.readyState == .closing || dataChannel.readyState == .closed
		if isTerminal {
			_ = terminalGate.request(nil, connector: self)
		} else if isOpen {
			scheduleOpenTransition()
		}
	}
}

extension WebRTCConnector {
	@_spi(AirbridgeQualification) nonisolated public func scheduleOpenTransitionForQualification() {
		scheduleOpenTransition()
	}

	nonisolated private func scheduleOpenTransition() {
		let gate = terminalGate
		guard gate.acceptOpenTransition() else { return }
		Task { @MainActor [weak self, gate] in
			defer { gate.openTransitionDidDrain() }
			await self?.terminalObserver.beforeOpenTransition()
			guard gate.shouldProcessAcceptedIngress() else { return }
			self?.receiveDataChannelState(
				isOpen: true,
				isTerminal: false,
				fromAcceptedIngress: true
			)
		}
	}

	nonisolated package func receiveInbound(_ data: Data) {
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			_ = terminalGate.request(.eventTooLarge, connector: self)
			return
		}
		terminalGate.acceptIngress(data, with: ingressStream, connector: self)
	}

	private func drainInbound(_ data: Data) async {
		defer {
			terminalGate.acceptedIngressDidDrain()
			terminalObserver.didRetireAcceptedIngress()
		}
		guard terminalGate.shouldProcessAcceptedIngress() else { return }
		guard lifecycle.isCurrent(generation) else { return }
		await terminalObserver.beforeDrainInbound()
		guard terminalGate.shouldProcessAcceptedIngress() else { return }
		guard lifecycle.isCurrent(generation) else { return }
		terminalObserver.didDrainInbound()
		do {
			guard let inboundEvent = try inboundEventDecoder.decodeForConnector(data) else { return }
			if inboundEvent == .providerError {
				requestTerminalFromAcceptedIngress(WebRTCTransportFailure.providerError)
				return
			}
			guard lifecycle.isCurrent(generation) else { return }
			guard status == .connected else {
				guard preReadyInboundEvents.isEmpty else {
					requestTerminalFromAcceptedIngress(WebRTCTransportFailure.malformedEvent)
					return
				}
				preReadyInboundEvents = [PreReadyInboundEvent(
					event: inboundEvent,
					retentionToken: terminalObserver.makePreReadyRetentionToken()
				)]
				return
			}
			yieldInbound(inboundEvent)
		}
		catch let failure as WebRTCTransportFailure {
			requestTerminalFromAcceptedIngress(failure)
		} catch {
			requestTerminalFromAcceptedIngress(WebRTCTransportFailure.malformedEvent)
		}
	}

	private func requestTerminalFromAcceptedIngress(_ failure: WebRTCTransportFailure) {
		_ = terminalGate.requestFromAcceptedIngress(failure, connector: self)
	}

	package func receiveDataChannelState(
		isOpen: Bool,
		isTerminal: Bool,
		fromAcceptedIngress: Bool = false
	) {
		guard lifecycle.isCurrent(generation) else { return }
		if isOpen {
			guard lifecycle.isCurrent(generation) else { return }
			guard status != .connected else { return }
			status = .connected
			if deliveryMode == .qualification {
				yieldQualification(.connected, fromAcceptedIngress: fromAcceptedIngress)
			}
			if fromAcceptedIngress, !terminalGate.shouldProcessAcceptedIngress() { return }
			let bufferedEvents = preReadyInboundEvents
			preReadyInboundEvents.removeAll()
			bufferedEvents.forEach { yieldInbound($0.event) }
		} else if isTerminal {
			requestTerminal()
		}
	}

	private func yieldInbound(_ event: WebRTCInboundEvent) {
		switch deliveryMode {
		case .ordinary:
			switch stream.yield(event) {
			case .dropped, .terminated: requestTerminalFromAcceptedIngress(WebRTCTransportFailure.ingressOverloaded)
			case .enqueued: break
			@unknown default: requestTerminalFromAcceptedIngress(WebRTCTransportFailure.ingressOverloaded)
			}
		case .qualification: yieldQualification(.inbound(event), fromAcceptedIngress: true)
		}
	}

	private func yieldQualification(_ event: WebRTCConnectorQualificationEvent, fromAcceptedIngress: Bool = false) {
		switch qualificationStream.yield(event) {
		case .dropped, .terminated:
			if fromAcceptedIngress {
				requestTerminalFromAcceptedIngress(WebRTCTransportFailure.ingressOverloaded)
			} else {
				requestTerminal(WebRTCTransportFailure.ingressOverloaded)
			}
		case .enqueued:
			break
		@unknown default:
			if fromAcceptedIngress {
				requestTerminalFromAcceptedIngress(WebRTCTransportFailure.ingressOverloaded)
			} else {
				requestTerminal(WebRTCTransportFailure.ingressOverloaded)
			}
		}
	}
}
