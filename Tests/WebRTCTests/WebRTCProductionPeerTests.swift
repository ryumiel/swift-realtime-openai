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
		await backing.emit(.ready)
		let ready = try await iterator.next()
		XCTAssertEqual(ready, .ready)

		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		XCTAssertEqual(backing.sessionUpdates, ["Ono_Anna|ja"])
		await backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		let configured = try await iterator.next()
		let connected = try await iterator.next()
		XCTAssertEqual(configured, .localAISessionConfigured(voice: "Ono_Anna", language: "ja"))
		XCTAssertEqual(connected, .connected)

		try peer.sendUserText("  hello\n")
		try peer.createResponse()
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		XCTAssertEqual(backing.commandTypes, ["conversation.item.create", "response.create", "response.cancel", "output_audio_buffer.clear"])
		let userText = try XCTUnwrap(backing.commandObjects.first)
		XCTAssertEqual(userText["type"] as? String, "conversation.item.create")
		let item = try XCTUnwrap(userText["item"] as? [String: Any])
		XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(item["id"] as? String)))
		XCTAssertEqual(item["type"] as? String, "message")
		XCTAssertEqual(item["role"] as? String, "user")
		XCTAssertEqual(item["status"] as? String, "completed")
		let content = try XCTUnwrap(item["content"] as? [[String: Any]])
		XCTAssertEqual(content.count, 1)
		XCTAssertEqual(content[0]["type"] as? String, "input_text")
		XCTAssertEqual(content[0]["text"] as? String, "  hello\n")
		peer.setLocalAudioState(.enabled)
		XCTAssertEqual(backing.audioStates.last, .enabled)

		async let firstClose: Void = peer.closeAndJoin()
		async let secondClose: Void = peer.closeAndJoin()
		await firstClose
		await secondClose
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testInitialEnabledAudioIsSelectedThenDisabledBeforeClose() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .enabled, makePeer: { backing }).makePeer()
		XCTAssertEqual(backing.audioStates, [.enabled])

		await peer.closeAndJoin()
		XCTAssertEqual(backing.operationOrder, ["audio:enabled", "audio:disabled", "close"])
	}

	@MainActor func testConcurrentOfferIsRejectedWhileFirstOfferIsInFlight() async throws {
		let backing = FakeProductionBacking(suspendOffer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let first = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()

		do {
			_ = try await peer.makeOffer()
			XCTFail("Concurrent offer must be rejected")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		backing.resumeOffer()
		switch await first.result {
		case .success: XCTFail("A settled in-flight offer must not succeed late")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCloseDuringSuspendedOfferCannotPublishALateOffer() async throws {
		let backing = FakeProductionBacking(suspendOffer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let offer = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()
		await peer.closeAndJoin()
		backing.resumeOffer()
		switch await offer.result {
		case .success: XCTFail("Closing an in-flight offer must prevent a late success")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testReadinessRacingSuspendedAnswerIsAdmittedOnlyAfterAnswer() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		await backing.emit(.ready)
		backing.resumeAnswer()
		try await answer.value
		let ready = try await iterator.next()
		XCTAssertEqual(ready, .ready)
		await peer.closeAndJoin()
	}

	@MainActor func testConcurrentAnswerAndCloseDuringSuspendedAnswerCannotSucceedLate() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		let first = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		do {
			try await peer.apply(remoteAnswer: "answer")
			XCTFail("Concurrent answer must be rejected")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidSDP)
		}
		backing.resumeAnswer()
		switch await first.result {
		case .success: XCTFail("A settled in-flight answer must not succeed late")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
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
		await backing.emit(.ready)
		_ = try await iterator.next()
		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		await backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		for _ in 0..<5 { await backing.emit(.inbound(.userTranscript("late"))) }
		await backing.waitForClose()
		_ = try await iterator.next()
		_ = try await iterator.next()
		do {
			_ = try await iterator.next()
			XCTFail("The checked public output bound must terminate the stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .ingressOverloaded)
		}
		XCTAssertThrowsError(try peer.createResponse())
		await peer.closeAndJoin()
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

	@MainActor func testIteratorCancellationClosesOnceDisablesFirstAndRejectsLateWork() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}
		reader.cancel()
		_ = try? await reader.value
		await backing.waitForClose()
		await backing.emit(.ready)
		XCTAssertThrowsError(try peer.createResponse()) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
		XCTAssertEqual(backing.operationOrder.suffix(2), ["audio:disabled", "close"])
	}

	@MainActor func testMismatchedAndDuplicateAcknowledgementsFailClosedWithoutAnotherConnected() async throws {
		let mismatchedBacking = FakeProductionBacking()
		let mismatchedPeer = try WebRTCConnectorPeerFactory(makePeer: { mismatchedBacking }).makePeer()
		var mismatchedEvents = mismatchedPeer.events.makeAsyncIterator()
		_ = try await mismatchedPeer.makeOffer()
		try await mismatchedPeer.apply(remoteAnswer: "answer")
		await mismatchedBacking.emit(.ready)
		_ = try await mismatchedEvents.next()
		try mismatchedPeer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		await mismatchedBacking.emit(.inbound(.sessionUpdated(voice: "Other", language: "ja")))
		do {
			_ = try await mismatchedEvents.next()
			XCTFail("Mismatched acknowledgement must fail")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .malformedEvent)
		}
		await mismatchedPeer.closeAndJoin()
		XCTAssertEqual(mismatchedBacking.closeCount, 1)

		let duplicateBacking = FakeProductionBacking()
		let duplicatePeer = try WebRTCConnectorPeerFactory(makePeer: { duplicateBacking }).makePeer()
		var duplicateEvents = duplicatePeer.events.makeAsyncIterator()
		_ = try await duplicatePeer.makeOffer()
		try await duplicatePeer.apply(remoteAnswer: "answer")
		await duplicateBacking.emit(.ready)
		_ = try await duplicateEvents.next()
		try duplicatePeer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		await duplicateBacking.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		let configured = try await duplicateEvents.next()
		let connected = try await duplicateEvents.next()
		XCTAssertEqual(configured, .localAISessionConfigured(voice: "Ono_Anna", language: "ja"))
		XCTAssertEqual(connected, .connected)
		await duplicateBacking.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		do {
			_ = try await duplicateEvents.next()
			XCTFail("Duplicate acknowledgement must fail")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .malformedEvent)
		}
		await duplicatePeer.closeAndJoin()
		XCTAssertEqual(duplicateBacking.closeCount, 1)
	}

	@MainActor func testBackingErrorsAreContentFreeAndStaleCallbacksAreIgnoredAfterSettlement() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}
		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		switch await reader.result {
		case .success: XCTFail("Backing errors must terminate with a typed failure")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
		}
		await peer.closeAndJoin()
		await backing.emit(.ready)
		XCTAssertEqual(backing.closeCount, 1)
		XCTAssertEqual(backing.lastYieldWasTerminated, true)
	}

	@MainActor func testProviderMalformedAndRacingBackingFailuresEachJoinTheTerminalStream() async throws {
		let providerBacking = FakeProductionBacking()
		let providerPeer = try WebRTCConnectorPeerFactory(makePeer: { providerBacking }).makePeer()
		var providerEvents = providerPeer.events.makeAsyncIterator()
		await providerBacking.emit(.inbound(.providerError))
		do {
			_ = try await providerEvents.next()
			XCTFail("Provider terminal events must fail the stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .providerError)
		}
		await providerPeer.closeAndJoin()
		XCTAssertEqual(providerBacking.closeCount, 1)

		let malformedBacking = FakeProductionBacking()
		let malformedPeer = try WebRTCConnectorPeerFactory(makePeer: { malformedBacking }).makePeer()
		var malformedEvents = malformedPeer.events.makeAsyncIterator()
		await malformedBacking.emit(.ready)
		do {
			_ = try await malformedEvents.next()
			XCTFail("Readiness before an answer must fail the stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .malformedEvent)
		}
		await malformedPeer.closeAndJoin()
		XCTAssertEqual(malformedBacking.closeCount, 1)

		let racingBacking = FakeProductionBacking()
		let racingPeer = try WebRTCConnectorPeerFactory(makePeer: { racingBacking }).makePeer()
		var racingEvents = racingPeer.events.makeAsyncIterator()
		async let closing: Void = racingPeer.closeAndJoin()
		racingBacking.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		do {
			_ = try await racingEvents.next()
			XCTFail("A backing failure accepted while closing must retain its typed failure")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
		}
		await closing
		XCTAssertEqual(racingBacking.closeCount, 1)
	}

	@MainActor func testEveryCommandRejectsInvalidPhaseAndBackingFailureWithJoinedSettlement() async throws {
		for command in CommandCase.allCases {
			let invalidBacking = FakeProductionBacking()
			let invalidPeer = try WebRTCConnectorPeerFactory(makePeer: { invalidBacking }).makePeer()
			XCTAssertThrowsError(try command.invoke(invalidPeer)) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
			}
			await invalidPeer.closeAndJoin()
			XCTAssertEqual(invalidBacking.closeCount, 1)

			let failedBacking = FakeProductionBacking(commandError: FakeProductionBacking.ArbitraryError())
			let failedPeer = try WebRTCConnectorPeerFactory(makePeer: { failedBacking }).makePeer()
			var events = failedPeer.events.makeAsyncIterator()
			_ = try await failedPeer.makeOffer()
			try await failedPeer.apply(remoteAnswer: "answer")
			await failedBacking.emit(.ready)
			_ = try await events.next()
			try failedPeer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
			await failedBacking.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
			_ = try await events.next()
			_ = try await events.next()
			XCTAssertThrowsError(try command.invoke(failedPeer)) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
			}
			await failedPeer.closeAndJoin()
			XCTAssertEqual(failedBacking.closeCount, 1)
		}
	}

}

