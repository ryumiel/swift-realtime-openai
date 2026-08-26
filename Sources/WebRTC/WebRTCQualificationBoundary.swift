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

/// OpenAI's current partial Realtime session-update shape, isolated from the
/// LocalAI-compatible partial update used by Airbridge production.
///
/// This is intentionally available only through the qualification SPI. It is
/// not a general raw-event escape hatch and is fixed to the bounded synthetic
/// audio experiment that exercises manual input-buffer commit over WebRTC.
@_spi(AirbridgeQualification) public struct OpenAIWebRTCQualificationSessionUpdate: Equatable, Sendable {
	public static let eventID = "airbridge-qualification-session-update"
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
			eventID: Self.eventID,
			type: "session.update",
			session: .init(voice: voice)
		))
	}

	private struct Event: Encodable {
		let eventID: String
		let type: String
		let session: Session

		private enum CodingKeys: String, CodingKey {
			case eventID = "event_id"
			case type
			case session
		}
	}

	private struct Session: Encodable {
		let type = "realtime"
		let audio: Audio

		init(voice: String) {
			audio = Audio(voice: voice)
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
		private enum CodingKeys: String, CodingKey {
			case turnDetection = "turn_detection"
		}

		func encode(to encoder: any Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encodeNil(forKey: .turnDetection)
		}
	}

	private struct Output: Encodable {
		let voice: String
	}
}

/// The minimal documented response trigger after a manually committed input
/// buffer. Session-level qualification policy owns the audio modality.
@_spi(AirbridgeQualification) public struct OpenAIWebRTCQualificationResponseCreate: Equatable, Sendable {
	public static let eventID = "airbridge-qualification-response-create"

	public init() {}

	public func encoded() throws -> Data {
		try JSONEncoder().encode(Event(
			eventID: Self.eventID,
			type: "response.create",
			response: Response()
		))
	}

	private struct Event: Encodable {
		let eventID: String
		let type: String
		let response: Response

		private enum CodingKeys: String, CodingKey {
			case eventID = "event_id"
			case type
			case response
		}
	}

	private struct Response: Encodable {
		let outputModalities = ["audio"]
		let maximumOutputTokens = 256

		private enum CodingKeys: String, CodingKey {
			case outputModalities = "output_modalities"
			case maximumOutputTokens = "max_output_tokens"
		}
	}
}

/// A fixed out-of-band audio-output control that does not consume conversation input.
@_spi(AirbridgeQualification) public struct OpenAIWebRTCQualificationOutputControl: Equatable, Sendable {
	public static let eventID = "airbridge-qualification-output-control"
	public init() {}

	public func encoded() throws -> Data {
		try JSONEncoder().encode(Event(
			eventID: Self.eventID,
			type: "response.create",
			response: Response()
		))
	}

	private struct Event: Encodable {
		let eventID: String
		let type: String
		let response: Response

		private enum CodingKeys: String, CodingKey {
			case eventID = "event_id"
			case type
			case response
		}
	}

	private struct Response: Encodable {
		let conversation = "none"
		let input: [String] = []
		let instructions = "Say one short greeting."
		let outputModalities = ["audio"]
		let maximumOutputTokens = 256

		private enum CodingKeys: String, CodingKey {
			case conversation
			case input
			case instructions
			case outputModalities = "output_modalities"
			case maximumOutputTokens = "max_output_tokens"
		}
	}
}

/// Content-free classifications retained from a provider `error` event.
///
/// Raw provider strings and messages never cross this boundary. Only exact,
/// documented identifiers selected by this allowlist are represented.
@_spi(AirbridgeQualification) public struct WebRTCProviderErrorEvidence: Equatable, Sendable {
	public enum ErrorType: String, Equatable, Sendable {
		case invalidRequest = "invalid_request_error"
		case server = "server_error"
		case unknown
	}

	public enum Code: String, Equatable, Sendable {
		case insufficientQuota = "insufficient_quota"
		case rateLimitExceeded = "rate_limit_exceeded"
		case inputAudioBufferCommitEmpty = "input_audio_buffer_commit_empty"
		case invalidAudioBuffer = "invalid_audio_buffer"
		case invalidAudioFormat = "invalid_audio_format"
		case invalidValue = "invalid_value"
		case modelNotFound = "model_not_found"
		case serverError = "server_error"
		case unknown
	}

