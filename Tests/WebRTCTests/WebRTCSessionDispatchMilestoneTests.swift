import Foundation
@_spi(AirbridgeQualification) @testable import WebRTC
import XCTest

final class WebRTCSessionDispatchMilestoneTests: XCTestCase {
	@MainActor func testOpenAICreationIsOfferedOnlyAfterSuccessfulConfigurationSend() async throws {
		let backing = DispatchBacking()
		let peer = try WebRTCConnectorPeerFactory(
			provider: .openAI, initialAudioState: .disabled, makePeer: { backing }
		).makePeer()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "synthetic-answer")
		backing.emit(.ready)
		try peer.configure(.openAI(language: "en"))
		let stream = peer.events
		let drained = DispatchSemaphore(value: 0)
		var reader: Task<Bool, any Error>?
		// Readiness occupies one slot. Inside send, the other must still be
		// available because creation has not been offered. The detached reader
		// owns its iterator throughout and drains both controls before send returns.
		backing.duringSend = {
			XCTAssertTrue(stream.storage.offer(.ready), "Creation must not occupy a slot before send returns")
			reader = Task.detached {
				var iterator = stream.makeAsyncIterator()
				var onlyControls = true
				do {
					for _ in 0..<2 {
						let event = try await iterator.next()
						onlyControls = onlyControls && event == .ready
					}
				} catch { drained.signal(); throw error }
				drained.signal()
				// A premature creation is a bounded failure, not a third next()
				// that could remain suspended forever on the old implementation.
				guard onlyControls else { return false }
				let event = try await iterator.next()
				return event == .openAISessionCreated
			}
			XCTAssertTrue(drained.wait(timeout: .now() + 2) == .success)
		}
		backing.emitCreation()
		let creationFollowedSend = try await XCTUnwrap(reader).value
		XCTAssertTrue(creationFollowedSend)
		XCTAssertTrue(backing.sendReturned)
		XCTAssertTrue(backing.sendCount == 1)
		await peer.closeAndJoin()
	}

	@MainActor func testFailedOpenAISendNeverOffersCreationAndSettlesContentFree() async throws {
		let (peer, backing) = try await makePendingPeer()
		var iterator = peer.events.makeAsyncIterator()
		let ready = try await iterator.next()
		XCTAssertTrue(ready == .ready)
		let storage = peer.events.storage
		backing.duringSend = {
			// Both slots remain free throughout the failed dispatch; terminal
			// selection purges these content-free control markers afterwards.
			XCTAssertTrue(storage.offer(.ready))
			XCTAssertTrue(storage.offer(.ready), "No creation-success event may precede a failed send")
			throw DispatchBacking.SyntheticFailure()
		}
		backing.emitCreation()
		do {
			_ = try await iterator.next()
			XCTFail("Expected only a content-free terminal failure")
		} catch {
			let matches = (error as? WebRTCTransportFailure) == .requestFailed
			XCTAssertTrue(matches, "Terminal failure must retain its closed category")
		}
		let end = try await iterator.next()
		XCTAssertTrue(end == nil)
		XCTAssertFalse(backing.sendReturned)
		XCTAssertTrue(backing.closeCount == 1)
		await peer.closeAndJoin()
	}

	@MainActor func testReentrantTerminalDuringSendSuppressesCreationAndPreservesTerminal() async throws {
		for failSend in [false, true] {
			for terminalFailure: WebRTCTransportFailure? in [nil, .providerError] {
				let (peer, backing) = try await makePendingPeer()
				var iterator = peer.events.makeAsyncIterator()
				let ready = try await iterator.next()
				XCTAssertTrue(ready == .ready)
				backing.duringSend = {
					backing.emitTerminal(terminalFailure)
					if failSend { throw DispatchBacking.SyntheticFailure() }
				}
				backing.emitCreation()
				if let terminalFailure {
					do {
						_ = try await iterator.next()
						XCTFail("Expected only a content-free terminal failure")
					} catch {
						let matches = (error as? WebRTCTransportFailure) == terminalFailure
						XCTAssertTrue(matches, "Terminal failure must retain its closed category")
					}
				}
				else {
					let terminal = try await iterator.next()
					XCTAssertTrue(terminal == .closed)
				}
				let end = try await iterator.next()
				XCTAssertTrue(end == nil)
				XCTAssertTrue(backing.closeCount == 1)
				await peer.closeAndJoin()
			}
		}
	}

	@MainActor func testTerminalSelectedDuringSendWinsOverLaterIteratorCancellation() async throws {
		for terminalFailure: WebRTCTransportFailure? in [nil, .providerError] {
			let (peer, backing) = try await makePendingPeer()
			var iterator = peer.events.makeAsyncIterator()
			let ready = try await iterator.next()
			XCTAssertTrue(ready == .ready)
			let storage = peer.events.storage
			backing.duringSend = {
				backing.emitTerminal(terminalFailure)
				storage.cancelIterator()
			}
			backing.emitCreation()
			if let terminalFailure {
				do {
					_ = try await iterator.next()
					XCTFail("Expected only a content-free terminal failure")
				} catch {
					let matches = (error as? WebRTCTransportFailure) == terminalFailure
					XCTAssertTrue(matches, "Terminal failure must retain its closed category")
				}
			}
			else {
				let terminal = try await iterator.next()
				XCTAssertTrue(terminal == .closed)
			}
			await peer.closeAndJoin()
			XCTAssertTrue(backing.closeCount == 1)
		}
	}

	@MainActor func testTerminalBoundaryRejectsConcurrentCancellationAfterSnapshotAndAfterSelection() async throws {
		for pauseAfterSelection in [false, true] {
			for terminalFailure: WebRTCTransportFailure? in [nil, .providerError] {
				let (peer, backing) = try await makePendingPeer()
				var iterator = peer.events.makeAsyncIterator()
				let ready = try await iterator.next()
				XCTAssertTrue(ready == .ready)
				let storage = peer.events.storage
				let attempted = DispatchSemaphore(value: 0)
				let returned = DispatchSemaphore(value: 0)
				let contender: @Sendable () -> Void = {
					DispatchQueue.global().async {
						attempted.signal()
						storage.cancelIterator()
						returned.signal()
					}
					XCTAssertTrue(attempted.wait(timeout: .now() + 2) == .success)
					// Both former gaps must retain the same storage lock. A
					// cancellation contender cannot return until admission closes.
					XCTAssertTrue(returned.wait(timeout: .now() + 0.05) == .timedOut)
				}
				storage.installTerminalSelectionHooks(
					afterCancellationSnapshot: pauseAfterSelection ? nil : contender,
					afterFailureSelection: pauseAfterSelection ? contender : nil
				)
				backing.duringSend = { backing.emitTerminal(terminalFailure) }
				backing.emitCreation()
				XCTAssertTrue(returned.wait(timeout: .now() + 2) == .success)
				XCTAssertFalse(storage.iteratorCancellationSelected)
				if let terminalFailure {
					do {
						_ = try await iterator.next()
						XCTFail("Expected the terminal that won the atomic boundary")
					} catch {
						let matches = (error as? WebRTCTransportFailure) == terminalFailure
						XCTAssertTrue(matches, "Late cancellation must retain the selected failure category")
					}
				} else {
					let terminal = try await iterator.next()
					XCTAssertTrue(terminal == .closed)
				}
				let end = try await iterator.next()
				XCTAssertTrue(end == nil)
				await peer.closeAndJoin()
				XCTAssertTrue(backing.closeCount == 1)
			}
		}
	}

	@MainActor func testCancellationWinningAtomicBoundarySelectsSameFailureBeforeHandlerPublication() async throws {
		for competingFailure: WebRTCTransportFailure? in [nil, .providerError] {
			let storage = WebRTCConnectorEventStream.Storage()
			let selection = ProductionTerminalSelection()
			let stream = WebRTCConnectorEventStream(storage: storage)
			let selected = DispatchSemaphore(value: 0)
			let release = DispatchSemaphore(value: 0)
			storage.installCancellationSelectionHook {
				selected.signal()
				release.wait()
			}
			let cancellation = Task.detached { storage.cancelIterator() }
			XCTAssertTrue(selected.wait(timeout: .now() + 2) == .success)
			// Cancellation owns storage before the terminal contender enters.
			// The result must agree even before cancellation publishes its handler.
			let failure = storage.beginTerminalSelection(using: selection, failure: competingFailure)
			XCTAssertTrue(failure == .cancelled)
			XCTAssertTrue(selection.cancellationWins())
			XCTAssertTrue(storage.iteratorCancellationSelected)
			XCTAssertFalse(storage.offer(.openAISessionCreated))
			release.signal()
			await cancellation.value
			storage.finish(failure: failure)
			var iterator = stream.makeAsyncIterator()
			do {
				_ = try await iterator.next()
				XCTFail("Cancellation must own both the mailbox and terminal result")
			} catch {
				let matches = (error as? WebRTCTransportFailure) == .cancelled
				XCTAssertTrue(matches)
			}
		}
	}

	@MainActor func testCancellationSelectedDuringSendBeforeHandlerPublicationSuppressesCreation() async throws {
		for failSend in [false, true] {
			for reentrantTerminal in [false, true] {
				let (peer, backing) = try await makePendingPeer()
				var iterator = peer.events.makeAsyncIterator()
				let ready = try await iterator.next()
				XCTAssertTrue(ready == .ready)
				let storage = peer.events.storage
				let selected = DispatchSemaphore(value: 0)
				let release = DispatchSemaphore(value: 0)
				storage.installCancellationSelectionHook {
					selected.signal()
					release.wait()
				}
				var cancellation: Task<Void, Never>?
				backing.duringSend = {
					cancellation = Task.detached { storage.cancelIterator() }
					XCTAssertTrue(selected.wait(timeout: .now() + 2) == .success)
					XCTAssertFalse(storage.offer(.ready), "Cancellation closes semantic admission before its actor hop")
					if reentrantTerminal { backing.emitTerminal(.providerError) }
					if failSend { throw DispatchBacking.SyntheticFailure() }
				}
				backing.emitCreation()
				release.signal()
				await cancellation?.value
				do {
					_ = try await iterator.next()
					XCTFail("Expected only a content-free terminal failure")
				} catch {
					let matches = (error as? WebRTCTransportFailure) == .cancelled
					XCTAssertTrue(matches, "Terminal failure must retain its closed category")
				}
				await peer.closeAndJoin()
				XCTAssertTrue(backing.closeCount == 1)
			}
		}
	}

	@MainActor func testCancellationSelectedBeforeCreationPreventsConfigurationSend() async throws {
		let (peer, backing) = try await makePendingPeer()
		var iterator = peer.events.makeAsyncIterator()
		let ready = try await iterator.next()
		XCTAssertTrue(ready == .ready)
		peer.events.storage.cancelIterator()
		backing.emitCreation()
		do {
			_ = try await iterator.next()
			XCTFail("Expected only a content-free terminal failure")
		} catch {
			let matches = (error as? WebRTCTransportFailure) == .cancelled
			XCTAssertTrue(matches, "Terminal failure must retain its closed category")
		}
		XCTAssertTrue(backing.sendCount == 0)
		await peer.closeAndJoin()
	}

	@MainActor func testLocalAIStillDispatchesDuringConfigureAndPublishesOnlyAcknowledgementAndConnected() async throws {
		let (peer, backing) = try await makePendingPeer(provider: .localAI)
		var iterator = peer.events.makeAsyncIterator()
		let ready = try await iterator.next()
		XCTAssertTrue(ready == .ready)
		XCTAssertTrue(backing.sendCount == 1)
		XCTAssertTrue(backing.sendReturned)
		backing.emit(.inbound(.sessionUpdated(voice: "synthetic-voice", language: "en")))
		let configured = try await iterator.next()
		let configurationMatches: Bool
		if case let .localAISessionConfigured(voice, language) = configured {
			configurationMatches = voice == "synthetic-voice" && language == "en"
		} else { configurationMatches = false }
		XCTAssertTrue(configurationMatches)
		let connected = try await iterator.next()
		XCTAssertTrue(connected == .connected)
		await peer.closeAndJoin()
	}

	@MainActor func testRawAndSemanticMailboxCapacitiesRemainThirtyTwoAndTwo() {
		XCTAssertTrue(WebRTCConnector.inboundMailboxCapacity == 32)
		let storage = WebRTCConnectorEventStream.Storage()
		XCTAssertTrue(storage.offer(.ready))
		XCTAssertTrue(storage.offer(.ready))
		XCTAssertFalse(storage.offer(.ready))
	}

	@MainActor private func makePendingPeer(provider: WebRTCSessionProvider = .openAI) async throws -> (
		any WebRTCConnectorPeer, DispatchBacking
	) {
		let backing = DispatchBacking()
		let peer = try WebRTCConnectorPeerFactory(
			provider: provider,
			initialAudioState: provider == .openAI ? .disabled : .enabled,
			makePeer: { backing }
		).makePeer()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "synthetic-answer")
		backing.emit(.ready)
		try peer.configure(provider == .openAI
			? .openAI(language: "en")
			: .localAI(voice: "synthetic-voice", language: "en"))
		return (peer, backing)
	}

}