@MainActor private enum CommandCase: CaseIterable {
	case userText, createResponse, cancelResponse, clearOutputAudio
	func invoke(_ peer: any WebRTCConnectorPeer) throws {
		switch self {
		case .userText: try peer.sendUserText("  preserved whitespace\n")
		case .createResponse: try peer.createResponse()
		case .cancelResponse: try peer.cancelResponse()
		case .clearOutputAudio: try peer.clearOutputAudio()
		}
	}
}

@MainActor private final class FakeProductionBacking: WebRTCConnectorPeerBacking, @unchecked Sendable {
	let productionEvents: AsyncThrowingStream<WebRTCConnectorPeerBackingEvent, any Error>
	private let continuation: AsyncThrowingStream<WebRTCConnectorPeerBackingEvent, any Error>.Continuation
	private(set) var sessionUpdates: [String] = []
	private(set) var commandTypes: [String] = []
	private(set) var commandObjects: [[String: Any]] = []
	private(set) var audioStates: [WebRTCLocalAudioState] = []
	private(set) var closeCount = 0
	private(set) var operationOrder: [String] = []
	private(set) var lastYieldWasTerminated = false
	private var closeWaiter: CheckedContinuation<Void, Never>?
	private var offerStartWaiter: CheckedContinuation<Void, Never>?
	private var answerStartWaiter: CheckedContinuation<Void, Never>?
	private var offerContinuation: CheckedContinuation<String, Never>?
	private var answerContinuation: CheckedContinuation<Void, Never>?
	private let suspendOffer: Bool
	private let suspendAnswer: Bool
	private let commandError: (any Error)?

