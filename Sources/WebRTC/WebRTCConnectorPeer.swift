import Core
import Foundation

public enum WebRTCLocalAudioState: Sendable, Equatable { case enabled, disabled }
public enum WebRTCSessionProvider: Sendable, Equatable { case localAI, openAI }

package extension WebRTCSessionProvider {
	func supports(initialAudioState: WebRTCLocalAudioState) -> Bool {
		(self == .localAI && initialAudioState == .enabled) ||
			(self == .openAI && initialAudioState == .disabled)
	}
}

public struct WebRTCSessionConfiguration: Sendable, Equatable {
	fileprivate enum Provider: Sendable, Equatable { case localAI(voice: String), openAI }
	fileprivate let provider: Provider
	fileprivate let language: String

	private init(provider: Provider, language: String) {
		self.provider = provider
		self.language = language
	}

	fileprivate var sessionProvider: WebRTCSessionProvider {
		switch provider {
		case .localAI: .localAI
		case .openAI: .openAI
		}
	}

	public static func localAI(voice: String, language: String) throws -> Self {
		let update = try WebRTCSessionUpdate(voice: voice, language: language)
		return Self(provider: .localAI(voice: update.voice), language: update.language)
	}

	public static func openAI(language: String) throws -> Self {
		_ = try OpenAIProductionStateMachine(language: language)
		return Self(provider: .openAI, language: language)
	}

