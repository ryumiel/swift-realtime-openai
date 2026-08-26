import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Limits untrusted provider bodies before decoding or retaining them.
public enum WebRTCTransportLimits {
	public static let maximumPayloadBytes = 256 * 1024
}

/// Stable, payload-free failures exposed by the qualified WebRTC surface.
public enum WebRTCTransportFailure: Error, Equatable, Sendable {
	case invalidRequest
	case invalidModel
	case invalidSDP
	case requestFailed
	case invalidResponse
	case responseTooLarge
	case malformedResponse
	case eventTooLarge
	case ingressOverloaded
	case providerError
	case malformedEvent
	case unsupportedEvent
	case cancelled
	case iceGatheringTimedOut
}

/// A bounded partial session update for Airbridge's qualified WebRTC seam.
///
/// This deliberately does not reuse the provider's full-session model: that
/// model requires unrelated fields, restricts voice names, and cannot express
/// a language-only transcription patch without selecting a transcription
/// backend.
@_spi(AirbridgeQualification) public struct WebRTCSessionUpdate: Equatable, Sendable {
	public let voice: String
	public let language: String

	public init(voice: String, language: String) throws {
		guard Self.isValidVoice(voice), Self.isISO6391Language(language) else {
			throw WebRTCTransportFailure.invalidRequest
		}
		self.voice = voice
		self.language = language
	}

	public func encoded() throws -> Data {
		try JSONEncoder().encode(Event(
			type: "session.update",
			session: .init(
				type: "realtime",
				audio: .init(
					input: .init(transcription: .init(language: language)),
					output: .init(voice: voice)
				)
			)
		))
	}

	private static func isValidVoice(_ voice: String) -> Bool {
		guard voice == voice.trimmingCharacters(in: .whitespacesAndNewlines),
			(1...64).contains(voice.utf8.count)
		else { return false }
		return voice.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
	}

	private static func isISO6391Language(_ language: String) -> Bool {
		language.utf8.count == 2 && language.utf8.allSatisfy { (97...122).contains($0) }
	}

	private struct Event: Encodable { let type: String; let session: Session }
	private struct Session: Encodable { let type: String; let audio: Audio }
	private struct Audio: Encodable { let input: Input; let output: Output }
	private struct Input: Encodable { let transcription: Transcription }
	private struct Transcription: Encodable { let language: String }
	private struct Output: Encodable { let voice: String }
}

/// OpenAI's current Realtime session-update shape, isolated from the
/// LocalAI-compatible partial update used by Airbridge production.
///
/// This is intentionally available only through the qualification SPI. It is
/// not a general raw-event escape hatch and is fixed to the bounded synthetic
/// audio experiment that exercises manual input-buffer commit over WebRTC.
@_spi(AirbridgeQualification) public struct OpenAIWebRTCQualificationSessionUpdate: Equatable, Sendable {
	public let model: String
	public let voice: String

	public init(model: String, voice: String) throws {
		guard model == "gpt-realtime-2.1", ["marin", "cedar"].contains(voice) else {
			throw WebRTCTransportFailure.invalidRequest
		}
		self.model = model
		self.voice = voice
	}

	public func encoded() throws -> Data {
		try JSONEncoder().encode(Event(
			type: "session.update",
			session: .init(model: model, voice: voice)
		))
	}

	private struct Event: Encodable {
		let type: String
		let session: Session
	}

	private struct Session: Encodable {
		let type = "realtime"
		let model: String
		let outputModalities = ["audio"]
		let audio: Audio
		let instructions = "Respond briefly to the supplied synthetic audio."

		init(model: String, voice: String) {
			self.model = model
			audio = Audio(voice: voice)
		}

		private enum CodingKeys: String, CodingKey {
			case type, model, audio, instructions
			case outputModalities = "output_modalities"
		}
	}

	private struct Audio: Encodable {
		let input = Input()
		let output: Output

		init(voice: String) {
			output = Output(voice: voice)
		}
	}

	private struct Input: Encodable {
		let format = PCMInputFormat()