	public enum Parameter: String, Equatable, Sendable {
		case session
		case sessionAudioInput = "session.audio.input"
		case sessionAudioInputFormat = "session.audio.input.format"
		case response
		case responseMaxOutputTokens = "response.max_output_tokens"
		case model
		case inputAudioBuffer = "input_audio_buffer"
		case none
		case unknown
	}

	public enum Trigger: String, Equatable, Sendable {
		case sessionUpdate = "session.update"
		case inputAudioClear = "input_audio_buffer.clear"
		case inputAudioCommit = "input_audio_buffer.commit"
		case responseCreate = "response.create"
		case outputControl = "output-control response.create"
		case none
		case unknown
	}

	public let type: ErrorType
	public let code: Code
	public let parameter: Parameter
	public let trigger: Trigger

	public init(type: ErrorType, code: Code, parameter: Parameter, trigger: Trigger) {
		self.type = type
		self.code = code
		self.parameter = parameter
		self.trigger = trigger
	}
}

/// Content-free terminal status from a qualification `response.done` event.
@_spi(AirbridgeQualification) public struct WebRTCResponseCompletionEvidence: Equatable, Sendable {
	public enum Status: String, Equatable, Sendable {
		case completed
		case failed
		case cancelled
		case incomplete
		case unknown
	}

	public let status: Status
	public let code: WebRTCProviderErrorEvidence.Code

	public init(status: Status, code: WebRTCProviderErrorEvidence.Code) {
		self.status = status
		self.code = code
	}
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

	package func isInputAudioCommittedForConnector(_ data: Data) throws -> Bool {
		try hasEventType("input_audio_buffer.committed", data: data)
	}

	package func isInputAudioClearedForConnector(_ data: Data) throws -> Bool {
		try hasEventType("input_audio_buffer.cleared", data: data)
	}

