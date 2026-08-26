import Foundation
import Core
@_spi(AirbridgeQualification) import WebRTC
import LiveKitWebRTC
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

    func testPartialSessionUpdateUsesExactJSONWithoutTranscriptionModel() throws {
		let update = try WebRTCSessionUpdate(voice: "Custom_Voice", language: "ko")
		let object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: update.encoded()) as? [String: Any]
		)

		XCTAssertEqual(Set(object.keys), ["type", "session"])
		XCTAssertEqual(object["type"] as? String, "session.update")
		let session = try XCTUnwrap(object["session"] as? [String: Any])
		XCTAssertEqual(Set(session.keys), ["type", "audio"])
		XCTAssertEqual(session["type"] as? String, "realtime")
		let audio = try XCTUnwrap(session["audio"] as? [String: Any])
		let input = try XCTUnwrap(audio["input"] as? [String: Any])
		let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
		let output = try XCTUnwrap(audio["output"] as? [String: Any])
		XCTAssertEqual(transcription as? [String: String], ["language": "ko"])
		XCTAssertNil(transcription["model"])
		XCTAssertEqual(output as? [String: String], ["voice": "Custom_Voice"])
	}

	func testPartialSessionUpdateValidatesVoiceAndISO6391Language() throws {
		XCTAssertNoThrow(try WebRTCSessionUpdate(voice: "Ono_Anna", language: "ja"))
		XCTAssertThrowsError(try WebRTCSessionUpdate(voice: "", language: "en"))
		XCTAssertThrowsError(try WebRTCSessionUpdate(voice: "Ryan", language: "EN"))
		XCTAssertThrowsError(try WebRTCSessionUpdate(voice: "Ryan", language: "eng"))
	}

    func testEventIngressAcceptsConfiguredSessionTranscriptTerminalAndProviderErrorEvents() throws {
        let decoder = WebRTCInboundEventDecoder()
		XCTAssertEqual(
			try decoder.decode(Data(#"{"type":"session.updated","session":{"type":"realtime","audio":{"input":{"transcription":{"language":"ja"}},"output":{"voice":"Ono_Anna"}}}}"#.utf8)),
			.sessionUpdated(voice: "Ono_Anna", language: "ja")
		)
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
		XCTAssertThrowsError(try decoder.decode(Data(#"{"type":"session.created"}"#.utf8))) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .unsupportedEvent)
		}
		XCTAssertThrowsError(
			try decoder.decode(Data(#"{"type":"session.updated","session":{"type":"realtime","audio":{"input":{"transcription":{}},"output":{"voice":"Ryan"}}}}"#.utf8))
		) { error in
			XCTAssertEqual(error as? WebRTCTransportFailure, .malformedEvent)
		}
    }

	func testConnectorIngressIgnoresOnlyKnownAudioLifecycleEvents() throws {
		let decoder = WebRTCInboundEventDecoder()
		let simpleEventTypes = [
			"session.created",
			"input_audio_buffer.committed",
			"input_audio_buffer.cleared",
			"input_audio_buffer.speech_started",
			"input_audio_buffer.speech_stopped",
			"input_audio_buffer.timeout_triggered",
			"conversation.item.input_audio_transcription.delta",
			"conversation.item.input_audio_transcription.segment",
			"response.output_audio_transcript.delta",
			"response.output_audio.delta",
			"response.output_audio.done",
			"rate_limits.updated",
		]

		for eventType in simpleEventTypes {
			let payload = try XCTUnwrap(#"{"type":"\#(eventType)"}"#.data(using: .utf8))
			XCTAssertNil(try decoder.decodeForConnector(payload), eventType)
		}

		let audioLifecyclePayloads = [
			Data(#"{"type":"conversation.item.added","item":{"type":"message","role":"user","content":[{"type":"input_audio","transcript":"ignored"}]}}"#.utf8),
			Data(#"{"type":"conversation.item.done","item":{"type":"message","role":"user","content":[{"type":"input_audio"}]}}"#.utf8),
			Data(#"{"type":"response.created","response":{"output":[]}}"#.utf8),
			Data(#"{"type":"response.output_item.added","item":{"type":"message","role":"assistant","content":[{"type":"output_audio"}]}}"#.utf8),
			Data(#"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_audio","transcript":"ignored"}]}}"#.utf8),
			Data(#"{"type":"response.content_part.added","part":{"type":"output_audio"}}"#.utf8),
			Data(#"{"type":"response.content_part.done","part":{"type":"output_audio","transcript":"ignored"}}"#.utf8),
		]
		for payload in audioLifecyclePayloads {
			XCTAssertNil(try decoder.decodeForConnector(payload))
		}
		XCTAssertEqual(
			try decoder.decodeForConnector(Data(#"{"type":"response.done","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_audio"}]}]}}"#.utf8)),
			.responseFinished
		)

		for eventType in ["response.function_call_arguments.done", "response.mcp_call.completed", "unknown.event"] {
			let payload = try XCTUnwrap(#"{"type":"\#(eventType)"}"#.data(using: .utf8))
			XCTAssertThrowsError(try decoder.decodeForConnector(payload), eventType) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .unsupportedEvent)
			}
		}
	}

	func testConnectorIngressRejectsNonAudioLifecyclePayloads() throws {
		let decoder = WebRTCInboundEventDecoder()
		let rejectedPayloads = [
			Data(#"{"type":"conversation.item.added"}"#.utf8),
			Data(#"{"type":"conversation.item.added","item":{"type":"message","role":"user","content":[{"type":"input_text"}]}}"#.utf8),
			Data(#"{"type":"response.created","response":{"output":[{"type":"function_call"}]}}"#.utf8),
			Data(#"{"type":"response.done"}"#.utf8),
			Data(#"{"type":"response.done","response":{}}"#.utf8),
			Data(#"{"type":"response.done","response":{"output":null}}"#.utf8),
			Data(#"{"type":"response.done","response":{"output":[{"type":"function_call"}]}}"#.utf8),
			Data(#"{"type":"response.done","response":{"output":[{"type":"mcp_tool_call"}]}}"#.utf8),
			Data(#"{"type":"response.done","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text"}]}]}}"#.utf8),
			Data(#"{"type":"response.output_item.done","item":{"type":"function_call"}}"#.utf8),
			Data(#"{"type":"response.output_item.done","item":{"type":"mcp_tool_call"}}"#.utf8),
			Data(#"{"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text"}]}}"#.utf8),
			Data(#"{"type":"response.content_part.done","part":{"type":"text"}}"#.utf8),
		]

		for payload in rejectedPayloads {
			XCTAssertThrowsError(try decoder.decodeForConnector(payload)) { error in
				XCTAssertEqual(error as? WebRTCTransportFailure, .unsupportedEvent)
			}
		}
	}

	@MainActor
	func testConnectorContinuesAfterLocalAISessionCreatedHandshake() async throws {
		let sessionCreatedDrainProbe = TestTaskCompletionProbe()
		let terminalObserver = WebRTCConnector.TerminalObserver(
			cancelSignaling: {},
			closeData: {},
			closePeer: {},
			disableAudio: {},
			didDrainInbound: { sessionCreatedDrainProbe.markComplete() }
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: terminalObserver
		)
		let events = connector.qualificationEvents
		let readerProbe = TestTaskCompletionProbe()
		let reader = Task { @MainActor in
			defer { readerProbe.markComplete() }
			var iterator = events.makeAsyncIterator()
			do {
				guard case .connected = try await iterator.next() else { return false }
				guard case .sessionCreated = try await iterator.next() else { return false }
				guard case .inbound(.responseFinished) = try await iterator.next() else { return false }
				return true
			} catch {
				return false
			}
		}

		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		connector.receiveInbound(Data(#"{"type":"session.created"}"#.utf8))
		await fulfillment(of: [sessionCreatedDrainProbe.expectation()], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))

		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted {
			reader.cancel()
			readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		}
		await connector.closeAndSettle()
		await Self.finalizeOwnedTasks([
			(readerCompleted, "LocalAI handshake reader", { await Self.assertTrueValue(await reader.value) })
		])
		XCTAssertTrue(readerCompleted)
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
	func testLocalICEGatheringWaitReturnsAsSoonAsGatheringCompletes() async throws {
		var checks = 0
		var sleeps = 0

		try await WebRTCConnector.waitForLocalICEGathering(
			maximumChecks: 50,
			isCurrent: { true },
			isComplete: {
				checks += 1
				return checks == 3
			},
			sleep: { sleeps += 1 }
		)

		XCTAssertEqual(checks, 3)
		XCTAssertEqual(sleeps, 2)
	}

	@MainActor
	func testLocalICEGatheringWaitObservesCompletionAfterTheFinalSleep() async throws {
		var checks = 0
		var sleeps = 0

		try await WebRTCConnector.waitForLocalICEGathering(
			maximumChecks: 50,
			isCurrent: { true },
			isComplete: {
				checks += 1
				return checks == 51
			},
			sleep: { sleeps += 1 }
		)

		XCTAssertEqual(checks, 51)
		XCTAssertEqual(sleeps, 50)
	}

	@MainActor
	func testLocalICEGatheringWaitTimesOutAfterTheBoundWhenGatheringNeverCompletes() async throws {
		var sleeps = 0

		do {
			try await WebRTCConnector.waitForLocalICEGathering(
				maximumChecks: 50,
				isCurrent: { true },
				isComplete: { false },
				sleep: { sleeps += 1 }
			)
			XCTFail("Expected ICE gathering timeout")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .iceGatheringTimedOut)
		}

		XCTAssertEqual(sleeps, 50)
	}

	@MainActor
	func testLocalICEGatheringWaitStopsOnGenerationOrSleepCancellation() async throws {
		var slept = false
		do {
			try await WebRTCConnector.waitForLocalICEGathering(
				isCurrent: { false },
				isComplete: { false },
				sleep: { slept = true }
			)
			XCTFail("Expected cancelled generation")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		XCTAssertFalse(slept)

		do {
			try await WebRTCConnector.waitForLocalICEGathering(
				isCurrent: { true },
				isComplete: { false },
				sleep: { throw CancellationError() }
			)
			XCTFail("Expected cancelled sleep")
		} catch {
			XCTAssertTrue(error is CancellationError)
		}
	}

	@MainActor
	func testLocalICEGatheringWaitCancelsWhenGenerationChangesAfterASleep() async throws {
		var current = true
		var sleeps = 0

		do {
			try await WebRTCConnector.waitForLocalICEGathering(
				maximumChecks: 50,
				isCurrent: { current },
				isComplete: { false },
				sleep: {
					sleeps += 1
					current = false
				}
			)
			XCTFail("Expected cancelled generation")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}

		XCTAssertEqual(sleeps, 1)
	}

	func testQualificationDiagnosticMilestonesAreFixedAndContentFree() {
		let expected: Set<WebRTCConnectorDiagnosticMilestone> = [
			.peerCreated, .offerCreated, .localDescriptionInstalled, .iceGatheringComplete, .iceGatheringTimedOut,
			.remoteDescriptionInstalled, .iceChecking, .iceConnected, .iceCompleted, .iceDisconnected, .iceFailed,
			.iceClosed, .peerConnecting, .peerConnected, .peerDisconnected, .peerFailed, .peerClosed,
			.dataChannelConnecting, .dataChannelOpen, .dataChannelClosing, .dataChannelClosed,
			.remoteAudioTrackObserved, .teardownBegan, .teardownCompleted,
		]
		XCTAssertEqual(Set(WebRTCConnectorDiagnosticMilestone.allCases), expected)
		XCTAssertEqual(WebRTCConnectorDiagnosticMilestone.iceGatheringTimedOut.rawValue, "iceGatheringTimedOut")
	}

	func testQualificationAudioEvidenceFiltersAudioAndCapsCounts() {
		let evidence = WebRTCConnector.audioEvidence(from: [
			(type: "outbound-rtp", values: [
				"kind": NSString(string: "audio"),
				"bytesReceived": NSNumber(value: 999),
			]),
			(type: "inbound-rtp", values: [
				"kind": NSString(string: "video"),
				"bytesReceived": NSNumber(value: 999),
			]),
			(type: "inbound-rtp", values: [
				"mediaType": NSString(string: "audio"),
				"bytesReceived": NSNumber(value: 12),
				"totalSamplesReceived": NSNumber(value: 34),
			]),
		])

		XCTAssertEqual(evidence.receivedByteCount, 12)
		XCTAssertEqual(evidence.receivedSampleCount, 34)
		XCTAssertTrue(evidence.hasReceivedAudio)
		XCTAssertFalse(evidence.limitExceeded)

		let capped = WebRTCConnector.audioEvidence(from: [
			(type: "inbound-rtp", values: [
				"kind": NSString(string: "audio"),
				"bytesReceived": NSNumber(value: UInt64.max),
				"totalSamplesReceived": NSNumber(value: UInt64.max),
			]),
		])
		XCTAssertEqual(
			capped.receivedByteCount,
			WebRTCConnectorQualificationAudioEvidence.maximumReportedByteCount
		)
		XCTAssertEqual(
			capped.receivedSampleCount,
			WebRTCConnectorQualificationAudioEvidence.maximumReportedSampleCount
		)
		XCTAssertTrue(capped.limitExceeded)
	}

	@MainActor
	func testReceiveOnlyQualificationPeerNeedsNoMicrophoneAndSuppressesPlayout() async throws {
		let probe = ConnectorTerminalProbe(
			recordPermissionGranted: { false },
			waitForLocalICEGathering: {}
		)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(
				data: Data(), statusCode: 201, contentType: "application/sdp"
			)),
			terminalObserver: probe.observer,
			mediaMode: .receiveOnlyAudioEvidence
		)

		XCTAssertFalse(connector.qualificationHasLocalAudioTrack)
		XCTAssertTrue(connector.qualificationUsesManualAudioRendering)
		let offer = try await connector.makeOffer()
		XCTAssertTrue(offer.contains("m=audio"))
		XCTAssertTrue(offer.contains("a=recvonly"))
		await connector.closeAndSettle()
	}

	func testUnifiedPlanRemoteAudioDiagnosticRecognizesOnlyStreamsWithAudioTracks() {
		let factory = LKRTCPeerConnectionFactory()
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		let audioTrack = factory.audioTrack(with: audioSource, trackId: "qualification_audio")
		let streamWithAudio = factory.mediaStream(withStreamId: "qualification_stream")
		streamWithAudio.addAudioTrack(audioTrack)
		let streamWithoutAudio = factory.mediaStream(withStreamId: "qualification_empty_stream")

		XCTAssertTrue(WebRTCConnector.remoteStreamsContainAudioTrack([streamWithAudio]))
		XCTAssertFalse(WebRTCConnector.remoteStreamsContainAudioTrack([streamWithoutAudio]))
		XCTAssertTrue(WebRTCConnector.receiverOrStreamsContainAudioTrack(trackKind: "audio", streams: []))
		XCTAssertFalse(WebRTCConnector.receiverOrStreamsContainAudioTrack(trackKind: "video", streams: []))
		XCTAssertFalse(WebRTCConnector.receiverOrStreamsContainAudioTrack(trackKind: nil, streams: []))
	}

	@MainActor
	func testSelectedTerminalImmediatelyRejectsOfferBeforeSignalingCanStart() async throws {
		let drainGate = StickySuspensionGate()
		let startedDrain = expectation(description: "accepted ingress is draining")
		let signaling = CountingSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		let probe = ConnectorTerminalProbe(
			beforeDrainInbound: {
				startedDrain.fulfill()
				await drainGate.wait()
			},
			recordPermissionGranted: { true }
		)
		let connector = try WebRTCConnector.createQualification(session: signaling, terminalObserver: probe.observer)

		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		await fulfillment(of: [startedDrain], timeout: 1)
		connector.disconnect()

		do {
			try await connector.connect(using: WebRTCSignalingRequest(
				endpoint: URL(string: "https://local.invalid")!, model: "model", bearerToken: nil
			))
			XCTFail("A selected terminal must reject signaling progression")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}
		let callCount = await signaling.callCount
		XCTAssertEqual(callCount, 0)

		await drainGate.release()
		await connector.closeAndSettle()
		XCTAssertEqual(probe.signalingCancels, 1)
	}

	@MainActor
	func testBlockingDiagnosticSinkCannotDelayTerminalCleanup() async throws {
		let slowSink = BlockingDiagnosticProbe()
		let probe = ConnectorTerminalProbe()
		var connector: WebRTCConnector? = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer,
			diagnosticSink: { slowSink.record($0) }
		)
		weak let releasedConnector = connector
		XCTAssertEqual(slowSink.didEnter.wait(timeout: .now() + 1), .success)
		let closeStarted = expectation(description: "terminal cleanup task started")
		let closeProbe = TestTaskCompletionProbe()
		let closeTask = Task { @MainActor [weak connector] in
			defer { closeProbe.markComplete() }
			closeStarted.fulfill()
			await connector?.closeAndSettle()
		}
		await fulfillment(of: [closeStarted], timeout: 1)
		let closeCompleted = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed

		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
		if closeCompleted {
			connector = nil
			XCTAssertNil(releasedConnector)
		}
		slowSink.release()
		var joined = closeCompleted
		if !joined {
			closeTask.cancel()
			joined = await XCTWaiter.fulfillment(of: [closeProbe.expectation()], timeout: 1) == .completed
		}
		await Self.finalizeOwnedTasks([(joined, "blocking diagnostic terminal cleanup", { await closeTask.value })])
		XCTAssertTrue(closeCompleted)
		await fulfillment(of: [slowSink.expectation(forCount: 1)], timeout: 1)
	}

	@MainActor
	func testBlockedDiagnosticSinkRetainsOnlyTheFixedBoundedBacklog() async throws {
		let slowSink = BlockingDiagnosticProbe()
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			diagnosticSink: { slowSink.record($0) }
		)
		XCTAssertEqual(slowSink.didEnter.wait(timeout: .now() + 1), .success)
		let factory = LKRTCPeerConnectionFactory()
		let callbackConnection = try XCTUnwrap(factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		))

		for _ in 0..<96 {
			connector.peerConnection(callbackConnection, didChange: LKRTCIceConnectionState.checking)
		}
		await connector.closeAndSettle()
		slowSink.release()
		await fulfillment(of: [slowSink.expectation(forCount: 33)], timeout: 1)
		XCTAssertEqual(slowSink.values, [.peerCreated] + Array(repeating: .iceChecking, count: 32))
	}

	@MainActor
	func testQualificationDiagnosticsUseTheSeparateSinkWithoutOccupyingQualificationEvents() async throws {
		let diagnostics = DiagnosticProbe()
		let connector = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			diagnosticSink: { diagnostics.record($0) }
		).makePeer()
		let concreteConnector = try XCTUnwrap(connector as? WebRTCConnector)
		let events = concreteConnector.qualificationEvents
		let reader = Task { @MainActor in
			var iterator = events.makeAsyncIterator()
			return [try await iterator.next(), try await iterator.next()]
		}

		concreteConnector.receiveDataChannelState(isOpen: true, isTerminal: false)
		concreteConnector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		let eventsReceived = try await reader.value
		await concreteConnector.closeAndSettle()
		await fulfillment(of: [diagnostics.expectation(forCount: 8)], timeout: 1)

		XCTAssertEqual(eventsReceived, [.connected, .inbound(.responseFinished)])
		XCTAssertEqual(diagnostics.values, [
			.peerCreated, .dataChannelOpen, .teardownBegan, .dataChannelClosing,
			.dataChannelClosed, .iceClosed, .peerClosed, .teardownCompleted,
		])
	}

	@MainActor
	func testInjectedICETimeoutSettlesTheRealConnectorBeforeAnySignalingRequest() async throws {
		let signaling = CountingSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		let diagnostics = DiagnosticProbe()
		let probe = ConnectorTerminalProbe(recordPermissionGranted: { true }, waitForLocalICEGathering: {
			throw WebRTCTransportFailure.iceGatheringTimedOut
		})
		var connector: WebRTCConnector? = try WebRTCConnector.createQualification(
			session: signaling,
			terminalObserver: probe.observer,
			diagnosticSink: { diagnostics.record($0) }
		)
		weak let releasedConnector = connector

		do {
			try await connector?.connect(using: WebRTCSignalingRequest(
				endpoint: URL(string: "https://local.invalid")!, model: "model", bearerToken: nil
			))
			XCTFail("Expected injected ICE timeout")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .iceGatheringTimedOut)
		}

		let callCount = await signaling.callCount
		XCTAssertEqual(callCount, 0)
		XCTAssertEqual(probe.signalingCancels, 1)
		XCTAssertEqual(probe.dataCloses, 1)
		XCTAssertEqual(probe.peerCloses, 1)
		XCTAssertEqual(probe.audioDisables, 1)
		await fulfillment(of: [diagnostics.expectation(forCount: 10)], timeout: 1)
		XCTAssertTrue(diagnostics.values.contains(.iceGatheringTimedOut))
		connector = nil
		XCTAssertNil(releasedConnector)
	}

	@MainActor
	func testCancelledICEWaitCannotEmitAStaleCompletionMilestone() async throws {
		let diagnostics = DiagnosticProbe()
		var connector: WebRTCConnector?
		let probe = ConnectorTerminalProbe(recordPermissionGranted: { true }, waitForLocalICEGathering: {
			await connector?.closeAndSettle()
		})
		connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer,
			diagnosticSink: { diagnostics.record($0) }
		)

		do {
			_ = try await connector?.makeOffer()
			XCTFail("Expected cancelled ICE wait")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .cancelled)
		}

		await fulfillment(of: [diagnostics.expectation(forCount: 9)], timeout: 1)
		XCTAssertFalse(diagnostics.values.contains(.iceGatheringComplete))
		XCTAssertEqual(diagnostics.values.suffix(2), [.peerClosed, .teardownCompleted])
	}

	@MainActor
	func testNativeDiagnosticCallbacksPreserveFixedOrderBeforeTerminalSettlement() async throws {
		let diagnostics = DiagnosticProbe()
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			diagnosticSink: { diagnostics.record($0) }
		)
		let factory = LKRTCPeerConnectionFactory()
		let callbackConnection = try XCTUnwrap(factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		))
		let callbackChannel = try XCTUnwrap(callbackConnection.dataChannel(
			forLabel: "qualification-callback", configuration: LKRTCDataChannelConfiguration()
		))
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		let remoteAudioTrack = factory.audioTrack(with: audioSource, trackId: "qualification_remote_audio")
		_ = callbackConnection.add(remoteAudioTrack, streamIds: ["qualification_receiver_stream"])
		let receiver = try XCTUnwrap(callbackConnection.transceivers.first?.receiver)

		connector.peerConnection(callbackConnection, didChange: LKRTCIceConnectionState.checking)
		connector.peerConnection(callbackConnection, didChange: LKRTCIceConnectionState.connected)
		connector.peerConnection(callbackConnection, didChange: LKRTCPeerConnectionState.connecting)
		connector.peerConnection(callbackConnection, didChange: LKRTCPeerConnectionState.connected)
		connector.dataChannelDidChangeState(callbackChannel)
		// Unified Plan supplies the receiver's authoritative audio track even
		// when its legacy stream list is empty; this is observation only.
		connector.peerConnection(callbackConnection, didAdd: receiver, streams: [])
		await connector.closeAndSettle()
		await fulfillment(of: [diagnostics.expectation(forCount: 13)], timeout: 1)

		XCTAssertEqual(diagnostics.values, [
			.peerCreated, .iceChecking, .iceConnected, .peerConnecting, .peerConnected,
			.dataChannelConnecting, .remoteAudioTrackObserved, .teardownBegan,
			.dataChannelClosing, .dataChannelClosed, .iceClosed, .peerClosed, .teardownCompleted,
		])
	}

	@MainActor
	func testSelectedTerminalDropsLateNativeProgressionDiagnosticsButKeepsCloseOrder() async throws {
		let drainGate = StickySuspensionGate()
		let drainStarted = expectation(description: "terminal selection waits for accepted ingress")
		let diagnostics = DiagnosticProbe()
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: ConnectorTerminalProbe(beforeDrainInbound: {
				drainStarted.fulfill()
				await drainGate.wait()
			}).observer,
			diagnosticSink: { diagnostics.record($0) }
		)
		let factory = LKRTCPeerConnectionFactory()
		let callbackConnection = try XCTUnwrap(factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		))
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
		let audioTrack = factory.audioTrack(with: audioSource, trackId: "late_remote_audio")
		_ = callbackConnection.add(audioTrack, streamIds: ["late_receiver"])
		let receiver = try XCTUnwrap(callbackConnection.transceivers.first?.receiver)

		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		await fulfillment(of: [drainStarted], timeout: 1)
		connector.disconnect()

		connector.peerConnection(callbackConnection, didChange: LKRTCIceConnectionState.connected)
		connector.peerConnection(callbackConnection, didChange: LKRTCIceConnectionState.completed)
		connector.peerConnection(callbackConnection, didChange: LKRTCPeerConnectionState.connected)
		connector.peerConnection(callbackConnection, didAdd: receiver, streams: [])
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)
		await fulfillment(of: [diagnostics.expectation(forCount: 1)], timeout: 1)
		let lateSuccesses: Set<WebRTCConnectorDiagnosticMilestone> = [.iceConnected, .iceCompleted, .peerConnected, .dataChannelOpen, .remoteAudioTrackObserved]
		XCTAssertTrue(lateSuccesses.isDisjoint(with: Set(diagnostics.values)))

		await drainGate.release()
		await connector.closeAndSettle()
		await fulfillment(of: [diagnostics.expectation(forCount: 7)], timeout: 1)
		XCTAssertEqual(diagnostics.values, [
			.peerCreated, .teardownBegan, .dataChannelClosing, .dataChannelClosed,
			.iceClosed, .peerClosed, .teardownCompleted,
		])
	}

	@MainActor
	func testConnectorLifecycleTerminatesResourcesOnceAndDropsQueuedCallback() async throws {
		let probe = ConnectorTerminalProbe()
		let productionPeer = try WebRTCConnectorQualificationPeerFactory(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
		).makePeer()
		guard let productionConnector = productionPeer as? WebRTCConnector else {
			return XCTFail("Expected the production qualification factory to create WebRTCConnector")
		}
		XCTAssertTrue(productionConnector.qualificationHasLocalAudioTrack)
		XCTAssertFalse(productionConnector.qualificationUsesManualAudioRendering)
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
		await Self.finalizeOwnedTasks([
			(lifecycleCompleted, "connector lifecycle reader", { await Self.assertTrueValue(await lifecycleReader.value) }),
			(disconnectCompleted, "connector lifecycle disconnect", { await productionDisconnect.value })
		])
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
			connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(callbackCompleted, "connector callback", { await callback.value }),
			(signalingCompleted, "connector signaling", {
				do { _ = try await signalingTask.value; XCTFail("Expected the connector-owned signaling task to be cancelled") }
				catch { XCTAssertTrue(error is CancellationError) }
			})
		])
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
		await Self.finalizeOwnedTasks([(terminalCompleted, "connector terminal reader", { await Self.assertTrueValue(await terminalReader.value) })])
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
			await Self.finalizeOwnedTasks([
				(readerCompleted, "decoded failure reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(expected)) }),
				(closeCompleted, "decoded failure close", { await closeTask.value })
			])
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "bounded mailbox reader", { await Self.assertTrueValue(await reader.value) }),
			(closeCompleted, "bounded mailbox close", { await closeTask.value })
		])
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
				guard case .sessionCreated = try await iterator.next() else {
					return .unexpected
				}
				_ = try await iterator.next()
				return TerminalObservation.unexpected
			} catch let failure as WebRTCTransportFailure {
				return .expectedFailure(failure)
			} catch {
				return .unexpected
			}
		}

		for _ in 0...WebRTCConnector.inboundMailboxCapacity {
			connector.receiveInbound(Data(#"{"type":"session.created"}"#.utf8))
		}

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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "overflow reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.ingressOverloaded)) }),
			(closeCompleted, "overflow close", { await closeTask.value })
		])
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor
	func testLocalAIResponseSizedIngressBurstDrainsWithoutClosing() async throws {
		let burstCount = 17
		let retired = expectation(description: "LocalAI-sized ingress burst retired")
		retired.expectedFulfillmentCount = burstCount
		let probe = ConnectorTerminalProbe(retirementExpectation: retired)
		let connector = try WebRTCConnector.createQualification(
			session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")),
			terminalObserver: probe.observer
		)
		connector.receiveDataChannelState(isOpen: true, isTerminal: false)

		for _ in 0..<burstCount {
			connector.receiveInbound(Data(#"{"type":"session.created"}"#.utf8))
		}

		let drained = await XCTWaiter.fulfillment(of: [retired], timeout: 1) == .completed
		XCTAssertTrue(drained)
		XCTAssertEqual(connector.status, .connected)
		await connector.closeAndSettle()
		XCTAssertEqual(connector.status, .disconnected)
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		let firstDrained = await XCTWaiter.fulfillment(of: [firstInboundDrained], timeout: 1) == .completed
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "capacity overflow reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.ingressOverloaded)) }),
			(closeCompleted, "capacity overflow close", { await closeTask.value })
		])
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "oversized ingress reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.eventTooLarge)) }),
			(closeCompleted, "oversized ingress close", { await closeTask.value })
		])
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "ordinary event reader", { await Self.assertTrueValue(await reader.value) }),
			(closeCompleted, "ordinary event close", { await closeTask.value })
		])
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
		await Self.finalizeOwnedTasks([
			(observerCompleted, "retention observer", { await Self.assertTrueValue(await observer.value) }),
			(closeCompleted, "retention close", { await closeTask.value })
		])
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "absent consumer reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.ingressOverloaded)) }),
			(closeCompleted, "absent consumer close", { await closeTask.value })
		])
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
				connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
			await Self.finalizeOwnedTasks([
				(closeCompleted, "custody close", { await closeTask.value }),
				(observerCompleted, "custody observer", { await Self.assertTrueValue(await observer.value) })
			])
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "accepted-ingress reader", { await Self.assertTrueValue(await reader.value) }),
			(closeCompleted, "accepted-ingress close", { await closeTask.value }),
			(settledCompleted, "accepted-ingress settlement", {})
		])
	}

	@MainActor
	func testFirstAcceptedIngressFailureSuppressesLaterAcceptedDeliveryAndFailure() async throws {
		let laterPayloads = [
			Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8),
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
			XCTAssertEqual(entered, .completed)
			XCTAssertEqual(retired, .completed)
			await Self.finalizeOwnedTasks([
				(readerCompleted, "first accepted failure reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.providerError)) }),
				(closeCompleted, "first accepted failure close", { await closeTask.value })
			])
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "scheduled-open delivery reader", { await Self.assertTrueValue(await reader.value) }),
			(closeCompleted, "scheduled-open delivery close", { await close.value })
		])
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
		XCTAssertEqual(open, .completed)
		XCTAssertEqual(retired, .completed)
		await Self.finalizeOwnedTasks([
			(readerCompleted, "earlier accepted failure reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.providerError)) }),
			(closeCompleted, "earlier accepted failure close", { await closeTask.value })
		])
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

		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		let firstDrained = await XCTWaiter.fulfillment(of: [firstDrainCompleted], timeout: 1)
		connector.scheduleOpenTransitionForQualification()
		let entered = await XCTWaiter.fulfillment(of: [openEntered], timeout: 1)
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "accepted-open delivery reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.ingressOverloaded)) }),
			(closeCompleted, "accepted-open delivery close", { await closeTask.value })
		])
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
		await Self.finalizeOwnedTasks([(disconnectCompleted, "retained connector disconnect", { await disconnectTask.value })])
		connector = nil

		let settledCompleted = await XCTWaiter.fulfillment(of: [settled], timeout: 1) == .completed
		await readerStartGate.release()
		var readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		if !readerCompleted {
			reader.cancel()
			await readerStartGate.release()
			readerCompleted = await XCTWaiter.fulfillment(of: [readerProbe.expectation()], timeout: 1) == .completed
		}
		await Self.finalizeOwnedTasks([(readerCompleted, "retained connector reader", { await Self.assertTrueValue(await reader.value) })])
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "first failure reader", { await Self.assertEqualValue(await reader.value, .expectedFailure(.eventTooLarge)) }),
			(closeCompleted, "first failure close", { await closeTask.value }),
			(disconnectCompleted, "first failure disconnect", { await disconnectTask.value })
		])
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
		do {
			_ = try await peer.remoteAudioEvidence()
			XCTFail("Expected the compatibility default to reject audio evidence")
		} catch {
			XCTAssertEqual(error as? WebRTCTransportFailure, .invalidRequest)
		}
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
		await Self.finalizeOwnedTasks([(settled, "withhold observation", { await observer.value })])
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertEqual(secondBound, .timedOut)
		XCTAssertTrue(settled)
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "terminal lifecycle reader", { _ = await reader.value }),
			(closeCompleted, "terminal lifecycle close", { await closeTask.value })
		])
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
		var joinedFailure: TerminalObservation?
		await Self.finalizeOwnedTasks([
			(retiredCompleted, "decoded failure retirement", {}),
			(terminalSettled, "decoded failure settlement", {}),
			(readerCompleted, "decoded failure reader", { joinedFailure = await reader.value }),
			(closeCompleted, "decoded failure close", { await closeTask.value })
		])
		let failure = try XCTUnwrap(joinedFailure)
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "ordinary delivery reader", { _ = await reader.value }),
			(closeCompleted, "ordinary delivery close", { await closeTask.value })
		])
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertTrue(readerCompleted)
		XCTAssertTrue(closeCompleted)
	}

	@MainActor func testQueuedContentTimeoutSettlesRealDrainAndConnector() async throws {
		let gate = StickySuspensionGate()
		let entered = expectation(description: "queued drain entered")
		let terminalProbe = ConnectorTerminalProbe(beforeDrainInbound: { entered.fulfill(); await gate.wait() })
		let connector = try WebRTCConnector.createQualification(session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json")), terminalObserver: terminalProbe.observer)
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		await Self.finalizeOwnedTasks([(closeCompleted, "queued content close", { await closeTask.value })])
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
			if occupancy == 2 { connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8)) }
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
			await Self.finalizeOwnedTasks([
				(readerCompleted, "custody loop reader", { await reader.value }),
				(closeCompleted, "custody loop close", { await closeTask.value })
			])
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		var joinedResult: Bool?
		await Self.finalizeOwnedTasks([
			(readerCompleted, "accepted-ingress reader", { joinedResult = await reader.value }),
			(closeCompleted, "accepted-ingress close", { await closeTask.value })
		])
		let result = try XCTUnwrap(joinedResult)
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
		var joinedResult: TerminalObservation?
		await Self.finalizeOwnedTasks([
			(retiredCompleted, "first-failure retirement", {}),
			(readerCompleted, "first-failure reader", { joinedResult = await reader.value }),
			(closeCompleted, "first-failure close", { await closeTask.value })
		])
		let result = try XCTUnwrap(joinedResult)
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
		await Self.finalizeOwnedTasks([
			(readerCompleted, "scheduled-open reader", { _ = await reader.value }),
			(closeCompleted, "scheduled-open close", { await closeTask.value })
		])
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
		var joinedResult: TerminalObservation?
		await Self.finalizeOwnedTasks([
			(readerCompleted, "pending-open reader", { joinedResult = await reader.value }),
			(closeCompleted, "pending-open close", { await closeTask.value })
		])
		let result = try XCTUnwrap(joinedResult)
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
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
		connector.scheduleOpenTransitionForQualification()
		let acceptedOpenEntered = await XCTWaiter.fulfillment(of: [openEntered], timeout: 1) == .completed
		let firstRetiredBeforeSecondInbound = await XCTWaiter.fulfillment(of: [firstRawMailboxRetired], timeout: 1) == .completed
		connector.receiveInbound(Data(#"{"type":"response.done","response":{"output":[]}}"#.utf8))
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
		var joinedResult: TerminalObservation?
		await Self.finalizeOwnedTasks([
			(readerCompleted, "accepted-open reader", { joinedResult = await reader.value }),
			(closeCompleted, "accepted-open close", { await closeTask.value })
		])
		let result = try XCTUnwrap(joinedResult)
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
		XCTAssertEqual(beforeCleanup, .timedOut)
		await Self.finalizeOwnedTasks([(closeCompleted, "retention close", { await closeTask.value })])
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
		await Self.finalizeOwnedTasks([
			(observerCompleted, "observation helper reader", { _ = await observer.value }),
			(closeCompleted, "observation helper close", { await closeTask.value })
		])
		XCTAssertEqual(firstBound, .timedOut)
		XCTAssertEqual(secondBound, .timedOut)
	}

	private enum TerminalObservation: Equatable, Sendable {
		case expectedFailure(WebRTCTransportFailure)
		case unexpected
	}

	@MainActor private static func finalizeOwnedTasks(
		_ inventory: [(completed: Bool, label: String, join: @MainActor () async -> Void)]
	) async {
		var incomplete: [String] = []
		for task in inventory {
			if task.completed {
				await task.join()
			} else {
				incomplete.append(task.label)
			}
		}
		guard incomplete.isEmpty else {
			XCTFail("Content-free owned tasks did not settle: \(incomplete.joined(separator: ", "))")
			fatalError("Content-free owned tasks did not settle")
		}
	}

	@MainActor private static func assertTrueValue(_ value: Bool) async {
		XCTAssertTrue(value)
	}

	@MainActor private static func assertEqualValue<Value: Equatable>(_ actual: Value, _ expected: Value) async {
		XCTAssertEqual(actual, expected)
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
	private let recordPermissionGranted: () -> Bool
	private let waitForLocalICEGathering: (@MainActor () async throws -> Void)?
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
		recordPermissionGranted: @escaping () -> Bool = { false },
		waitForLocalICEGathering: (@MainActor () async throws -> Void)? = nil,
		drainExpectation: XCTestExpectation? = nil,
		retirementExpectation: XCTestExpectation? = nil,
		settledExpectation: XCTestExpectation? = nil
	) {
		self.beforeDrainInbound = beforeDrainInbound
		self.beforeOpenTransition = beforeOpenTransition
		self.makePreReadyRetentionToken = makePreReadyRetentionToken
		self.recordPermissionGranted = recordPermissionGranted
		self.waitForLocalICEGathering = waitForLocalICEGathering
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
			recordPermissionGranted: recordPermissionGranted,
			waitForLocalICEGathering: waitForLocalICEGathering,
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

private final class DiagnosticProbe: @unchecked Sendable {
	private let lock = NSLock()
	private var recorded: [WebRTCConnectorDiagnosticMilestone] = []
	private var countWaiters: [(count: Int, expectation: XCTestExpectation)] = []

	func record(_ milestone: WebRTCConnectorDiagnosticMilestone) {
		let ready = lock.withLock { () -> [XCTestExpectation] in
			recorded.append(milestone)
			let ready = countWaiters.filter { $0.count <= recorded.count }.map(\.expectation)
			countWaiters.removeAll { $0.count <= recorded.count }
			return ready
		}
		ready.forEach { $0.fulfill() }
	}

	var values: [WebRTCConnectorDiagnosticMilestone] {
		lock.withLock { recorded }
	}

	func expectation(forCount count: Int) -> XCTestExpectation {
		let expectation = XCTestExpectation(description: "content-free diagnostic count \(count)")
		let immediatelyReady = lock.withLock { () -> Bool in
			guard recorded.count < count else { return true }
			countWaiters.append((count, expectation))
			return false
		}
		if immediatelyReady { expectation.fulfill() }
		return expectation
	}
}

private final class BlockingDiagnosticProbe: @unchecked Sendable {
	let didEnter = DispatchSemaphore(value: 0)
	private let releaseGate = DispatchSemaphore(value: 0)
	private let lock = NSLock()
	private var isFirst = true
	private var recorded: [WebRTCConnectorDiagnosticMilestone] = []
	private var countWaiters: [(count: Int, expectation: XCTestExpectation)] = []

	func record(_ milestone: WebRTCConnectorDiagnosticMilestone) {
		let waits = lock.withLock { () -> Bool in
			guard isFirst else { return false }
			isFirst = false
			return true
		}
		if waits {
			didEnter.signal()
			releaseGate.wait()
		}
		let ready = lock.withLock { () -> [XCTestExpectation] in
			recorded.append(milestone)
			let ready = countWaiters.filter { $0.count <= recorded.count }.map(\.expectation)
			countWaiters.removeAll { $0.count <= recorded.count }
			return ready
		}
		ready.forEach { $0.fulfill() }
	}

	func release() {
		releaseGate.signal()
	}

	var values: [WebRTCConnectorDiagnosticMilestone] {
		lock.withLock { recorded }
	}

	func expectation(forCount count: Int) -> XCTestExpectation {
		let expectation = XCTestExpectation(description: "blocked content-free diagnostic count \(count)")
		let immediatelyReady = lock.withLock { () -> Bool in
			guard recorded.count < count else { return true }
			countWaiters.append((count, expectation))
			return false
		}
		if immediatelyReady { expectation.fulfill() }
		return expectation
	}
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