		private enum CodingKeys: String, CodingKey {
			case format
			case turnDetection = "turn_detection"
		}

		func encode(to encoder: any Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encode(format, forKey: .format)
			try container.encodeNil(forKey: .turnDetection)
		}
	}

	private struct PCMInputFormat: Encodable {
		let type = "audio/pcm"
		let rate = 24_000
	}

	private struct Output: Encodable {
		let format = PCMOutputFormat()
		let voice: String
	}

	private struct PCMOutputFormat: Encodable {
		let type = "audio/pcm"
	}
}

/// The minimal documented response trigger after a manually committed input
/// buffer. Session-level qualification policy owns the audio modality.
@_spi(AirbridgeQualification) public struct OpenAIWebRTCQualificationResponseCreate: Equatable, Sendable {
	public init() {}

	public func encoded() throws -> Data {
		try JSONEncoder().encode(Event(type: "response.create"))
	}

	private struct Event: Encodable { let type: String }
}

public struct WebRTCSignalingRequest: Sendable {
	public let endpoint: URL
	public let model: String
	public let bearerToken: String?

	public init(endpoint: URL, model: String, bearerToken: String?) throws {
		guard endpoint.query == nil, endpoint.fragment == nil, endpoint.user == nil, endpoint.password == nil,
			let scheme = endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https"
		else { throw WebRTCTransportFailure.invalidRequest }
		guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw WebRTCTransportFailure.invalidModel
		}
		if let bearerToken, bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			throw WebRTCTransportFailure.invalidRequest
		}
		self.endpoint = endpoint
		self.model = model
		self.bearerToken = bearerToken
	}

	public func makeRequest(localSDP: String) throws -> URLRequest {
		guard !localSDP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw WebRTCTransportFailure.invalidSDP
		}
		var request = URLRequest(url: endpoint.appendingPathComponent("realtime/calls"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		if let bearerToken {
			request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
		}
		request.httpBody = try JSONEncoder().encode(["sdp": localSDP, "model": model])
		return request
	}
}

public struct WebRTCSignalingHTTPResponse: Sendable {
	public let data: Data
	public let statusCode: Int
	public let contentType: String?

	public init(data: Data, statusCode: Int, contentType: String?) {
		self.data = data
		self.statusCode = statusCode
		self.contentType = contentType
	}
}

public protocol WebRTCSignalingSession: Sendable {
	func data(for request: URLRequest) async throws -> WebRTCSignalingHTTPResponse
}

/// The dedicated session never shares cookies, caches, credentials, or redirects.
public final class URLSessionWebRTCSignalingSession: NSObject, WebRTCSignalingSession, @unchecked Sendable {
	// URLSession delegate callbacks are serialized by Foundation; this wrapper only forwards
	// immutable request/response values and rejects every redirect before it can be followed.
	public static func configuration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 30
		configuration.timeoutIntervalForResource = 30
		return configuration
	}

	private let session: URLSession

	public override init() {
		session = URLSession(configuration: Self.configuration(), delegate: RedirectRejectingDelegate(), delegateQueue: nil)
		super.init()
	}

	public func data(for request: URLRequest) async throws -> WebRTCSignalingHTTPResponse {
		do {
			let (data, response) = try await session.data(for: request)
			guard let response = response as? HTTPURLResponse else { throw WebRTCTransportFailure.invalidResponse }
			return WebRTCSignalingHTTPResponse(
				data: data,
				statusCode: response.statusCode,
				contentType: response.value(forHTTPHeaderField: "Content-Type")
			)
		} catch is CancellationError {
			throw WebRTCTransportFailure.cancelled
		} catch let error as URLError where error.code == .cancelled {
			throw WebRTCTransportFailure.cancelled
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.requestFailed
		}
	}

	package final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
		// Foundation owns delegate invocation; this object retains no request, credential, or response data.
		package func urlSession(
			_: URLSession,
			task _: URLSessionTask,
			willPerformHTTPRedirection _: HTTPURLResponse,
			newRequest _: URLRequest,
			completionHandler: @escaping @Sendable (URLRequest?) -> Void
		) {
			completionHandler(nil)
		}
	}
}