	package func encoded() throws -> Data {
		switch provider {
		case let .localAI(voice): return try WebRTCSessionUpdate(voice: voice, language: language).encoded()
		case .openAI:
			return Data(#"{"type":"session.update","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"\#(language)"},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#.utf8)
		}
	}
}

/// Opaque identity minted exactly once for an accepted OpenAI `response.created`
/// event in one peer generation. It intentionally exposes neither a provider
/// identifier nor construction API.
public struct WebRTCOpenAIResponseToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	fileprivate let identity = UUID()
	package init() {}
	public var description: String { "WebRTCOpenAIResponseToken()" }
	public var debugDescription: String { description }
	public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Correlated OpenAI response lifecycle output. Every response-scoped event
/// carries the same token, preventing one response's queued semantic output
/// from being applied to a later response.
public enum WebRTCOpenAIResponseEvent: Sendable, Equatable {
	case started(WebRTCOpenAIResponseToken)
	case assistantTranscript(WebRTCOpenAIResponseToken, String)
	case finished(WebRTCOpenAIResponseToken)
	case cancellationTerminalObserved(WebRTCOpenAIResponseToken)
}

/// Opaque, peer-scoped permission for the ordered cancellation phases. Repeating
/// reservation for the same pending token returns the same value. It contains no
/// provider identifier and has no public construction API.
public struct WebRTCOpenAICancellationReservation: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
	fileprivate let peerIdentity: UUID
	fileprivate let token: WebRTCOpenAIResponseToken
	fileprivate init(peerIdentity: UUID, token: WebRTCOpenAIResponseToken) {
		self.peerIdentity = peerIdentity
		self.token = token
	}
	public var description: String { "WebRTCOpenAICancellationReservation()" }
	public var debugDescription: String { description }
	public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// The local result of a targeted OpenAI cancellation dispatch decision. `.sent`
/// means the targeted wire command dispatched successfully; it is not a server
/// acknowledgement. `.alreadyCompleted` means the exact reserved response had
/// already completed or cancelled locally.
public enum WebRTCOpenAICancelDisposition: Sendable, Equatable { case sent, alreadyCompleted }

public enum WebRTCConnectorEvent: Sendable, Equatable {
	case ready
	case localAISessionConfigured(voice: String, language: String)
	/// Creation accepted and initial session configuration dispatched successfully.
	case openAISessionCreated
	case openAISessionConfigured(language: String)
	case connected
	case userTranscript(String)
	case assistantTranscript(String)
	case responseStarted
	case responseFinished
	case responseCancellationTerminalObserved
	case openAIResponse(WebRTCOpenAIResponseEvent)
	case closed
}

@MainActor public protocol WebRTCConnectorPeer: Sendable {
	var events: WebRTCConnectorEventStream { get }
	func makeOffer() async throws -> String
	func apply(remoteAnswer: String) async throws
	func configure(_ configuration: WebRTCSessionConfiguration) throws
	func sendUserText(_ text: String) throws
	func createResponse() throws
	func cancelResponse() throws
	func clearOutputAudio() throws
	func settleCancelledResponse() throws
	/// Reserves exactly one current or most-recently completed OpenAI response.
	/// Reservation is local-only: it sends no command and prevents a successor
	/// response from replacing the selected response before ordered settlement.
	/// The caller must reserve the exact response, await
	/// `disableAudioAndWaitForMediaQuiescence()`, dispatch a disposition, clear
	/// output, complete its semantic rendezvous, and then settle this handle.
	/// A foreign, stale, or different pending token is rejected without mutation.
	func reserveCancellation(for token: WebRTCOpenAIResponseToken) throws -> WebRTCOpenAICancellationReservation
	/// Dispatches at most one cancel for a valid reservation. A matching terminal
	/// observed before this phase reports `.alreadyCompleted` without a wire send.
	/// Replaying this live or most-recent settled phase returns its recorded result.
	/// Calling it with a foreign, stale, or out-of-order reservation is non-mutating.
	func cancelResponse(reservation: WebRTCOpenAICancellationReservation) throws -> WebRTCOpenAICancelDisposition
	/// Clears the provider's shared output buffer once after a successful exact
	/// disposition. The shared command has no response selector. Replaying a live
	/// or most-recent settled clear sends nothing; clear before disposition rejects
	/// without mutation.
	func clearOutputAudio(reservation: WebRTCOpenAICancellationReservation) throws
	/// Releases a reservation after the caller's separate semantic rendezvous.
	/// Settlement is the final phase after media quiescence, disposition, clear,
	/// and that caller-owned rendezvous. It records one receipt for replay. A
	/// newer accepted response invalidates that receipt. Caller cancellation,
	/// terminal selection, and close invalidate both handles and receipts;
	/// foreign, stale, and out-of-order settlement rejects without mutation.
	func settleCancelledResponse(reservation: WebRTCOpenAICancellationReservation) throws
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	/// Disables local audio and OpenAI remote-media admission, then waits for
	/// already-admitted remote media callbacks to return. This does not close or
	/// settle the peer; a later explicit `.enabled` state may admit media again.
	func disableAudioAndWaitForMediaQuiescence() async
	func closeAndJoin() async
}

@MainActor public extension WebRTCConnectorPeer {
	/// Other conformers, including LocalAI, reject OpenAI-only reservations without
	/// issuing a command. Legacy no-argument methods remain strict and source
	/// compatible; a pending reservation cannot use them to bypass ordered phases.
	func reserveCancellation(for _: WebRTCOpenAIResponseToken) throws -> WebRTCOpenAICancellationReservation { throw WebRTCTransportFailure.invalidRequest }
	func cancelResponse(reservation _: WebRTCOpenAICancellationReservation) throws -> WebRTCOpenAICancelDisposition { throw WebRTCTransportFailure.invalidRequest }
	func clearOutputAudio(reservation _: WebRTCOpenAICancellationReservation) throws { throw WebRTCTransportFailure.invalidRequest }
	func settleCancelledResponse(reservation _: WebRTCOpenAICancellationReservation) throws { throw WebRTCTransportFailure.invalidRequest }
}

/// Synchronously records whether caller cancellation beat terminal selection.
/// Normal close remains a normal close, but a cancellation selected before any
/// actor hop is preserved until settlement installs its public terminal.
final class ProductionTerminalSelection: @unchecked Sendable {
	private enum State { case open, cancellation, selected }
	private let lock = NSLock()
	private var state: State = .open

	func selectCancellation() -> Bool {
		lock.withLock {
			if case .open = state { state = .cancellation }
			return state == .cancellation
		}
	}