	package func isResponseCreatedForConnector(_ data: Data) throws -> Bool {
		guard try hasEventType("response.created", data: data) else { return false }
		do {
			let envelope = try JSONDecoder().decode(Envelope.self, from: data)
			guard let response = envelope.response, response.output?.isEmpty != false else {
				throw WebRTCTransportFailure.unsupportedEvent
			}
			return true
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
	}

	package func providerErrorEvidenceForConnector(
		_ data: Data
	) throws -> WebRTCProviderErrorEvidence? {
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.eventTooLarge
		}
		do {
			let envelope = try JSONDecoder().decode(Envelope.self, from: data)
			guard envelope.type == "error", let error = envelope.error else { return nil }
			let errorType: WebRTCProviderErrorEvidence.ErrorType
			switch error.type {
			case "invalid_request_error": errorType = .invalidRequest
			case "server_error": errorType = .server
			default: errorType = .unknown
			}
			let code: WebRTCProviderErrorEvidence.Code
			switch error.code {
			case "insufficient_quota": code = .insufficientQuota
			case "rate_limit_exceeded": code = .rateLimitExceeded
			case "input_audio_buffer_commit_empty": code = .inputAudioBufferCommitEmpty
			case "invalid_audio_buffer": code = .invalidAudioBuffer
			case "invalid_audio_format": code = .invalidAudioFormat
			case "invalid_value": code = .invalidValue
			case "model_not_found": code = .modelNotFound
			case "server_error": code = .serverError
			default: code = .unknown
			}
			let parameter: WebRTCProviderErrorEvidence.Parameter
			switch error.param {
			case "session": parameter = .session
			case "session.audio.input": parameter = .sessionAudioInput
			case "session.audio.input.format": parameter = .sessionAudioInputFormat
			case "response": parameter = .response
			case "response.max_output_tokens", "max_output_tokens": parameter = .responseMaxOutputTokens
			case "model": parameter = .model
			case "input_audio_buffer": parameter = .inputAudioBuffer
			case nil: parameter = .none
			default: parameter = .unknown
			}
			let trigger: WebRTCProviderErrorEvidence.Trigger
			switch error.eventID {
			case OpenAIWebRTCQualificationSessionUpdate.eventID: trigger = .sessionUpdate
			case "airbridge-qualification-input-audio-clear": trigger = .inputAudioClear
			case "airbridge-qualification-input-audio-commit": trigger = .inputAudioCommit
			case OpenAIWebRTCQualificationResponseCreate.eventID: trigger = .responseCreate
			case OpenAIWebRTCQualificationOutputControl.eventID: trigger = .outputControl
			case nil: trigger = .none
			default: trigger = .unknown
			}
			return WebRTCProviderErrorEvidence(
				type: errorType,
				code: code,
				parameter: parameter,
				trigger: trigger
			)
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
	}

	package func responseCompletionEvidenceForConnector(
		_ data: Data
	) throws -> WebRTCResponseCompletionEvidence? {
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.eventTooLarge
		}
		do {
			let envelope = try JSONDecoder().decode(Envelope.self, from: data)
			guard envelope.type == "response.done", let response = envelope.response,
				let output = response.output,
				output.allSatisfy(\.isOutputAudioMessage)
			else { return nil }
			let status: WebRTCResponseCompletionEvidence.Status
			switch response.status {
			case "completed": status = .completed
			case "failed": status = .failed
			case "cancelled": status = .cancelled
			case "incomplete": status = .incomplete
			default: status = .unknown
			}
			let code: WebRTCProviderErrorEvidence.Code
			switch response.statusDetails?.error?.code {
			case "insufficient_quota": code = .insufficientQuota
			case "rate_limit_exceeded": code = .rateLimitExceeded
			case "input_audio_buffer_commit_empty": code = .inputAudioBufferCommitEmpty
			case "invalid_audio_buffer": code = .invalidAudioBuffer
			case "invalid_audio_format": code = .invalidAudioFormat
			case "invalid_value": code = .invalidValue
			case "model_not_found": code = .modelNotFound
			case "server_error": code = .serverError
			default: code = .unknown
			}
			return .init(status: status, code: code)
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
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
				case "conversation.item.added" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isInputAudioMessage == true
						|| envelope.item?.isOutputAudioMessageStart == true
						|| envelope.item?.isOutputAudioMessage == true
					else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "conversation.item.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isInputAudioMessage == true
						|| envelope.item?.isOutputAudioMessage == true
					else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "response.created" where permitsKnownAudioLifecycleEvents:
					guard let response = envelope.response, response.output?.isEmpty != false else {
						throw WebRTCTransportFailure.unsupportedEvent
					}
					return nil
				case "response.output_item.added" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isOutputAudioMessageStart == true
						|| envelope.item?.isOutputAudioMessage == true
					else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "response.output_item.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.item?.isOutputAudioMessage == true else { throw WebRTCTransportFailure.unsupportedEvent }
					return nil
				case "response.content_part.added" where permitsKnownAudioLifecycleEvents,
					"response.content_part.done" where permitsKnownAudioLifecycleEvents:
					guard envelope.part?.isOutputAudio == true else { throw WebRTCTransportFailure.unsupportedEvent }
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
		let error: ErrorEnvelope?
		let item: ItemEnvelope?
		let part: ContentEnvelope?
		let response: ResponseEnvelope?
		let session: SessionEnvelope?
	}

	private struct ErrorEnvelope: Decodable {
		let type: String?
		let code: String?
		let param: String?
		let eventID: String?

		private enum CodingKeys: String, CodingKey {
			case type
			case code
			case param
			case eventID = "event_id"
		}
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
			type == "message" && role == "assistant"
				&& hasOnlyContent(types: ["audio", "output_audio"])
		}

		var isOutputAudioMessageStart: Bool {
			type == "message" && role == "assistant" && content?.isEmpty == true
		}

		private func hasOnlyContent(type expectedType: String) -> Bool {
			hasOnlyContent(types: [expectedType])
		}

		private func hasOnlyContent(types expectedTypes: Set<String>) -> Bool {
			guard let content, !content.isEmpty else { return false }
			return content.allSatisfy { expectedTypes.contains($0.type) }
		}
	}

	private struct ContentEnvelope: Decodable {
		let type: String

		var isOutputAudio: Bool {
			type == "audio" || type == "output_audio"
		}
	}
	private struct ResponseEnvelope: Decodable {
		let output: [ItemEnvelope]?
		let status: String?
		let statusDetails: StatusDetailsEnvelope?

		private enum CodingKeys: String, CodingKey {
			case output
			case status
			case statusDetails = "status_details"
		}
	}
	private struct StatusDetailsEnvelope: Decodable { let error: StatusErrorEnvelope? }
	private struct StatusErrorEnvelope: Decodable { let code: String? }
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