	struct ArbitraryError: Error {}

	init(suspendOffer: Bool = false, suspendAnswer: Bool = false, commandError: (any Error)? = nil) {
		self.suspendOffer = suspendOffer
		self.suspendAnswer = suspendAnswer
		self.commandError = commandError
		(productionEvents, continuation) = AsyncThrowingStream.makeStream(
			of: WebRTCConnectorPeerBackingEvent.self, bufferingPolicy: .bufferingOldest(0)
		)
	}

	func emit(_ event: WebRTCConnectorPeerBackingEvent) async {
		for _ in 0..<64 {
			switch continuation.yield(event) {
			case .enqueued: return
			case .terminated: lastYieldWasTerminated = true; return
			case .dropped: await Task.yield()
			@unknown default: await Task.yield()
			}
		}
		XCTFail("The controlled rendezvous source had no awaiting consumer")
	}
	func finishEvents(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }
	func makeOffer() async throws -> String {
		offerStartWaiter?.resume()
		offerStartWaiter = nil
		guard suspendOffer else { return "offer" }
		return await withCheckedContinuation { offerContinuation = $0 }
	}
	func apply(answer: String) async throws {
		XCTAssertEqual(answer, "answer")
		answerStartWaiter?.resume()
		answerStartWaiter = nil
		guard suspendAnswer else { return }
		await withCheckedContinuation { answerContinuation = $0 }
	}
	func waitForOfferStart() async { await withCheckedContinuation { offerStartWaiter = $0 } }
	func waitForAnswerStart() async { await withCheckedContinuation { answerStartWaiter = $0 } }
	func resumeOffer() { offerContinuation?.resume(returning: "offer"); offerContinuation = nil }
	func resumeAnswer() { answerContinuation?.resume(); answerContinuation = nil }
	func sendSessionUpdate(voice: String, language: String) throws { sessionUpdates.append("\(voice)|\(language)") }
	func sendProductionCommand(_ command: ProductionCommand) throws {
		if let commandError { throw commandError }
		let object = try JSONSerialization.jsonObject(with: command.encoded()) as? [String: Any]
		if let object { commandObjects.append(object) }
		commandTypes.append(object?["type"] as? String ?? "")
	}
	func setLocalAudioState(_ state: WebRTCLocalAudioState) { audioStates.append(state); operationOrder.append("audio:\(state == .enabled ? "enabled" : "disabled")") }
	func closeAndSettle() async {
		closeCount += 1
		operationOrder.append("close")
		continuation.finish()
		closeWaiter?.resume()
		closeWaiter = nil
	}
	func waitForClose() async {
		guard closeCount == 0 else { return }
		await withCheckedContinuation { closeWaiter = $0 }
	}
}
