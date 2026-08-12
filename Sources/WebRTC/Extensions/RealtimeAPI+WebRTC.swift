import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension RealtimeAPI {
	/// Connect to the OpenAI WebRTC Realtime API with the given request.
	static func webRTC(endpoint: URL, model: String, bearerToken: String? = nil) async throws -> RealtimeAPI {
		let signaling = try WebRTCSignalingRequest(endpoint: endpoint, model: model, bearerToken: bearerToken)
		return try RealtimeAPI(connector: await WebRTCConnector.create(connectingTo: signaling))
	}

	/// Connect to the OpenAI WebRTC Realtime API with the given authentication token and model.
	static func webRTC(ephemeralKey: String, model: Model = .gptRealtime) async throws -> RealtimeAPI {
		return try await webRTC(
			endpoint: URL(string: "https://api.openai.com/v1")!,
			model: model.rawValue,
			bearerToken: ephemeralKey
		)
	}
}
