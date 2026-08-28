import WebRTC

@MainActor
func exercise(_ peer: any WebRTCConnectorPeer, configuration: WebRTCSessionConfiguration) async throws {
	_ = try await peer.makeOffer()
	try await peer.apply(remoteAnswer: "answer")
	try peer.configure(configuration)
	try peer.sendUserText(" text \n")
	try peer.createResponse()
	try peer.cancelResponse()
	try peer.clearOutputAudio()
	peer.setLocalAudioState(.enabled)
	peer.setLocalAudioState(.disabled)
	await peer.closeAndJoin()
}

@main struct ExternalConsumerProof {
	static func main() throws {
		_ = WebRTCConnectorPeerFactory(initialAudioState: .disabled)
		_ = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		_ = try WebRTCSessionConfiguration.openAI(language: "en")
		_ = WebRTCConnectorEvent.ready
	}
}
