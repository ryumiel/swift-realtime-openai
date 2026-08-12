/// The only Realtime event values emitted by the qualified WebRTC transport.
public enum WebRTCInboundEvent: Equatable, Sendable {
	case userTranscript(String)
	case assistantTranscript(String)
	case responseFinished
	case providerError
}
