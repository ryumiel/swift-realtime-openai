import Core
import AVFAudio
import Foundation
import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProductionRemoteAudioAdmissionGate: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
	private static let trackCapacity = 1
	private let condition = NSCondition()
	private var enabled: Bool
	private var closed = false
	private var tracks: [LKRTCMediaStreamTrack] = []
	private var admittedCallbacks = 0
	private let attemptedFrame: @Sendable () -> Void
	private let admittedFrame: @Sendable () -> Void

	init(
		initiallyEnabled: Bool,
		attemptedFrame: @escaping @Sendable () -> Void = {},
		admittedFrame: @escaping @Sendable () -> Void = {}
	) {
		enabled = initiallyEnabled
		self.attemptedFrame = attemptedFrame
		self.admittedFrame = admittedFrame
	}

	func setEnabled(_ enabled: Bool) {
		condition.withLock {
			guard !closed else { return }
			self.enabled = enabled
			tracks.forEach { $0.isEnabled = enabled }
		}
	}

	func register(_ candidates: [LKRTCMediaStreamTrack]) {
		condition.withLock {
			if closed {
				candidates.filter { $0.kind == "audio" }.forEach { $0.isEnabled = false }
				return
			}
			for track in candidates where track.kind == "audio" && !tracks.contains(where: { $0.isEqual(track) }) {
				if tracks.count < Self.trackCapacity {
					track.isEnabled = enabled
					tracks.append(track)
					(track as? LKRTCAudioTrack)?.add(self)
				} else { track.isEnabled = false }
			}
		}
	}

	func unregister(_ candidates: [LKRTCMediaStreamTrack]) {
		condition.withLock {
			for candidate in candidates where candidate.kind == "audio" {
				let retained = tracks.filter { $0.isEqual(candidate) }
				retained.forEach {
					$0.isEnabled = false
					($0 as? LKRTCAudioTrack)?.remove(self)
				}
				tracks.removeAll { $0.isEqual(candidate) }
			}
		}
	}

	func deliverIfAdmitted(_ delivery: () -> Void) {
		let admitted = condition.withLock { () -> Bool in
			guard !closed, enabled else { return false }
			admittedCallbacks += 1
			return true
		}
		guard admitted else { return }
		delivery()
		condition.withLock {
			admittedCallbacks = max(0, admittedCallbacks - 1)
			if admittedCallbacks == 0 { condition.broadcast() }
		}
	}

	func render(pcmBuffer _: AVAudioPCMBuffer) {
		attemptedFrame()
		deliverIfAdmitted(admittedFrame)
	}

	func close() {
		condition.lock()
		closed = true
		enabled = false
		tracks.forEach { $0.isEnabled = false }
		while admittedCallbacks != 0 { condition.wait() }
		condition.unlock()
	}

	func releaseTracks() {
		condition.withLock {
			closed = true
			enabled = false
			tracks.forEach {
				$0.isEnabled = false
				($0 as? LKRTCAudioTrack)?.remove(self)
			}
			tracks.removeAll(keepingCapacity: false)
		}
	}
}

private final class ProductionMediaCloser: @unchecked Sendable {
	private let lock = NSLock()
	private let localTrack: LKRTCAudioTrack
	private let remoteGate: ProductionRemoteAudioAdmissionGate?
	private let didDisable: () -> Void
	private var closed = false

	init(localTrack: LKRTCAudioTrack, remoteGate: ProductionRemoteAudioAdmissionGate?, didDisable: @escaping () -> Void) {
		self.localTrack = localTrack
		self.remoteGate = remoteGate
		self.didDisable = didDisable
	}

	func set(_ state: WebRTCLocalAudioState) {
		lock.withLock {
			guard !closed else { return }
			localTrack.isEnabled = state == .enabled
			remoteGate?.setEnabled(state == .enabled)
		}
	}

	func close() {
		let didClose = lock.withLock { () -> Bool in
			guard !closed else { return false }
			closed = true
			localTrack.isEnabled = false
			remoteGate?.close()
			return true
		}
		if didClose { didDisable() }
	}

	func releaseRemoteTracks() { remoteGate?.releaseTracks() }
}

