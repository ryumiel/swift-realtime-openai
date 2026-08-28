import Core
import Foundation

public enum WebRTCLocalAudioState: Sendable, Equatable { case enabled, disabled }

/// A validated LocalAI initial session configuration. OpenAI policy is added by
/// the later provider-specific task; it is intentionally not constructible yet.
public struct WebRTCSessionConfiguration: Sendable, Equatable {
	fileprivate let voice: String
	fileprivate let language: String

	private init(voice: String, language: String) {
		self.voice = voice
		self.language = language
	}

	public static func localAI(voice: String, language: String) throws -> Self {
		let update = try WebRTCSessionUpdate(voice: voice, language: language)
		return Self(voice: update.voice, language: update.language)
	}
}

public enum WebRTCConnectorEvent: Sendable, Equatable {
	case ready
	case localAISessionConfigured(voice: String, language: String)
	case connected
	case userTranscript(String)
	case assistantTranscript(String)
	case responseFinished
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
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	func closeAndJoin() async
}

/// Package-only deterministic test seam. It is not visible to normal imports.
package enum WebRTCConnectorPeerBackingEvent: Sendable, Equatable {
	case ready
	case inbound(WebRTCInboundEvent)
}

@MainActor package protocol WebRTCConnectorPeerBacking: Sendable {
	var productionEvents: AsyncThrowingStream<WebRTCConnectorPeerBackingEvent, any Error> { get }
	func makeOffer() async throws -> String
	func apply(answer: String) async throws
	func sendSessionUpdate(voice: String, language: String) throws
	func sendProductionCommand(_ command: ProductionCommand) throws
	func setLocalAudioState(_ state: WebRTCLocalAudioState)
	func closeAndSettle() async
}

@MainActor public struct WebRTCConnectorPeerFactory: Sendable {
	private let makePeerClosure: @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking

	public init(initialAudioState: WebRTCLocalAudioState) {
		makePeerClosure = { try WebRTCConnector.createProduction(initialAudioState: initialAudioState) }
	}

	package init(makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking) {
		makePeerClosure = makePeer
	}

	/// Keeps deterministic direct-fork tests on the same initial-audio contract
	/// as the production factory without making injection available to consumers.
	package init(initialAudioState: WebRTCLocalAudioState, makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorPeerBacking) {
		makePeerClosure = {
			let backing = try makePeer()
			backing.setLocalAudioState(initialAudioState)
			return backing
		}
	}

	public func makePeer() throws -> any WebRTCConnectorPeer {
		try ProductionWebRTCConnectorPeer(backing: makePeerClosure())
	}
}

