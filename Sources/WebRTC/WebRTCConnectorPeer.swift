import Core
import Foundation

public enum WebRTCLocalAudioState: Sendable, Equatable { case enabled, disabled }

public struct WebRTCSessionConfiguration: Sendable, Equatable {
	fileprivate enum Provider: Sendable, Equatable { case localAI(voice: String), openAI }
	fileprivate let provider: Provider
	fileprivate let language: String

	private init(provider: Provider, language: String) {
		self.provider = provider
		self.language = language
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

public enum WebRTCConnectorEvent: Sendable, Equatable {
	case ready
	case localAISessionConfigured(voice: String, language: String)
	case openAISessionCreated
	case openAISessionConfigured(language: String)
	case connected
	case userTranscript(String)
	case assistantTranscript(String)
	case responseStarted
	case responseFinished
	case responseCancellationTerminalObserved
	case closed
}

@MainActor public protocol WebRTCConnectorPeer: Sendable {
	var events: AsyncThrowingStream<WebRTCConnectorEvent, any Error> { get }
	func makeOffer() async throws -> String
	func apply(remoteAnswer: String) async throws
	func configure(_ configuration: WebRTCSessionConfiguration) throws
	func sendUserText(_ text: String) throws
	func createResponse() throws
	func cancelResponse() throws
	func clearOutputAudio() throws
	func settleCancelledResponse() throws
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	func closeAndJoin() async
}

/// Synchronously records whether caller cancellation beat terminal selection.
/// Normal close remains a normal close, but a cancellation selected before any
/// actor hop is preserved until settlement installs its public terminal.
private final class ProductionTerminalSelection: @unchecked Sendable {
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
	case rawInbound(Data)
	case terminal(WebRTCTransportFailure?)
}
package enum ProductionSessionSelection: Sendable, Equatable {
	case localAI, openAI
	init(initialAudioState: WebRTCLocalAudioState) { self = initialAudioState == .disabled ? .openAI : .localAI }
}

@MainActor package protocol WebRTCConnectorPeerBacking: Sendable {
	func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)
	func makeOffer() async throws -> String
	func apply(answer: String) async throws
	func sendSessionConfiguration(_ data: Data) throws
	func sendProductionCommand(_ command: ProductionCommand) throws
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	func closeAndSettle() async
}

@MainActor public struct WebRTCConnectorPeerFactory: Sendable {
	private let makePeerClosure: @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking
	private let initialAudioState: WebRTCLocalAudioState

	public init(initialAudioState: WebRTCLocalAudioState) {
		self.initialAudioState = initialAudioState
		makePeerClosure = { try WebRTCConnector.createProduction(initialAudioState: initialAudioState) }
	}

	package init(makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking) {
		initialAudioState = .enabled
		makePeerClosure = makePeer
	}

	/// Keeps deterministic direct-fork tests on the same initial-audio contract
	/// as the production factory without making injection available to consumers.
	package init(initialAudioState: WebRTCLocalAudioState, makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking) {
		self.initialAudioState = initialAudioState
		makePeerClosure = {
			let backing = try makePeer()
			backing.setLocalAudioState(initialAudioState)
			return backing
		}
	}