@_spi(AirbridgeQualification) @MainActor @Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	private enum DeliveryMode { case ordinary, production, qualification }
	/// Terminal states describe teardown progress and remain observable after a
	/// winner is selected. Every other native category is connection progression
	/// and must be admitted while the terminal gate is still open.
	private enum NativeDiagnosticAdmission {
		case progression
		case terminal
	}
	/// A bounded best-effort boundary for content-free diagnostics. Its detached
	/// worker is deliberately independent from connector settlement: a sink is
	/// allowed to be slow, but it cannot retain the connector or delay cleanup.
	private final class DiagnosticDispatcher: @unchecked Sendable {
		private static let capacity = 32
		private struct Pending {
			let ticket: Int
			let milestone: WebRTCConnectorDiagnosticMilestone
			var isReady = false
		}
		private let lock = NSLock()
		private let sink: @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void
		private var pending: [Pending] = []
		private var nextTicket = 0
		private var isDraining = false
		private var isClosed = false

		init(sink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void) {
			self.sink = sink
		}

		func submit(_ milestone: WebRTCConnectorDiagnosticMilestone) {
			guard let ticket = reserve(milestone, closing: false) else { return }
			activate(ticket)
		}

		/// Delegate callbacks reserve source order before crossing to MainActor.
		/// The dispatcher keeps those accepted static categories alive through
		/// terminal cleanup even if MainActor receives the hops out of order.
		func submitFromDelegate(_ milestone: WebRTCConnectorDiagnosticMilestone) {
			guard let ticket = reserve(milestone, closing: false) else { return }
			let dispatcher = self
			Task { @MainActor in dispatcher.activate(ticket) }
		}

		/// Atomically accepts completion before rejecting every subsequent native
		/// callback. Completion may be dropped if a blocked sink filled the fixed
		/// queue; diagnostics never influence terminal settlement.
		func submitAndClose(_ milestone: WebRTCConnectorDiagnosticMilestone) {
			guard let ticket = reserve(milestone, closing: true) else { return }
			activate(ticket)
		}

		private func reserve(_ milestone: WebRTCConnectorDiagnosticMilestone, closing: Bool) -> Int? {
			lock.withLock {
				guard !isClosed else { return nil }
				defer { if closing { isClosed = true } }
				guard pending.count < Self.capacity else { return nil }
				let ticket = nextTicket
				nextTicket += 1
				pending.append(Pending(ticket: ticket, milestone: milestone))
				return ticket
			}
		}

		private func activate(_ ticket: Int) {
			let shouldStart = lock.withLock { () -> Bool in
				guard let index = pending.firstIndex(where: { $0.ticket == ticket }) else { return false }
				pending[index].isReady = true
				guard pending.first?.isReady == true, !isDraining else { return false }
				isDraining = true
				return true
			}
			if shouldStart { scheduleDrain() }
		}

		private func scheduleDrain() {
			Task.detached { [self] in
				while let milestone = next() { sink(milestone) }
			}
		}

		private func next() -> WebRTCConnectorDiagnosticMilestone? {
			lock.withLock { () -> WebRTCConnectorDiagnosticMilestone? in
				if let first = pending.first, first.isReady { return pending.removeFirst().milestone }
				isDraining = false
				return nil
			}
		}
	}

	private struct AcceptedRawInbound: Sendable {
		let data: Data
		let configurationDispatchedAtAcceptance: Bool
	}

	private final class TerminalGate: @unchecked Sendable {
		private let lock = NSLock()
		private enum RequestReservation {
			case start
			case existing(Task<Void, Never>)
			case pending
			case settled
		}
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
		private var productionConfigurationDispatched = false
		private var settlementTaskWaiters: [CheckedContinuation<Task<Void, Never>?, Never>] = []

		func acceptIngress(
			_ data: Data,
			with continuation: AsyncThrowingStream<AcceptedRawInbound, Error>.Continuation,
			connector: WebRTCConnector
		) {
			let closesProductionMedia = connector.requiresSynchronousProductionMediaClosure
			let reservation = lock.withLock { () -> RequestReservation? in
				guard case let .open(acceptedIngress) = state else { return nil }
				let accepted = AcceptedRawInbound(
					data: data,
					configurationDispatchedAtAcceptance: productionConfigurationDispatched
				)
				switch continuation.yield(accepted) {
				case .enqueued:
					state = .open(acceptedIngress: acceptedIngress + 1)
					return nil
				case .dropped, .terminated:
					return reserveLocked(.ingressOverloaded, acceptedFailureSelected: closesProductionMedia)
				@unknown default:
					return reserveLocked(.ingressOverloaded, acceptedFailureSelected: closesProductionMedia)
				}
			}
			guard let reservation else { return }
			connector.terminalObserver.didReserveIngressOverload()
			_ = finish(reservation, closesProductionMedia: closesProductionMedia, connector: connector)
		}

		func markProductionConfigurationDispatched() -> Bool {
			lock.withLock {
				guard case .open = state else { return false }
				productionConfigurationDispatched = true
				return true
			}
		}

		func request(_ failure: WebRTCTransportFailure?, connector: WebRTCConnector) -> Task<Void, Never>? {
			let closesProductionMedia = connector.requiresSynchronousProductionMediaClosure
			let reservation = lock.withLock {
				reserveLocked(failure, acceptedFailureSelected: closesProductionMedia)
			}
			return finish(reservation, closesProductionMedia: closesProductionMedia, connector: connector)
		}

		func acceptsProgression() -> Bool {
			lock.withLock {
				if case .open = state { return true }
				return false
			}
		}

		func admitProgression(_ accepted: () -> Void) -> Bool {
			lock.withLock {
				guard case .open = state else { return false }
				accepted()
				return true
			}
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
			let closesProductionMedia = connector.requiresSynchronousProductionMediaClosure
			let reservation = lock.withLock { () -> RequestReservation in
				switch state {
				case let .closing(_, acceptedFailureSelected, acceptedIngress, task, waiter):
					guard !acceptedFailureSelected else {
						if let task { return .existing(task) }
						return .pending
					}
					state = .closing(
						failure: failure,
						acceptedFailureSelected: true,
						acceptedIngress: acceptedIngress,
						task: task,
						waiter: waiter
					)
					if let task { return .existing(task) }
					return .pending
				case .open:
					return reserveLocked(failure, acceptedFailureSelected: true)
				case .settled:
					return .settled
				}
			}
			return finish(reservation, closesProductionMedia: closesProductionMedia, connector: connector)
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
			var taskWaiters: [CheckedContinuation<Task<Void, Never>?, Never>] = []
			lock.withLock {
				if case let .closing(failure, _, _, _, _) = state { state = .settled(failure) }
				taskWaiters = settlementTaskWaiters
				settlementTaskWaiters.removeAll(keepingCapacity: false)
			}
			taskWaiters.forEach { $0.resume(returning: nil) }
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

		private func reserveLocked(
			_ failure: WebRTCTransportFailure?,
			acceptedFailureSelected: Bool
		) -> RequestReservation {
			switch state {
			case let .open(acceptedIngress):
				state = .closing(failure: failure, acceptedFailureSelected: acceptedFailureSelected, acceptedIngress: acceptedIngress, task: nil, waiter: nil)
				return .start
			case let .closing(_, _, _, task?, _):
				return .existing(task)
			case .closing:
				return .pending
			case .settled:
				return .settled
			}
		}

		private func finish(
			_ reservation: RequestReservation,
			closesProductionMedia: Bool,
			connector: WebRTCConnector
		) -> Task<Void, Never>? {
			switch reservation {
			case .start:
				if closesProductionMedia { _ = connector.closeProductionMediaSynchronously() }
				let gate = self
				Task { @MainActor [weak connector] in connector?.resumeProductionReadinessForTerminal() }
				let task = Task { @MainActor [connector, gate] in
					let selectedFailure = await gate.failureAfterAcceptedIngressDrains()
					await connector.completeTerminal(selectedFailure)
				}
				install(task)
				return task
			case let .existing(task):
				return task
			case .pending:
				return Task { await self.joinPendingSettlement() }
			case .settled:
				return nil
			}
		}

		private func install(_ task: Task<Void, Never>) {
			var taskWaiters: [CheckedContinuation<Task<Void, Never>?, Never>] = []
			lock.withLock {
				switch state {
				case let .closing(failure, acceptedFailureSelected, acceptedIngress, nil, waiter):
					state = .closing(
						failure: failure,
						acceptedFailureSelected: acceptedFailureSelected,
						acceptedIngress: acceptedIngress,
						task: task,
						waiter: waiter
					)
				case .closing, .settled:
					break
				case .open:
					preconditionFailure("Terminal settlement task installed before selection")
				}
				taskWaiters = settlementTaskWaiters
				settlementTaskWaiters.removeAll(keepingCapacity: false)
			}
			taskWaiters.forEach { $0.resume(returning: task) }
		}

		private func joinPendingSettlement() async {
			let task = await withCheckedContinuation { continuation in
				var immediate: Task<Void, Never>??
				lock.withLock {
					switch state {
					case let .closing(_, _, _, task?, _): immediate = .some(task)
					case .closing: settlementTaskWaiters.append(continuation)
					case .settled: immediate = .some(nil)
					case .open: preconditionFailure("Terminal join requested before selection")
					}
				}
				if let immediate { continuation.resume(returning: immediate) }
			}
			await task?.value
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
		let recordPermissionGranted: () -> Bool
		let waitForLocalICEGathering: (@MainActor () async throws -> Void)?
		let didDrainInbound: () -> Void
		let didRetireAcceptedIngress: () -> Void
		let didSettle: () -> Void
		let didReserveIngressOverload: @Sendable () -> Void
		let didAttemptRemoteAudioFrame: @Sendable () -> Void
		let didAdmitRemoteAudioFrame: @Sendable () -> Void

		package init(
			cancelSignaling: @escaping () -> Void,
			closeData: @escaping () -> Void,
			closePeer: @escaping () -> Void,
			disableAudio: @escaping () -> Void,
			beforeDrainInbound: @escaping () async -> Void = {},
			beforeOpenTransition: @escaping () async -> Void = {},
			makePreReadyRetentionToken: @escaping () -> AnyObject? = { nil },
			recordPermissionGranted: @escaping () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
			waitForLocalICEGathering: (@MainActor () async throws -> Void)? = nil,
			didDrainInbound: @escaping () -> Void = {},
			didRetireAcceptedIngress: @escaping () -> Void = {},
			didSettle: @escaping () -> Void = {},
			didReserveIngressOverload: @escaping @Sendable () -> Void = {},
			didAttemptRemoteAudioFrame: @escaping @Sendable () -> Void = {},
			didAdmitRemoteAudioFrame: @escaping @Sendable () -> Void = {}
		) {
			self.cancelSignaling = cancelSignaling
			self.closeData = closeData
			self.closePeer = closePeer
			self.disableAudio = disableAudio
			self.beforeDrainInbound = beforeDrainInbound
			self.beforeOpenTransition = beforeOpenTransition
			self.makePreReadyRetentionToken = makePreReadyRetentionToken
			self.recordPermissionGranted = recordPermissionGranted
			self.waitForLocalICEGathering = waitForLocalICEGathering
			self.didDrainInbound = didDrainInbound
			self.didRetireAcceptedIngress = didRetireAcceptedIngress
			self.didSettle = didSettle
			self.didReserveIngressOverload = didReserveIngressOverload
			self.didAttemptRemoteAudioFrame = didAttemptRemoteAudioFrame
			self.didAdmitRemoteAudioFrame = didAdmitRemoteAudioFrame
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
	nonisolated private let remoteAudioGate: ProductionRemoteAudioAdmissionGate?
	nonisolated private let productionMediaCloser: ProductionMediaCloser
	nonisolated private let productionSession: WebRTCSessionProvider?

	private let stream: AsyncThrowingStream<WebRTCInboundEvent, Error>.Continuation
	private var productionEventSink: (@MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)?
	private let qualificationStream: AsyncThrowingStream<WebRTCConnectorQualificationEvent, Error>.Continuation
	private let signalingClient: WebRTCSignalingClient
	private let inboundEventDecoder = WebRTCInboundEventDecoder()
	private let lifecycle = WebRTCLifecycle()
	private let generation: Int
	private let terminalObserver: TerminalObserver
	private let deliveryMode: DeliveryMode
	nonisolated private let diagnosticDispatcher: DiagnosticDispatcher
	private let ingressEvents: AsyncThrowingStream<AcceptedRawInbound, Error>
	nonisolated private let ingressStream: AsyncThrowingStream<AcceptedRawInbound, Error>.Continuation
	private var ingressDrainTask: Task<Void, Never>?
	nonisolated private let terminalGate = TerminalGate()
	private var productionReadinessWaiter: CheckedContinuation<Void, Never>?
	private var productionConfigurationWaiter: CheckedContinuation<Void, Never>?
	private var productionConfigurationInstalled = false
	private var productionDeliveryCancelled = false
	package static let inboundMailboxCapacity = 32
	private enum PreReadyInboundEvent {
		case decoded(WebRTCInboundEvent, retentionToken: AnyObject?)
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

	private init(
		connection: LKRTCPeerConnection,
		audioTrack: LKRTCAudioTrack,
		dataChannel: LKRTCDataChannel,
		signalingClient: WebRTCSignalingClient,
		terminalObserver: TerminalObserver,
		deliveryMode: DeliveryMode,
		productionSession: WebRTCSessionProvider?,
		remoteAudioGate: ProductionRemoteAudioAdmissionGate?,
		productionMediaCloser: ProductionMediaCloser,
		diagnosticSink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void
	) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		self.signalingClient = signalingClient
		self.terminalObserver = terminalObserver
		self.deliveryMode = deliveryMode
		self.productionSession = productionSession
		self.remoteAudioGate = remoteAudioGate
		self.productionMediaCloser = productionMediaCloser
		diagnosticDispatcher = DiagnosticDispatcher(sink: diagnosticSink)
		generation = lifecycle.begin()
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCInboundEvent.self, bufferingPolicy: .bufferingOldest(0))
		(qualificationEvents, qualificationStream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorQualificationEvent.self, bufferingPolicy: .bufferingOldest(2))
		(ingressEvents, ingressStream) = AsyncThrowingStream.makeStream(
			of: AcceptedRawInbound.self,
			bufferingPolicy: .bufferingOldest(Self.inboundMailboxCapacity)
		)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
		enqueueDiagnostic(.peerCreated)
		let ingressEvents = ingressEvents
		ingressDrainTask = Task { [weak self, ingressEvents] in
			do {
				for try await accepted in ingressEvents {
					guard !Task.isCancelled else { return }
					await self?.drainInbound(accepted)
				}
			} catch {}
		}
	}

	package func connect(using signaling: WebRTCSignalingRequest) async throws {
		guard connection.connectionState == .new else { return }
		guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }

		do {
			let localSDP = try await makeOffer()
			guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
			let remoteSDP = try await fetchRemoteSDP(using: signaling, localSdp: localSDP)
			try await apply(answer: remoteSDP)
		} catch {
			await requestTerminal()?.value
			throw error
		}
	}

	@_spi(AirbridgeQualification) public func makeOffer() async throws -> String {
		guard connection.connectionState == .new else { throw WebRTCTransportFailure.cancelled }
		guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
		guard terminalObserver.recordPermissionGranted() else {
			disconnect()
			throw WebRTCError.missingAudioPermission
		}
		let sdp: LKRTCSessionDescription
		do {
			sdp = try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil))
		} catch {
			throw WebRTCError.failedToCreateSDPOffer(error)
		}
		guard acceptProgression(.offerCreated) else { throw WebRTCTransportFailure.cancelled }

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }
		guard acceptProgression(.localDescriptionInstalled) else { throw WebRTCTransportFailure.cancelled }
		do {
			if let waitForLocalICEGathering = terminalObserver.waitForLocalICEGathering {
				try await waitForLocalICEGathering()
			} else {
				try await Self.waitForLocalICEGathering(
					isCurrent: { self.isCurrentAndAcceptingProgression() },
					isComplete: { self.connection.iceGatheringState == .complete }
				)
			}
			guard acceptProgression(.iceGatheringComplete) else { throw WebRTCTransportFailure.cancelled }
		} catch let failure as WebRTCTransportFailure where failure == .iceGatheringTimedOut {
			guard acceptProgression(.iceGatheringTimedOut) else { throw WebRTCTransportFailure.cancelled }
			throw failure
		}
		guard isCurrentAndAcceptingProgression(), let localSDP = connection.localDescription?.sdp else {
			throw WebRTCTransportFailure.cancelled
		}
		return localSDP
	}

	@_spi(AirbridgeQualification) public func apply(answer: String) async throws {
		guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
		guard acceptProgression(.remoteDescriptionInstalled) else { throw WebRTCTransportFailure.cancelled }
		Self.configureAudioSession()
	}

	package func installSignalingTask(_ task: Task<String, Error>) -> Bool {
		lifecycle.installSignalingTask(task, for: generation)
	}

	@_spi(AirbridgeQualification) public func send(event: ClientEvent) throws {
		guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	package func sendProductionCommand(_ command: ProductionCommand) throws {
		guard isCurrentAndAcceptingProgression(), dataChannel.readyState == .open else {
			throw WebRTCTransportFailure.cancelled
		}
		guard dataChannel.sendData(LKRTCDataBuffer(data: try command.encoded(), isBinary: false)) else {
			throw WebRTCTransportFailure.requestFailed
		}
	}

	package func sendSessionConfiguration(_ data: Data) throws {
		guard isCurrentAndAcceptingProgression(), dataChannel.readyState == .open else {
			throw WebRTCTransportFailure.cancelled
		}
		guard terminalGate.markProductionConfigurationDispatched() else {
			throw WebRTCTransportFailure.cancelled
		}
		guard dataChannel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
			throw WebRTCTransportFailure.requestFailed
		}
	}

	package func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void) {
		productionEventSink = sink
	}

	package func installProductionConfiguration() {
		guard !productionConfigurationInstalled else { return }
		productionConfigurationInstalled = true
		productionConfigurationWaiter?.resume()
		productionConfigurationWaiter = nil
	}

	package func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		guard lifecycle.isCurrent(generation) else { return }
		productionMediaCloser.set(state)
	}

	@_spi(AirbridgeQualification) public func sendSessionUpdate(
		voice: String,
		language: String
	) throws {
		guard isCurrentAndAcceptingProgression(), dataChannel.readyState == .open else {
			throw WebRTCTransportFailure.cancelled
		}
		let update = try WebRTCSessionUpdate(voice: voice, language: language)
		try dataChannel.sendData(LKRTCDataBuffer(data: update.encoded(), isBinary: false))
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
		enqueueDiagnostic(.teardownBegan)
		status = .disconnected
		terminalObserver.cancelSignaling()
		lifecycle.cancelSignalingTask()
		dataChannel.close()
		terminalObserver.closeData()
		connection.close()
		terminalObserver.closePeer()
		productionMediaCloser.releaseRemoteTracks()
		productionMediaCloser.close()
		Self.deactivateAudioSession()
		preReadyInboundEvents.removeAll()
		productionReadinessWaiter?.resume()
		productionReadinessWaiter = nil
		productionConfigurationWaiter?.resume()
		productionConfigurationWaiter = nil
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
		productionEventSink?(.success(.terminal(failure)))
		await drain?.value
		terminalGate.markSettled()
		diagnosticDispatcher.submitAndClose(.teardownCompleted)
		terminalObserver.didSettle()
	}

	nonisolated private func closeProductionMediaSynchronously() -> Bool {
		guard productionSession == .openAI else { return false }
		productionMediaCloser.close()
		return true
	}

	nonisolated private var requiresSynchronousProductionMediaClosure: Bool {
		productionSession == .openAI
	}

	public func toggleMute() {
		guard lifecycle.isCurrent(generation) else { return }
		audioTrack.isEnabled.toggle()
	}

	private func enqueueDiagnostic(_ milestone: WebRTCConnectorDiagnosticMilestone) {
		diagnosticDispatcher.submit(milestone)
	}

	nonisolated private func enqueueDiagnosticFromDelegate(_ milestone: WebRTCConnectorDiagnosticMilestone) {
		switch Self.nativeDiagnosticAdmission(for: milestone) {
		case .terminal:
			diagnosticDispatcher.submitFromDelegate(milestone)
		case .progression:
			_ = terminalGate.admitProgression { diagnosticDispatcher.submitFromDelegate(milestone) }
		}
	}

	nonisolated private static func nativeDiagnosticAdmission(
		for milestone: WebRTCConnectorDiagnosticMilestone
	) -> NativeDiagnosticAdmission {
		switch milestone {
		case .iceDisconnected, .iceFailed, .iceClosed,
			.peerDisconnected, .peerFailed, .peerClosed,
			.dataChannelClosing, .dataChannelClosed,
			.teardownBegan, .teardownCompleted:
			return .terminal
		case .peerCreated, .offerCreated, .localDescriptionInstalled,
			.iceGatheringComplete, .iceGatheringTimedOut,
			.remoteDescriptionInstalled, .iceChecking, .iceConnected, .iceCompleted,
			.peerConnecting, .peerConnected,
			.dataChannelConnecting, .dataChannelOpen, .remoteAudioTrackObserved:
			return .progression
		}
	}

	private func isCurrentAndAcceptingProgression() -> Bool {
		lifecycle.isCurrent(generation) && terminalGate.acceptsProgression()
	}

	private func acceptProgression(_ milestone: WebRTCConnectorDiagnosticMilestone) -> Bool {
		guard lifecycle.isCurrent(generation) else { return false }
		guard terminalGate.admitProgression({ diagnosticDispatcher.submit(milestone) }) else { return false }
		return lifecycle.isCurrent(generation) && terminalGate.acceptsProgression()
	}
}

