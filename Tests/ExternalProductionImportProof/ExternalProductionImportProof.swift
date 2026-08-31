import WebRTC
import XCTest

final class ExternalProductionImportProof: XCTestCase {
	@MainActor func testExternalConsumerCompilesEveryProductionOperation() throws {
		let factory = WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled)
		let openAIFactory = WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled)
		let configuration = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		let openAIConfiguration = try WebRTCSessionConfiguration.openAI(language: "en")
		let _: WebRTCConnectorEvent = .ready
		let _: WebRTCLocalAudioState = .enabled
		let _: WebRTCSessionProvider = .openAI
		_ = factory
		_ = openAIFactory
		_ = configuration
		_ = openAIConfiguration
	}

	@MainActor func exercise(_ peer: any WebRTCConnectorPeer, configuration: WebRTCSessionConfiguration) async throws {
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		_ = try await events.next()
		try peer.configure(configuration)
		try peer.sendUserText("text")
		try peer.createResponse()
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		try peer.settleCancelledResponse()
		peer.setLocalAudioState(.enabled)
		peer.setLocalAudioState(.disabled)
		await peer.closeAndJoin()
	}

	@MainActor func exerciseOpenAI(_ peer: any WebRTCConnectorPeer) async throws {
		try await exercise(peer, configuration: .openAI(language: "en"))
	}
}
