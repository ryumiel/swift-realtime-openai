import WebRTC
import XCTest

final class WebRTCRegularImportProof: XCTestCase {
	@MainActor func testRegularImportExposesOnlyTheProductionPeerBoundary() throws {
		let _: WebRTCLocalAudioState = .disabled
		let _: WebRTCConnectorEvent = .ready
		let _: WebRTCSessionConfiguration = try .localAI(voice: "Ono_Anna", language: "ja")
		let factory = WebRTCConnectorPeerFactory(initialAudioState: .enabled)
		_ = factory
	}
}