@MainActor package final class ProductionWebRTCConnectorPeer: WebRTCConnectorPeer, @unchecked Sendable {
	package let events: AsyncThrowingStream<WebRTCConnectorEvent, any Error>
	private let stream: AsyncThrowingStream<WebRTCConnectorEvent, any Error>.Continuation
	private let backing: any WebRTCConnectorPeerBacking
	private var forwardingTask: Task<Void, Never>?
	private var settlementTask: Task<Void, Never>?
	private var terminalFailure: WebRTCTransportFailure?
	private var offerMade = false
	private var offerInFlight = false
	private var answerApplied = false
	private var answerInFlight = false
	private var pendingReady = false
	private var ready = false
	private var configuration: WebRTCSessionConfiguration?
	private var configurationAcknowledgementPending = false
	private var connected = false
	private var terminal = false

	init(backing: any WebRTCConnectorPeerBacking) {
		self.backing = backing
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorEvent.self, bufferingPolicy: .bufferingOldest(2))
		stream.onTermination = { [weak self] _ in
			Task { @MainActor in _ = self?.startSettlement(failure: nil) }
		}
		let source = backing.productionEvents
		forwardingTask = Task { [weak self, source] in
			do {
				for try await event in source {
					guard !Task.isCancelled, await self?.receive(event) != false else { break }
				}
				await self?.forwardingFinished(failure: nil)
			} catch {
				await self?.forwardingFinished(failure: Self.contentFree(error))
			}
		}
	}

	package func makeOffer() async throws -> String {
		guard !terminal, !offerMade, !offerInFlight else {
			await beginSettlement(failure: .invalidRequest)
			throw WebRTCTransportFailure.invalidRequest
		}
		offerInFlight = true
		defer { offerInFlight = false }
		do {
			let offer = try await backing.makeOffer()
			guard !terminal else { throw WebRTCTransportFailure.cancelled }
			guard !offer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebRTCTransportFailure.invalidSDP }
			offerMade = true
			return offer
		} catch {
			let failure = Self.contentFree(error)
			await beginSettlement(failure: failure)
			throw failure
		}
	}

	package func apply(remoteAnswer: String) async throws {
		guard !terminal, offerMade, !answerApplied, !answerInFlight, !remoteAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			await beginSettlement(failure: .invalidSDP)
			throw WebRTCTransportFailure.invalidSDP
		}
		answerInFlight = true
		defer { answerInFlight = false }
		do {
			try await backing.apply(answer: remoteAnswer)
			guard !terminal else { throw WebRTCTransportFailure.cancelled }
			answerApplied = true
			if pendingReady {
				pendingReady = false
				guard admitReady() else { throw WebRTCTransportFailure.malformedEvent }
			}
		} catch {
			let failure = Self.contentFree(error)
			await beginSettlement(failure: failure)
			throw failure
		}
	}

	package func configure(_ configuration: WebRTCSessionConfiguration) throws {
		guard !terminal, offerMade, answerApplied, ready, self.configuration == nil else {
			startSettlement(failure: .invalidRequest)
			throw WebRTCTransportFailure.invalidRequest
		}
		do {
			try backing.sendSessionUpdate(voice: configuration.voice, language: configuration.language)
			self.configuration = configuration
			configurationAcknowledgementPending = true
		} catch {
			let failure = Self.contentFree(error)
			startSettlement(failure: failure)
			throw failure
		}
	}

	package func sendUserText(_ text: String) throws {
		guard Self.isValidText(text) else { try rejectCommand() }
		try sendCommand(.userText(text))
	}
	package func createResponse() throws { try sendCommand(.createResponse) }
	package func cancelResponse() throws { try sendCommand(.cancelResponse) }
	package func clearOutputAudio() throws { try sendCommand(.clearOutputAudio) }

	package func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		guard !terminal, state == .disabled || connected else { return }
		backing.setLocalAudioState(state)
	}

	package func closeAndJoin() async { await beginSettlement(failure: nil) }
	private var isConnected: Bool { !terminal && connected }

	private func receive(_ event: WebRTCConnectorPeerBackingEvent) async -> Bool {
		guard !terminal else { return false }
		switch event {
		case .ready:
			guard !ready else { startSettlement(failure: .malformedEvent); return false }
			if answerInFlight { pendingReady = true; return true }
			guard admitReady() else { startSettlement(failure: .malformedEvent); return false }
			return true
		case let .inbound(inbound):
			switch inbound {
			case let .sessionUpdated(voice, language):
				guard ready, configurationAcknowledgementPending, let configuration, configuration.voice == voice, configuration.language == language,
					yield(.localAISessionConfigured(voice: voice, language: language)), yield(.connected)
				else { startSettlement(failure: .malformedEvent); return false }
				configurationAcknowledgementPending = false
				connected = true
				return true
			case let .userTranscript(text): guard connected, yield(.userTranscript(text)) else { startSettlement(failure: .malformedEvent); return false }; return true
			case let .assistantTranscript(text): guard connected, yield(.assistantTranscript(text)) else { startSettlement(failure: .malformedEvent); return false }; return true
			case .responseFinished: guard connected, yield(.responseFinished) else { startSettlement(failure: .malformedEvent); return false }; return true
			case .providerError: startSettlement(failure: .providerError); return false
			}
		}
	}

	private func yield(_ event: WebRTCConnectorEvent) -> Bool {
		switch stream.yield(event) {
		case .enqueued: return true
		case .dropped, .terminated: startSettlement(failure: .ingressOverloaded); return false
		@unknown default: startSettlement(failure: .ingressOverloaded); return false
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
			startSettlement(failure: failure)
			throw failure
		}
	}

	private func rejectCommand() throws -> Never {
		startSettlement(failure: .invalidRequest)
		throw WebRTCTransportFailure.invalidRequest
	}

	private func beginSettlement(failure: WebRTCTransportFailure?) async { await startSettlement(failure: failure).value }
	private func forwardingFinished(failure: WebRTCTransportFailure?) async {
		if terminal {
			if let failure { startSettlement(failure: failure) }
			return
		}
		startSettlement(failure: failure)
	}
	@discardableResult private func startSettlement(failure: WebRTCTransportFailure?) -> Task<Void, Never> {
		if let settlementTask {
			if terminalFailure == nil, let failure { terminalFailure = failure }
			return settlementTask
		}
		terminal = true
		terminalFailure = failure
		let task = Task { @MainActor [weak self] in
			guard let self else { return }
			self.backing.setLocalAudioState(.disabled)
			await self.backing.closeAndSettle()
			self.forwardingTask?.cancel()
			await self.forwardingTask?.value
			if let failure = self.terminalFailure { self.stream.finish(throwing: failure) }
			else {
				switch self.stream.yield(.closed) {
				case .enqueued: self.stream.finish()
				case .dropped, .terminated: self.stream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
				@unknown default: self.stream.finish(throwing: WebRTCTransportFailure.ingressOverloaded)
				}
			}
		}
		settlementTask = task
		return task
	}

	private static func contentFree(_ error: any Error) -> WebRTCTransportFailure { (error as? WebRTCTransportFailure) ?? .requestFailed }
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