extension WebRTCConnector {
	package static func createProduction(
		provider: WebRTCSessionProvider,
		initialAudioState: WebRTCLocalAudioState
	) throws -> WebRTCConnector {
		guard provider.supports(initialAudioState: initialAudioState) else {
			throw WebRTCTransportFailure.invalidRequest
		}
		return try create(
			session: URLSessionWebRTCSignalingSession(), terminalObserver: .none,
			deliveryMode: .production,
			productionSession: provider,
			initialAudioState: initialAudioState,
			diagnosticSink: { _ in }
		)
	}

	package static func createProduction(
		provider: WebRTCSessionProvider,
		initialAudioState: WebRTCLocalAudioState,
		session: any WebRTCSignalingSession,
		terminalObserver: TerminalObserver = .none
	) throws -> WebRTCConnector {
		guard provider.supports(initialAudioState: initialAudioState) else {
			throw WebRTCTransportFailure.invalidRequest
		}
		return try create(
			session: session, terminalObserver: terminalObserver, deliveryMode: .production,
			productionSession: provider,
			initialAudioState: initialAudioState, diagnosticSink: { _ in }
		)
	}

	public static func create(connectingTo signaling: WebRTCSignalingRequest, session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession()) async throws -> WebRTCConnector {
		let connector = try create(session: session)
		try await connector.connect(using: signaling)
		return connector
	}

