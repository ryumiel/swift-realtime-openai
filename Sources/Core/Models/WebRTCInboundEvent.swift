/// The only Realtime event values emitted by the qualified WebRTC transport.
public enum WebRTCInboundEvent: Equatable, Sendable {
	case sessionUpdated(voice: String, language: String)
	case userTranscript(String)
	case assistantTranscript(String)
	case responseFinished
	case providerError
}
