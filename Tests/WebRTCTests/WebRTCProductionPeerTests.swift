import Core
import AVFAudio
import Foundation
import LiveKitWebRTC
@_spi(AirbridgeQualification) @testable import WebRTC
import XCTest

final class WebRTCProductionPeerTests: XCTestCase {
	@MainActor func testRealOpenAIConnectorAndPeerGateRemotePCMFromConstructionThroughTerminal() async throws {
		let frames = ProductionFrameCounter()
		let connector = try WebRTCConnector.createProduction(
			provider: .openAI,
			initialAudioState: .disabled,
			session: ProductionStubSession(),
			terminalObserver: .init(
				cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {},
				recordPermissionGranted: { true },
				didAttemptRemoteAudioFrame: { frames.recordAttempt() },
				didAdmitRemoteAudioFrame: { frames.recordAdmission() }
			)
		)
		let factory = LKRTCPeerConnectionFactory()
		let remoteConnection = try XCTUnwrap(factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		))
		let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		let track = factory.audioTrack(with: source, trackId: "synthetic-remote")
		let overflowTrack = factory.audioTrack(with: source, trackId: "synthetic-overflow")
		XCTAssertNotNil(remoteConnection.add(track, streamIds: ["openai-remote"]))
		XCTAssertNotNil(remoteConnection.add(overflowTrack, streamIds: ["openai-overflow"]))
		XCTAssertEqual(frames.admittedValue, 0, "Pre-peer-construction PCM is discarded")

		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { connector }).makePeer()
		var events = peer.events.makeAsyncIterator()
		let offer = try await peer.makeOffer()
		try await remoteConnection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer))
		let answer = try await remoteConnection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		try await remoteConnection.setLocalDescription(answer)
		for _ in 0..<500 where remoteConnection.iceGatheringState != .complete {
			try await Task.sleep(for: .milliseconds(10))
		}
		let gatheredAnswer = try XCTUnwrap(remoteConnection.localDescription)
		try await peer.apply(remoteAnswer: gatheredAnswer.sdp)
		let ready = try await events.next()
		XCTAssertEqual(ready, .ready)

		try await waitUntil(timeout: .seconds(2)) { frames.attemptedValue > 0 }
		let precreationAttempts = frames.attemptedValue
		XCTAssertEqual(frames.admittedValue, 0, "Observed pre-creation RTP/frame attempts are discarded")

		connector.receiveInbound(Data(#"{"type":"session.created"}"#.utf8))
		await Task.yield()
		XCTAssertEqual(frames.admittedValue, 0, "Preconfiguration ingress remains quarantined")
		try peer.configure(.openAI(language: "en"))
		let created = try await events.next()
		XCTAssertEqual(created, .openAISessionCreated)
		try await waitUntil(timeout: .seconds(2)) { frames.attemptedValue > precreationAttempts }
		let preackAttempts = frames.attemptedValue
		XCTAssertEqual(frames.admittedValue, 0, "Observed creation-to-ack RTP/frame attempts are discarded")
		connector.receiveInbound(Data(#"{"type":"session.updated","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"en"},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#.utf8))
		let configured = try await events.next()
		XCTAssertEqual(configured, .openAISessionConfigured(language: "en"))
		peer.setLocalAudioState(.enabled)
		XCTAssertEqual(frames.admittedValue, 0, "Discarded callbacks are never replayed")
		try await waitUntil(timeout: .seconds(2)) {
			frames.attemptedValue > preackAttempts && frames.admittedValue > 0
		}
		frames.blockNextFrame()
		try await waitUntil(timeout: .seconds(2)) { frames.isFrameBlocked }
		let releaseObserved = LockedFlag()
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
			releaseObserved.set()
			frames.releaseBlockedFrame()
		}

		connector.receiveDataChannelState(isOpen: false, isTerminal: true)
		XCTAssertTrue(releaseObserved.value, "Terminal selection joins every already-admitted real RTP/frame callback")
		let framesAtTerminal = frames.admittedValue
		peer.setLocalAudioState(.enabled)
		let lateTrack = factory.audioTrack(with: source, trackId: "synthetic-late-remote")
		XCTAssertNotNil(remoteConnection.add(lateTrack, streamIds: ["openai-late-remote"]))
		try await Task.sleep(for: .milliseconds(100))
		XCTAssertEqual(frames.admittedValue, framesAtTerminal, "Post-invalidation tracks and frames are neither retained nor replayed")
		await peer.closeAndJoin()
		remoteConnection.close()
	}

	func testLocalAIConfigurationValidatesVoiceAndLanguageBeforePeerConstruction() throws {
		let configuration = try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja")
		XCTAssertEqual(configuration, try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionConfiguration.localAI(voice: "Ono_Anna", language: "JA"))
	}

	@MainActor func testFactoryConstructionFailureIsContentFree() throws {
		let factory = WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { () throws -> any WebRTCConnectorPeerBacking in
			throw FakeProductionBacking.ArbitraryError()
		})
		XCTAssertThrowsError(try factory.makePeer()) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
			XCTAssertFalse(String(describing: error).contains("ArbitraryError"))
		}
	}

	@MainActor func testFactoryRejectsUnsupportedProviderAudioPairsBeforeCreatingBacking() throws {
		for (provider, initialAudioState) in [
			(WebRTCSessionProvider.localAI, WebRTCLocalAudioState.disabled),
			(.openAI, .enabled)
		] {
			let backing = FakeProductionBacking()
			let factory = WebRTCConnectorPeerFactory(
				provider: provider,
				initialAudioState: initialAudioState,
				makePeer: { backing }
			)
			XCTAssertThrowsError(try factory.makePeer()) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
			}
			XCTAssertTrue(backing.audioStates.isEmpty, "Rejected pairs cannot create or configure a backing resource")
		}
	}

	@MainActor func testProductionSurfaceHasExplicitAudioAndOnlyTypedCommands() {
		let factory = WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled)
		let _: WebRTCSessionProvider = .localAI
		let _: WebRTCLocalAudioState = .enabled
		let _: WebRTCConnectorEvent = .closed
		_ = factory
	}

	@MainActor func testRealProductionConnectorDirectlyRetainsReadyAndPreReadyInboundInOrder() async throws {
		let drained = expectation(description: "pre-ready inbound drained")
		let delivered = expectation(description: "configured raw inbound delivered")
		let connector = try WebRTCConnector.createProduction(
			provider: .openAI,
			initialAudioState: .disabled,
			session: ProductionStubSession(),
			terminalObserver: .init(cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {}, didDrainInbound: { drained.fulfill() })
		)
		let recorder = ProductionEventRecorder()
		connector.installProductionEventSink { result in
			recorder.values.append(result)
			if case .success(.rawInbound) = result { delivered.fulfill() }
		}
		let raw = Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8)
		connector.receiveInbound(raw)
		await fulfillment(of: [drained], timeout: 1)
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		await Task.yield()
		XCTAssertEqual(recorder.values.count, 1)
		XCTAssertEqual(try recorder.values[0].get(), .ready)
		connector.installProductionConfiguration()
		await fulfillment(of: [delivered], timeout: 1)
		XCTAssertEqual(recorder.values.count, 2)
		XCTAssertEqual(try recorder.values[0].get(), .ready)
		XCTAssertEqual(try recorder.values[1].get(), .rawInbound(raw))
		await connector.closeAndSettle()
	}

	@MainActor func testProductionMailboxFailsAtThirtyTwoPlusOneWhileDrainIsSuspended() async throws {
		let drainGate = ProductionDrainGate()
		let terminal = expectation(description: "mailbox overflow settles")
		let connector = try WebRTCConnector.createProduction(
			provider: .openAI,
			initialAudioState: .disabled,
			session: ProductionStubSession(),
			terminalObserver: .init(
				cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {},
				beforeDrainInbound: { await drainGate.hold() }
			)
		)
		let recorder = ProductionEventRecorder()
		connector.installProductionEventSink { result in
			recorder.values.append(result)
			if case .success(.terminal(.ingressOverloaded)) = result { terminal.fulfill() }
		}
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		connector.receiveInbound(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8))
		await drainGate.waitUntilHeld()
		for _ in 0...32 { connector.receiveInbound(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8)) }
		await drainGate.release()
		await fulfillment(of: [terminal], timeout: 1)
		await connector.closeAndSettle()
	}

	@MainActor func testProductionMailboxUsesConstructionBoundProviderOnOpenChannel() async throws {
		let drained = expectation(description: "open-channel input reached the authoritative mailbox")
		let delivered = expectation(description: "construction-bound provider releases the input")
		let connector = try WebRTCConnector.createProduction(
			provider: .localAI,
			initialAudioState: .enabled,
			session: ProductionStubSession(),
			terminalObserver: .init(cancelSignaling: {}, closeData: {}, closePeer: {}, disableAudio: {}, didDrainInbound: { drained.fulfill() })
		)
		let recorder = ProductionEventRecorder()
		connector.installProductionEventSink { result in
			recorder.values.append(result)
			if case .success(.rawInbound) = result { delivered.fulfill() }
		}
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		let raw = Data(#"{"type":"input_audio_buffer.committed"}"#.utf8)
		connector.receiveInbound(raw)
		await fulfillment(of: [drained], timeout: 1)
		await Task.yield()
		XCTAssertEqual(recorder.values.count, 1)
		XCTAssertEqual(try recorder.values[0].get(), .ready)
		connector.installProductionConfiguration()
		await fulfillment(of: [delivered], timeout: 1)
		XCTAssertEqual(try recorder.values[0].get(), .ready)
		XCTAssertEqual(try recorder.values[1].get(), .rawInbound(raw))
		await connector.closeAndSettle()
	}

	@MainActor func testRealProductionOversizeMappingIsProviderSpecific() async throws {
		for (provider, initialAudioState, expected) in [
			(WebRTCSessionProvider.openAI, WebRTCLocalAudioState.disabled, WebRTCTransportFailure.responseTooLarge),
			(.localAI, .enabled, .eventTooLarge)
		] {
			let terminal = expectation(description: "provider-specific terminal")
			let connector = try WebRTCConnector.createProduction(provider: provider, initialAudioState: initialAudioState)
			connector.installProductionEventSink { result in
				if case let .success(.terminal(failure)) = result {
					XCTAssertEqual(failure, expected)
					terminal.fulfill()
				}
			}
			connector.receiveInbound(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))
			await fulfillment(of: [terminal], timeout: 1)
			await connector.closeAndSettle()
		}
	}

	@MainActor func testLocalAIConstructionDoesNotApplyOpenAIRemoteTrackCustody() async throws {
		let connector = try WebRTCConnector.createProduction(provider: .localAI, initialAudioState: .enabled, session: ProductionStubSession())
		let factory = LKRTCPeerConnectionFactory()
		let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		let first = factory.audioTrack(with: source, trackId: "localai-first")
		let second = factory.audioTrack(with: source, trackId: "localai-second")
		let stream = factory.mediaStream(withStreamId: "localai-stream")
		stream.addAudioTrack(first)
		stream.addAudioTrack(second)
		let observerConnection = try XCTUnwrap(factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		))
		connector.peerConnection(observerConnection, didAdd: stream)
		XCTAssertTrue(first.isEnabled)
		XCTAssertTrue(second.isEnabled, "LocalAI keeps native multi-track behavior")
		await connector.closeAndSettle()
	}

	@MainActor func testRealProductionTerminalDisablesAudioBeforeResourcesAndPublication() async throws {
		var order: [String] = []
		let connector = try WebRTCConnector.createProduction(
			provider: .openAI,
			initialAudioState: .disabled,
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
		XCTAssertEqual(order, ["audio"], "Native terminal selection disables media synchronously")
		XCTAssertTrue(connector.isMuted)
		await connector.closeAndSettle()
		XCTAssertEqual(order, ["audio", "data", "peer", "terminal"])
	}

	@MainActor func testLocalAITerminalPreservesExistingResourceCleanupOrder() async throws {
		var order: [String] = []
		let connector = try WebRTCConnector.createProduction(
			provider: .localAI,
			initialAudioState: .enabled,
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
		XCTAssertTrue(order.isEmpty, "LocalAI keeps its existing asynchronous media cleanup timing")
		await connector.closeAndSettle()
		XCTAssertEqual(order, ["data", "peer", "audio", "terminal"])
	}

	@MainActor func testPeerDisablesSynchronouslyAndCannotReopenDuringSettlement() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		await backing.emit(.ready)
		_ = try await iterator.next()
		try peer.configure(.openAI(language: "en"))
		await backing.emit(.rawInbound(Data(#"{"type":"session.created"}"#.utf8)))
		_ = try await iterator.next()
		await backing.emit(.rawInbound(Data(#"{"type":"session.updated","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"en"},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#.utf8)))
		_ = try await iterator.next()
		backing.audioStateCallback = { state in
			if state == .disabled { peer.setLocalAudioState(.enabled) }
		}
		backing.clearAudioObservations()
		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		backing.audioStateCallback = nil
		XCTAssertEqual(backing.audioStates, [.disabled], "Media is disabled before asynchronous settlement begins")
		await peer.closeAndJoin()
		XCTAssertEqual(backing.audioStates, [.disabled], "A reentrant callback cannot reopen media")
	}

	@MainActor func testCloseAndJoinPublishesTerminalClosedEvent() async throws {
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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

	@MainActor func testLocalAIConstructionRejectsOpenAIConfiguration() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		await backing.emit(.ready)
		_ = try await events.next()
		XCTAssertThrowsError(try peer.configure(.openAI(language: "en"))) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
		XCTAssertTrue(backing.sessionUpdates.isEmpty)
		await peer.closeAndJoin()
	}

	@MainActor func testInitialEnabledAudioIsSelectedThenDisabledBeforeClose() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		XCTAssertEqual(backing.audioStates, [.enabled])

		await peer.closeAndJoin()
		XCTAssertEqual(backing.operationOrder, ["audio:enabled", "audio:disabled", "close"])
	}

	@MainActor func testConcurrentOfferIsRejectedWhileFirstOfferIsInFlight() async throws {
		let backing = FakeProductionBacking(suspendOffer: true)
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		await backing.emit(.ready)
		_ = try await iterator.next()
		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		await backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		for _ in 0..<5 { await backing.emit(.inbound(.userTranscript("late"))) }
		await backing.waitForClose()
		do {
			_ = try await iterator.next()
			XCTFail("Overflow must purge pending semantic events and terminate the stream")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .ingressOverloaded)
		}
		XCTAssertThrowsError(try peer.createResponse())
		await peer.closeAndJoin()
		XCTAssertEqual(backing.closeCount, 1)
	}

	@MainActor func testRemoteTerminalUsesTheSameJoinableSettlement() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let backing = FakeProductionBacking(suspendClose: true)
		var peer: (any WebRTCConnectorPeer)? = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		let weakPeer = WeakPeerBox(peer as AnyObject)
		let closeStarted = expectation(description: "iterator cancellation started retained settlement")
		backing.didStartClose = { closeStarted.fulfill() }
		var reader: Task<WebRTCConnectorEvent?, any Error>?
		if let peer {
			reader = Task { @MainActor [peer] in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
			}
		}
		await Task.yield()
		peer = nil
		reader?.cancel()
		await fulfillment(of: [closeStarted], timeout: 1)
		guard backing.closeCount == 1 else { return }
		XCTAssertNotNil(weakPeer.value, "Iterator cancellation retains peer settlement while backing close is suspended")
		backing.resumeClose()
		do {
			_ = try await reader?.value
			XCTFail("Iterator cancellation must return a content-free cancelled error")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		reader = nil
		XCTAssertEqual(backing.closeCount, 1)
		XCTAssertEqual(backing.operationOrder.suffix(2), ["audio:disabled", "close"])
		for _ in 0..<16 where weakPeer.value != nil { await Task.yield() }
		XCTAssertNil(weakPeer.value)
	}

	@MainActor func testIteratorCancellationWinsBeforeLaterBackingFailure() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		let closeStarted = expectation(description: "iterator cancellation selected settlement")
		backing.didStartClose = { closeStarted.fulfill() }
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}
		await Task.yield()
		reader.cancel()
		await fulfillment(of: [closeStarted], timeout: 1)
		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		backing.resumeClose()
		do {
			_ = try await reader.value
			XCTFail("Cancellation that wins terminal arbitration must remain cancelled")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		await peer.closeAndJoin()
	}

	@MainActor func testIteratorCancellationAfterExplicitClosePreservesClosedTerminal() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		let closeStarted = expectation(description: "explicit close selected terminal first")
		backing.didStartClose = { closeStarted.fulfill() }
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}
		await Task.yield()
		let close = Task { @MainActor in await peer.closeAndJoin() }
		await fulfillment(of: [closeStarted], timeout: 1)
		reader.cancel()
		await Task.yield()
		backing.resumeClose()
		await close.value
		let terminal = try await reader.value
		XCTAssertEqual(terminal, .closed)
	}

	@MainActor func testIteratorCancellationAfterProviderFailurePreservesFailureTerminal() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		let closeStarted = expectation(description: "provider failure selected terminal first")
		backing.didStartClose = { closeStarted.fulfill() }
		let reader = Task { @MainActor in
			var iterator = peer.events.makeAsyncIterator()
			return try await iterator.next()
		}
		await Task.yield()
		backing.finishEvents(throwing: FakeProductionBacking.ArbitraryError())
		await fulfillment(of: [closeStarted], timeout: 1)
		reader.cancel()
		await Task.yield()
		backing.resumeClose()
		do {
			_ = try await reader.value
			XCTFail("Late iterator cancellation cannot replace a selected provider failure")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .requestFailed)
		}
		await peer.closeAndJoin()
	}

	@MainActor func testClosePurgesPendingSemanticEventsAndEndsTheSingleConsumer() async throws {
		let backing = FakeProductionBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
		var iterator = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		await backing.emit(.ready)
		_ = try await iterator.next()
		try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		await backing.emit(.inbound(.sessionUpdated(voice: "Ono_Anna", language: "ja")))
		_ = try await iterator.next()
		_ = try await iterator.next()
		await backing.emit(.inbound(.userTranscript("pending-one")))
		await backing.emit(.inbound(.assistantTranscript("pending-two")))

		await peer.closeAndJoin()
		let terminal = try await iterator.next()
		let end = try await iterator.next()
		XCTAssertEqual(terminal, .closed)
		XCTAssertNil(end)
	}

	@MainActor func testSecondEventIteratorIsRejectedContentFree() async throws {
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled).makePeer()
		var first = peer.events.makeAsyncIterator()
		var second = peer.events.makeAsyncIterator()
		await peer.closeAndJoin()
		let terminal = try await first.next()
		XCTAssertEqual(terminal, .closed)
		do {
			_ = try await second.next()
			XCTFail("The production event sequence permits exactly one consumer")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
	}

	@MainActor func testSynchronousFailureRetainsPeerThroughSettlementThenReleases() async throws {
		let backing = FakeProductionBacking(suspendClose: true)
		var peer: (any WebRTCConnectorPeer)? = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let mismatchedPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { mismatchedBacking }).makePeer()
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
		let duplicatePeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { duplicateBacking }).makePeer()
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
		let peer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { backing }).makePeer()
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
		let providerPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { providerBacking }).makePeer()
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
		let malformedPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { malformedBacking }).makePeer()
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
		let racingPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { racingBacking }).makePeer()
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
			let invalidPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { invalidBacking }).makePeer()
			XCTAssertThrowsError(try command.invoke(invalidPeer)) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
			}
			await invalidPeer.closeAndJoin()
			XCTAssertEqual(invalidBacking.closeCount, 1)

			let failedBacking = FakeProductionBacking(commandError: FakeProductionBacking.ArbitraryError())
			let failedPeer = try WebRTCConnectorPeerFactory(provider: .localAI, initialAudioState: .enabled, makePeer: { failedBacking }).makePeer()
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

	@MainActor private func waitUntil(timeout: Duration, condition: @escaping @Sendable () -> Bool) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while !condition() {
			guard clock.now < deadline else {
				XCTFail("Timed out waiting for a deterministic production observation")
				return
			}
			try await Task.sleep(for: .milliseconds(10))
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

private final class ProductionFrameCounter: @unchecked Sendable {
	private let condition = NSCondition()
	private var attemptedCount = 0
	private var admittedCount = 0
	private var shouldBlockNextFrame = false
	private var frameBlocked = false
	private var releaseFrame = false
	func recordAttempt() {
		condition.withLock {
			attemptedCount += 1
			condition.broadcast()
		}
	}
	func recordAdmission() {
		condition.lock()
		admittedCount += 1
		if shouldBlockNextFrame {
			shouldBlockNextFrame = false
			frameBlocked = true
			condition.broadcast()
			while !releaseFrame { condition.wait() }
			frameBlocked = false
			releaseFrame = false
		}
		condition.unlock()
	}
	func blockNextFrame() { condition.withLock { shouldBlockNextFrame = true } }
	func releaseBlockedFrame() {
		condition.withLock {
			releaseFrame = true
			condition.broadcast()
		}
	}
	var isFrameBlocked: Bool { condition.withLock { frameBlocked } }
	var attemptedValue: Int { condition.withLock { attemptedCount } }
	var admittedValue: Int { condition.withLock { admittedCount } }
}

private final class LockedFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var stored = false
	func set() { lock.withLock { stored = true } }
	var value: Bool { lock.withLock { stored } }
}