public struct WebRTCSignalingAnswer: Equatable, Sendable {
	public let sdp: String
	let sessionID: String
}

public struct WebRTCSignalingClient: Sendable {
	private let session: any WebRTCSignalingSession

	public init(session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession()) {
		self.session = session
	}

	public func answer(for request: URLRequest) async throws -> WebRTCSignalingAnswer {
		let response: WebRTCSignalingHTTPResponse
		do {
			response = try await session.data(for: request)
		} catch is CancellationError {
			throw WebRTCTransportFailure.cancelled
		} catch let error as URLError where error.code == .cancelled {
			throw WebRTCTransportFailure.cancelled
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.requestFailed
		}
		guard response.data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.responseTooLarge
		}
		guard response.statusCode == 201,
			let contentType = response.contentType,
			Self.isJSONMediaType(contentType)
		else { throw WebRTCTransportFailure.invalidResponse }
		do {
			let answer = try JSONDecoder().decode(Response.self, from: response.data)
			guard !answer.sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
				!answer.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else { throw WebRTCTransportFailure.malformedResponse }
			return WebRTCSignalingAnswer(sdp: answer.sdp, sessionID: answer.sessionID)
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedResponse
		}
	}

	private struct Response: Decodable {
		let sdp: String
		let sessionID: String

		enum CodingKeys: String, CodingKey { case sdp; case sessionID = "session_id" }
	}

	private static func isJSONMediaType(_ value: String) -> Bool {
		let mediaType = value.split(separator: ";", maxSplits: 1).first?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return mediaType?.caseInsensitiveCompare("application/json") == .orderedSame
	}
}

public struct WebRTCInboundEventDecoder: Sendable {
	public init() {}

	public func decode(_ data: Data) throws -> WebRTCInboundEvent {
		guard let event = try decode(data, permitsKnownAudioLifecycleEvents: false) else {
			throw WebRTCTransportFailure.unsupportedEvent
		}
		return event
	}

	package func decodeForConnector(_ data: Data) throws -> WebRTCInboundEvent? {
		try decode(data, permitsKnownAudioLifecycleEvents: true)
	}

	package func isSessionCreatedForConnector(_ data: Data) throws -> Bool {
		try hasEventType("session.created", data: data)
	}

	package func isSessionUpdatedForConnector(_ data: Data) throws -> Bool {
		try hasEventType("session.updated", data: data)
	}

	private func hasEventType(_ expectedType: String, data: Data) throws -> Bool {
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.eventTooLarge
		}
		do {
			return try JSONDecoder().decode(EventTypeEnvelope.self, from: data).type == expectedType
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
	}

	private func decode(
		_ data: Data,
		permitsKnownAudioLifecycleEvents: Bool
	) throws -> WebRTCInboundEvent? {
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.eventTooLarge
		}
		do {
			let envelope = try JSONDecoder().decode(Envelope.self, from: data)
			switch envelope.type {
				case "session.updated":
					guard envelope.session?.type == "realtime",
						let voice = envelope.session?.audio?.output?.voice,
						let language = envelope.session?.audio?.input?.transcription?.language
					else { throw WebRTCTransportFailure.malformedEvent }
					let update = try WebRTCSessionUpdate(voice: voice, language: language)
					return .sessionUpdated(voice: update.voice, language: update.language)
				case "conversation.item.input_audio_transcription.completed":
					guard let transcript = envelope.transcript, !transcript.isEmpty else { throw WebRTCTransportFailure.malformedEvent }
					return .userTranscript(transcript)
				case "response.output_audio_transcript.done":
					guard let transcript = envelope.transcript, !transcript.isEmpty else { throw WebRTCTransportFailure.malformedEvent }
					return .assistantTranscript(transcript)
				case "response.done":
					if permitsKnownAudioLifecycleEvents {
						guard let response = envelope.response,
							let output = response.output,
							output.allSatisfy(\.isOutputAudioMessage)
						else { throw WebRTCTransportFailure.unsupportedEvent }
					}
					return .responseFinished
				case "error": return .providerError
				case let type where permitsKnownAudioLifecycleEvents && Self.knownSimpleAudioLifecycleEventTypes.contains(type):
					return nil
				case "conversation.item.added" where permitsKnownAudioLifecycleEvents,
					"conversation.item.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isInputAudioMessage == true else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "response.created" where permitsKnownAudioLifecycleEvents:
					guard let response = envelope.response, response.output?.isEmpty != false else {
						throw WebRTCTransportFailure.unsupportedEvent
					}
					return nil
				case "response.output_item.added" where permitsKnownAudioLifecycleEvents,
					"response.output_item.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isOutputAudioMessage == true else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "response.content_part.added" where permitsKnownAudioLifecycleEvents,
					"response.content_part.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.part?.type == "output_audio" else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				default: throw WebRTCTransportFailure.unsupportedEvent
			}
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
	}

