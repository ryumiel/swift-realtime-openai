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
        XCTAssertTrue(
            try decoder.decode(Data(#"{"type":"response.output_audio_transcript.done","transcript":"spoken"}"#.utf8))
                == .assistantTranscript("spoken")
        )
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
		var productionLifecycle = productionPeer.qualificationEvents.makeAsyncIterator()
		productionPeer.disconnect()
		let terminal = try await productionLifecycle.next()
		let end = try await productionLifecycle.next()
		XCTAssertEqual(terminal, .terminal)
		XCTAssertNil(end)
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
	func testProductionIngressPreservesDecodedFailureCategory() async throws {
		let cases: [(Data, WebRTCTransportFailure)] = [
			(Data(#"{"type":"error"}"#.utf8), .providerError),
			(Data(#"{"type":"response.function_call_arguments.done"}"#.utf8), .unsupportedEvent),
			(Data(repeating: 0, count: WebRTCTransportLimits.maximumPayloadBytes + 1), .eventTooLarge),
			(Data(#"{"type":"response.done""#.utf8), .malformedEvent),
		]
		for (payload, expected) in cases {
			let connector = try WebRTCConnector.create(
				session: StubSession(response: .init(data: Data(), statusCode: 201, contentType: "application/json"))
			)
			let productionEvents = connector.events
			let qualificationEvents = connector.qualificationEvents
			connector.receiveInbound(payload)
			let productionResult = await Self.terminalObservation(from: productionEvents, within: .milliseconds(100))
			let qualificationResult = await Self.terminalObservation(from: qualificationEvents, within: .milliseconds(100))
			XCTAssertEqual(productionResult, .expectedFailure(expected))
			XCTAssertEqual(qualificationResult, .expectedFailure(expected))
		}
	}

	func testTerminalObservationTimesOutAndCancelsPendingRead() async {
		let probe = TerminalReadProbe()
		let stream = AsyncThrowingStream<Int, Error> { continuation in
			continuation.onTermination = { _ in probe.recordCancellation() }
		}

		let result = await Self.terminalObservation(from: stream, within: .milliseconds(25))

		XCTAssertEqual(result, .timeout)
		XCTAssertTrue(probe.wasCancelled)
	}

	private enum TerminalObservation: Equatable, Sendable {
		case expectedFailure(WebRTCTransportFailure)
		case unexpected
		case timeout
	}

	private static func terminalObservation<Element: Sendable>(
		from stream: AsyncThrowingStream<Element, Error>, within bound: Duration
	) async -> TerminalObservation {
		await withTaskGroup(of: TerminalObservation.self) { group in
			group.addTask {
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
			group.addTask {
				try? await Task.sleep(for: bound)
				return .timeout
			}
			guard let first = await group.next() else { return .unexpected }
			group.cancelAll()
			return first
		}
	}

	private final class TerminalReadProbe: @unchecked Sendable {
		private let lock = NSLock()
		private var didCancel = false

		func recordCancellation() { lock.withLock { didCancel = true } }
		var wasCancelled: Bool { lock.withLock { didCancel } }
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

@MainActor private final class ConnectorTerminalProbe {
	private(set) var signalingCancels = 0
	private(set) var dataCloses = 0
	private(set) var peerCloses = 0
	private(set) var audioDisables = 0

	var observer: WebRTCConnector.TerminalObserver {
		.init(
			cancelSignaling: { self.signalingCancels += 1 },
			closeData: { self.dataCloses += 1 },
			closePeer: { self.peerCloses += 1 },
			disableAudio: { self.audioDisables += 1 }
		)
	}
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