	func cancellationWins() -> Bool { lock.withLock { state == .cancellation } }

	func failureForSettlement(_ failure: WebRTCTransportFailure?) -> WebRTCTransportFailure? {
		lock.withLock {
			switch state {
			case .open:
				state = failure == .cancelled ? .cancellation : .selected
				return failure
			case .cancellation:
				return .cancelled
			case .selected:
				return failure == .cancelled ? nil : failure
			}
		}
	}
}

/// Package-only deterministic test seam. It is not visible to normal imports.
package enum WebRTCConnectorPeerBackingEvent: Sendable, Equatable {
	case ready
	case inbound(WebRTCInboundEvent)
	case rawInbound(Data, configurationDispatchedAtAcceptance: Bool)
	case terminal(WebRTCTransportFailure?)
}
@MainActor package protocol WebRTCConnectorPeerBacking: Sendable {
	func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)
	func installProductionConfiguration()
	func makeOffer() async throws -> String
	func apply(answer: String) async throws
	func sendSessionConfiguration(_ data: Data) throws
	/// Nil leaves a previously selected backing terminal in charge of notification.
	/// False means semantic admission rejected the successfully dispatched milestone.
	func dispatchOpenAIConfiguration(_ data: Data, offeringCreationTo storage: WebRTCConnectorEventStream.Storage) throws -> Bool?
	func sendProductionCommand(_ command: ProductionCommand) throws
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	func disableAudioForMediaQuiescence() -> UInt64?
	func waitForMediaQuiescence(through cutoff: UInt64?) async
	func closeAndSettle() async
}

@MainActor package extension WebRTCConnectorPeerBacking {
	func installProductionConfiguration() {}
	func dispatchOpenAIConfiguration(_ data: Data, offeringCreationTo storage: WebRTCConnectorEventStream.Storage) throws -> Bool? {
		try sendSessionConfiguration(data)
		return storage.offer(.openAISessionCreated)
	}
}

@MainActor public struct WebRTCConnectorPeerFactory: Sendable {
	private let makePeerClosure: @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking
	private let provider: WebRTCSessionProvider
	private let initialAudioState: WebRTCLocalAudioState

	public init(provider: WebRTCSessionProvider, initialAudioState: WebRTCLocalAudioState) {
		self.provider = provider
		self.initialAudioState = initialAudioState
		makePeerClosure = { try WebRTCConnector.createProduction(provider: provider, initialAudioState: initialAudioState) }
	}

	/// Keeps deterministic direct-fork tests on the same initial-audio contract
	/// as the production factory without making injection available to consumers.
	package init(
		provider: WebRTCSessionProvider,
		initialAudioState: WebRTCLocalAudioState,
		makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking
	) {
		self.provider = provider
		self.initialAudioState = initialAudioState
		makePeerClosure = {
			let backing = try makePeer()
			backing.setLocalAudioState(initialAudioState)
			return backing
		}
	}

	public func makePeer() throws -> any WebRTCConnectorPeer {
		do {
			guard provider.supports(initialAudioState: initialAudioState) else {
				throw WebRTCTransportFailure.invalidRequest
			}
			return try ProductionWebRTCConnectorPeer(
				backing: makePeerClosure(),
				provider: provider
			)
		}
		catch { throw ProductionWebRTCConnectorPeer.contentFree(error) }
	}
}