	public func makePeer() throws -> any WebRTCConnectorPeer {
		do { return try ProductionWebRTCConnectorPeer(backing: makePeerClosure(), initialAudioState: initialAudioState) }
		catch { throw ProductionWebRTCConnectorPeer.contentFree(error) }
	}
}

@MainActor package final class ProductionWebRTCConnectorPeer: WebRTCConnectorPeer, @unchecked Sendable {
	private enum SettlementOrigin { case explicitClose, caller, backing }
	package let events: AsyncThrowingStream<WebRTCConnectorEvent, any Error>
	private let stream: AsyncThrowingStream<WebRTCConnectorEvent, any Error>.Continuation
	private let backing: any WebRTCConnectorPeerBacking
	private let initialAudioState: WebRTCLocalAudioState
	private let productionSession: ProductionSessionSelection
	private let terminalSelection = ProductionTerminalSelection()
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

	init(backing: any WebRTCConnectorPeerBacking, initialAudioState: WebRTCLocalAudioState) {
		self.backing = backing
		self.initialAudioState = initialAudioState
		productionSession = ProductionSessionSelection(initialAudioState: initialAudioState)
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorEvent.self, bufferingPolicy: .bufferingOldest(2))
		stream.onTermination = { [weak self] _ in
			guard let self else { return }
			Task { @MainActor [self] in await self.beginSettlement(failure: nil, origin: .caller) }
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
			self.configuration = configuration
			switch configuration.provider {
			case .localAI:
				guard productionSession == .localAI else { throw WebRTCTransportFailure.invalidRequest }
				try backing.sendSessionConfiguration(configuration.encoded())
				configurationAcknowledgementPending = true
			case .openAI:
				guard productionSession == .openAI, initialAudioState == .disabled else { throw WebRTCTransportFailure.invalidRequest }
				openAIState = try OpenAIProductionStateMachine(language: configuration.language)
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
	package func clearOutputAudio() throws { try sendCommand(.clearOutputAudio) }
	package func settleCancelledResponse() throws {
		guard openAIState != nil else { try rejectCommand() }
		do { try openAIState?.settleCancelledResponse() }
		catch { try rejectCommand() }
	}

	package func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		guard !terminal, !settlementStarting, state == .disabled || connected else { return }
		backing.setLocalAudioState(state)
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
		case let .rawInbound(data):
			do { try receiveRaw(data) }
			catch let failure as WebRTCTransportFailure { startSettlement(failure: failure, origin: .backing) }
			catch { startSettlement(failure: Self.contentFree(error), origin: .backing) }
		case let .inbound(inbound):
			switch inbound {
			case let .sessionUpdated(voice, language):
				guard ready, configurationAcknowledgementPending, let configuration,
					case let .localAI(expectedVoice) = configuration.provider,
					expectedVoice == voice, configuration.language == language,
					yield(.localAISessionConfigured(voice: voice, language: language)), yield(.connected)
				else { startSettlement(failure: .malformedEvent, origin: .backing); return }
				configurationAcknowledgementPending = false
				connected = true
			case let .userTranscript(text): guard connected, yield(.userTranscript(text)) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case let .assistantTranscript(text): guard connected, yield(.assistantTranscript(text)) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case .responseFinished: guard connected, yield(.responseFinished) else { startSettlement(failure: .malformedEvent, origin: .backing); return }; return
			case .providerError: startSettlement(failure: .providerError, origin: .backing); return
			}
		}
	}

	private func receiveRaw(_ data: Data) throws {
		guard ready else { throw WebRTCTransportFailure.malformedEvent }
		guard let configuration else { throw WebRTCTransportFailure.malformedEvent }
		switch configuration.provider {
		case .localAI:
			guard let inbound = try WebRTCInboundEventDecoder().decodeForConnector(data) else { return }
			receive(.success(.inbound(inbound)))
		case .openAI:
			guard let event = try openAIState?.consume(data) else { return }
			switch event {
			case .sessionCreated:
				guard yield(.openAISessionCreated) else { return }
				try backing.sendSessionConfiguration(configuration.encoded())
			case .sessionAcknowledged:
				guard yield(.openAISessionConfigured(language: configuration.language)) else { return }
				connected = true
			case let .userTranscript(text): guard yield(.userTranscript(text)) else { return }
			case let .assistantTranscript(text): guard yield(.assistantTranscript(text)) else { return }
			case .responseStarted: guard yield(.responseStarted) else { return }
			case .responseFinished: guard yield(.responseFinished) else { return }
			case .cancellationTerminalObserved: guard yield(.responseCancellationTerminalObserved) else { return }
			}
		}
	}

	private func yield(_ event: WebRTCConnectorEvent) -> Bool {
		switch stream.yield(event) {
		case .enqueued: return true
		case .dropped, .terminated: startSettlement(failure: .ingressOverloaded, origin: .backing); return false
		@unknown default: startSettlement(failure: .ingressOverloaded, origin: .backing); return false
		}
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

	private func beginSettlement(failure: WebRTCTransportFailure?, origin: SettlementOrigin) async { await startSettlement(failure: failure, origin: origin).value }
	@discardableResult private func startSettlement(failure: WebRTCTransportFailure?, origin: SettlementOrigin) -> Task<Void, Never> {
		let failure = terminalSelection.failureForSettlement(failure)
		if let settlementTask {
			if terminalFailure == nil, let failure, origin == .backing { terminalFailure = failure }
			return settlementTask
		}
		guard !terminal, !settlementStarting else { return Task {} }
		settlementStarting = true
		backing.setLocalAudioState(.disabled)
		terminal = true
		openAIState?.invalidate()
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
			if let failure = self.terminalFailure { self.stream.finish(throwing: failure) }
			else {
				switch self.stream.yield(.closed) {
				case .enqueued: self.stream.finish()
				case .dropped, .terminated: self.stream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
				@unknown default: self.stream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
				}
			}
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
	case createResponse, cancelResponse, clearOutputAudio
	func encoded() throws -> Data {
		switch self {
		case let .userText(text): return try JSONEncoder().encode(UserTextEvent(type: "conversation.item.create", item: .init(id: Self.itemID(), type: "message", role: "user", status: "completed", content: [.init(type: "input_text", text: text)])))
		case .createResponse: return try JSONEncoder().encode(TypeEvent(type: "response.create"))
		case .cancelResponse: return try JSONEncoder().encode(TypeEvent(type: "response.cancel"))
		case .clearOutputAudio: return try JSONEncoder().encode(TypeEvent(type: "output_audio_buffer.clear"))
		}
	}
	private static func itemID() -> String { UUID().uuidString }
	private struct TypeEvent: Encodable { let type: String }
	private struct UserTextEvent: Encodable { let type: String; let item: Item }
	private struct Item: Encodable { let id: String; let type: String; let role: String; let status: String; let content: [Content] }
	private struct Content: Encodable { let type: String; let text: String }
}
