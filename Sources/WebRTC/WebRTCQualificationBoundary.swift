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
	case providerError
	case malformedEvent
	case unsupportedEvent
	case cancelled
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
		guard data.count <= WebRTCTransportLimits.maximumPayloadBytes else {
			throw WebRTCTransportFailure.eventTooLarge
		}
		do {
			let envelope = try JSONDecoder().decode(Envelope.self, from: data)
			switch envelope.type {
				case "conversation.item.input_audio_transcription.completed":
					guard let transcript = envelope.transcript, !transcript.isEmpty else { throw WebRTCTransportFailure.malformedEvent }
					return .userTranscript(transcript)
				case "response.output_audio_transcript.done":
					guard let transcript = envelope.transcript, !transcript.isEmpty else { throw WebRTCTransportFailure.malformedEvent }
					return .assistantTranscript(transcript)
				case "response.done": return .responseFinished
				case "error": return .providerError
				default: throw WebRTCTransportFailure.unsupportedEvent
			}
		} catch let failure as WebRTCTransportFailure {
			throw failure
		} catch {
			throw WebRTCTransportFailure.malformedEvent
		}
	}

	private struct Envelope: Decodable { let type: String; let transcript: String? }
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