	package static func create(session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession(), terminalObserver: TerminalObserver = .none) throws -> WebRTCConnector {
		try create(session: session, terminalObserver: terminalObserver, deliveryMode: .ordinary, productionSession: nil, initialAudioState: .enabled, diagnosticSink: { _ in })
	}

	@_spi(AirbridgeQualification) public static func createQualification(
		session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession(),
		diagnosticSink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void = { _ in }
	) throws -> WebRTCConnector {
		try create(session: session, terminalObserver: .none, deliveryMode: .qualification, productionSession: nil, initialAudioState: .enabled, diagnosticSink: diagnosticSink)
	}

	package static func createQualification(
		session: any WebRTCSignalingSession,
		terminalObserver: TerminalObserver,
		diagnosticSink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void = { _ in }
	) throws -> WebRTCConnector {
		try create(session: session, terminalObserver: terminalObserver, deliveryMode: .qualification, productionSession: nil, initialAudioState: .enabled, diagnosticSink: diagnosticSink)
	}

	private static func create(
		session: any WebRTCSignalingSession,
		terminalObserver: TerminalObserver,
		deliveryMode: DeliveryMode,
		productionSession: WebRTCSessionProvider?,
		initialAudioState: WebRTCLocalAudioState,
		diagnosticSink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void
	) throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection, initialAudioState: initialAudioState)
		let remoteAudioGate = productionSession == .openAI
			? ProductionRemoteAudioAdmissionGate(
				initiallyEnabled: initialAudioState == .enabled,
				attemptedFrame: terminalObserver.didAttemptRemoteAudioFrame,
				admittedFrame: terminalObserver.didAdmitRemoteAudioFrame
			)
			: nil
		let productionMediaCloser = ProductionMediaCloser(
			localTrack: audioTrack, remoteGate: remoteAudioGate, didDisable: terminalObserver.disableAudio
		)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(
			connection: connection,
			audioTrack: audioTrack,
			dataChannel: dataChannel,
			signalingClient: WebRTCSignalingClient(session: session),
			terminalObserver: terminalObserver,
			deliveryMode: deliveryMode,
			productionSession: productionSession,
			remoteAudioGate: remoteAudioGate,
			productionMediaCloser: productionMediaCloser,
			diagnosticSink: diagnosticSink
		)
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
		guard isCurrent() else { throw WebRTCTransportFailure.cancelled }
		guard isComplete() else { throw WebRTCTransportFailure.iceGatheringTimedOut }
	}

}


