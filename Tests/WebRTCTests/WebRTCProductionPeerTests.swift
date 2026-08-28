import Core
import Foundation
@_spi(AirbridgeQualification) @testable import WebRTC
import XCTest

final class WebRTCProductionPeerTests: XCTestCase {
	func testLocalAIConfigurationValidatesVoiceAndLanguageBeforePeerConstruction() throws {
		let configuration = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		XCTAssertEqual(configuration, try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "JA"))
	}

	@MainActor func testFactoryConstructionFailureIsContentFree() throws {
		let factory = WebRTCConnectorPeerFactory(makePeer: { () throws -> any WebRTCConnectorPeerBacking in
			throw FakeProductionBacking.ArbitraryError()
		})
		XCTAssertThrowsError(try factory.makePeer()) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
			XCTAssertFalse(String(describing: error).contains("ArbitraryError"))
		}
	}

	@MainActor func testProductionSurfaceHasExplicitAudioAndOnlyTypedCommands() {
		let factory = WebRTCConnectorPeerFactory(initialAudioState: .disabled)
		let _: WebRTCLocalAudioState = .enabled
		let _: WebRTCConnectorEvent = .closed
		_ = factory
	}

	@MainActor func testRealProductionConnectorDirectlyRetainsReadyAndPreReadyInboundInOrder() async throws {
		let drained = expectation(description: "pre-ready inbound drained")
		let connector = try WebRTCConnector.createProduction(
			session: ProductionStubSession(),
			terminalObserver: .init(cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {}, didDrainInbound: { drained.fulfill() })
		)
		let recorder = ProductionEventRecorder()
		connector.installProductionEventSink { result in recorder.values.append(result) }
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		await fulfillment(of: [drained], timeout: 1)
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		XCTAssertEqual(recorder.values.count, 2)
		XCTAssertEqual(try recorder.values[0].get(), .ready)
		XCTAssertEqual(try recorder.values[1].get(), .inbound(.responseFinished))
		await connector.closeAndSettle()
	}

	@MainActor func testRealProductionTerminalDisablesAudioBeforeResourcesAndPublication() async throws {
		var order: [String] = []
		let connector = try WebRTCConnector.createProduction(
			session: ProductionStubSession(),
			terminalObserver: .init(
				cancelSignaling: {},
				closeData: { order.append("data") },
				closePeer: { order.append("peer") },
				disableAudio: { order.append("audio") }
			)
		)
		connector.installProductionEventSink { _ in order.append("terminal") }

		connector.receiveDataChannelState(isOpen: false, isTerminal: true)
		await connector.closeAndSettle()
		XCTAssertEqual(order, ["audio", "data", "peer", "terminal"])
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

		let second = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForDisable()
		await backing.waitForClose()
		XCTAssertEqual(backing.closeCount, 1)
		switch await second.result {
		case .success: XCTFail("Concurrent offer must be rejected")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
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
		let didClose = expectation(description: "close releases held offer")
		backing.didClose = { didClose.fulfill() }
		let close = Task { @MainActor in await peer.closeAndJoin() }
		await fulfillment(of: [didClose], timeout: 0.1)
		guard backing.closeCount == 1 else { return }
		XCTAssertEqual(backing.operationOrder.suffix(2), ["audio:disabled", "close"])
		await close.value
		switch await offer.result {
		case .success: XCTFail("Closing an in-flight offer must prevent a late success")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCallerCancellationOfSuspendedOfferSettlesAndReturnsCancelled() async throws {
		let backing = FakeProductionBacking(suspendOffer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let offer = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()
		offer.cancel()
		await backing.waitForDisable()
		await backing.waitForClose()
		XCTAssertEqual(backing.closeCount, 1)
		switch await offer.result {
		case .success: XCTFail("Cancelled offer must not publish success")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await backing.waitForClose()
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCancelledOfferKeepsCancellationPrecedenceOverBackingError() async throws {
		let backing = FakeProductionBacking(suspendOffer: true, offerErrorOnClose: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let offer = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()
		offer.cancel()

		switch await offer.result {
		case .success: XCTFail("Cancellation must not return a backing-error result")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		do {
			_ = try await iterator.next()
			XCTFail("Cancellation settlement must not publish the backing error")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testOfferCancellationWinsBeforeAnyTerminalSelection() async throws {
		let backing = FakeProductionBacking(suspendOffer: true, offerErrorOnCancellation: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let offer = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()
		offer.cancel()

		switch await offer.result {
		case .success: XCTFail("Caller cancellation must interrupt offer")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		do {
			_ = try await iterator.next()
			XCTFail("Cancellation must select the terminal stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
	}

	@MainActor func testExplicitCloseWinsOverInterruptedOfferCancellation() async throws {
		let backing = FakeProductionBacking(suspendOffer: true, suspendClose: true, offerErrorOnCancellation: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let offer = Task { @MainActor in try await peer.makeOffer() }
		await backing.waitForOfferStart()
		let closeStarted = expectation(description: "explicit offer close selected")
		backing.didStartClose = { closeStarted.fulfill() }
		let close = Task { @MainActor [peer] in await peer.closeAndJoin() }
		await fulfillment(of: [closeStarted], timeout: 0.1)
		backing.resumeClose()
		await close.value

		switch await offer.result {
		case .success: XCTFail("Explicit close must interrupt offer")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		let terminal = try await iterator.next()
		XCTAssertEqual(terminal, .closed)
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
		let second = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForDisable()
		await backing.waitForClose()
		XCTAssertEqual(backing.closeCount, 1)
		switch await second.result {
		case .success: XCTFail("Concurrent answer must be rejected")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .invalidSDP)
		}
		switch await first.result {
		case .success: XCTFail("A settled in-flight answer must not succeed late")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCloseDuringSuspendedAnswerCannotPublishALateAnswer() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		let didClose = expectation(description: "close releases held answer")
		backing.didClose = { didClose.fulfill() }
		let close = Task { @MainActor in await peer.closeAndJoin() }
		await fulfillment(of: [didClose], timeout: 0.1)
		guard backing.closeCount == 1 else { return }
		XCTAssertEqual(backing.operationOrder.suffix(2), ["audio:disabled", "close"])
		await close.value
		switch await answer.result {
		case .success: XCTFail("Closing an in-flight answer must prevent a late success")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCallerCancellationOfSuspendedAnswerSettlesAndReturnsCancelled() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		answer.cancel()
		await backing.waitForDisable()
		await backing.waitForClose()
		XCTAssertEqual(backing.closeCount, 1)
		switch await answer.result {
		case .success: XCTFail("Cancelled answer must not publish success")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await backing.waitForClose()
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testCancelledAnswerKeepsCancellationPrecedenceOverBackingError() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true, answerErrorOnClose: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		answer.cancel()

		switch await answer.result {
		case .success: XCTFail("Cancellation must not return a backing-error result")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		do {
			_ = try await iterator.next()
			XCTFail("Cancellation settlement must not publish the backing error")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testAnswerCancellationWinsBeforeAnyTerminalSelection() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true, answerErrorOnCancellation: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		answer.cancel()

		switch await answer.result {
		case .success: XCTFail("Caller cancellation must interrupt answer")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		do {
			_ = try await iterator.next()
			XCTFail("Cancellation must select the terminal stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
	}

	@MainActor func testExplicitCloseWinsOverInterruptedAnswerCancellation() async throws {
		let backing = FakeProductionBacking(suspendAnswer: true, suspendClose: true, answerErrorOnCancellation: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		let answer = Task { @MainActor in try await peer.apply(remoteAnswer: "answer") }
		await backing.waitForAnswerStart()
		let closeStarted = expectation(description: "explicit answer close selected")
		backing.didStartClose = { closeStarted.fulfill() }
		let close = Task { @MainActor [peer] in await peer.closeAndJoin() }
		await fulfillment(of: [closeStarted], timeout: 0.1)
		backing.resumeClose()
		await close.value

		switch await answer.result {
		case .success: XCTFail("Explicit close must interrupt answer")
		case let .failure(error): XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		let terminal = try await iterator.next()
		XCTAssertEqual(terminal, .closed)
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

	@MainActor func testIteratorCancellationRetainsPeerUntilJoinedSettlementCompletes() async throws {
		let backing = FakeProductionBacking()
		var peer: (any WebRTCConnectorPeer)? = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let weakPeer = WeakPeerBox(peer as AnyObject)
		var reader: Task<WebRTCConnectorEvent?, any Error>?
		if let peer {
			reader = Task { @MainActor [peer] in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
			}
		}
		peer = nil
		reader?.cancel()
		_ = try? await reader?.value
		reader = nil
		await backing.waitForClose()
		XCTAssertEqual(backing.closeCount, 1)
		XCTAssertEqual(backing.operationOrder.suffix(2), ["audio:disabled", "close"])
		XCTAssertNotNil(weakPeer.value)
	}

	@MainActor func testSynchronousFailureRetainsPeerThroughSettlementThenReleases() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		var peer: (any WebRTCConnectorPeer)? = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		let weakPeer = WeakPeerBox(peer as AnyObject)
		var iterator = peer!.events.makeAsyncIterator()
		let closeStarted = expectation(description: "settlement owns peer through close")
		backing.didStartClose = { closeStarted.fulfill() }

		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		peer = nil
		await fulfillment(of: [closeStarted], timeout: 0.1)
		guard backing.closeCount == 1 else { return }
		XCTAssertNotNil(weakPeer.value)
		backing.resumeClose()
		do {
			_ = try await iterator.next()
			XCTFail("The synchronous backing failure must terminate the retained stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
		}
		for _ in 0..<16 where weakPeer.value != nil { await Task.yield() }
		XCTAssertNil(weakPeer.value)
	}

	@MainActor func testBackingFailureUpgradesNormalCloseBeforeTerminalCompletion() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let closeStarted = expectation(description: "normal close entered backing settlement")
		backing.didStartClose = { closeStarted.fulfill() }
		let close = Task { @MainActor [peer] in await peer.closeAndJoin() }
		await fulfillment(of: [closeStarted], timeout: 0.1)

		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		backing.resumeClose()
		do {
			_ = try await iterator.next()
			XCTFail("A racing backing failure must replace normal closure")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
		}
		await close.value
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testSuspendedExplicitCloseRejectsLaterCallerGuardsWithoutRewritingClosedTerminal() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let closeStarted = expectation(description: "explicit close selected before later caller guards")
		backing.didStartClose = { closeStarted.fulfill() }
		let close = Task { @MainActor [peer] in await peer.closeAndJoin() }
		await fulfillment(of: [closeStarted], timeout: 0.1)

		do {
			_ = try await peer.makeOffer()
			XCTFail("Later offer must remain method-local")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		do {
			try await peer.apply(remoteAnswer: "answer")
			XCTFail("Later answer must remain method-local")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidSDP)
		}
		XCTAssertThrowsError(try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		XCTAssertThrowsError(try peer.createResponse()) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}

		backing.resumeClose()
		await close.value
		let terminal = try await iterator.next()
		XCTAssertEqual(terminal, .closed)
	}

	@MainActor func testSuspendedBackingNormalTerminalRejectsCallerGuardsWithoutRewritingClosedTerminal() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		let closeStarted = expectation(description: "backing normal terminal selected before caller guards")
		backing.didStartClose = { closeStarted.fulfill() }
		backing.finishEvents()
		await fulfillment(of: [closeStarted], timeout: 0.1)

		do {
			_ = try await peer.makeOffer()
			XCTFail("Later offer must remain method-local")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		XCTAssertThrowsError(try peer.createResponse()) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}

		backing.resumeClose()
		let terminal = try await iterator.next()
		XCTAssertEqual(terminal, .closed)
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

@MainActor private final class ProductionEventRecorder {
	var values: [Result<WebRTCConnectorPeerBackingEvent, any Error>] = []
}

private struct ProductionStubSession: WebRTCSignalingSession {
	func data(for _: URLRequest) async throws -> WebRTCSignalingHTTPResponse {
		throw FakeProductionBacking.ArbitraryError()
	}
}

private final class WeakPeerBox {
	weak var value: AnyObject?
	init(_ value: AnyObject) { self.value = value }
}

@MainActor private final class FakeProductionBacking: WebRTCConnectorPeerBacking, @unchecked Sendable {
	private var eventSink: (@MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)?
	private(set) var sessionUpdates: [String] = []
	private(set) var commandTypes: [String] = []
	private(set) var commandObjects: [[String: Any]] = []
	private(set) var audioStates: [WebRTCLocalAudioState] = []
	private(set) var closeCount = 0
	private(set) var operationOrder: [String] = []
	private(set) var lastYieldWasTerminated = false
	private var closeWaiter: CheckedContinuation<Void, Never>?
	private var disableWaiter: CheckedContinuation<Void, Never>?
	private var offerStartWaiter: CheckedContinuation<Void, Never>?
	private var answerStartWaiter: CheckedContinuation<Void, Never>?
	private var offerContinuation: CheckedContinuation<String, any Error>?
	private var answerContinuation: CheckedContinuation<Void, any Error>?
	private var closeContinuation: CheckedContinuation<Void, Never>?
	private let suspendOffer: Bool
	private let suspendAnswer: Bool
	private let suspendClose: Bool
	private let offerErrorOnClose: Bool
	private let answerErrorOnClose: Bool
	private let offerErrorOnCancellation: Bool
	private let answerErrorOnCancellation: Bool
	private let commandError: (any Error)?
	private var closed = false
	var didStartClose: (() -> Void)?
	var didClose: (() -> Void)?

	struct ArbitraryError: Error {}

	init(suspendOffer: Bool = false, suspendAnswer: Bool = false, suspendClose: Bool = false, offerErrorOnClose: Bool = false, answerErrorOnClose: Bool = false, offerErrorOnCancellation: Bool = false, answerErrorOnCancellation: Bool = false, commandError: (any Error)? = nil) {
		self.suspendOffer = suspendOffer
		self.suspendAnswer = suspendAnswer
		self.suspendClose = suspendClose
		self.offerErrorOnClose = offerErrorOnClose
		self.answerErrorOnClose = answerErrorOnClose
		self.offerErrorOnCancellation = offerErrorOnCancellation
		self.answerErrorOnCancellation = answerErrorOnCancellation
		self.commandError = commandError
	}

	func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void) { eventSink = sink }
	func emit(_ event: WebRTCConnectorPeerBackingEvent) async {
		guard !closed else { lastYieldWasTerminated = true; return }
		guard let eventSink else { return XCTFail("Production peer did not install its direct sink") }
		eventSink(.success(event))
	}
	func finishEvents(throwing error: (any Error)? = nil) {
		closed = true
		if let error { eventSink?(.failure(error)) }
		else { eventSink?(.success(.terminal(nil))) }
	}
	func makeOffer() async throws -> String {
		offerStartWaiter?.resume()
		offerStartWaiter = nil
		guard suspendOffer else { return "offer" }
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { offerContinuation = $0 }
		} onCancel: { [weak self] in
			guard let self, self.offerErrorOnCancellation else { return }
			Task { @MainActor in self.failOffer() }
		}
	}
	func apply(answer: String) async throws {
		XCTAssertEqual(answer, "answer")
		answerStartWaiter?.resume()
		answerStartWaiter = nil
		guard suspendAnswer else { return }
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { answerContinuation = $0 }
		} onCancel: { [weak self] in
			guard let self, self.answerErrorOnCancellation else { return }
			Task { @MainActor in self.failAnswer() }
		}
	}
	func waitForOfferStart() async { await withCheckedContinuation { offerStartWaiter = $0 } }
	func waitForAnswerStart() async { await withCheckedContinuation { answerStartWaiter = $0 } }
	func resumeOffer() { offerContinuation?.resume(returning: "offer"); offerContinuation = nil }
	func resumeAnswer() { answerContinuation?.resume(); answerContinuation = nil }
	func failOffer() { offerContinuation?.resume(throwing: ArbitraryError()); offerContinuation = nil }
	func failAnswer() { answerContinuation?.resume(throwing: ArbitraryError()); answerContinuation = nil }
	func resumeClose() { closeContinuation?.resume(); closeContinuation = nil }
	func sendSessionUpdate(voice: String, language: String) throws { sessionUpdates.append("\(voice)|\(language)") }
	func sendProductionCommand(_ command: ProductionCommand) throws {
		if let commandError { throw commandError }
		let object = try JSONSerialization.jsonObject(with: command.encoded()) as? [String: Any]
		if let object { commandObjects.append(object) }
		commandTypes.append(object?["type"] as? String ?? "")
	}
	func setLocalAudioState(_ state: WebRTCLocalAudioState) {
		audioStates.append(state)
		operationOrder.append("audio:\(state == .enabled ? "enabled" : "disabled")")
		if state == .disabled { disableWaiter?.resume(); disableWaiter = nil }
	}
	func closeAndSettle() async {
		closeCount += 1
		operationOrder.append("close")
		didStartClose?()
		if suspendClose { await withCheckedContinuation { closeContinuation = $0 } }
		closed = true
		if offerErrorOnClose { failOffer() } else { resumeOffer() }
		if answerErrorOnClose { failAnswer() } else { resumeAnswer() }
		closeWaiter?.resume()
		closeWaiter = nil
		didClose?()
	}
	func waitForClose() async {
		guard closeCount == 0 else { return }
		await withCheckedContinuation { closeWaiter = $0 }
	}
	func waitForDisable() async {
		guard !audioStates.contains(.disabled) else { return }
		await withCheckedContinuation { disableWaiter = $0 }
	}
}