@MainActor package final class ProductionWebRTCConnectorPeer: WebRTCConnectorPeer, @unchecked Sendable {
	private enum SettlementOrigin { case explicitClose, caller, backing }
	package let events: WebRTCConnectorEventStream
	private let eventStorage: WebRTCConnectorEventStream.Storage
	private let backing: any WebRTCConnectorPeerBacking
	private let productionSession: WebRTCSessionProvider
	private let terminalSelection = ProductionTerminalSelection()
	private let reservationPeerIdentity = UUID()
	private var settlementTask: Task<Void, Never>?
	private var offerOperation: Task<String, Error>?
	private var answerOperation: Task<Void, Error>?
	private var terminalFailure: WebRTCTransportFailure?
	private var offerMade = false
	private var offerInFlight = false
	private var answerApplied = false
	private var answerInFlight = false
	private var pendingReady = false
	private var ready = false
	private var configuration: WebRTCSessionConfiguration?
	private var openAIState: OpenAIProductionStateMachine?
	private var configurationAcknowledgementPending = false
	private var connected = false
	private var terminal = false
	private var settlementStarting = false
	private var pendingCancellationReservation: WebRTCOpenAICancellationReservation?
	private var settledCancellationReservation: (reservation: WebRTCOpenAICancellationReservation, disposition: WebRTCOpenAICancelDisposition)?

	init(
		backing: any WebRTCConnectorPeerBacking,
		provider: WebRTCSessionProvider
	) {
		self.backing = backing
		productionSession = provider
		let eventStorage = WebRTCConnectorEventStream.Storage()
		self.eventStorage = eventStorage
		events = WebRTCConnectorEventStream(storage: eventStorage)
		eventStorage.installCancellationHandler(owner: { [weak self] in self }) { [weak self] in
			Task { @MainActor [weak self] in
				await self?.beginSettlement(failure: .cancelled, origin: .caller)
			}
		}
		backing.installProductionEventSink { [weak self] result in self?.receive(result) }
	}

	package func makeOffer() async throws -> String {
		guard !terminal, !offerMade, !offerInFlight else {
			if terminal { startSettlement(failure: .invalidRequest, origin: .caller) }
			else { await beginSettlement(failure: .invalidRequest, origin: .caller) }
			throw WebRTCTransportFailure.invalidRequest
		}
		offerInFlight = true
		defer { offerInFlight = false }
		do {
			let operation = Task { @MainActor [backing] in try await backing.makeOffer() }
			offerOperation = operation
			defer { offerOperation = nil }
			let terminalSelection = terminalSelection
			let offer = try await withTaskCancellationHandler {
				try Task.checkCancellation()
				let offer = try await operation.value
				try Task.checkCancellation()
				return offer
			} onCancel: { [weak self, terminalSelection] in
				operation.cancel()
				let cancellationWins = terminalSelection.selectCancellation()
				Task { @MainActor [weak self] in await self?.beginSettlement(failure: cancellationWins ? .cancelled : nil, origin: .caller) }
			}
			guard !terminal else { throw WebRTCTransportFailure.cancelled }
			guard !offer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebRTCTransportFailure.invalidSDP }
			offerMade = true
			return offer
		} catch {
			let cancellationWins = selectCallerCancellationIfNeeded()
			if cancellationWins || (terminal && terminalFailure == nil) {
				await beginSettlement(failure: cancellationWins ? .cancelled : nil, origin: .caller)
				throw WebRTCTransportFailure.cancelled
			}
			let failure = Self.contentFree(error)
			await beginSettlement(failure: failure, origin: .caller)
			throw failure
		}
	}

	package func apply(remoteAnswer: String) async throws {
		guard !terminal, offerMade, !answerApplied, !answerInFlight, !remoteAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			if terminal { startSettlement(failure: .invalidSDP, origin: .caller) }
			else { await beginSettlement(failure: .invalidSDP, origin: .caller) }
			throw WebRTCTransportFailure.invalidSDP
		}
		answerInFlight = true
		defer { answerInFlight = false }
		do {
			let operation = Task { @MainActor [backing] in try await backing.apply(answer: remoteAnswer) }
			answerOperation = operation
			defer { answerOperation = nil }
			let terminalSelection = terminalSelection
			try await withTaskCancellationHandler {
				try Task.checkCancellation()
				try await operation.value
				try Task.checkCancellation()
			} onCancel: { [weak self, terminalSelection] in
				operation.cancel()
				let cancellationWins = terminalSelection.selectCancellation()
				Task { @MainActor [weak self] in await self?.beginSettlement(failure: cancellationWins ? .cancelled : nil, origin: .caller) }
			}
			guard !terminal else { throw WebRTCTransportFailure.cancelled }
			answerApplied = true
			if pendingReady {
				pendingReady = false
				guard admitReady() else { throw WebRTCTransportFailure.malformedEvent }
			}
		} catch {
			let cancellationWins = selectCallerCancellationIfNeeded()
			if cancellationWins || (terminal && terminalFailure == nil) {
				await beginSettlement(failure: cancellationWins ? .cancelled : nil, origin: .caller)
				throw WebRTCTransportFailure.cancelled
			}
			let failure = Self.contentFree(error)
			await beginSettlement(failure: failure, origin: .caller)
			throw failure
		}
	}

	package func configure(_ configuration: WebRTCSessionConfiguration) throws {
		guard !terminal, offerMade, answerApplied, ready, self.configuration == nil else {
			startSettlement(failure: .invalidRequest, origin: .caller)
			throw WebRTCTransportFailure.invalidRequest
		}
		do {
			guard configuration.sessionProvider == productionSession else {
				throw WebRTCTransportFailure.invalidRequest
			}
			self.configuration = configuration
			switch configuration.provider {
			case .localAI:
				configurationAcknowledgementPending = true
				try backing.sendSessionConfiguration(configuration.encoded())
				backing.installProductionConfiguration()
			case .openAI:
				openAIState = try OpenAIProductionStateMachine(language: configuration.language)
				backing.installProductionConfiguration()
			}
		} catch {
			let failure = Self.contentFree(error)
			startSettlement(failure: failure, origin: .caller)
			throw failure
		}
	}

	package func sendUserText(_ text: String) throws {
		guard Self.isValidText(text) else { try rejectCommand() }
		try sendCommand(.userText(text))
	}
	package func createResponse() throws {
		if openAIState != nil { do { try openAIState?.prepareCreateResponse() } catch { try rejectCommand() } }
		try sendCommand(.createResponse)
	}
	package func cancelResponse() throws {
		if openAIState != nil { do { try openAIState?.prepareCancelResponse() } catch { try rejectCommand() } }
		try sendCommand(.cancelResponse)
	}
	package func clearOutputAudio() throws {
		guard pendingCancellationReservation == nil else { try rejectCommand() }
		try sendCommand(.clearOutputAudio)
	}
	package func settleCancelledResponse() throws {
		guard openAIState != nil else { try rejectCommand() }
		do { try openAIState?.settleCancelledResponse() }
		catch { try rejectCommand() }
	}
	package func reserveCancellation(for token: WebRTCOpenAIResponseToken) throws -> WebRTCOpenAICancellationReservation {
		try rejectSelectedIteratorCancellation()
		guard isConnected, openAIState != nil else { throw WebRTCTransportFailure.invalidRequest }
		if let pendingCancellationReservation {
			guard pendingCancellationReservation.token == token else { throw WebRTCTransportFailure.invalidRequest }
			return pendingCancellationReservation
		}
		guard settledCancellationReservation == nil else { throw WebRTCTransportFailure.invalidRequest }
		do { try openAIState?.reserveCancellation(for: token) }
		catch { throw WebRTCTransportFailure.invalidRequest }
		let reservation = WebRTCOpenAICancellationReservation(peerIdentity: reservationPeerIdentity, token: token)
		pendingCancellationReservation = reservation
		return reservation
	}
	package func cancelResponse(reservation: WebRTCOpenAICancellationReservation) throws -> WebRTCOpenAICancelDisposition {
		try rejectSelectedIteratorCancellation()
		if let settledCancellationReservation, settledCancellationReservation.reservation == reservation { return settledCancellationReservation.disposition }
		guard pendingCancellationReservation == reservation, reservation.peerIdentity == reservationPeerIdentity, !terminal else { throw WebRTCTransportFailure.invalidRequest }
		do {
			let decision = try openAIState?.cancellationDecision(for: reservation.token)
			guard let decision else { throw WebRTCTransportFailure.invalidRequest }
			switch decision {
			case let .send(responseID):
				try sendCommand(.cancelResponseTargeted(responseID))
				try openAIState?.recordCancellationDisposition(.sent, for: reservation.token)
				return .sent
			case .sent:
				return .sent
			case .alreadyCompleted:
				try openAIState?.recordCancellationDisposition(.alreadyCompleted, for: reservation.token)
				return .alreadyCompleted
			}
		} catch let failure as WebRTCTransportFailure { throw failure }
		catch { throw WebRTCTransportFailure.invalidRequest }
	}
	package func clearOutputAudio(reservation: WebRTCOpenAICancellationReservation) throws {
		try rejectSelectedIteratorCancellation()
		if let settledCancellationReservation, settledCancellationReservation.reservation == reservation { return }
		guard pendingCancellationReservation == reservation, reservation.peerIdentity == reservationPeerIdentity, !terminal else { throw WebRTCTransportFailure.invalidRequest }
		do {
			guard try openAIState?.shouldDispatchOutputClear(for: reservation.token) == true else { return }
			try sendCommand(.clearOutputAudio)
			try openAIState?.recordOutputClear(for: reservation.token)
		} catch let failure as WebRTCTransportFailure { throw failure }
		catch { throw WebRTCTransportFailure.invalidRequest }
	}
	package func settleCancelledResponse(reservation: WebRTCOpenAICancellationReservation) throws {
		try rejectSelectedIteratorCancellation()
		if let settledCancellationReservation, settledCancellationReservation.reservation == reservation { return }
		guard pendingCancellationReservation == reservation, reservation.peerIdentity == reservationPeerIdentity, !terminal else { throw WebRTCTransportFailure.invalidRequest }
		do {
			let disposition = try openAIState?.settleReservation(for: reservation.token)
			guard let disposition else { throw WebRTCTransportFailure.invalidRequest }
			pendingCancellationReservation = nil
			settledCancellationReservation = (reservation, disposition)
		} catch { throw WebRTCTransportFailure.invalidRequest }
	}

	package func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		guard !eventStorage.iteratorCancellationSelected else {
			startSettlement(failure: .cancelled, origin: .caller)
			return
		}
		guard !terminal, !settlementStarting, state == .disabled || connected else { return }
		backing.setLocalAudioState(state)
	}

	package func disableAudioAndWaitForMediaQuiescence() async {
		let cutoff = backing.disableAudioForMediaQuiescence()
		await backing.waitForMediaQuiescence(through: cutoff)
	}

	package func closeAndJoin() async { await beginSettlement(failure: nil, origin: .explicitClose) }
	private var isConnected: Bool { !terminal && !settlementStarting && connected }

	private func receive(_ result: Result<WebRTCConnectorPeerBackingEvent, any Error>) {
		if settlementStarting, !terminal { return }
		if terminal {
			switch result {
			case let .failure(error): startSettlement(failure: Self.contentFree(error), origin: .backing)
			case let .success(.terminal(failure)): startSettlement(failure: failure, origin: .backing)
			case .success: break
			}
			return
		}
		guard case let .success(event) = result else {
			if case let .failure(error) = result { startSettlement(failure: Self.contentFree(error), origin: .backing) }
			return
		}
		switch event {
		case let .terminal(failure): startSettlement(failure: failure, origin: .backing); return
		case .ready:
			guard !ready else { startSettlement(failure: .malformedEvent, origin: .backing); return }
			if answerInFlight { pendingReady = true; return }
			guard admitReady() else { startSettlement(failure: .malformedEvent, origin: .backing); return }
		case let .rawInbound(data, configurationDispatchedAtAcceptance):
			do {
				try receiveRaw(
					data,
					configurationDispatchedAtAcceptance: configurationDispatchedAtAcceptance
				)
			}
			catch let failure as WebRTCTransportFailure { startSettlement(failure: failure, origin: .backing) }
			catch { startSettlement(failure: Self.contentFree(error), origin: .backing) }
		case let .inbound(inbound):
			guard productionSession == .localAI else {
				startSettlement(failure: .malformedEvent, origin: .backing)
				return
			}
			switch inbound {
			case let .sessionUpdated(voice, language):
				guard ready, configurationAcknowledgementPending, let configuration,
					case let .localAI(expectedVoice) = configuration.provider
				else { startSettlement(failure: .malformedEvent, origin: .backing); return }
				guard expectedVoice == voice, configuration.language == language else {
					startSettlement(failure: .providerError, origin: .backing)
					return
				}
				guard yield(.localAISessionConfigured(voice: voice, language: language)), yield(.connected) else { return }
				configurationAcknowledgementPending = false
				connected = true
			case let .userTranscript(text): guard connected, yield(.userTranscript(text)) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case let .assistantTranscript(text): guard connected, yield(.assistantTranscript(text)) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case .responseFinished: guard connected, yield(.responseFinished) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case .providerError: startSettlement(failure: .providerError, origin: .backing); return
			}
		}
	}

	private func receiveRaw(
		_ data: Data,
		configurationDispatchedAtAcceptance: Bool
	) throws {
		guard ready else { throw WebRTCTransportFailure.malformedEvent }
		guard let configuration else { throw WebRTCTransportFailure.malformedEvent }
		switch configuration.provider {
		case .localAI:
			guard configurationDispatchedAtAcceptance || !Self.identifiesLocalAISessionUpdated(data) else {
				throw WebRTCTransportFailure.malformedEvent
			}
			do {
				guard let inbound = try WebRTCInboundEventDecoder().decodeForConnector(data) else { return }
				receive(.success(.inbound(inbound)))
			} catch let failure as WebRTCTransportFailure {
				let acknowledgementRejected = configurationAcknowledgementPending &&
					(failure == .malformedEvent || failure == .invalidRequest) &&
					Self.identifiesLocalAISessionUpdated(data)
				throw acknowledgementRejected ? WebRTCTransportFailure.providerError : failure
			}
		case .openAI:
			guard let event = try openAIState?.consume(data) else { return }
			switch event {
			case .sessionCreated:
				guard !eventStorage.iteratorCancellationSelected else { throw WebRTCTransportFailure.cancelled }
				let admitted: Bool?
				do { admitted = try backing.dispatchOpenAIConfiguration(configuration.encoded(), offeringCreationTo: eventStorage) }
				catch {
					// A reentrant backing terminal already owns settlement.
					guard !terminal, !settlementStarting else { return }
					throw error
				}
				guard !terminal, !settlementStarting, let admitted else { return }
				guard admitted else {
					startSettlement(failure: .ingressOverloaded, origin: .backing)
					return
				}
			case .sessionAcknowledged:
				guard yield(.openAISessionConfigured(language: configuration.language)) else { return }
				connected = true
			case let .userTranscript(text): guard yield(.userTranscript(text)) else { return }
			case let .assistantTranscript(text): guard yield(.assistantTranscript(text)) else { return }
			case let .openAIResponse(responseEvent):
				if case .started = responseEvent { settledCancellationReservation = nil }
				guard yield(.openAIResponse(responseEvent)) else { return }
			}
		}
	}

	private nonisolated static func identifiesLocalAISessionUpdated(_ data: Data) -> Bool {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
		return object["type"] as? String == "session.updated"
	}

	private func yield(_ event: WebRTCConnectorEvent) -> Bool {
		guard eventStorage.offer(event) else {
			startSettlement(failure: .ingressOverloaded, origin: .backing)
			return false
		}
		return true
	}

	private func admitReady() -> Bool {
		guard answerApplied, !ready, yield(.ready) else { return false }
		ready = true
		return true
	}

	private func sendCommand(_ command: ProductionCommand) throws {
		guard isConnected else { try rejectCommand() }
		do { try backing.sendProductionCommand(command) }
		catch {
			let failure = Self.contentFree(error)
			startSettlement(failure: failure, origin: .caller)
			throw failure
		}
	}

	private func rejectCommand() throws -> Never {
		startSettlement(failure: .invalidRequest, origin: .caller)
		throw WebRTCTransportFailure.invalidRequest
	}
	private func rejectSelectedIteratorCancellation() throws {
		guard eventStorage.iteratorCancellationSelected else { return }
		startSettlement(failure: .cancelled, origin: .caller)
		throw WebRTCTransportFailure.cancelled
	}

	private func beginSettlement(failure: WebRTCTransportFailure?, origin: SettlementOrigin) async { await startSettlement(failure: failure, origin: origin).value }
	@discardableResult private func startSettlement(failure: WebRTCTransportFailure?, origin: SettlementOrigin) -> Task<Void, Never> {
		let failure = productionSession == .openAI
			? eventStorage.beginTerminalSelection(using: terminalSelection, failure: failure)
			: terminalSelection.failureForSettlement(failure)
		if let settlementTask {
			if terminalFailure == nil, let failure, origin == .backing { terminalFailure = failure }
			return settlementTask
		}
		guard !terminal, !settlementStarting else { return Task {} }
		settlementStarting = true
		backing.setLocalAudioState(.disabled)
		eventStorage.beginTerminalSelection()
		terminal = true
		openAIState?.invalidate()
		pendingCancellationReservation = nil
		settledCancellationReservation = nil
		terminalFailure = failure
		let task = Task { @MainActor [self] in
			let offerOperation = self.offerOperation
			let answerOperation = self.answerOperation
			offerOperation?.cancel()
			answerOperation?.cancel()
			let backing = self.backing
			let backingClose = Task { @MainActor [backing] in await backing.closeAndSettle() }
			await backingClose.value
			_ = await offerOperation?.result
			_ = await answerOperation?.result
			await self.eventStorage.waitForAdmittedDeliveries()
			self.eventStorage.finish(failure: self.terminalFailure)
			self.settlementTask = nil
		}
		settlementTask = task
		return task
	}

	private func selectCallerCancellationIfNeeded() -> Bool {
		if terminalSelection.cancellationWins() { return true }
		guard !terminal, Task.isCancelled else { return false }
		return terminalSelection.selectCancellation()
	}

	fileprivate static func contentFree(_ error: any Error) -> WebRTCTransportFailure {
		if error is CancellationError { return .cancelled }
		return (error as? WebRTCTransportFailure) ?? .requestFailed
	}
	private static func isValidText(_ text: String) -> Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 8 * 1024
	}
}