private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection, initialAudioState: WebRTCLocalAudioState) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			audioTrack.isEnabled = initialAudioState == .enabled
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
		guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
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
			guard isCurrentAndAcceptingProgression() else { throw WebRTCTransportFailure.cancelled }
			return sdp
		} onCancel: {
			task.cancel()
		}
	}
}

// LiveKit's delegate protocols predate actor annotations. The imported callbacks derive
// fixed content-free milestones only; the bounded dispatcher serializes best-effort delivery.
extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	nonisolated public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
		reportRemoteAudioTrackIfPresent(in: [stream])
	}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
		reportRemoteAudioTrackIfPresent(receiverTrack: receiver.track, streams: streams)
	}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {
		remoteAudioGate?.unregister(stream.audioTracks)
	}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didRemove receiver: LKRTCRtpReceiver) {
		if let track = receiver.track { remoteAudioGate?.unregister([track]) }
	}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		let milestone: WebRTCConnectorDiagnosticMilestone?
		switch newState {
		case .checking: milestone = .iceChecking
		case .connected: milestone = .iceConnected
		case .completed: milestone = .iceCompleted
		case .disconnected: milestone = .iceDisconnected
		case .failed: milestone = .iceFailed
		case .closed: milestone = .iceClosed
		default: milestone = nil
		}
		if let milestone { enqueueDiagnosticFromDelegate(milestone) }
		let terminal = newState == .closed || newState == .disconnected
		if terminal { _ = terminalGate.request(nil, connector: self) }
	}

	nonisolated public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
		let milestone: WebRTCConnectorDiagnosticMilestone?
		switch newState {
		case .connecting: milestone = .peerConnecting
		case .connected: milestone = .peerConnected
		case .disconnected: milestone = .peerDisconnected
		case .failed: milestone = .peerFailed
		case .closed: milestone = .peerClosed
		default: milestone = nil
		}
		if let milestone { enqueueDiagnosticFromDelegate(milestone) }
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
		let milestone: WebRTCConnectorDiagnosticMilestone?
		switch dataChannel.readyState {
		case .connecting: milestone = .dataChannelConnecting
		case .open: milestone = .dataChannelOpen
		case .closing: milestone = .dataChannelClosing
		case .closed: milestone = .dataChannelClosed
		@unknown default: milestone = nil
		}
		if let milestone { enqueueDiagnosticFromDelegate(milestone) }
		if isTerminal {
			_ = terminalGate.request(nil, connector: self)
		} else if isOpen {
			scheduleOpenTransition()
		}
	}
}

