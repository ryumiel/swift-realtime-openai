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
		let productionDisconnectGate = StickySuspensionGate()
		let productionDisconnectProbe = TestTaskCompletionProbe()
		let productionDisconnect = Task { @MainActor in
			defer { productionDisconnectProbe.markComplete() }
			await productionDisconnectGate.wait()
			productionPeer.disconnect()
		}
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
		await productionDisconnectGate.release()
		var lifecycleCompleted = await XCTWaiter.fulfillment(of: [lifecycleProbe.expectation()], timeout: 1) == .completed
		var disconnectCompleted = await XCTWaiter.fulfillment(of: [productionDisconnectProbe.expectation()], timeout: 1) == .completed
		if !lifecycleCompleted || !disconnectCompleted {
			if !lifecycleCompleted { lifecycleReader.cancel() }
			if !disconnectCompleted { productionDisconnect.cancel() }
			await productionDisconnectGate.release()
			if !lifecycleCompleted {
				lifecycleCompleted = await XCTWaiter.fulfillment(of: [lifecycleProbe.expectation()], timeout: 1) == .completed
			}
			if !disconnectCompleted {
				disconnectCompleted = await XCTWaiter.fulfillment(of: [productionDisconnectProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(lifecycleCompleted, task: "connector lifecycle reader")
		Self.requireCompleted(disconnectCompleted, task: "connector lifecycle disconnect")
		let lifecycleSucceeded = await lifecycleReader.value
		await productionDisconnect.value
		XCTAssertTrue(lifecycleSucceeded)
		XCTAssertTrue(disconnectCompleted)
		let connector = try WebRTCConnector.create(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let signalingProbe = TestTaskCompletionProbe()
		let signalingTask = Task<String, Error> {
			defer { signalingProbe.markComplete() }
			try await Task.sleep(for: .seconds(30))
			return "answer"
		}
		XCTAssertTrue(connector.installSignalingTask(signalingTask))
		let callbackProbe = TestTaskCompletionProbe()
		let callback = Task { @MainActor in
			defer { callbackProbe.markComplete() }
			connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		}

		connector.disconnect()
		connector.disconnect()
		var callbackCompleted = await XCTWaiter.fulfillment(of: [callbackProbe.expectation()], timeout: 1) == .completed
		var signalingCompleted = await XCTWaiter.fulfillment(of: [signalingProbe.expectation()], timeout: 1) == .completed
		if !callbackCompleted || !signalingCompleted {
			if !callbackCompleted { callback.cancel() }
			if !signalingCompleted { signalingTask.cancel() }
			if !callbackCompleted {
				callbackCompleted = await XCTWaiter.fulfillment(of: [callbackProbe.expectation()], timeout: 1) == .completed
			}
			if !signalingCompleted {
				signalingCompleted = await XCTWaiter.fulfillment(of: [signalingProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(callbackCompleted, task: "connector callback")
		Self.requireCompleted(signalingCompleted, task: "connector signaling")
		await callback.value
		do {
			_ = try await signalingTask.value
			XCTFail("Expected the connector-owned signaling task to be cancelled")
		} catch {
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertTrue(callbackCompleted)
		XCTAssertTrue(signalingCompleted)
		XCTAssertEqual(connector.status, .disconnected)
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
		let terminalProbe = TestTaskCompletionProbe()
		let terminalReader = Task { @MainActor in
			defer { terminalProbe.markComplete() }
			var iterator = connector.events.makeAsyncIterator()
			do { return try await iterator.next() == nil } catch { return false }
		}
		var terminalCompleted = await XCTWaiter.fulfillment(of: [terminalProbe.expectation()], timeout: 1) == .completed
		if !terminalCompleted {
			terminalReader.cancel()
			terminalCompleted = await XCTWaiter.fulfillment(of: [terminalProbe.expectation()], timeout: 1) == .completed
		}
		Self.requireCompleted(terminalCompleted, task: "connector terminal reader")
		let terminalEnded = await terminalReader.value
		XCTAssertTrue(terminalEnded)
		XCTAssertTrue(terminalCompleted)
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
			let closeGate = StickySuspensionGate()
			let closeProbe = TestTaskCompletionProbe()
			let closeTask = Task { @MainActor in
				defer { closeProbe.markComplete() }
				await closeGate.wait()
				await connector.closeAndSettle()
			}
			let readerProbe = TestTaskCompletionProbe()
			let reader = Task { @MainActor in
				defer { readerProbe.markComplete() }
				var iterator = qualificationEvents.makeAsyncIterator()
				do {
					_ = try await iterator.next()
					return TerminalObservation.unexpected
				} catch let failure as WebRTCTransportFailure {
					return .expectedFailure(failure)
				} catch {
					return .unexpected
				}
			}
			connector.receiveInbound(payload)
			if expected == .eventTooLarge {
				drained.fulfill()
			}
			let drainedCompleted = await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
			await closeGate.release()
			var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			if !readerCompleted || !closeCompleted {
				if !readerCompleted { reader.cancel() }
				if !closeCompleted { closeTask.cancel() }
				await closeGate.release()
				if !readerCompleted {
					readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
				}
				if !closeCompleted {
					closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
				}
			}
			Self.requireCompleted(readerCompleted, task: "decoded failure reader")
			Self.requireCompleted(closeCompleted, task: "decoded failure close")
			let result = await reader.value
			XCTAssertEqual(result, .expectedFailure(expected))
			await closeTask.value
			XCTAssertTrue(drainedCompleted)
			XCTAssertTrue(readerCompleted)
			XCTAssertTrue(closeCompleted)
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
		let readerStartGate = StickySuspensionGate()
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<Bool, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = qualification.makeAsyncIterator()
			do {
				guard case .connected = try await iterator.next() else { return false }
				guard case .inbound = try await iterator.next() else { return false }
				return true
			} catch {
				return false
			}
		}
		connector.scheduleOpenTransitionForQualification()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		let connected = connector.status == .connected
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"bounded"}"#.utf8))
		let drainedCompleted = await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
		await readerStartGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await readerStartGate.release()
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "bounded mailbox reader")
		Self.requireCompleted(closeCompleted, task: "bounded mailbox close")
		let ordered = await reader.value
		XCTAssertTrue(ordered)
		await closeTask.value
		XCTAssertTrue(connected)
		XCTAssertTrue(drainedCompleted)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor
	func testIngressOverflowFailsTheExactQualificationSessionAndSettles() async throws {
		let peer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		let connector = try XCTUnwrap(peer as? WebRTCConnector)
		let qualification = connector.qualificationEvents
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = qualification.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return TerminalObservation.unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}

		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))

		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "overflow reader")
		Self.requireCompleted(closeCompleted, task: "overflow close")
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await closeTask.value
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
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
		let events = connector.qualificationEvents
		let readerStartGate = StickySuspensionGate()
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
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
		connector.scheduleOpenTransitionForQualification()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		let connected = connector.status == .connected
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let firstDrained = await XCTWaiter.fulfillment(of: [firstInboundDrained], timeout: 1) == .completed
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let retired = await XCTWaiter.fulfillment(of: [acceptedOutputsRetired], timeout: 1) == .completed
		let terminalSettled = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		await readerStartGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await readerStartGate.release()
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "capacity overflow reader")
		Self.requireCompleted(closeCompleted, task: "capacity overflow close")
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await closeTask.value
		XCTAssertTrue(connected)
		XCTAssertTrue(firstDrained)
		XCTAssertTrue(retired)
		XCTAssertTrue(terminalSettled)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor
	func testIngressRejectsOversizedBytesBeforeMailboxCustody() async throws {
		let peer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		let connector = try XCTUnwrap(peer as? WebRTCConnector)
		let events = connector.qualificationEvents
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = events.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return TerminalObservation.unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}

		connector.receiveInbound(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "oversized ingress reader")
		Self.requireCompleted(closeCompleted, task: "oversized ingress close")
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.eventTooLarge))
		await closeTask.value
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor
	func testOrdinaryConnectorRetainsItsPublicEventDelivery() async throws {
		let connector = try WebRTCConnector.create(
			 session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		)
		let events = connector.events
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
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
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "ordinary event reader")
		Self.requireCompleted(closeCompleted, task: "ordinary event close")
		let readSucceeded = await reader.value
		XCTAssertTrue(readSucceeded)
		await closeTask.value
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
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
		let observerStartGate = StickySuspensionGate()
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let observerProbe = TestTaskCompletionProbe()
		let observer = Task { @MainActor in
			defer { observerProbe.markComplete() }
			await observerStartGate.wait()
			var iterator = events.makeAsyncIterator()
			do { return try await iterator.next() == nil } catch { return false }
		}
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
		let drainedCompleted = await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
		XCTAssertNotNil(retention.token)
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		await observerStartGate.release()
		var observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed
		if !observerCompleted || !closeCompleted {
			if !observerCompleted { observer.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await observerStartGate.release()
			await closeGate.release()
			if !observerCompleted { observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		XCTAssertNil(retention.token)
		Self.requireCompleted(observerCompleted, task: "retention observer")
		Self.requireCompleted(closeCompleted, task: "retention close")
		let finished = await observer.value
		XCTAssertTrue(finished)
		await closeTask.value
		XCTAssertTrue(drainedCompleted)
		XCTAssertTrue(observerCompleted)
		XCTAssertTrue(closeCompleted)
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
		let events = connector.events
		let readerStartGate = StickySuspensionGate()
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let drainedCompleted = await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
		await readerStartGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "absent consumer reader")
		Self.requireCompleted(closeCompleted, task: "absent consumer close")
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		await closeTask.value
		XCTAssertTrue(drainedCompleted)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
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
			let observerStartGate = StickySuspensionGate()
			let closeGate = StickySuspensionGate()
			let closeProbe = TestTaskCompletionProbe()
			let closeTask = Task { @MainActor in
				defer { closeProbe.markComplete() }
				await closeGate.wait()
				await connector.closeAndSettle()
			}
			let observerProbe = TestTaskCompletionProbe()
			let observer = Task { @MainActor in
				defer { observerProbe.markComplete() }
				await observerStartGate.wait()
				var iterator = events.makeAsyncIterator()
				do { return try await iterator.next() == nil } catch { return false }
			}
			if occupancy >= 1 {
				connector.receiveDataChannelState(isOpen: true, isTerminal: false)
			}
			var drainedCompleted = true
			if occupancy == 2 {
				connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
				if let drained {
					drainedCompleted = await XCTWaiter.fulfillment(of: [drained], timeout: 1) == .completed
				}
			}
			await closeGate.release()
			var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			await observerStartGate.release()
			var observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed
			if !closeCompleted || !observerCompleted {
				if !closeCompleted { closeTask.cancel() }
				if !observerCompleted { observer.cancel() }
				await closeGate.release()
				await observerStartGate.release()
				if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
				if !observerCompleted { observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed }
			}
			Self.requireCompleted(closeCompleted, task: "custody close")
			Self.requireCompleted(observerCompleted, task: "custody observer")
			await closeTask.value
			let finished = await observer.value
			XCTAssertTrue(finished)
			XCTAssertTrue(drainedCompleted)
			XCTAssertTrue(closeCompleted)
			XCTAssertTrue(observerCompleted)
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
		let closeGate = StickySuspensionGate()
		let closeTaskProbe = TestTaskCompletionProbe()
		let closeProbe = CompletionFlag()
		let closeTask = Task { @MainActor in
			defer { closeTaskProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
			await closeProbe.markComplete()
		}
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

		let closeCompletedEarly = await closeProbe.currentValue()
		XCTAssertFalse(closeCompletedEarly)

		await drainGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeTaskProbe.expectation()], timeout: 1) == .completed
		var settledCompleted = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted || !settledCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await drainGate.release()
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeTaskProbe.expectation()], timeout: 1) == .completed }
			if !settledCompleted { settledCompleted = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "accepted-ingress reader")
		Self.requireCompleted(closeCompleted, task: "accepted-ingress close")
		Self.requireCompleted(settledCompleted, task: "accepted-ingress settlement")
		let readSucceeded = await reader.value
		await closeTask.value
		XCTAssertTrue(readSucceeded)
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
			let closeGate = StickySuspensionGate()
			let closeProbe = TestTaskCompletionProbe()
			let closeTask = Task { @MainActor in
				defer { closeProbe.markComplete() }
				await closeGate.wait()
				await connector.closeAndSettle()
			}
			let events = connector.qualificationEvents
			let readerProbe = TestTaskCompletionProbe()
			let reader = Task { @MainActor in
				defer { readerProbe.markComplete() }
				var iterator = events.makeAsyncIterator()
				do {
					_ = try await iterator.next()
					return TerminalObservation.unexpected
				} catch let failure as WebRTCTransportFailure {
					return .expectedFailure(failure)
				} catch {
					return .unexpected
				}
			}

			connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
			let entered = await XCTWaiter.fulfillment(of: [firstDrainEntered], timeout: 1)
			connector.receiveInbound(laterPayload)
			await drainGate.release()
			let retired = await XCTWaiter.fulfillment(of: [acceptedIngressRetired], timeout: 1)
			await closeGate.release()
			var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			if !readerCompleted || !closeCompleted {
				if !readerCompleted { reader.cancel() }
				if !closeCompleted { closeTask.cancel() }
				await drainGate.release()
				await closeGate.release()
				if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
				if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
			}
			Self.requireCompleted(readerCompleted, task: "first accepted failure reader")
			Self.requireCompleted(closeCompleted, task: "first accepted failure close")
			XCTAssertEqual(entered, .completed)
			XCTAssertEqual(retired, .completed)
			let result = await reader.value
			await closeTask.value
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
		let closeStartGate = StickySuspensionGate()
		let closeTaskProbe = TestTaskCompletionProbe()
		let closeProbe = CompletionFlag()
		let close = Task { @MainActor in
			defer { closeTaskProbe.markComplete() }
			await closeStartGate.wait()
			await connector.closeAndSettle()
			await closeProbe.markComplete()
		}
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

		let closeCompletedEarly = await closeProbe.currentValue()
		XCTAssertFalse(closeCompletedEarly)
		await closeStartGate.release()
		await openGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeTaskProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { close.cancel() }
			await openGate.release()
			await closeStartGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeTaskProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "scheduled-open delivery reader")
		Self.requireCompleted(closeCompleted, task: "scheduled-open delivery close")
		let readSucceeded = await reader.value
		await close.value
		XCTAssertTrue(readSucceeded)
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
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let events = connector.qualificationEvents
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = events.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return TerminalObservation.unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}

		connector.scheduleOpenTransitionForQualification()
		connector.scheduleOpenTransitionForQualification()
		let open = await XCTWaiter.fulfillment(of: [openEntered], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
		let retired = await XCTWaiter.fulfillment(of: [ingressRetired], timeout: 1)
		await openGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await openGate.release()
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "earlier accepted failure reader")
		Self.requireCompleted(closeCompleted, task: "earlier accepted failure close")
		XCTAssertEqual(open, .completed)
		XCTAssertEqual(retired, .completed)
		let result = await reader.value
		await closeTask.value
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
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let events = connector.qualificationEvents
		let readerStartGate = StickySuspensionGate()
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
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

		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let firstDrained = await XCTWaiter.fulfillment(of: [firstDrainCompleted], timeout: 1)
		connector.scheduleOpenTransitionForQualification()
		let entered = await XCTWaiter.fulfillment(of: [openEntered], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let laterEntered = await XCTWaiter.fulfillment(of: [laterDrainEntered], timeout: 1)
		await openGate.release()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		let opened = connector.status == .connected
		await laterDrainGate.release()
		let settlement = await XCTWaiter.fulfillment(of: [settled], timeout: 1)
		XCTAssertEqual(firstDrained, .completed)
		XCTAssertEqual(entered, .completed)
		XCTAssertEqual(laterEntered, .completed)
		XCTAssertTrue(opened)
		XCTAssertEqual(settlement, .completed)
		await readerStartGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await openGate.release()
			await laterDrainGate.release()
			await readerStartGate.release()
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "accepted-open delivery reader")
		Self.requireCompleted(closeCompleted, task: "accepted-open delivery close")
		let result = await reader.value
		await closeTask.value
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
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
		let readerStartGate = StickySuspensionGate()
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
			do { return try await iterator.next() == nil } catch { return false }
		}
		let disconnectProbe = TestTaskCompletionProbe()
		let disconnectTask = Task { @MainActor in
			defer { disconnectProbe.markComplete() }
			try? XCTUnwrap(connector).disconnect()
		}
		var disconnectCompleted = await XCTWaiter.fulfillment(of: [disconnectProbe.expectation()], timeout: 1) == .completed
		if !disconnectCompleted {
			disconnectTask.cancel()
			disconnectCompleted = await XCTWaiter.fulfillment(of: [disconnectProbe.expectation()], timeout: 1) == .completed
		}
		Self.requireCompleted(disconnectCompleted, task: "retained connector disconnect")
		await disconnectTask.value
		connector = nil

		let settledCompleted = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		await readerStartGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted {
			reader.cancel()
			await readerStartGate.release()
			readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		}
		Self.requireCompleted(readerCompleted, task: "retained connector reader")
		let result = await reader.value
		XCTAssertTrue(result)
		XCTAssertTrue(settledCompleted)
		XCTAssertTrue(disconnectCompleted)
		XCTAssertTrue(readerCompleted)
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
		let events = connector.events
		let readerStartGate = StickySuspensionGate()
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch { return .unexpected }
		}
		let disconnectStartGate = StickySuspensionGate()
		let disconnectProbe = TestTaskCompletionProbe()
		let disconnectTask = Task { @MainActor in
			defer { disconnectProbe.markComplete() }
			await disconnectStartGate.wait()
			connector.disconnect()
		}
		connector.receiveInbound(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1))
		await disconnectStartGate.release()
		var disconnectCompleted = await XCTWaiter.fulfillment(of: [disconnectProbe.expectation()], timeout: 1) == .completed
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await readerStartGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted || !disconnectCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			if !disconnectCompleted { disconnectTask.cancel() }
			await readerStartGate.release()
			await closeGate.release()
			await disconnectStartGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
			if !disconnectCompleted { disconnectCompleted = await XCTWaiter.fulfillment(of: [disconnectProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "first failure reader")
		Self.requireCompleted(closeCompleted, task: "first failure close")
		Self.requireCompleted(disconnectCompleted, task: "first failure disconnect")
		let result = await reader.value
		XCTAssertEqual(result, .expectedFailure(.eventTooLarge))
		await closeTask.value
		await disconnectTask.value
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
		XCTAssertTrue(disconnectCompleted)
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

	@MainActor
	func testWithholdThenSettleObservationControlReleasesEveryOwnedWaiter() async {
		let gate = StickySuspensionGate()
		let entered = expectation(description: "observation entered withheld wait")
		let completion = TestTaskCompletionProbe()
		let observer = Task { @MainActor in
			defer { completion.markComplete() }
			entered.fulfill()
			await gate.wait()
		}
		await fulfillment(of: [entered], timeout: 1)
		let firstBound = await XCTWaiter.fulfillment(of: [completion.expectation()], timeout: 0.05)
		let secondBound = await XCTWaiter.fulfillment(of: [completion.expectation()], timeout: 0.05)
		await gate.release()
		let settled = await XCTWaiter.fulfillment(of: [completion.expectation()], timeout: 1) == .completed
		Self.requireCompleted(settled, task: "withhold observation")
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertEqual(secondBound, .timedOut)
		XCTAssertTrue(settled)
		await observer.value
	}

	@MainActor func testTerminalLifecycleReaderTimeoutSettlesReaderIteratorAndConnectorControl() async throws {
		let probe = ConnectorTerminalProbe()
		let connector = try WebRTCConnector.createQualification(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")), terminalObserver: probe.observer)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<WebRTCConnectorQualificationEvent?, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			return try? await iterator.next()
		}
		let firstBound = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		reader.cancel()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "terminal lifecycle reader")
		Self.requireCompleted(closeCompleted, task: "terminal lifecycle close")
		_ = await reader.value
		await closeTask.value
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
	}
	@MainActor func testDecodedFailureTimeoutSettlesRealDrainReaderAndConnector() async throws {
		let drainGate = StickySuspensionGate()
		let entered = expectation(description: "decoded failure entered drain")
		let retired = expectation(description: "decoded failure retired")
		let settled = expectation(description: "decoded failure settled")
		let terminalProbe = ConnectorTerminalProbe(
			beforeDrainInbound: { entered.fulfill(); await drainGate.wait() },
			retirementExpectation: retired,
			settledExpectation: settled
		)
		let connector = try WebRTCConnector.createQualification(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")), terminalObserver: terminalProbe.observer)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return TerminalObservation.unexpected
			} catch let failure as WebRTCTransportFailure {
				return TerminalObservation.expectedFailure(failure)
			} catch {
				return TerminalObservation.unexpected
			}
		}
		connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
		await fulfillment(of: [entered], timeout: 1)
		let firstBound = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		await drainGate.release()
		await closeGate.release()
		var retiredCompleted = await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed
		var terminalSettled = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !retiredCompleted || !terminalSettled || !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await drainGate.release()
			await closeGate.release()
			if !retiredCompleted { retiredCompleted = await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed }
			if !terminalSettled { terminalSettled = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed }
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(retiredCompleted, task: "decoded failure retirement")
		Self.requireCompleted(terminalSettled, task: "decoded failure settlement")
		Self.requireCompleted(readerCompleted, task: "decoded failure reader")
		Self.requireCompleted(closeCompleted, task: "decoded failure close")
		let failure = await reader.value
		await closeTask.value
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertTrue(retiredCompleted)
		XCTAssertTrue(terminalSettled)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
		XCTAssertEqual(failure, .expectedFailure(.providerError))
		XCTAssertEqual(terminalProbe.signalingCancels, 1)
		XCTAssertEqual(terminalProbe.dataCloses, 1)
		XCTAssertEqual(terminalProbe.peerCloses, 1)
		XCTAssertEqual(terminalProbe.audioDisables, 1)
	}

	@MainActor func testOrdinaryDeliveryTimeoutSettlesRealReaderIteratorAndConnector() async throws {
		let connector = try WebRTCConnector.create(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")))
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.events.makeAsyncIterator()
			return try? await iterator.next()
		}
		let firstBound = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		reader.cancel()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
			if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
		}
		Self.requireCompleted(readerCompleted, task: "ordinary delivery reader")
		Self.requireCompleted(closeCompleted, task: "ordinary delivery close")
		_ = await reader.value
		await closeTask.value
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor func testQueuedContentTimeoutSettlesRealDrainAndConnector() async throws {
		let gate = StickySuspensionGate()
		let entered = expectation(description: "queued drain entered")
		let terminalProbe = ConnectorTerminalProbe(beforeDrainInbound: { entered.fulfill(); await gate.wait() })
		let connector = try WebRTCConnector.createQualification(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")), terminalObserver: terminalProbe.observer)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await fulfillment(of: [entered], timeout: 1)
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in defer { closeProbe.markComplete() }; await connector.closeAndSettle() }
		let firstBound = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 0.05)
		await gate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !closeCompleted {
			closeTask.cancel()
			await gate.release()
			closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		}
		Self.requireCompleted(closeCompleted, task: "queued content close")
		await closeTask.value
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertTrue(closeCompleted)
		XCTAssertEqual(terminalProbe.signalingCancels, 1)
		XCTAssertEqual(terminalProbe.dataCloses, 1)
		XCTAssertEqual(terminalProbe.peerCloses, 1)
		XCTAssertEqual(terminalProbe.audioDisables, 1)
	}

	@MainActor func testCustodyLoopTimeoutSettlesIterationDrainAndIteratorControl() async throws {
		var allSettled = true
		for occupancy in 0...2 {
			let connector = try WebRTCConnector.createQualification(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")))
			if occupancy >= 1 { connector.receiveDataChannelState(isOpen: true, isTerminal: false) }
			if occupancy == 2 { connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8)) }
			let readerProbe = TestTaskCompletionProbe()
			let closeStartGate = StickySuspensionGate()
			let reader = Task { @MainActor in
				defer { readerProbe.markComplete() }
				var iterator = connector.qualificationEvents.makeAsyncIterator()
				do { while try await iterator.next() != nil {} } catch {}
			}
			let closeProbe = TestTaskCompletionProbe()
			let closeTask = Task { @MainActor in
				defer { closeProbe.markComplete() }
				await closeStartGate.wait()
				await connector.closeAndSettle()
			}
			let firstBound = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
			await closeStartGate.release()
			var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			if !readerCompleted || !closeCompleted {
				if !readerCompleted { reader.cancel() }
				if !closeCompleted { closeTask.cancel() }
				await closeStartGate.release()
				if !readerCompleted { readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed }
				if !closeCompleted { closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed }
			}
			Self.requireCompleted(readerCompleted, task: "custody loop reader")
			Self.requireCompleted(closeCompleted, task: "custody loop close")
			await reader.value
			await closeTask.value
			allSettled = allSettled && firstBound == .timedOut
		}
		XCTAssertTrue(allSettled)
	}
	@MainActor
	func testAcceptedIngressTimeoutSettlesReaderCloseAndDrainGateControl() async throws {
		let drainGate = StickySuspensionGate()
		let drainEntered = expectation(description: "accepted ingress entered drain")
		let probe = ConnectorTerminalProbe(beforeDrainInbound: {
			drainEntered.fulfill()
			await drainGate.wait()
		})
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			do {
				guard case .connected = try await iterator.next() else { return false }
				guard case .inbound = try await iterator.next() else { return false }
				return true
			} catch {
				return false
			}
		}
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		await fulfillment(of: [drainEntered], timeout: 1)
		let beforeCleanup = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		reader.cancel()
		await drainGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await drainGate.release()
			await closeGate.release()
			if !readerCompleted {
				readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(readerCompleted, task: "accepted-ingress reader")
		Self.requireCompleted(closeCompleted, task: "accepted-ingress close")
		let result = await reader.value
		await closeTask.value
		XCTAssertEqual(beforeCleanup, .timedOut)
		XCTAssertEqual(result, false)
	}

	@MainActor
	func testFirstFailureTimeoutSettlesReaderGateAndRetirementControl() async throws {
		let drainGate = StickySuspensionGate()
		let drainEntered = expectation(description: "first failure entered drain")
		let retired = expectation(description: "first failure retired")
		let probe = ConnectorTerminalProbe(
			beforeDrainInbound: { drainEntered.fulfill(); await drainGate.wait() },
			retirementExpectation: retired
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
		connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
		await fulfillment(of: [drainEntered], timeout: 1)

		let beforeCleanup = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		await drainGate.release()
		await closeGate.release()
		var retiredCompleted = await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !retiredCompleted || !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await drainGate.release()
			await closeGate.release()
			if !retiredCompleted {
				retiredCompleted = await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed
			}
			if !readerCompleted {
				readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(retiredCompleted, task: "first-failure retirement")
		Self.requireCompleted(readerCompleted, task: "first-failure reader")
		Self.requireCompleted(closeCompleted, task: "first-failure close")
		let result = await reader.value
		await closeTask.value
		XCTAssertEqual(beforeCleanup, .timedOut)
		XCTAssertEqual(result, .expectedFailure(.providerError))
	}

	@MainActor
	func testScheduledOpenTimeoutSettlesReaderCloseAndOpenGateControl() async throws {
		let openGate = StickySuspensionGate()
		let openEntered = expectation(description: "scheduled open entered")
		let probe = ConnectorTerminalProbe(beforeOpenTransition: {
			openEntered.fulfill()
			await openGate.wait()
		})
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			return try? await iterator.next()
		}
		connector.scheduleOpenTransitionForQualification()
		await fulfillment(of: [openEntered], timeout: 1)

		let beforeCleanup = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		await openGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await openGate.release()
			await closeGate.release()
			if !readerCompleted {
				readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(readerCompleted, task: "scheduled-open reader")
		Self.requireCompleted(closeCompleted, task: "scheduled-open close")
		_ = await reader.value
		await closeTask.value
		XCTAssertEqual(beforeCleanup, .timedOut)
	}

	@MainActor
	func testPendingOpenTimeoutSettlesReaderAndPendingGateControl() async throws {
		let openGate = StickySuspensionGate()
		let openEntered = expectation(description: "pending open entered")
		let retired = expectation(description: "pending open failure retired")
		let probe = ConnectorTerminalProbe(
			beforeOpenTransition: { openEntered.fulfill(); await openGate.wait() },
			retirementExpectation: retired
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
		connector.scheduleOpenTransitionForQualification()
		connector.scheduleOpenTransitionForQualification()
		await fulfillment(of: [openEntered], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"error"}"#.utf8))
		await fulfillment(of: [retired], timeout: 1)

		let beforeCleanup = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)
		await openGate.release()
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await openGate.release()
			await closeGate.release()
			if !readerCompleted {
				readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(readerCompleted, task: "pending-open reader")
		Self.requireCompleted(closeCompleted, task: "pending-open close")
		let result = await reader.value
		await closeTask.value
		XCTAssertEqual(beforeCleanup, .timedOut)
		XCTAssertEqual(result, .expectedFailure(.providerError))
	}

	@MainActor
	func testAcceptedOpenPrecedenceTimeoutSettlesObservationAndBothGatesControl() async throws {
		let openGate = StickySuspensionGate()
		let drainGate = StickySuspensionGate()
		let readerStartGate = StickySuspensionGate()
		let openEntered = expectation(description: "accepted open entered")
		let firstRawMailboxRetired = expectation(description: "first raw mailbox retired")
		let drainEntered = expectation(description: "accepted open later drain entered")
		let settled = expectation(description: "accepted open precedence settled")
		let connectedObserved = expectation(description: "accepted open connected observed")
		var drainCount = 0
		var acceptedIngressRetirements = 0
		let terminalObserver = WebRTCConnector.TerminalObserver(
			cancelSignaling: {},
			closeData: {},
			closePeer: {},
			disableAudio: {},
			beforeDrainInbound: {
				drainCount += 1
				if drainCount == 2 {
					drainEntered.fulfill()
					await drainGate.wait()
				}
			},
			beforeOpenTransition: {
				openEntered.fulfill()
				await openGate.wait()
			},
			didRetireAcceptedIngress: {
				acceptedIngressRetirements += 1
				if acceptedIngressRetirements == 1 {
					firstRawMailboxRetired.fulfill()
				}
			},
			didSettle: { settled.fulfill() }
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: terminalObserver
		)
		let events = connector.qualificationEvents
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let readerProbe = TestTaskCompletionProbe()
		let reader: Task<TerminalObservation, Never> = Task { @MainActor in
			defer { readerProbe.markComplete() }
			await readerStartGate.wait()
			var iterator = events.makeAsyncIterator()
			do {
				guard case .connected = try await iterator.next() else { return .unexpected }
				connectedObserved.fulfill()
				guard case .inbound(.responseFinished) = try await iterator.next() else { return .unexpected }
				_ = try await iterator.next()
				return .unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		connector.scheduleOpenTransitionForQualification()
		let acceptedOpenEntered = await XCTWaiter.fulfillment(of: [openEntered], timeout: 1) == .completed
		let firstRetiredBeforeSecondInbound = await XCTWaiter.fulfillment(of: [firstRawMailboxRetired], timeout: 1) == .completed
		connector.receiveInbound(Data(#"{"type":"response.done"}"#.utf8))
		let laterDrainControlled = await XCTWaiter.fulfillment(of: [drainEntered], timeout: 1) == .completed
		let beforeCleanup = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 0.05)

		await openGate.release()
		let openDeadline = ContinuousClock.now + .seconds(1)
		while connector.status != .connected, ContinuousClock.now < openDeadline {
			await Task.yield()
		}
		let acceptedOpen = connector.status == .connected
		await drainGate.release()
		let terminalSettled = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		await readerStartGate.release()
		let orderedConnected = await XCTWaiter.fulfillment(of: [connectedObserved], timeout: 1) == .completed
		await closeGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted || !closeCompleted {
			if !readerCompleted { reader.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await openGate.release()
			await drainGate.release()
			await readerStartGate.release()
			await closeGate.release()
			if !readerCompleted {
				readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(readerCompleted, task: "accepted-open reader")
		Self.requireCompleted(closeCompleted, task: "accepted-open close")
		let result = await reader.value
		await closeTask.value
		XCTAssertEqual(beforeCleanup, .timedOut)
		XCTAssertTrue(acceptedOpenEntered)
		XCTAssertTrue(firstRetiredBeforeSecondInbound)
		XCTAssertTrue(laterDrainControlled)
		XCTAssertTrue(acceptedOpen)
		XCTAssertTrue(terminalSettled)
		XCTAssertTrue(orderedConnected)
		XCTAssertEqual(acceptedIngressRetirements, 2)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
		XCTAssertEqual(result, .expectedFailure(.ingressOverloaded))
		XCTAssertNotEqual(result, .expectedFailure(.malformedEvent))
	}

	@MainActor
	func testRetentionTimeoutSettlesCloseAndReleaseControl() async throws {
		let drainGate = StickySuspensionGate()
		let entered = expectation(description: "retention ingress entered")
		let retention = WeakRetentionBox()
		let probe = ConnectorTerminalProbe(
			beforeDrainInbound: { entered.fulfill(); await drainGate.wait() },
			makePreReadyRetentionToken: {
				let token = RetentionToken()
				retention.token = token
				return token
			}
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		connector.receiveInbound(Data(#"{"type":"response.output_audio_transcript.done","transcript":"x"}"#.utf8))
		await fulfillment(of: [entered], timeout: 1)
		let beforeCleanup = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 0.05)
		await drainGate.release()
		await closeGate.release()
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !closeCompleted {
			closeTask.cancel()
			await drainGate.release()
			await closeGate.release()
			closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		}
		Self.requireCompleted(closeCompleted, task: "retention close")
		XCTAssertEqual(beforeCleanup, .timedOut)
		await closeTask.value
		XCTAssertNil(retention.token)
	}

	@MainActor
	func testObservationHelperTimeoutSettlesIteratorTaskAndProbeControl() async throws {
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		)
		let closeGate = StickySuspensionGate()
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor in
			defer { closeProbe.markComplete() }
			await closeGate.wait()
			await connector.closeAndSettle()
		}
		let observerProbe = TestTaskCompletionProbe()
		let observer = Task { @MainActor in
			defer { observerProbe.markComplete() }
			var iterator = connector.qualificationEvents.makeAsyncIterator()
			do {
				return try await iterator.next() == nil
			} catch {
				return false
			}
		}

		let firstBound = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 0.05)
		let secondBound = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 0.05)
		await closeGate.release()
		var observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed
		var closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		if !observerCompleted || !closeCompleted {
			if !observerCompleted { observer.cancel() }
			if !closeCompleted { closeTask.cancel() }
			await closeGate.release()
			if !observerCompleted {
				observerCompleted = await XCTWaiter.fulfillment(of: [observerProbe.expectation()], timeout: 1) == .completed
			}
			if !closeCompleted {
				closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
			}
		}
		Self.requireCompleted(observerCompleted, task: "observation helper reader")
		Self.requireCompleted(closeCompleted, task: "observation helper close")
		_ = await observer.value
		await closeTask.value
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertEqual(secondBound, .timedOut)
	}

	private enum TerminalObservation: Equatable, Sendable {
		case expectedFailure(WebRTCTransportFailure)
		case unexpected
	}

	@MainActor private static func requireCompleted(_ completed: Bool, task: String) {
		guard !completed else { return }
		XCTFail("Content-free owned task did not settle: \(task)")
		fatalError("Content-free owned task did not settle")
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
	var isComplete: Bool { complete }

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
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		if released { return }
		await withCheckedContinuation { continuation in
			if released {
				continuation.resume()
			} else {
				waiters.append(continuation)
			}
		}
	}

	func release() {
		released = true
		let installed = waiters
		waiters.removeAll()
		installed.forEach { $0.resume() }
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