private actor ProductionDrainGate {
	private var held = false
	private var holdWaiters: [CheckedContinuation<Void, Never>] = []
	private var releaseContinuation: CheckedContinuation<Void, Never>?

	func hold() async {
		guard !held else { return }
		held = true
		holdWaiters.forEach { $0.resume() }
		holdWaiters.removeAll()
		await withCheckedContinuation { releaseContinuation = $0 }
	}

	func waitUntilHeld() async {
		guard !held else { return }
		await withCheckedContinuation { holdWaiters.append($0) }
	}

	func release() {
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
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
	var audioStateCallback: ((WebRTCLocalAudioState) -> Void)?

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
	func sendSessionConfiguration(_ data: Data) throws {
		let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		let session = root?["session"] as? [String: Any]
		let audio = session?["audio"] as? [String: Any]
		let input = audio?["input"] as? [String: Any]
		let output = audio?["output"] as? [String: Any]
		let transcription = input?["transcription"] as? [String: Any]
		guard let voice = output?["voice"] as? String, let language = transcription?["language"] as? String else {
			throw ArbitraryError()
		}
		sessionUpdates.append("\(voice)|\(language)")
	}
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
		audioStateCallback?(state)
	}
	func clearAudioObservations() { audioStates.removeAll(); operationOrder.removeAll() }
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