extension WebRTCConnector {
	nonisolated private func reportRemoteAudioTrackIfPresent(in streams: [LKRTCMediaStream]) {
		reportRemoteAudioTrackIfPresent(receiverTrack: nil, streams: streams)
	}

	nonisolated private func reportRemoteAudioTrackIfPresent(receiverTrack: LKRTCMediaStreamTrack?, streams: [LKRTCMediaStream]) {
		let tracks: [LKRTCMediaStreamTrack] = streams.flatMap(\.audioTracks) + (receiverTrack.map { [$0] } ?? [])
		remoteAudioGate?.register(tracks)
		guard Self.receiverOrStreamsContainAudioTrack(trackKind: receiverTrack?.kind, streams: streams) else { return }
		if let remoteAudioGate {
			remoteAudioGate.deliverIfAdmitted { enqueueDiagnosticFromDelegate(.remoteAudioTrackObserved) }
		} else { enqueueDiagnosticFromDelegate(.remoteAudioTrackObserved) }
	}

	nonisolated package static func remoteStreamsContainAudioTrack(_ streams: [LKRTCMediaStream]) -> Bool {
		streams.contains { !$0.audioTracks.isEmpty }
	}

	/// This records only that a remote audio track was observed; it is not a
	/// rendering or playback-success signal.
	nonisolated package static func receiverOrStreamsContainAudioTrack(trackKind: String?, streams: [LKRTCMediaStream]) -> Bool {
		trackKind == "audio" || remoteStreamsContainAudioTrack(streams)
	}

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
			let failure: WebRTCTransportFailure = productionSession == .openAI ? .responseTooLarge : .eventTooLarge
			_ = terminalGate.request(failure, connector: self)
			return
		}
		terminalGate.acceptIngress(data, with: ingressStream, connector: self)
	}

	private func drainInbound(_ accepted: AcceptedRawInbound) async {
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
		if deliveryMode == .production {
			await waitForProductionReadiness()
			guard !productionDeliveryCancelled, terminalGate.shouldProcessAcceptedIngress(), lifecycle.isCurrent(generation) else { return }
			await waitForProductionConfiguration()
			guard !productionDeliveryCancelled, terminalGate.shouldProcessAcceptedIngress(), lifecycle.isCurrent(generation) else { return }
			yieldProduction(
				.rawInbound(
					accepted.data,
					configurationDispatchedAtAcceptance: accepted.configurationDispatchedAtAcceptance
				),
				fromAcceptedIngress: true
			)
			return
		}
		do {
			guard let inboundEvent = try inboundEventDecoder.decodeForConnector(accepted.data) else { return }
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
				preReadyInboundEvents = [.decoded(inboundEvent, retentionToken: terminalObserver.makePreReadyRetentionToken())]
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

	private func waitForProductionReadiness() async {
		while status != .connected {
			guard !productionDeliveryCancelled, terminalGate.shouldProcessAcceptedIngress(), lifecycle.isCurrent(generation) else { return }
			await withCheckedContinuation { productionReadinessWaiter = $0 }
		}
	}

	private func resumeProductionReadinessIfPossible() {
		guard status == .connected else { return }
		productionReadinessWaiter?.resume()
		productionReadinessWaiter = nil
	}

	private func waitForProductionConfiguration() async {
		while !productionConfigurationInstalled {
			guard !productionDeliveryCancelled, terminalGate.shouldProcessAcceptedIngress(), lifecycle.isCurrent(generation) else { return }
			await withCheckedContinuation { productionConfigurationWaiter = $0 }
		}
	}

	private func resumeProductionReadinessForTerminal() {
		productionDeliveryCancelled = true
		productionReadinessWaiter?.resume()
		productionReadinessWaiter = nil
		productionConfigurationWaiter?.resume()
		productionConfigurationWaiter = nil
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
		if isOpen, !fromAcceptedIngress, !terminalGate.acceptsProgression() { return }
		if isOpen {
			if !fromAcceptedIngress { enqueueDiagnostic(.dataChannelOpen) }
			guard lifecycle.isCurrent(generation) else { return }
			guard status != .connected else { return }
			status = .connected
			if deliveryMode == .qualification {
				yieldQualification(.connected, fromAcceptedIngress: fromAcceptedIngress)
			} else if deliveryMode == .production {
				yieldProduction(.ready, fromAcceptedIngress: fromAcceptedIngress)
				resumeProductionReadinessIfPossible()
			}
			if fromAcceptedIngress, !terminalGate.shouldProcessAcceptedIngress() { return }
			let bufferedEvents = preReadyInboundEvents
			preReadyInboundEvents.removeAll()
			bufferedEvents.forEach {
				switch $0 {
				case let .decoded(event, _): yieldInbound(event)
				}
			}
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
		case .production: yieldProduction(.inbound(event), fromAcceptedIngress: true)
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

	private func yieldProduction(_ event: WebRTCConnectorPeerBackingEvent, fromAcceptedIngress _: Bool) {
		// Production delivery is a direct MainActor handoff. The public peer stream
		// below is the sole checked two-slot semantic buffer.
		productionEventSink?(.success(event))
	}
}

extension WebRTCConnector: WebRTCConnectorPeerBacking {}

extension WebRTCConnector: LKRTCAudioRenderer {
	nonisolated public func render(pcmBuffer: AVAudioPCMBuffer) { remoteAudioGate?.render(pcmBuffer: pcmBuffer) }
}