@MainActor private final class DispatchBacking: WebRTCConnectorPeerBacking {
	struct SyntheticFailure: Error {}
	private var sink: (@MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)?
	var duringSend: (() throws -> Void)?
	private(set) var sendCount = 0
	private(set) var sendReturned = false
	private(set) var closeCount = 0

	func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void) { self.sink = sink }
	func makeOffer() async throws -> String { "synthetic-offer" }
	func apply(answer: String) async throws {}
	func sendSessionConfiguration(_ data: Data) throws {
		sendCount += 1
		let send = duringSend
		duringSend = nil
		try send?()
		sendReturned = true
	}
	func sendProductionCommand(_ command: ProductionCommand) throws {}
	func setLocalAudioState(_ state: WebRTCLocalAudioState) {}
	func disableAudioForMediaQuiescence() -> UInt64? { nil }
	func waitForMediaQuiescence(through cutoff: UInt64?) async {}
	func closeAndSettle() async { closeCount += 1 }
	func emit(_ event: WebRTCConnectorPeerBackingEvent) { sink?(.success(event)) }
	func emitCreation() {
		emit(.rawInbound(Data(#"{"type":"session.created"}"#.utf8), configurationDispatchedAtAcceptance: false))
	}
	func emitTerminal(_ failure: WebRTCTransportFailure?) { emit(.terminal(failure)) }
}
