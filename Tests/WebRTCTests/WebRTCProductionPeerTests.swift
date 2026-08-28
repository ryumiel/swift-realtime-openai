import WebRTC
import XCTest

final class WebRTCProductionPeerTests: XCTestCase {
	func testLocalAIConfigurationValidatesVoiceAndLanguageBeforePeerConstruction() throws {
		let configuration = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		XCTAssertEqual(configuration, try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "JA"))
	}

	@MainActor func testProductionSurfaceHasExplicitAudioAndOnlyTypedCommands() {
		let factory = WebRTCConnectorPeerFactory(initialAudioState: .disabled)
		let _: WebRTCLocalAudioState = .enabled
		let _: WebRTCConnectorEvent = .closed
		_ = factory
	}

	@MainActor func testCloseAndJoinPublishesTerminalClosedEvent() async throws {
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled).makePeer()
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}

		await peer.closeAndJoin()
		let event = try await reader.value
		XCTAssertEqual(event, .closed)
	}
}
