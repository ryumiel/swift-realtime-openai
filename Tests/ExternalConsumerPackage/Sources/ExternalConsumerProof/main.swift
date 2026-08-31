import WebRTC

@MainActor
func exercise(_ peer: any WebRTCConnectorPeer, configuration: WebRTCSessionConfiguration) async throws {
	var events = peer.events.makeAsyncIterator()
	_ = try await peer.makeOffer()
	try await peer.apply(remoteAnswer: "answer")
	_ = try await events.next()
	try peer.configure(configuration)
	try peer.sendUserText(" text \n")
	try peer.createResponse()
	try peer.cancelResponse()
	try peer.clearOutputAudio()
	try peer.settleCancelledResponse()
	peer.setLocalAudioState(.enabled)
	peer.setLocalAudioState(.disabled)
	await peer.closeAndJoin()
}

@MainActor
func exerciseOpenAI(_ peer: any WebRTCConnectorPeer) async throws {
	try await exercise(peer, configuration: .openAI(language: "en"))
}

@main struct ExternalConsumerProof {
	static func main() throws {
		let _: WebRTCSessionProvider = .localAI
		_ = WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled)
		_ = WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled)
		_ = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		_ = try WebRTCSessionConfiguration.openAI(language: "en")
		_ = WebRTCConnectorEvent.ready
	}
}
