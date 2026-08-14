import Foundation
import Core
@_spi(AirbridgeQualification) import WebRTC
import XCTest
import Darwin

final class WebRTCQualificationTests: XCTestCase {
    func testSignalingRequestUsesExactJSONAndOmitsAbsentAuthorization() throws {
        let endpoint = URL(string: "https://local.invalid/api/v1")!
        let request = try WebRTCSignalingRequest(
            endpoint: endpoint,
            model: "local-model",
            bearerToken: nil
        ).makeRequest(localSDP: "offer")

        XCTAssertEqual(request.url?.absoluteString, "https://local.invalid/api/v1/realtime/calls")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
                == ["sdp": "offer", "model": "local-model"]
        )
    }

    func testDedicatedSignalingConfigurationIsEphemeralAndBounded() {
        let configuration = URLSessionWebRTCSignalingSession.configuration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    func testSignalingClientAcceptsOnlyBoundedCreatedJSONAnswerWithoutRetry() async throws {
        let session = CountingSession(
            response: .init(
                data: Data(#"{"sdp":"answer","session_id":"internal"}"#.utf8),
                statusCode: 201,
                contentType: "application/json"
            )
        )
        let answer = try await WebRTCSignalingClient(session: session).answer(
            for: try WebRTCSignalingRequest(
                endpoint: URL(string: "https://local.invalid/base")!,
                model: "model",
                bearerToken: "token"
            ).makeRequest(localSDP: "offer")
        )

        XCTAssertTrue(answer.sdp == "answer")
        let callCount = await session.callCount
        let authorization = await session.authorization
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(authorization == "Bearer token")
    }

    func testSignalingClientRejectsOversizedOrInvalidAnswers() async throws {
        let request = try WebRTCSignalingRequest(
            endpoint: URL(string: "https://local.invalid")!, model: "model", bearerToken: nil
        ).makeRequest(localSDP: "offer")
        let oversized = WebRTCSignalingClient(session: StubSession(response: .init(
            data: Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1),
            statusCode: 201,
            contentType: "application/json"
        )))
        let malformed = WebRTCSignalingClient(session: StubSession(response: .init(
            data: Data("{}".utf8), statusCode: 201, contentType: "application/json"
        )))

        await XCTAssertThrowsErrorAsync(try await oversized.answer(for: request)) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .responseTooLarge)
        }
        await XCTAssertThrowsErrorAsync(try await malformed.answer(for: request)) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .malformedResponse)
        }
    }

    func testSignalingClientRejectsJSONPAndMapsURLCancellation() async throws {
        let request = try WebRTCSignalingRequest(
            endpoint: URL(string: "https://local.invalid")!, model: "model", bearerToken: nil
        ).makeRequest(localSDP: "offer")
        let jsonp = WebRTCSignalingClient(session: StubSession(response: .init(
            data: Data(#"{"sdp":"answer","session_id":"internal"}"#.utf8),
            statusCode: 201,
            contentType: "application/jsonp"
        )))
        let cancelled = WebRTCSignalingClient(session: ThrowingSession(error: URLError(.cancelled)))
		let swiftCancelled = WebRTCSignalingClient(session: ThrowingSession(error: CancellationError()))

        await XCTAssertThrowsErrorAsync(try await jsonp.answer(for: request)) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .invalidResponse)
        }
        await XCTAssertThrowsErrorAsync(try await cancelled.answer(for: request)) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
        }
		await XCTAssertThrowsErrorAsync(try await swiftCancelled.answer(for: request)) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
    }

	@MainActor
    func testConsumedConnectorSurfaceEmitsOnlyNarrowEvents() {
        let connector = NarrowConnector()
        let client = RealtimeAPI(connector: connector)
        let _: AsyncThrowingStream<WebRTCInboundEvent, any Error> = client.events
    }

    func testRedirectDelegateRejectsCredentialedSameAndCrossOriginRequests() {
        let delegate = URLSessionWebRTCSignalingSession.RedirectRejectingDelegate()
        let response = HTTPURLResponse(url: URL(string: "https://local.invalid")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://local.invalid")!)
        for redirect in [URL(string: "https://local.invalid/other")!, URL(string: "https://elsewhere.invalid")!] {
            var request = URLRequest(url: redirect)
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            let completion = expectation(description: "redirect rejected")
            delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
                XCTAssertNil(redirected)
                completion.fulfill()
            }
            wait(for: [completion], timeout: 1)
        }
    }

	func testProductionSignalingSessionRejectsSameAndCrossOriginRedirectsWithoutFollowing() async throws {
		let sameOrigin = try LoopbackHTTPServer(response: { _ in
			"HTTP/1.1 302 Found\r\nLocation: /same-origin\r\nContent-Length: 0\r\n\r\n"
		})
		try await assertRedirectIsNotFollowed(origin: sameOrigin, target: sameOrigin, expectedTargetPath: "/same-origin")

		let crossOriginTarget = try LoopbackHTTPServer(response: { _ in "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" })
		let crossOrigin = try LoopbackHTTPServer(response: { _ in
			"HTTP/1.1 302 Found\r\nLocation: \(crossOriginTarget.url.absoluteString)\r\nContent-Length: 0\r\n\r\n"
		})
		try await assertRedirectIsNotFollowed(origin: crossOrigin, target: crossOriginTarget, expectedTargetPath: "/")
	}

    func testEventIngressAcceptsOnlyTranscriptTerminalAndProviderErrorEvents() throws {
        let decoder = WebRTCInboundEventDecoder()
        let transcript = try decoder.decode(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
        guard case .assistantTranscript = transcript else {
            return XCTFail("Expected transcript event kind")
        }
        XCTAssertTrue(
            try decoder.decode(Data(#"{"type":"response.done"}"#.utf8))
                == .responseFinished
        )

        XCTAssertThrowsError(try decoder.decode(Data(#"{"type":"response.function_call_arguments.done"}"#.utf8))) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .unsupportedEvent)
        }
    }

    func testEventIngressRejectsOversizedPayloadBeforeDecoding() throws {
        XCTAssertThrowsError(try WebRTCInboundEventDecoder().decode(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))) { error in
            XCTAssertEqual(error as? WebRTCTransportFailure, .eventTooLarge)
        }
    }

	@MainActor
    func testLifecycleInvalidatesStaleGenerationAndFinishesOnlyOnce() {
        let lifecycle = WebRTCLifecycle()
        let first = lifecycle.begin()
        let second = lifecycle.begin()

        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.isCurrent(second))
		XCTAssertTrue(lifecycle.markTerminal(second))
		lifecycle.cancelSignalingTask()
		XCTAssertFalse(lifecycle.markTerminal(second))
        XCTAssertFalse(lifecycle.isCurrent(second))
    }

	@MainActor
	func testConnectorLifecycleTerminatesResourcesOnceAndDropsQueuedCallback() async throws {
		let probe = ConnectorTerminalProbe()
		let productionPeer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		XCTAssertTrue(productionPeer is WebRTCConnector)
		let productionLifecycle = productionPeer.qualificationEvents
		let lifecycleReady = expectation(description: "terminal reader ready")
		let lifecycleProbe = TestTaskCompletionProbe()
		let lifecycleReader = Task { @MainActor in
			var iterator = productionLifecycle.makeAsyncIterator()
			lifecycleReady.fulfill()
			defer { lifecycleProbe.markComplete() }
			do {
				let terminal = try await iterator.next()
				let end = try await iterator.next()
				guard case .terminal = terminal else { return false }
				return end == nil
			} catch {
				return false
			}
		}
		await fulfillment(of: [lifecycleReady], timeout: 1)
		productionPeer.disconnect()
		let lifecycleWait = await XCTWaiter.fulfillment(of: [lifecycleProbe.expectation()], timeout: 1)
		guard lifecycleWait == .completed else {
			lifecycleReader.cancel()
			if await XCTWaiter.fulfillment(of: [lifecycleProbe.expectation()], timeout: 1) == .completed {
				_ = await lifecycleReader.value
			}
			return XCTFail("Terminal reader did not complete within bound")
		}
		let lifecycleSucceeded = await lifecycleReader.value
		XCTAssertTrue(lifecycleSucceeded)
		let connector = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let signalingTask = Task<String, Error> {
			try await Task.sleep(for: .seconds(30))
			return "answer"
		}
		XCTAssertTrue(connector.installSignalingTask(signalingTask))
		let callback = Task { @MainActor in
			connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		}

		connector.disconnect()
		connector.disconnect()
		await callback.value
		do {
			_ = try await signalingTask.value
			XCTFail("Expected the connector-owned signaling task to be cancelled")
		} catch {
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertEqual(connector.status, .disconnected)
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
		var iterator = connector.events.makeAsyncIterator()
		do {
			let received = try await iterator.next()
			XCTAssertNil(received)
		} catch {
			XCTFail("Terminal stream should not throw")
		}
	}

	@MainActor
	func testQualificationIngressPreservesDecodedFailureCategory() async throws {
		let cases: [(Data, WebRTCTransportFailure)] = [
			(Data(#"{"type":"error"}"#.utf8), .providerError),
			(Data(#"{"type":"response.function_call_arguments.done"}"#.utf8), .unsupportedEvent),
			(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1), .eventTooLarge),
			(Data(#"{"type":"response.done""#.utf8), .malformedEvent),
		]
		for (payload, expected) in cases {
			let drained = expectation(description: "ingress drained")
			let probe = ConnectorTerminalProbe(drainExpectation: drained)
			let connector = try WebRTCConnector.createQualification(
				session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
				terminalObserver: probe.observer
			)
			let qualificationEvents = connector.qualificationEvents
			connector.receiveInbound(payload)
			if expected == .eventTooLarge {
				drained.fulfill()
			}
			guard await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed else {
				return XCTFail("Ingress did not retire within bound")
			}
			let qualificationResult = await Self.firstResult(from: qualificationEvents)
			XCTAssertEqual(qualificationResult, .expectedFailure(expected))
			await connector.closeAndSettle()
		}
	}

	@MainActor
	func testQualificationIngressUsesOneBoundedMailboxAndDoesNotPopulateOrdinaryEvents() async throws {
		let drained = expectation(description: "pre-reader inbound drained")
		let probe = ConnectorTerminalProbe(drainExpectation: drained)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let qualification = connector.qualificationEvents
		connector.scheduleOpenTransitionForQualification()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		guard connector.status == .connected else {
			await connector.closeAndSettle()
			return XCTFail("Pre-reader open did not complete within bound")
		}
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"bounded"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed else {
			await connector.closeAndSettle()
			return XCTFail("Pre-reader inbound did not retire within bound")
		}

		let ordered = await Self.connectedThenInbound(from: qualification)
		XCTAssertTrue(ordered)

		await connector.closeAndSettle()
	}

	@MainActor
	func testIngressOverflowFailsTheExactQualificationSessionAndSettles() async throws {
		let peer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		let connector = try XCTUnwrap(peer as? WebRTCConnector)
		let qualification = connector.qualificationEvents

		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))

		let result = await Self.firstResult(from: qualification)
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await connector.closeAndSettle()
	}

	@MainActor
	func testQualificationEventCapacityOverflowFailsTheExactSession() async throws {
		let firstInboundDrained = expectation(description: "first pre-reader inbound drained")
		firstInboundDrained.assertForOverFulfill = false
		let acceptedOutputsRetired = expectation(description: "pre-reader outputs retired")
		acceptedOutputsRetired.expectedFulfillmentCount = 2
		let settled = expectation(description: "qualification overflow settled")
		let probe = ConnectorTerminalProbe(
			drainExpectation: firstInboundDrained,
			retirementExpectation: acceptedOutputsRetired,
			settledExpectation: settled
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		connector.scheduleOpenTransitionForQualification()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		guard connector.status == .connected else {
			await connector.closeAndSettle()
			return XCTFail("Pre-reader open did not complete within bound")
		}
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [firstInboundDrained], timeout: 1) == .completed else {
			await connector.closeAndSettle()
			return XCTFail("First pre-reader inbound did not retire within bound")
		}
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))

		guard await XCTWaiter.fulfillment(of: [acceptedOutputsRetired, settled], timeout: 1) == .completed else {
			await connector.closeAndSettle()
			return XCTFail("Qualification overflow did not settle within bound")
		}
		let result = await Self.twoEventsThenFailure(from: connector.qualificationEvents)
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await connector.closeAndSettle()
	}

	@MainActor
	func testIngressRejectsOversizedBytesBeforeMailboxCustody() async throws {
		let peer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		let connector = try XCTUnwrap(peer as? WebRTCConnector)

		connector.receiveInbound(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))
		let result = await Self.firstResult(from: connector.qualificationEvents)
		XCTAssertEqual(result, .expectedFailure(.eventTooLarge))
		await connector.closeAndSettle()
	}

	@MainActor
	func testOrdinaryConnectorRetainsItsPublicEventDelivery() async throws {
		let connector = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		)
		let events = connector.events
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		let readerReady = expectation(description: "ordinary reader ready")
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			var iterator = events.makeAsyncIterator()
			readerReady.fulfill()
			defer { readerProbe.markComplete() }
			do {
				guard case .assistantTranscript = try await iterator.next() else { return false }
				return true
			} catch { return false }
		}
		await fulfillment(of: [readerReady], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed else {
			reader.cancel()
			if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
				_ = await reader.value
			}
			return XCTFail("Ordinary reader did not complete within bound")
		}
		let readSucceeded = await reader.value
		XCTAssertTrue(readSucceeded)
		await connector.closeAndSettle()
	}

	@MainActor
	func testQualificationCloseAndSettleReleasesQueuedContentWithoutDiagnostics() async throws {
		let drained = expectation(description: "qualification ingress drained")
		let retention = WeakRetentionBox()
		let probe = ConnectorTerminalProbe(
			makePreReadyRetentionToken: {
				let token = RetentionToken()
				retention.token = token
				return token
			},
			drainExpectation: drained
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let events = connector.qualificationEvents
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed else {
			return XCTFail("Queued ingress did not retire within bound")
		}
		XCTAssertNotNil(retention.token)
		await connector.closeAndSettle()
		XCTAssertNil(retention.token)
		let finished = await Self.finishedResult(from: events)
		XCTAssertTrue(finished)
		XCTAssertEqual(connector.status, .disconnected)
	}

	@MainActor
	func testOrdinaryAbsentConsumerFailsWithoutRetainingEvent() async throws {
		let drained = expectation(description: "ingress drained")
		let probe = ConnectorTerminalProbe(drainExpectation: drained)
		let connector = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed else {
			return XCTFail("Ordinary ingress did not retire within bound")
		}
		await connector.closeAndSettle()
		let result = await Self.firstResult(from: connector.events)
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
	}

	@MainActor
	func testQualificationCloseAndSettleDrainsEmptyPartialAndFullCustody() async throws {
		for occupancy in 0...2 {
			let drained = occupancy == 2 ? expectation(description: "content-free custody drained") : nil
			let probe = ConnectorTerminalProbe(drainExpectation: drained)
			let connector = try WebRTCConnector.createQualification(
				session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
				terminalObserver: probe.observer
			)
			let events = connector.qualificationEvents
			if occupancy >= 1 {
				connector.receiveDataChannelState(isOpen: true, isTerminal: false)
			}
			if occupancy == 2 {
				connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
				guard let drained,
					await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
				else {
					await connector.closeAndSettle()
					return XCTFail("Full custody did not retire accepted ingress")
				}
			}

			await connector.closeAndSettle()
			let finished = await Self.finishedResult(from: events)
			XCTAssertTrue(finished)
			XCTAssertEqual(connector.status, .disconnected)
		}
	}

	@MainActor
	func testAcceptedIngressDrainsBeforeLaterTerminalSettlement() async throws {
		let drainGate = StickySuspensionGate()
		let drainEntered = expectation(description: "accepted ingress entered drain")
		let settled = expectation(description: "terminal settled")
		let probe = ConnectorTerminalProbe(
			beforeDrainInbound: {
				drainEntered.fulfill()
				await drainGate.wait()
			},
			settledExpectation: settled
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let events = connector.qualificationEvents
		let readerReady = expectation(description: "ordered reader ready")
		let connectedObserved = expectation(description: "ordered connected observed")
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			var iterator = events.makeAsyncIterator()
			readerReady.fulfill()
			defer { readerProbe.markComplete() }
			do {
				guard case .connected = try await iterator.next() else { return false }
				connectedObserved.fulfill()
				guard case .inbound(.responseFinished) = try await iterator.next() else { return false }
				return true
			} catch { return false }
		}
		await fulfillment(of: [readerReady], timeout: 1)
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		await fulfillment(of: [connectedObserved], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await fulfillment(of: [drainEntered], timeout: 1)

		let closeStarted = expectation(description: "close started")
		let closeTaskProbe = TestTaskCompletionProbe()
		let closeProbe = CompletionFlag()
		let closeTask = Task { @MainActor in
			defer { closeTaskProbe.markComplete() }
			closeStarted.fulfill()
			await connector.closeAndSettle()
			await closeProbe.markComplete()
		}
		await fulfillment(of: [closeStarted], timeout: 1)
		let closeCompletedEarly = await closeProbe.currentValue()
		XCTAssertFalse(closeCompletedEarly)

		await drainGate.release()
		let waits = await XCTWaiter.fulfillment(
			of: [readerProbe.expectation(), closeTaskProbe.expectation(), settled],
			timeout: 1
		)
		guard waits == .completed else {
			reader.cancel()
			closeTask.cancel()
			await drainGate.release()
			let cleanup = await XCTWaiter.fulfillment(
				of: [readerProbe.expectation(), closeTaskProbe.expectation()],
				timeout: 1
			)
			if cleanup == .completed {
				_ = await reader.value
				_ = await closeTask.value
			}
			return XCTFail("Ordered drain cleanup did not complete within bound")
		}
		let readSucceeded = await reader.value
		XCTAssertTrue(readSucceeded)
		await closeTask.value
	}

	@MainActor
	func testFirstAcceptedIngressFailureSuppressesLaterAcceptedDeliveryAndFailure() async throws {
		let laterPayloads = [
			Data(#"{"type":"response.done"}"#.utf8),
			Data(#"{"type":"response.function_call_arguments.done"}"#.utf8),
		]
		for laterPayload in laterPayloads {
			let drainGate = StickySuspensionGate()
			let firstDrainEntered = expectation(description: "first accepted ingress entered")
			let acceptedIngressRetired = expectation(description: "accepted ingress retired")
			acceptedIngressRetired.expectedFulfillmentCount = 2
			let probe = ConnectorTerminalProbe(beforeDrainInbound: {
				firstDrainEntered.fulfill()
				await drainGate.wait()
			}, retirementExpectation: acceptedIngressRetired)
			let connector = try WebRTCConnector.createQualification(
				session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
				terminalObserver: probe.observer
			)
			let events = connector.qualificationEvents
			let readerProbe = TestTaskCompletionProbe()
			let reader = Task { @MainActor in
				defer { readerProbe.markComplete() }
				return await Self.firstResult(from: events)
			}

			connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
			guard await XCTWaiter.fulfillment(of: [firstDrainEntered], timeout: 1) == .completed else {
				await drainGate.release()
				reader.cancel()
				if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
					_ = await reader.value
				}
				return XCTFail("First accepted ingress did not enter within bound")
			}
			connector.receiveInbound(laterPayload)
			await drainGate.release()
			guard await XCTWaiter.fulfillment(of: [acceptedIngressRetired], timeout: 1) == .completed else {
				reader.cancel()
				if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
					_ = await reader.value
				}
				return XCTFail("Accepted ingress did not retire within bound")
			}
			await connector.closeAndSettle()

			guard await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed else {
				reader.cancel()
				if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
					_ = await reader.value
				}
				return XCTFail("First-failure reader did not settle")
			}
			let result = await reader.value
			XCTAssertEqual(result, .expectedFailure(.providerError))
		}
	}

	@MainActor
	func testScheduledOpenTransitionDeliversEarlierAcceptedIngressBeforeLaterClose() async throws {
		let openGate = StickySuspensionGate()
		let openEntered = expectation(description: "open transition entered")
		let inboundDrained = expectation(description: "pre-ready ingress drained")
		let probe = ConnectorTerminalProbe(
			beforeOpenTransition: {
				openEntered.fulfill()
				await openGate.wait()
			},
			drainExpectation: inboundDrained
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let events = connector.qualificationEvents
		let readerReady = expectation(description: "delegate-order reader ready")
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			var iterator = events.makeAsyncIterator()
			readerReady.fulfill()
			defer { readerProbe.markComplete() }
			do {
				guard case .connected = try await iterator.next() else { return false }
				guard case .inbound(.responseFinished) = try await iterator.next() else { return false }
				return true
			} catch { return false }
		}
		await fulfillment(of: [readerReady], timeout: 1)

		connector.scheduleOpenTransitionForQualification()
		await fulfillment(of: [openEntered], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await fulfillment(of: [inboundDrained], timeout: 1)

		let closeTaskProbe = TestTaskCompletionProbe()
		let closeProbe = CompletionFlag()
		let close = Task { @MainActor in
			defer { closeTaskProbe.markComplete() }
			await connector.closeAndSettle()
			await closeProbe.markComplete()
		}
		let closeCompletedEarly = await closeProbe.currentValue()
		XCTAssertFalse(closeCompletedEarly)
		await openGate.release()

		let waits = await XCTWaiter.fulfillment(
			of: [readerProbe.expectation(), closeTaskProbe.expectation()],
			timeout: 1
		)
		guard waits == .completed else {
			reader.cancel()
			close.cancel()
			await openGate.release()
			if await XCTWaiter.fulfillment(
				of: [readerProbe.expectation(), closeTaskProbe.expectation()],
				timeout: 1
			) == .completed {
				_ = await reader.value
				await close.value
			}
			return XCTFail("Delegate-order cleanup did not complete")
		}
		let readSucceeded = await reader.value
		XCTAssertTrue(readSucceeded)
		await close.value
	}

	@MainActor
	func testEarlierAcceptedFailureSuppressesOneBoundedPendingOpenTransition() async throws {
		let openGate = StickySuspensionGate()
		let openEntered = expectation(description: "single pending open entered")
		openEntered.assertForOverFulfill = true
		let ingressRetired = expectation(description: "failing ingress retired")
		let probe = ConnectorTerminalProbe(
			beforeOpenTransition: {
				openEntered.fulfill()
				await openGate.wait()
			},
			retirementExpectation: ingressRetired
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let events = connector.qualificationEvents
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			return await Self.firstResult(from: events)
		}

		connector.scheduleOpenTransitionForQualification()
		connector.scheduleOpenTransitionForQualification()
		guard await XCTWaiter.fulfillment(of: [openEntered], timeout: 1) == .completed else {
			await openGate.release()
			reader.cancel()
			if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
				_ = await reader.value
			}
			return XCTFail("Pending open transition did not enter")
		}
		connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [ingressRetired], timeout: 1) == .completed else {
			await openGate.release()
			reader.cancel()
			if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
				_ = await reader.value
			}
			return XCTFail("Failing ingress did not retire")
		}
		await openGate.release()
		await connector.closeAndSettle()
		guard await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed else {
			reader.cancel()
			if await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed {
				_ = await reader.value
			}
			return XCTFail("Suppressed-open reader did not settle")
		}
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.providerError))
	}

	@MainActor
	func testAcceptedOpenDeliveryFailureOverridesLaterNormalTerminal() async throws {
		let openGate = StickySuspensionGate()
		let openEntered = expectation(description: "accepted open entered")
		let laterDrainGate = StickySuspensionGate()
		let laterDrainEntered = expectation(description: "later accepted ingress entered")
		let firstDrainCompleted = expectation(description: "pre-ready ingress drained")
		firstDrainCompleted.assertForOverFulfill = false
		let settled = expectation(description: "accepted output failure settled")
		var drainInvocation = 0
		let probe = ConnectorTerminalProbe(
			beforeDrainInbound: {
				drainInvocation += 1
				if drainInvocation == 2 {
					laterDrainEntered.fulfill()
					await laterDrainGate.wait()
				}
			},
			beforeOpenTransition: {
				openEntered.fulfill()
				await openGate.wait()
			},
			drainExpectation: firstDrainCompleted,
			settledExpectation: settled
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let events = connector.qualificationEvents

		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [firstDrainCompleted], timeout: 1) == .completed else {
			return XCTFail("Pre-ready ingress did not drain")
		}
		connector.scheduleOpenTransitionForQualification()
		guard await XCTWaiter.fulfillment(of: [openEntered], timeout: 1) == .completed else {
			await openGate.release()
			return XCTFail("Accepted open transition did not enter")
		}
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		guard await XCTWaiter.fulfillment(of: [laterDrainEntered], timeout: 1) == .completed else {
			await openGate.release()
			await laterDrainGate.release()
			return XCTFail("Later accepted ingress did not enter")
		}
		await openGate.release()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		guard connector.status == .connected else {
			await laterDrainGate.release()
			return XCTFail("Accepted open did not complete within bound")
		}
		await laterDrainGate.release()
		guard await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed else {
			await connector.closeAndSettle()
			return XCTFail("Accepted output failure did not settle")
		}
		let result = await Self.twoEventsThenFailure(from: events)
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await connector.closeAndSettle()
	}

	@MainActor
	func testTerminalSettlementRetainsConnectorUntilCleanupThenReleasesIt() async throws {
		let settled = expectation(description: "retained terminal settled")
		let probe = ConnectorTerminalProbe(settledExpectation: settled)
		var connector: WebRTCConnector? = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		weak let releasedConnector = connector
		let events = try XCTUnwrap(connector).events
		try XCTUnwrap(connector).disconnect()
		connector = nil

		await fulfillment(of: [settled], timeout: 1)
		let result = await Self.finishedResult(from: events)
		XCTAssertTrue(result)
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
		XCTAssertNil(releasedConnector)
	}

	@MainActor
	func testFirstIngressFailureWinsAndCloseJoinsOneTerminalTransition() async throws {
		let probe = ConnectorTerminalProbe()
		let connector = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		connector.receiveInbound(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))
		connector.disconnect()
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await connector.closeAndSettle()

		let result = await Self.firstResult(from: connector.events)
		XCTAssertEqual(result, .expectedFailure(.eventTooLarge))
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
	}

	@MainActor
	func testQualificationPeerDefaultCloseAndSettlePreservesExistingConformers() async {
		let peer = QualificationPeerWithoutExplicitSettlement()
		await peer.closeAndSettle()
		XCTAssertTrue(peer.didDisconnect)
	}

	private enum TerminalObservation: Equatable, Sendable {
		case expectedFailure(WebRTCTransportFailure)
		case unexpected
	}

	@MainActor private static func firstResult<Element: Sendable>(
		from stream: AsyncThrowingStream<Element, Error>
	) async -> TerminalObservation {
		await boundedObservation(timeoutValue: .unexpected) {
			var iterator = stream.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
	}

	@MainActor private static func oneEventThenFailure<Element: Sendable>(
		from stream: AsyncThrowingStream<Element, Error>
	) async -> TerminalObservation {
		await boundedObservation(timeoutValue: .unexpected) {
			var iterator = stream.makeAsyncIterator()
			do {
				guard try await iterator.next() != nil else { return .unexpected }
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
	}

	@MainActor private static func twoEventsThenFailure<Element: Sendable>(
		from stream: AsyncThrowingStream<Element, Error>
	) async -> TerminalObservation {
		await boundedObservation(timeoutValue: .unexpected) {
			var iterator = stream.makeAsyncIterator()
			do {
				guard try await iterator.next() != nil else { return .unexpected }
				guard try await iterator.next() != nil else { return .unexpected }
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
	}

	@MainActor private static func connectedThenInbound(
		from stream: AsyncThrowingStream<WebRTCConnectorQualificationEvent, Error>
	) async -> Bool {
		await boundedObservation(timeoutValue: false) {
			var iterator = stream.makeAsyncIterator()
			do {
				guard case .connected = try await iterator.next() else { return false }
				guard case .inbound = try await iterator.next() else { return false }
				return true
			} catch {
				return false
			}
		}
	}

	@MainActor private static func finishedResult<Element: Sendable>(
		from stream: AsyncThrowingStream<Element, Error>
	) async -> Bool {
		await boundedObservation(timeoutValue: false) {
			var iterator = stream.makeAsyncIterator()
			do { return try await iterator.next() == nil }
			catch { return false }
		}
	}

	@MainActor private static func boundedObservation<Result: Sendable>(
		timeoutValue: Result,
		_ operation: @escaping @MainActor @Sendable () async -> Result
	) async -> Result {
		let completion = TestTaskCompletionProbe()
		let task = Task { @MainActor in
			defer { completion.markComplete() }
			return await operation()
		}
		guard await XCTWaiter.fulfillment(of: [completion.expectation()], timeout: 1) == .completed else {
			task.cancel()
			if await XCTWaiter.fulfillment(of: [completion.expectation()], timeout: 1) == .completed {
				_ = await task.value
			}
			XCTFail("Bounded observation did not complete")
			return timeoutValue
		}
		return await task.value
	}

}

private struct StubSession: WebRTCSignalingSession {
    let response: WebRTCSignalingHTTPResponse

    func data(for _: URLRequest) async throws -> WebRTCSignalingHTTPResponse { response }
}

private actor CountingSession: WebRTCSignalingSession {
    let response: WebRTCSignalingHTTPResponse
    private(set) var callCount = 0
    private(set) var authorization: String?

    init(response: WebRTCSignalingHTTPResponse) { self.response = response }

    func data(for request: URLRequest) async throws -> WebRTCSignalingHTTPResponse {
        callCount += 1
        authorization = request.value(forHTTPHeaderField: "Authorization")
        return response
    }
}

private struct ThrowingSession: WebRTCSignalingSession {
    let error: any Error

    func data(for _: URLRequest) async throws -> WebRTCSignalingHTTPResponse { throw error }
}

@MainActor private struct NarrowConnector: Connector {
    let events: AsyncThrowingStream<WebRTCInboundEvent, any Error> = AsyncThrowingStream { $0.finish() }
    let status = RealtimeAPI.Status.disconnected

    func disconnect() {}
    func send(event _: ClientEvent) async throws {}
}

@MainActor private final class QualificationPeerWithoutExplicitSettlement: WebRTCConnectorQualificationPeer {
	let qualificationEvents: AsyncThrowingStream<WebRTCConnectorQualificationEvent, any Error> = AsyncThrowingStream { $0.finish() }
	private(set) var didDisconnect = false

	func makeOffer() async throws -> String { throw WebRTCTransportFailure.cancelled }
	func apply(answer _: String) async throws { throw WebRTCTransportFailure.cancelled }
	func send(event _: ClientEvent) async throws { throw WebRTCTransportFailure.cancelled }
	func disconnect() { didDisconnect = true }
}

@MainActor private final class ConnectorTerminalProbe {
	private let beforeDrainInbound: () async -> Void
	private let beforeOpenTransition: () async -> Void
	private let makePreReadyRetentionToken: () -> AnyObject?
	private let drainExpectation: XCTestExpectation?
	private let retirementExpectation: XCTestExpectation?
	private let settledExpectation: XCTestExpectation?
	private(set) var signalingCancels = 0
	private(set) var dataCloses = 0
	private(set) var peerCloses = 0
	private(set) var audioDisables = 0

	init(
		beforeDrainInbound: @escaping () async -> Void = {},
		beforeOpenTransition: @escaping () async -> Void = {},
		makePreReadyRetentionToken: @escaping () -> AnyObject? = { nil },
		drainExpectation: XCTestExpectation? = nil,
		retirementExpectation: XCTestExpectation? = nil,
		settledExpectation: XCTestExpectation? = nil
	) {
		self.beforeDrainInbound = beforeDrainInbound
		self.beforeOpenTransition = beforeOpenTransition
		self.makePreReadyRetentionToken = makePreReadyRetentionToken
		self.drainExpectation = drainExpectation
		self.retirementExpectation = retirementExpectation
		self.settledExpectation = settledExpectation
	}

	var observer: WebRTCConnector.TerminalObserver {
		.init(
			cancelSignaling: { self.signalingCancels += 1 },
			closeData: { self.dataCloses += 1 },
			closePeer: { self.peerCloses += 1 },
			disableAudio: { self.audioDisables += 1 },
			beforeDrainInbound: beforeDrainInbound,
			beforeOpenTransition: beforeOpenTransition,
			makePreReadyRetentionToken: makePreReadyRetentionToken,
			didDrainInbound: { self.drainExpectation?.fulfill() },
			didRetireAcceptedIngress: { self.retirementExpectation?.fulfill() },
			didSettle: { self.settledExpectation?.fulfill() }
		)
	}
}

private final class RetentionToken {}

private final class WeakRetentionBox: @unchecked Sendable {
	weak var token: RetentionToken?
}

@MainActor private final class TestTaskCompletionProbe {
	private var complete = false
	private var waiters: [XCTestExpectation] = []

	func expectation() -> XCTestExpectation {
		let expectation = XCTestExpectation(description: "content-free task completion")
		if complete {
			expectation.fulfill()
		} else {
			waiters.append(expectation)
		}
		return expectation
	}

	func markComplete() {
		guard !complete else { return }
		complete = true
		let installed = waiters
		waiters.removeAll()
		installed.forEach { $0.fulfill() }
	}
}

private actor StickySuspensionGate {
	private var released = false
	private var waiter: CheckedContinuation<Void, Never>?

	func wait() async {
		if released { return }
		await withCheckedContinuation { continuation in
			if released {
				continuation.resume()
			} else {
				precondition(waiter == nil)
				waiter = continuation
			}
		}
	}

	func release() {
		released = true
		let installed = waiter
		waiter = nil
		installed?.resume()
	}
}

private actor CompletionFlag {
	private(set) var isComplete = false
	func markComplete() { isComplete = true }
	func currentValue() -> Bool { isComplete }
}

private actor LoopbackHTTPServer {
	private let socket: Int32
	private let makeResponse: @Sendable (URL) -> String
	private var requestCount = 0
	private var waiter: CheckedContinuation<Void, Never>?
	private var stoppedWaiter: CheckedContinuation<Void, Never>?
	private var stopped = false
	private var requestedPaths: [String] = []
	private var requestedAuthorization: [String?] = []

	let url: URL

	init(response: @escaping @Sendable (URL) -> String) throws {
		let listenerSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
		guard listenerSocket >= 0 else { throw URLError(.cannotCreateFile) }
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
		address.sin_port = 0
		guard withUnsafePointer(to: &address, { pointer in
			Darwin.bind(listenerSocket, UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
		}) == 0, Darwin.listen(listenerSocket, 1) == 0 else {
			Darwin.close(listenerSocket)
			throw URLError(.cannotConnectToHost)
		}
		var boundAddress = sockaddr_in()
		var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
		guard withUnsafeMutablePointer(to: &boundAddress, { pointer in
			Darwin.getsockname(listenerSocket, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), &boundLength)
		}) == 0 else {
			Darwin.close(listenerSocket)
			throw URLError(.cannotConnectToHost)
		}
		socket = listenerSocket
		makeResponse = response
		url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))")!
		let socket = listenerSocket
		Task.detached { [weak self] in
			while true {
				let client = Darwin.accept(socket, nil, nil)
				guard client >= 0 else {
					await self?.recordStop()
					return
				}
				var buffer = [UInt8](repeating: 0, count: 4096)
				let received = Darwin.recv(client, &buffer, buffer.count, 0)
				let request = String(decoding: buffer.prefix(max(received, 0)), as: UTF8.self)
				let response = await self?.response(for: request) ?? Data()
				response.withUnsafeBytes { bytes in
					_ = Darwin.send(client, bytes.baseAddress, bytes.count, 0)
				}
				Darwin.close(client)
				await self?.recordRequest()
			}
		}
	}

	func stopAndDrain() async {
		Darwin.close(socket)
		guard !stopped else { return }
		await withCheckedContinuation { stoppedWaiter = $0 }
	}

	func receivedRequestCount() -> Int { requestCount }

	func receivedPaths() -> [String] { requestedPaths }

	func receivedAuthorization() -> [String?] { requestedAuthorization }

	func waitForRequest() async {
		guard requestCount == 0 else { return }
		await withCheckedContinuation { waiter = $0 }
	}

	private func recordRequest() {
		requestCount += 1
		waiter?.resume()
		waiter = nil
	}

	private func recordStop() {
		stopped = true
		stoppedWaiter?.resume()
		stoppedWaiter = nil
	}

	private func response(for request: String) -> Data {
		let requestLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
		let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
		requestedPaths.append(path)
		let authorization = request
			.split(separator: "\r\n")
			.first(where: { $0.lowercased().hasPrefix("authorization:") })
			.map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
		requestedAuthorization.append(authorization)
		return Data(makeResponse(url).utf8)
	}
}

private func assertRedirectIsNotFollowed(
	origin: LoopbackHTTPServer,
	target: LoopbackHTTPServer,
	expectedTargetPath: String
) async throws {
	let request = try WebRTCSignalingRequest(
		endpoint: origin.url,
		model: "model",
		bearerToken: "credential"
	).makeRequest(localSDP: "offer")
	_ = try? await URLSessionWebRTCSignalingSession().data(for: request)
	// The production request and redirect delegate have completed before this first response barrier.
	await origin.waitForRequest()
	if origin === target {
		await origin.stopAndDrain()
		let targetCount = await target.receivedRequestCount()
		let targetPaths = await target.receivedPaths()
		let targetAuthorization = await target.receivedAuthorization()
		XCTAssertEqual(targetCount, 1)
		XCTAssertTrue(targetPaths == ["/realtime/calls"])
		XCTAssertFalse(targetPaths.contains(expectedTargetPath))
		XCTAssertTrue(targetAuthorization.dropFirst().allSatisfy { $0 == nil })
	} else {
		await origin.stopAndDrain()
		await target.stopAndDrain()
		let targetCount = await target.receivedRequestCount()
		let targetAuthorization = await target.receivedAuthorization()
		XCTAssertEqual(targetCount, 0)
		XCTAssertTrue(targetAuthorization.isEmpty)
	}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {
        verify(error)
    }
}