	private static let knownSimpleAudioLifecycleEventTypes: Set<String> = [
		"session.created",
		"input_audio_buffer.committed",
		"input_audio_buffer.cleared",
		"input_audio_buffer.speech_started",
		"input_audio_buffer.speech_stopped",
		"input_audio_buffer.timeout_triggered",
		"conversation.item.input_audio_transcription.delta",
		"conversation.item.input_audio_transcription.segment",
		"response.output_audio_transcript.delta",
		"response.output_audio.delta",
		"response.output_audio.done",
		"rate_limits.updated",
	]

	private struct Envelope: Decodable {
		let type: String
		let transcript: String?
		let item: ItemEnvelope?
		let part: ContentEnvelope?
		let response: ResponseEnvelope?
		let session: SessionEnvelope?
	}

	private struct EventTypeEnvelope: Decodable { let type: String }

	private struct SessionEnvelope: Decodable {
		let type: String?
		let audio: AudioEnvelope?
	}

	private struct AudioEnvelope: Decodable {
		let input: InputEnvelope?
		let output: OutputEnvelope?
	}

	private struct InputEnvelope: Decodable { let transcription: TranscriptionEnvelope? }
	private struct TranscriptionEnvelope: Decodable { let language: String? }
	private struct OutputEnvelope: Decodable { let voice: String? }

	private struct ItemEnvelope: Decodable {
		let type: String
		let role: String?
		let content: [ContentEnvelope]?

		var isInputAudioMessage: Bool {
			type == "message" && role == "user" && hasOnlyContent(type: "input_audio")
		}

		var isOutputAudioMessage: Bool {
			type == "message" && role == "assistant" && hasOnlyContent(type: "output_audio")
		}

		private func hasOnlyContent(type expectedType: String) -> Bool {
			guard let content, !content.isEmpty else { return false }
			return content.allSatisfy { $0.type == expectedType }
		}
	}

	private struct ContentEnvelope: Decodable { let type: String }
	private struct ResponseEnvelope: Decodable { let output: [ItemEnvelope]? }
}

/// Main-actor lifecycle identity and one terminal cleanup for the private connector.
@MainActor public final class WebRTCLifecycle {
	// The connector and every resource callback enter MainActor before touching this
	// state. The signaling task never leaves this boundary; terminal cleanup is inline.
	private var generation = 0
	private var terminal = false
	private var signalingTask: Task<String, Error>?

	public init() {}

	public func begin() -> Int {
		generation += 1
		terminal = false
		return generation
	}

	public func isCurrent(_ candidate: Int) -> Bool {
		candidate == generation && !terminal
	}

	public func installSignalingTask(_ task: Task<String, Error>, for candidate: Int) -> Bool {
		guard candidate == generation, !terminal else { return false }
		signalingTask = task
		return true
	}

	public func clearSignalingTask(for candidate: Int) {
		guard candidate == generation, !terminal else { return }
		signalingTask = nil
	}

	public func markTerminal(_ candidate: Int) -> Bool {
		guard candidate == generation, !terminal else { return false }
		terminal = true
		generation += 1
		return true
	}

	public func cancelSignalingTask() {
		signalingTask?.cancel()
		signalingTask = nil
	}
}
