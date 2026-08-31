import WebRTC
import XCTest

final class WebRTCRegularImportProof: XCTestCase {
	@MainActor func testRegularImportExposesOnlyTheProductionPeerBoundary() throws {
		let _: WebRTCLocalAudioState = .disabled
		let _: WebRTCSessionProvider = .localAI
		let _: WebRTCConnectorEvent = .ready
		let _: WebRTCSessionConfiguration = try .localAI(voice: "Ono_Anna", language: "ja")
		let factory = WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled)
		_ = factory
	}
}
