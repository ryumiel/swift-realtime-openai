import Core
import Foundation

/// The initial local-audio gate for an ordinary WebRTC peer.
public enum WebRTCLocalAudioState: Sendable, Equatable {
	case enabled
	case disabled
}

/// A validated initial provider session configuration.
public struct WebRTCSessionConfiguration: Sendable, Equatable {
	fileprivate enum Provider: Sendable, Equatable {
		case localAI(voice: String, language: String)
		case openAI(language: String)
	}

	fileprivate let provider: Provider

	private init(provider: Provider) {
		self.provider = provider
	}

	public static func localAI(voice: String, language: String) throws -> Self {
		let update = try WebRTCSessionUpdate(voice: voice, language: language)
		return Self(provider: .localAI(voice: update.voice, language: update.language))
	}

	/// The OpenAI case is reserved for the later provider-specific state machine.
	public static func openAI(language: String) throws -> Self {
		guard ["en", "ko", "ja"].contains(language) else {
			throw WebRTCTransportFailure.invalidRequest
		}
		return Self(provider: .openAI(language: language))
	}
}

/// Content-safe events from an ordinary production peer.
public enum WebRTCConnectorEvent: Sendable, Equatable {
	case connected
	case localAISessionConfigured(voice: String, language: String)
	case userTranscript(String)
	case assistantTranscript(String)
	case responseFinished
	case closed
}

/// The bounded production WebRTC lifecycle. It deliberately has no raw-provider
/// event, injected-media, diagnostic, renderer, or statistics operation.
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

/// Creates exactly one real-media production peer with an explicit initial
/// audio state. It intentionally offers no injected-peer construction.
@MainActor public struct WebRTCConnectorPeerFactory: Sendable {
	private let initialAudioState: WebRTCLocalAudioState

	public init(initialAudioState: WebRTCLocalAudioState) {
		self.initialAudioState = initialAudioState
	}

	public func makePeer() throws -> any WebRTCConnectorPeer {
		try ProductionWebRTCConnectorPeer(
			connector: WebRTCConnector.createProduction(initialAudioState: initialAudioState)
		)
	}
}

@MainActor private final class ProductionWebRTCConnectorPeer: WebRTCConnectorPeer, @unchecked Sendable {
	let events: AsyncThrowingStream<WebRTCConnectorEvent, any Error>
	private let stream: AsyncThrowingStream<WebRTCConnectorEvent, any Error>.Continuation
	private let connector: WebRTCConnector
	private var forwardingTask: Task<Void, Never>?
	private var configuration: WebRTCSessionConfiguration?
	private var connected = false
	private var isClosed = false

	init(connector: WebRTCConnector) {
		self.connector = connector
		(events, stream) = AsyncThrowingStream.makeStream(
			of: WebRTCConnectorEvent.self,
			bufferingPolicy: .bufferingOldest(2)
		)
		let inboundEvents = connector.events
		forwardingTask = Task { [weak self, inboundEvents] in
			do {
				for try await event in inboundEvents {
					guard !Task.isCancelled else { return }
					await self?.receive(event)
				}
				self?.finish()
			} catch {
				self?.finish(throwing: error)
			}
		}
	}

	func makeOffer() async throws -> String {
		guard !isClosed else { throw WebRTCTransportFailure.cancelled }
		return try await connector.makeOffer()
	}

