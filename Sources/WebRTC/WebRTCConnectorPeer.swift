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
	private var offerMade = false
	private var answerApplied = false
	private var ready = false
	private var configuration: WebRTCSessionConfiguration?
	private var connected = false
	private var terminal = false

	init(backing: any WebRTCConnectorPeerBacking) {
		self.backing = backing
		(events, stream) = AsyncThrowingStream.makeStream(of: WebRTCConnectorEvent.self, bufferingPolicy: .bufferingOldest(2))
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
		guard !terminal, !offerMade else {
			await beginSettlement(failure: .invalidRequest)
			throw WebRTCTransportFailure.invalidRequest
		}
		do {
			let offer = try await backing.makeOffer()
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
		guard !terminal, offerMade, !answerApplied, !remoteAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			await beginSettlement(failure: .invalidSDP)
			throw WebRTCTransportFailure.invalidSDP
		}
		do {
			try await backing.apply(answer: remoteAnswer)
			answerApplied = true
		} catch {
			let failure = Self.contentFree(error)
			await beginSettlement(failure: failure)
			throw failure
		}
	}

	package func configure(_ configuration: WebRTCSessionConfiguration) throws {
		guard !terminal, offerMade, answerApplied, ready, self.configuration == nil else {
			beginSettlement(failure: .invalidRequest)
			throw WebRTCTransportFailure.invalidRequest
		}
		do {
			try backing.sendSessionUpdate(voice: configuration.voice, language: configuration.language)
			self.configuration = configuration
		} catch {
			let failure = Self.contentFree(error)
			beginSettlement(failure: failure)
			throw failure
		}
	}

	package func sendUserText(_ text: String) throws {
		guard isConnected, Self.isValidText(text) else { throw WebRTCTransportFailure.invalidRequest }
		try backing.sendProductionCommand(.userText(text))
	}
	package func createResponse() throws { guard isConnected else { throw WebRTCTransportFailure.invalidRequest }; try backing.sendProductionCommand(.createResponse) }
	package func cancelResponse() throws { guard isConnected else { throw WebRTCTransportFailure.invalidRequest }; try backing.sendProductionCommand(.cancelResponse) }
	package func clearOutputAudio() throws { guard isConnected else { throw WebRTCTransportFailure.invalidRequest }; try backing.sendProductionCommand(.clearOutputAudio) }

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
			guard answerApplied, !ready, yield(.ready) else { await beginSettlement(failure: .malformedEvent); return false }
			ready = true
			return true
		case let .inbound(inbound):
			switch inbound {
			case let .sessionUpdated(voice, language):
				guard ready, let configuration, configuration.voice == voice, configuration.language == language,
					yield(.localAISessionConfigured(voice: voice, language: language)), yield(.connected)
				else { await beginSettlement(failure: .malformedEvent); return false }
				connected = true
				return true
			case let .userTranscript(text): guard connected, yield(.userTranscript(text)) else { await beginSettlement(failure: .malformedEvent); return false }; return true
			case let .assistantTranscript(text): guard connected, yield(.assistantTranscript(text)) else { await beginSettlement(failure: .malformedEvent); return false }; return true
			case .responseFinished: guard connected, yield(.responseFinished) else { await beginSettlement(failure: .malformedEvent); return false }; return true
			case .providerError: await beginSettlement(failure: .providerError); return false
			}
		}
	}

	private func yield(_ event: WebRTCConnectorEvent) -> Bool {
		switch stream.yield(event) {
		case .enqueued: return true
		case .dropped, .terminated: beginSettlement(failure: .ingressOverloaded); return false
		@unknown default: beginSettlement(failure: .ingressOverloaded); return false
		}
	}

	private func beginSettlement(failure: WebRTCTransportFailure?) async { await beginSettlement(failure: failure).value }
	private func forwardingFinished(failure: WebRTCTransportFailure?) async {
		guard !terminal else { return }
		let _: Task<Void, Never> = beginSettlement(failure: failure)
	}
	@discardableResult private func beginSettlement(failure: WebRTCTransportFailure?) -> Task<Void, Never> {
		if let settlementTask { return settlementTask }
		terminal = true
		let task = Task { @MainActor [weak self] in
			guard let self else { return }
			self.backing.setLocalAudioState(.disabled)
			await self.backing.closeAndSettle()
			self.forwardingTask?.cancel()
			await self.forwardingTask?.value
			if let failure { self.stream.finish(throwing: failure) }
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
		text == text.trimmingCharacters(in: .whitespacesAndNewlines) && !text.isEmpty && text.utf8.count <= 8 * 1024
			&& text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
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
	private static func itemID() -> String { "item_" + UUID().uuidString.lowercased() }
	private struct TypeEvent: Encodable { let type: String }
	private struct UserTextEvent: Encodable { let type: String; let item: Item }
	private struct Item: Encodable { let id: String; let type: String; let role: String; let status: String; let content: [Content] }
	private struct Content: Encodable { let type: String; let text: String }
}