package enum ProductionCommand: Encodable {
	case userText(String)
	case createResponse, cancelResponse, cancelResponseTargeted(String), clearOutputAudio
	func encoded() throws -> Data {
		switch self {
		case let .userText(text): return try JSONEncoder().encode(UserTextEvent(type: "conversation.item.create", item: .init(id: Self.itemID(), type: "message", role: "user", status: "completed", content: [.init(type: "input_text", text: text)])))
		case .createResponse: return try JSONEncoder().encode(TypeEvent(type: "response.create"))
		case .cancelResponse: return try JSONEncoder().encode(TypeEvent(type: "response.cancel"))
		case let .cancelResponseTargeted(responseID): return try JSONEncoder().encode(CancelEvent(type: "response.cancel", responseID: responseID))
		case .clearOutputAudio: return try JSONEncoder().encode(TypeEvent(type: "output_audio_buffer.clear"))
		}
	}
	private static func itemID() -> String { UUID().uuidString }
	private struct TypeEvent: Encodable { let type: String }
	private struct CancelEvent: Encodable { let type: String; let responseID: String
		enum CodingKeys: String, CodingKey { case type; case responseID = "response_id" }
	}
	private struct UserTextEvent: Encodable { let type: String; let item: Item }
	private struct Item: Encodable { let id: String; let type: String; let role: String; let status: String; let content: [Content] }
	private struct Content: Encodable { let type: String; let text: String }
}