	func apply(remoteAnswer: String) async throws {
		guard !isClosed, !remoteAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw WebRTCTransportFailure.invalidSDP
		}
		try await connector.apply(answer: remoteAnswer)
	}

	func configure(_ configuration: WebRTCSessionConfiguration) throws {
		guard !isClosed, self.configuration == nil else { throw WebRTCTransportFailure.invalidRequest }
		switch configuration.provider {
		case let .localAI(voice, language):
			try connector.sendSessionUpdate(voice: voice, language: language)
			self.configuration = configuration
		case .openAI:
			throw WebRTCTransportFailure.unsupportedEvent
		}
	}

	func sendUserText(_ text: String) throws {
		guard isReadyForCommands, Self.isValidText(text) else { throw WebRTCTransportFailure.invalidRequest }
		try connector.sendProductionCommand(.userText(text))
	}

	func createResponse() throws {
		guard isReadyForCommands else { throw WebRTCTransportFailure.invalidRequest }
		try connector.sendProductionCommand(.createResponse)
	}

	func cancelResponse() throws {
		guard isReadyForCommands else { throw WebRTCTransportFailure.invalidRequest }
		try connector.sendProductionCommand(.cancelResponse)
	}

	func clearOutputAudio() throws {
		guard isReadyForCommands else { throw WebRTCTransportFailure.invalidRequest }
		try connector.sendProductionCommand(.clearOutputAudio)
	}

	func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		guard !isClosed else { return }
		connector.setLocalAudioState(state)
	}

	func closeAndJoin() async {
		guard !isClosed else {
			await forwardingTask?.value
			return
		}
		isClosed = true
		connector.setLocalAudioState(.disabled)
		await connector.closeAndSettle()
		_ = stream.yield(.closed)
		stream.finish()
		forwardingTask?.cancel()
		await forwardingTask?.value
	}

	private var isReadyForCommands: Bool {
		!isClosed && connected && configuration != nil
	}

	private func receive(_ event: WebRTCInboundEvent) async {
		guard !isClosed else { return }
		switch event {
		case let .sessionUpdated(voice, language):
			guard case let .localAI(expectedVoice, expectedLanguage)? = configuration?.provider,
				expectedVoice == voice, expectedLanguage == language
			else {
				await failClosed(.malformedEvent)
				return
			}
			guard yield(.localAISessionConfigured(voice: voice, language: language)) else { return }
			connected = true
			_ = yield(.connected)
		case let .userTranscript(transcript):
			guard connected else { await failClosed(.malformedEvent); return }
			_ = yield(.userTranscript(transcript))
		case let .assistantTranscript(transcript):
			guard connected else { await failClosed(.malformedEvent); return }
			_ = yield(.assistantTranscript(transcript))
		case .responseFinished:
			guard connected else { await failClosed(.malformedEvent); return }
			_ = yield(.responseFinished)
		case .providerError:
			await failClosed(.providerError)
		}
	}

	private func yield(_ event: WebRTCConnectorEvent) -> Bool {
		switch stream.yield(event) {
		case .enqueued: return true
		case .dropped, .terminated:
			Task { @MainActor [weak self] in await self?.failClosed(.ingressOverloaded) }
			return false
		@unknown default:
			Task { @MainActor [weak self] in await self?.failClosed(.ingressOverloaded) }
			return false
		}
	}

	private func failClosed(_ failure: WebRTCTransportFailure) async {
		guard !isClosed else { return }
		isClosed = true
		connector.setLocalAudioState(.disabled)
		await connector.closeAndSettle()
		stream.finish(throwing: failure)
	}

	private func finish(throwing error: (any Error)? = nil) {
		guard !isClosed else { return }
		isClosed = true
		if let error { stream.finish(throwing: error) }
		else {
			_ = yield(.closed)
			stream.finish()
		}
	}

	private static func isValidText(_ text: String) -> Bool {
		text == text.trimmingCharacters(in: .whitespacesAndNewlines)
			&& !text.isEmpty
			&& text.utf8.count <= 8 * 1024
			&& text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
	}
}

package enum ProductionCommand: Encodable {
	case userText(String)
	case createResponse
	case cancelResponse
	case clearOutputAudio

	func encoded() throws -> Data {
		switch self {
		case let .userText(text):
			return try JSONEncoder().encode(UserTextEvent(type: "conversation.item.create", item: .init(
				type: "message", role: "user", content: [.init(type: "input_text", text: text)]
			)))
		case .createResponse: return try JSONEncoder().encode(TypeEvent(type: "response.create"))
		case .cancelResponse: return try JSONEncoder().encode(TypeEvent(type: "response.cancel"))
		case .clearOutputAudio: return try JSONEncoder().encode(TypeEvent(type: "output_audio_buffer.clear"))
		}
	}

	private struct TypeEvent: Encodable { let type: String }
	private struct UserTextEvent: Encodable { let type: String; let item: Item }
	private struct Item: Encodable { let type: String; let role: String; let content: [Content] }
	private struct Content: Encodable { let type: String; let text: String }
}
