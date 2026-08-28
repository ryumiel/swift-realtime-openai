import WebRTC
import XCTest

final class ExternalProductionImportProof: XCTestCase {
	@MainActor func testExternalConsumerCompilesEveryProductionOperation() throws {
		let factory = WebRTCConnectorPeerFactory(initialAudioState: .disabled)
		let configuration = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		let _: WebRTCConnectorEvent = .ready
		let _: WebRTCLocalAudioState = .enabled
		_ = factory
		_ = configuration
	}

	@MainActor func exercise(_ peer: any WebRTCConnectorPeer, configuration: WebRTCSessionConfiguration) async throws {
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		try peer.configure(configuration)
		try peer.sendUserText("text")
		try peer.createResponse()
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		peer.setLocalAudioState(.enabled)
		peer.setLocalAudioState(.disabled)
		await peer.closeAndJoin()
	}
}
