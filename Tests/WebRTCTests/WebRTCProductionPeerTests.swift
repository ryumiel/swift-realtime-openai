@testable import WebRTC
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

	@MainActor func testPublicPeerOrdersReadyConfigurationAcknowledgementAndCommands() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()

		let offer = try await peer.makeOffer()
		XCTAssertEqual(offer, "offer")
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		let ready = try await iterator.next()
		XCTAssertEqual(ready, .ready)

		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		XCTAssertEqual(backing.sessionUpdates, ["Ono_Anna|ja"])
		backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		let configured = try await iterator.next()
		let connected = try await iterator.next()
		XCTAssertEqual(configured, .localAISessionConfigured(voice: "Ono_Anna", language: "ja"))
		XCTAssertEqual(connected, .connected)

		try peer.sendUserText("hello")
		try peer.createResponse()
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		XCTAssertEqual(backing.commandTypes, ["conversation.item.create", "response.create", "response.cancel", "output_audio_buffer.clear"])
		peer.setLocalAudioState(.enabled)
		XCTAssertEqual(backing.audioStates.last, .enabled)

		async let firstClose: Void = peer.closeAndJoin()
		async let secondClose: Void = peer.closeAndJoin()
		await firstClose
		await secondClose
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testSecondOfferFailsClosedAndJoinsTheBacking() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		do {
			_ = try await peer.makeOffer()
			XCTFail("A second offer must be rejected")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testTwoSlotOutputOverflowClosesBeforeLaterCommands() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		_ = try await iterator.next()
		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		for _ in 0..<5 { backing.emit(.inbound(.userTranscript("late"))) }
		try await Task.sleep(for: .milliseconds(20))
		XCTAssertThrowsError(try peer.createResponse())
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testRemoteTerminalUsesTheSameJoinableSettlement() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}

		backing.finishEvents()
		let event = try await reader.value
		XCTAssertEqual(event, .closed)
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}
}

@MainActor private final class FakeProductionBacking: WebRTCConnectorPeerBacking, @unchecked Sendable {
	let productionEvents: AsyncThrowingStream<WebRTCConnectorPeerBackingEvent, any Error>
	private let continuation: AsyncThrowingStream<WebRTCConnectorPeerBackingEvent, any Error>.Continuation
	private(set) var sessionUpdates: [String] = []
	private(set) var commandTypes: [String] = []
	private(set) var audioStates: [WebRTCLocalAudioState] = []
	private(set) var closeCount = 0

	init() {
		(productionEvents, continuation) = AsyncThrowingStream.makeStream(
			of: WebRTCConnectorPeerBackingEvent.self, bufferingPolicy: .bufferingOldest(2)
		)
	}

	func emit(_ event: WebRTCConnectorPeerBackingEvent) { _ = continuation.yield(event) }
	func finishEvents() { continuation.finish() }
	func makeOffer() async throws -> String { "offer" }
	func apply(answer: String) async throws { XCTAssertEqual(answer, "answer") }
	func sendSessionUpdate(voice: String, language: String) throws { sessionUpdates.append("\(voice)|\(language)") }
	func sendProductionCommand(_ command: ProductionCommand) throws {
		let object = try JSONSerialization.jsonObject(with: command.encoded()) as? [String: Any]
		commandTypes.append(object?["type"] as? String ?? "")
	}
	func setLocalAudioState(_ state: WebRTCLocalAudioState) { audioStates.append(state) }
	func closeAndSettle() async { closeCount += 1; continuation.finish() }
}
