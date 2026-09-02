import Foundation
import Testing
@testable import WebRTC

@Suite("OpenAI production state machine")
@MainActor
struct WebRTCOpenAIStateMachineTests {
	@Test("RT-134 encoding fixes every value except language")
	func exactSessionEncoding() throws {
		let english = try WebRTCSessionConfiguration.openAI(language: "en")
		let korean = try WebRTCSessionConfiguration.openAI(language: "ko")
		let encodingMatchesContract = try english.encoded() == Data(#"{"type":"session.update","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"en"},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#.utf8)
		#expect(encodingMatchesContract, "Session configuration must use the fixed production schema")
		let koreanData = try korean.encoded()
		let englishData = try english.encoded()
		let languageChangesEncoding = koreanData != englishData
		#expect(languageChangesEncoding, "The selected language must affect the encoded configuration")
		assertFailure(.invalidRequest) {
			_ = try WebRTCSessionConfiguration.openAI(language: "fr")
		}
	}

	@Test("creation sends one update and exact acknowledgement gates audio")
	func strictHandshakeAndAudioGate() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		let ready = try await events.next()
		assertEventKind(.ready, ready)
		try peer.configure(.openAI(language: "en"))
		let payloadCountBeforeCreation = backing.configurationPayloads.count
		#expect(payloadCountBeforeCreation == 0)
		backing.emitRaw(#"{"type":"session.created","session":{"id":"synthetic"}}"#)
		let created = try await events.next()
		assertEventKind(.sessionCreated, created)
		let payloadCountAfterCreation = backing.configurationPayloads.count
		#expect(payloadCountAfterCreation == 1)
		backing.emitRaw(Self.acknowledgement(language: "en"))
		let configured = try await events.next()
		assertEventKind(.sessionConfigured, configured)
		#expect(backing.audioStates == [.disabled])
		peer.setLocalAudioState(.enabled)
		#expect(backing.audioStates == [.disabled, .enabled])
		await peer.closeAndJoin()
	}

	@Test("creation and acknowledgement fit the fixed two-slot production stream")
	func handshakeBurstFitsBoundedStream() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		_ = try await events.next()
		try peer.configure(.openAI(language: "en"))
		backing.emitRaw(#"{"type":"session.created"}"#)
		backing.emitRaw(Self.acknowledgement(language: "en"))
		let created = try await events.next()
		assertEventKind(.sessionCreated, created)
		let configured = try await events.next()
		assertEventKind(.sessionConfigured, configured)
		try peer.createResponse()
		let sentCreateOnly = backing.commandTypes == ["response.create"]
		#expect(sentCreateOnly, "The handshake must send exactly one create command")
		await peer.closeAndJoin()
	}

	@Test("session update send failure stays content free")
	func configurationSendFailureIsContentFree() async throws {
		let backing = OpenAIBacking(configurationSendFails: true)
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		_ = try await events.next()
		try peer.configure(.openAI(language: "en"))
		backing.emitRaw(#"{"type":"session.created"}"#)
		do {
			_ = try await events.next()
			Issue.record("send failure must purge pending semantic output and terminate")
		} catch {
			#expect(error as? WebRTCTransportFailure == .requestFailed)
		}
	}

	@Test("exact numeric tokens enforce acknowledgement and rate-limit bounds")
	func exactNumericValidation() throws {
		for threshold in ["0.5", "0.50", "5e-1", "50e-2", "500E-3"] {
			var machine = try OpenAIProductionStateMachine(language: "en")
			_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
			let event = try machine.consume(Data(Self.acknowledgement(language: "en", threshold: threshold).utf8))
			assertEventKind(.sessionAcknowledged, event)
		}
		for threshold in [
			"0.5000000000000000000000000000000000000001",
			"0.4999999999999999999999999999999999999999"
		] {
			var machine = try OpenAIProductionStateMachine(language: "en")
			_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
			assertFailure(.providerError) {
				_ = try machine.consume(Data(Self.acknowledgement(language: "en", threshold: threshold).utf8))
			}
		}

		let malformedRows = [
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":9223372036854775808,"remaining":0,"reset_seconds":0}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1.0,"remaining":0,"reset_seconds":0}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-1e-9999}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":1e9999}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-1e9999}]}"#
		]
		for json in malformedRows {
			var machine = try activeMachine()
			assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		var exactZero = try activeMachine()
		let exactZeroEvent = try exactZero.consume(Data(#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-0.0}]}"#.utf8))
		assertNoEvent(exactZeroEvent)
		for zero in ["-0e1", "-0.0e-1"] {
			var exponentZero = try activeMachine()
			let json = #"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":\#(zero)}]}"#
			let exponentZeroEvent = try exponentZero.consume(Data(json.utf8))
			assertNoEvent(exponentZeroEvent)
		}
		var finite = try activeMachine()
		let finiteEvent = try finite.consume(Data(#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":1.7976931348623157e308}]}"#.utf8))
		assertNoEvent(finiteEvent)
	}

	@Test("nullable response status containers preserve an absent error-code path")
	func nullableResponseStatusContainers() throws {
		for statusDetails in [#""status_details":null"#, #""status_details":{"error":null}"#] {
			for status in ["completed", "cancelled"] {
				var machine = try activeResponseMachine()
				let json = #"{"type":"response.done","response":{"id":"r1","status":"\#(status)",\#(statusDetails)}}"#
				let event = try machine.consume(Data(json.utf8))
				assertEventKind(.responseFinished, event)
			}
			for status in ["failed", "incomplete"] {
				var machine = try activeResponseMachine()
				let json = #"{"type":"response.done","response":{"id":"r1","status":"\#(status)",\#(statusDetails)}}"#
				assertFailure(.providerError) {
					_ = try machine.consume(Data(json.utf8))
				}
			}
		}
		var codePresent = try activeResponseMachine()
		assertFailure(.malformedEvent) {
			_ = try codePresent.consume(Data(#"{"type":"response.done","response":{"id":"r1","status":"completed","status_details":{"error":{"code":"synthetic"}}}}"#.utf8))
		}
	}

	@Test("RT-OE-022 covers one malformed case per required schema dimension")
	func schemaDimensionMatrix() throws {
		let overlongIdentifier = String(repeating: "x", count: 129)
		let validAcknowledgement = Self.acknowledgement(language: "en")
		let missingPath = validAcknowledgement.replacingOccurrences(of: #""model":"gpt-realtime-2.1","#, with: "")
		let mistypedPath = validAcknowledgement.replacingOccurrences(of: #""type":"realtime""#, with: #""type":1"#)
		let rows = [
			missingPath,
			mistypedPath,
			#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(overlongIdentifier)","content_index":0,"transcript":""}"#,
			#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u","content_index":0.5,"transcript":""}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-1e-9999}]}"#,
			#"{"type":"response.output_audio.done","response_id":"other","item_id":"a","output_index":0,"content_index":0}"#
		]
		for (index, json) in rows.enumerated() {
			if index < 2 {
				var machine = try OpenAIProductionStateMachine(language: "en")
				_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
					assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
			} else if index == 5 {
				var machine = try activeResponseMachine()
					assertFailure(.providerError) { _ = try machine.consume(Data(json.utf8)) }
			} else if index == 2 {
				var machine = try activeMachine()
					assertFailure(.responseTooLarge) { _ = try machine.consume(Data(json.utf8)) }
			} else {
				var machine = try activeMachine()
					assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
			}
		}
	}

	@Test("OpenAI construction requires initially disabled audio")
	func openAIRejectsInitiallyEnabledAudioBeforeCreatingBacking() throws {
		let backing = OpenAIBacking()
		let factory = WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .enabled) {
			return backing
		}
		#expect(throws: WebRTCTransportFailure.invalidRequest) { _ = try factory.makePeer() }
		let configurationPayloadCount = backing.configurationPayloads.count
		#expect(configurationPayloadCount == 0)
		#expect(backing.audioStates.isEmpty)
	}

	@Test("construction-bound provider rejects a LocalAI configuration on the OpenAI path")
	func openAIConstructionRejectsLocalAIConfiguration() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		assertFailure(.invalidRequest) {
			try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		}
		await peer.closeAndJoin()
		let configurationPayloadCount = backing.configurationPayloads.count
		#expect(configurationPayloadCount == 0)
	}

	@Test("handshake preserves structural semantic and unsupported failure partitions")
	func handshakeFailurePartitions() throws {
		var premature = try OpenAIProductionStateMachine(language: "en")
		assertFailure(.malformedEvent) {
			_ = try premature.consume(Data(#"{"type":"response.created","response":{"id":"r"}}"#.utf8))
		}

		var unknown = try OpenAIProductionStateMachine(language: "en")
		assertFailure(.unsupportedEvent) {
			_ = try unknown.consume(Data(#"{"type":"function.call"}"#.utf8))
		}

		var duplicate = try OpenAIProductionStateMachine(language: "en")
		assertFailure(.malformedEvent) {
			_ = try duplicate.consume(Data(#"{"type":"session.created","type":"session.created"}"#.utf8))
		}

		var conflictingPath = try OpenAIProductionStateMachine(language: "en")
		_ = try conflictingPath.consume(Data(#"{"type":"session.created","metadata.value":"ignored"}"#.utf8))
		assertFailure(.malformedEvent) {
			let acknowledgement = String(Self.acknowledgement(language: "en").dropLast())
			_ = try conflictingPath.consume(Data((acknowledgement + #", "session.type":"realtime"}"#).utf8))
		}

		var nested = try OpenAIProductionStateMachine(language: "en")
		let deeplyNested = #"{"type":"session.created","default":"# + String(repeating: "[", count: 1_024) + "null" + String(repeating: "]", count: 1_024) + "}"
		let nestedEvent = try nested.consume(Data(deeplyNested.utf8))
		assertEventKind(.sessionCreated, nestedEvent)

		var provider = try OpenAIProductionStateMachine(language: "en")
		assertFailure(.providerError) {
			_ = try provider.consume(Data(#"{"type":"error","error":{"type":"synthetic","code":null,"param":"bounded","event_id":null}}"#.utf8))
		}

		var mismatch = try OpenAIProductionStateMachine(language: "en")
		_ = try mismatch.consume(Data(#"{"type":"session.created"}"#.utf8))
		assertFailure(.providerError) {
			_ = try mismatch.consume(Data(Self.acknowledgement(language: "ko").utf8))
		}

		var longMismatch = try OpenAIProductionStateMachine(language: "en")
		_ = try longMismatch.consume(Data(#"{"type":"session.created"}"#.utf8))
		assertFailure(.providerError) {
			_ = try longMismatch.consume(Data(Self.acknowledgement(language: "not-the-selected-language").utf8))
		}
	}

	@Test("flattened conflicts are event specific and done stages are strict")
	func eventSpecificPathsAndDoneStages() throws {
		var unrelated = try OpenAIProductionStateMachine(language: "en")
		let unrelatedEvent = try unrelated.consume(Data(#"{"type":"session.created","response.id":"provider-default"}"#.utf8))
		assertEventKind(.sessionCreated, unrelatedEvent)
		assertFailure(.malformedEvent) {
			_ = try unrelated.consume(Data((String(Self.acknowledgement(language: "en").dropLast()) + #", "session.audio":"conflict"}"#).utf8))
		}

		for json in [
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","content":[{"type":"audio"}]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[{"type":"audio"}]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[]}}"#
		] {
			var machine = try activeMachine()
			assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		for json in [
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","content":[{"type":"audio"}]}}"#,
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[{"type":"audio"}]}}"#,
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[]}}"#
		] {
			var machine = try activeResponseMachine()
			assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		var rate = try activeMachine()
		assertFailure(.malformedEvent) {
			_ = try rate.consume(Data(#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":10,"remaining":9,"reset_seconds":1}],"rate_limits.remaining":9}"#.utf8))
		}
	}

	@Test("accepted and ignored inventory validates every named schema")
	func acceptedAndIgnoredInventory() throws {
		var machine = try activeMachine()
		for json in [
			#"{"type":"input_audio_buffer.speech_started"}"#,
			#"{"type":"input_audio_buffer.speech_stopped"}"#,
			#"{"type":"input_audio_buffer.committed"}"#,
			#"{"type":"input_audio_buffer.cleared"}"#,
			#"{"type":"output_audio_buffer.started"}"#,
			#"{"type":"output_audio_buffer.stopped"}"#,
			#"{"type":"output_audio_buffer.cleared"}"#,
			#"{"type":"conversation.item.added","item":{"id":"u","type":"message","role":"user","status":"in_progress","content":[{"type":"input_audio"}]}}"#,
			#"{"type":"conversation.item.created","item":{"id":"u","type":"message","role":"user","content":[{"type":"input_audio"}]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[{"type":"output_audio"}]}}"#,
			#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u","content_index":0,"delta":"partial"}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":10,"remaining":9,"reset_seconds":0.25}]}"#
		] {
			let event = try machine.consume(Data(json.utf8))
			assertNoEvent(event)
		}
		let transcriptEvent = try machine.consume(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u","content_index":0,"transcript":"hello"}"#.utf8))
		assertEventKind(.userTranscript, transcriptEvent)
	}

	@Test("response identity correlation cancellation drain and reuse stay bounded")
	func responseCorrelationAndCancellation() throws {
		var machine = try activeMachine()
		try machine.prepareCreateResponse()
		let startedEvent = try machine.consume(Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8))
		assertEventKind(.responseStarted, startedEvent)
		let addedEvent = try machine.consume(Data(#"{"type":"response.output_item.added","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[]}}"#.utf8))
		assertNoEvent(addedEvent)
		let contentEvent = try machine.consume(Data(#"{"type":"response.content_part.added","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"part":{"type":"audio"}}"#.utf8))
		assertNoEvent(contentEvent)
		let deltaEvent = try machine.consume(Data(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YQ=="}"#.utf8))
		assertNoEvent(deltaEvent)
		let alternateDeltaEvent = try machine.consume(Data(#"{"type":"response.audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YWJj"}"#.utf8))
		assertNoEvent(alternateDeltaEvent)
		let audioDoneEvent = try machine.consume(Data(#"{"type":"response.output_audio.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0}"#.utf8))
		assertNoEvent(audioDoneEvent)
		let transcriptDeltaEvent = try machine.consume(Data(#"{"type":"response.output_audio_transcript.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"partial"}"#.utf8))
		assertNoEvent(transcriptDeltaEvent)
		let partDoneEvent = try machine.consume(Data(#"{"type":"response.content_part.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"part":{"type":"output_audio"}}"#.utf8))
		assertNoEvent(partDoneEvent)
		let itemDoneEvent = try machine.consume(Data(#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[{"type":"audio"}]}}"#.utf8))
		assertNoEvent(itemDoneEvent)
		let transcriptDoneEvent = try machine.consume(Data(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"answer"}"#.utf8))
		assertEventKind(.assistantTranscript, transcriptDoneEvent)
		try machine.prepareCancelResponse()
		let suppressedEvent = try machine.consume(Data(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"suppressed"}"#.utf8))
		assertNoEvent(suppressedEvent)
		let cancellationEvent = try machine.consume(Data(#"{"type":"response.done","response":{"id":"r1","status":"cancelled"}}"#.utf8))
		assertEventKind(.cancellationTerminalObserved, cancellationEvent)
		#expect(throws: WebRTCTransportFailure.invalidRequest) { try machine.prepareCreateResponse() }
		try machine.settleCancelledResponse()
		try machine.prepareCreateResponse()
		assertFailure(.providerError) {
			_ = try machine.consume(Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8))
		}
	}

	@Test("peer exposes only bounded cancellation and settlement primitives")
	func peerCancellationPrimitives() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		_ = try await events.next()
		try peer.configure(.openAI(language: "en"))
		backing.emitRaw(#"{"type":"session.created"}"#)
		_ = try await events.next()
		backing.emitRaw(Self.acknowledgement(language: "en"))
		_ = try await events.next()
		backing.emitRaw(#"{"type":"response.created","response":{"id":"r1"}}"#)
		let responseStarted = try await events.next()
		assertEventKind(.responseStarted, responseStarted)
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		backing.emitRaw(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"not-delivered"}"#)
		backing.emitRaw(#"{"type":"response.done","response":{"id":"r1","status":"completed"}}"#)
		let cancellationTerminal = try await events.next()
		assertEventKind(.cancellationTerminalObserved, cancellationTerminal)
		try peer.settleCancelledResponse()
		try peer.createResponse()
		let commandSequenceIsCorrect = backing.commandTypes == ["response.cancel", "output_audio_buffer.clear", "response.create"]
		#expect(commandSequenceIsCorrect, "Cancellation settlement must preserve the restricted command order")
		await peer.closeAndJoin()
	}

	@Test("all OpenAI command send failures settle content free")
	func openAICommandFailuresSettle() async throws {
		for command in OpenAICommandCase.allCases {
			let backing = OpenAIBacking(commandSendFails: true)
			let peer = try WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled, makePeer: { backing }).makePeer()
			var events = peer.events.makeAsyncIterator()
			_ = try await peer.makeOffer()
			try await peer.apply(remoteAnswer: "answer")
			backing.emit(.ready); _ = try await events.next()
			try peer.configure(.openAI(language: "en"))
			backing.emitRaw(#"{"type":"session.created"}"#); _ = try await events.next()
			backing.emitRaw(Self.acknowledgement(language: "en")); _ = try await events.next()
			if command == .cancel {
				backing.emitRaw(#"{"type":"response.created","response":{"id":"r1"}}"#)
				_ = try await events.next()
			}
			assertFailure(.requestFailed) { try command.invoke(peer) }
			await peer.closeAndJoin()
			do { _ = try await events.next(); Issue.record("failed command must terminate") }
			catch { #expect(error as? WebRTCTransportFailure == .requestFailed) }
			#expect(backing.closeCount == 1)
		}
	}

	@Test("server VAD may open a response without an explicit create command")
	func serverVADOpensResponseEpoch() throws {
		var machine = try activeMachine()
		let startedEvent = try machine.consume(Data(#"{"type":"response.created","response":{"id":"server-vad"}}"#.utf8))
		assertEventKind(.responseStarted, startedEvent)
		let finishedEvent = try machine.consume(Data(#"{"type":"response.done","response":{"id":"server-vad","status":"completed"}}"#.utf8))
		assertEventKind(.responseFinished, finishedEvent)
	}

	@Test("malformed oversized and correlation failures remain distinct")
	func inboundFailurePartitions() throws {
		var invalidBase64 = try activeResponseMachine()
		assertFailure(.malformedEvent) {
			_ = try invalidBase64.consume(Data(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YQ-_"}"#.utf8))
		}

		var mismatch = try activeResponseMachine()
		assertFailure(.providerError) {
			_ = try mismatch.consume(Data(#"{"type":"response.output_audio.done","response_id":"other","item_id":"a","output_index":0,"content_index":0}"#.utf8))
		}

		var oversized = try activeResponseMachine()
		let identifier = String(repeating: "x", count: 129)
		assertFailure(.responseTooLarge) {
			_ = try oversized.consume(Data(#"{"type":"response.output_audio.done","response_id":"r1","item_id":"\#(identifier)","output_index":0,"content_index":0}"#.utf8))
		}

		var raw = try OpenAIProductionStateMachine(language: "en")
		assertFailure(.responseTooLarge) {
			_ = try raw.consume(Data(repeating: 0x20, count: 256 * 1024 + 1))
		}
	}

	@Test("event and aggregate caps are exact and stale invalidated input is a no-op")
	func sessionBoundsAndStaleGeneration() throws {
		var count = try activeMachine()
		for _ in 0..<(4_096 - 2) {
			_ = try count.consume(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8))
		}
		assertFailure(.responseTooLarge) {
			_ = try count.consume(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8))
		}

		var stale = try activeMachine()
		stale.invalidate()
		let staleEvent = try stale.consume(Data(repeating: 0, count: 256 * 1024 + 1))
		assertNoEvent(staleEvent)
	}

	@Test("aggregate raw custody fails before crossing sixteen MiB")
	func aggregateRawByteBound() throws {
		var machine = try activeMachine()
		let prefix = Data(#"{"type":"input_audio_buffer.committed","padding":""#.utf8)
		let suffix = Data(#""}"#.utf8)
		var maximumEvent = Data()
		maximumEvent.append(prefix)
		maximumEvent.append(Data(repeating: 120, count: 256 * 1024 - prefix.count - suffix.count))
		maximumEvent.append(suffix)
		#expect(maximumEvent.count == 256 * 1024)
		for _ in 0..<63 { _ = try machine.consume(maximumEvent) }
		assertFailure(.responseTooLarge) {
			_ = try machine.consume(maximumEvent)
		}
	}

	@Test("unsupported item shapes never become tool or text capability")
	func rejectsExpandedItemCapability() throws {
		var machine = try activeMachine()
		assertFailure(.unsupportedEvent) {
			_ = try machine.consume(Data(#"{"type":"conversation.item.added","item":{"id":"f","type":"function_call","role":"assistant","content":[]}}"#.utf8))
		}
		var text = try activeMachine()
		assertFailure(.unsupportedEvent) {
			_ = try text.consume(Data(#"{"type":"conversation.item.added","item":{"id":"t","type":"message","role":"user","content":[{"type":"input_text"}]}}"#.utf8))
		}
	}

	@Test("supported user item stages require nonempty audio content")
	func rejectsEmptyUserAudioItemsAsMalformed() throws {
		for json in [
			#"{"type":"conversation.item.added","item":{"id":"u","type":"message","role":"user","status":"in_progress","content":[]}}"#,
			#"{"type":"conversation.item.created","item":{"id":"u","type":"message","role":"user","content":[]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"u","type":"message","role":"user","status":"completed","content":[]}}"#
		] {
			var machine = try activeMachine()
			assertFailure(.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
	}

	@Test("near-cap nesting has no semantic depth limit or recursive lifetime")
	func nearCapNestingIsIterative() throws {
		var machine = try OpenAIProductionStateMachine(language: "en")
		let prefix = #"{"type":"session.created","default":"#
		let suffix = "}"
		let depth = (256 * 1024 - prefix.utf8.count - suffix.utf8.count - 4) / 2
		let json = prefix + String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth) + suffix
		let inputFitsRawCap = json.utf8.count <= 256 * 1024
		#expect(inputFitsRawCap, "The nesting fixture must stay within the raw input cap")
		let event = try machine.consume(Data(json.utf8))
		assertEventKind(.sessionCreated, event)
	}

	private enum ContentFreeEventKind: Equatable {
		case ready
		case sessionCreated
		case sessionAcknowledged
		case sessionConfigured
		case userTranscript
		case assistantTranscript
		case responseStarted
		case responseFinished
		case cancellationTerminalObserved
	}

	private func assertEventKind(
		_ expected: ContentFreeEventKind,
		_ event: OpenAIProductionEvent?
	) {
		let matches: Bool
		switch (expected, event) {
		case (.sessionCreated, .sessionCreated),
			(.sessionAcknowledged, .sessionAcknowledged),
			(.responseStarted, .responseStarted),
			(.responseFinished, .responseFinished),
			(.cancellationTerminalObserved, .cancellationTerminalObserved):
			matches = true
		case let (.userTranscript, .userTranscript(transcript)):
			matches = transcript == "hello"
		case let (.assistantTranscript, .assistantTranscript(transcript)):
			matches = transcript == "answer"
		default:
			matches = false
		}
		#expect(matches, "The state machine must publish the expected content-free event kind")
	}

	private func assertEventKind(
		_ expected: ContentFreeEventKind,
		_ event: WebRTCConnectorEvent?
	) {
		let matches: Bool
		switch (expected, event) {
		case (.ready, .ready),
			(.sessionCreated, .openAISessionCreated),
			(.responseStarted, .responseStarted),
			(.responseFinished, .responseFinished),
			(.cancellationTerminalObserved, .responseCancellationTerminalObserved):
			matches = true
		case let (.sessionConfigured, .openAISessionConfigured(language)):
			matches = language == "en"
		case let (.userTranscript, .userTranscript(transcript)):
			matches = transcript == "hello"
		case let (.assistantTranscript, .assistantTranscript(transcript)):
			matches = transcript == "answer"
		default:
			matches = false
		}
		#expect(matches, "The peer must publish the expected content-free event kind")
	}

	private func assertNoEvent(_ event: OpenAIProductionEvent?) {
		let isAbsent = event == nil
		#expect(isAbsent, "The input must not publish a semantic event")
	}

	private func assertFailure(
		_ expected: WebRTCTransportFailure,
		_ operation: () throws -> Void
	) {
		do {
			try operation()
			Issue.record("The operation must fail with the expected content-free category")
		} catch {
			let matches = error as? WebRTCTransportFailure == expected
			#expect(matches, "The operation must fail with the expected content-free category")
		}
	}

	private func activeMachine() throws -> OpenAIProductionStateMachine {
		var machine = try OpenAIProductionStateMachine(language: "en")
		_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
		_ = try machine.consume(Data(Self.acknowledgement(language: "en").utf8))
		return machine
	}

	private func activeResponseMachine() throws -> OpenAIProductionStateMachine {
		var machine = try activeMachine()
		try machine.prepareCreateResponse()
		_ = try machine.consume(Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8))
		return machine
	}

	private static func acknowledgement(language: String, threshold: String = "0.5") -> String {
		#"{"type":"session.updated","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"\#(language)"},"turn_detection":{"type":"server_vad","threshold":\#(threshold),"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#
	}
}

@MainActor private enum OpenAICommandCase: CaseIterable, Equatable {
	case user, create, cancel, clear
	func invoke(_ peer: any WebRTCConnectorPeer) throws {
		switch self {
		case .user: try peer.sendUserText("synthetic")
		case .create: try peer.createResponse()
		case .cancel: try peer.cancelResponse()
		case .clear: try peer.clearOutputAudio()
		}
	}
}

@MainActor
private final class OpenAIBacking: WebRTCConnectorPeerBacking, @unchecked Sendable {
	struct SyntheticError: Error {}
	private var sink: (@MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void)?
	private let configurationSendFails: Bool
	private let commandSendFails: Bool
	var configurationPayloads: [Data] = []
	var commandTypes: [String] = []
	var audioStates: [WebRTCLocalAudioState] = []
	var closeCount = 0
	init(configurationSendFails: Bool = false, commandSendFails: Bool = false) {
		self.configurationSendFails = configurationSendFails
		self.commandSendFails = commandSendFails
	}

	func installProductionEventSink(_ sink: @escaping @MainActor @Sendable (Result<WebRTCConnectorPeerBackingEvent, any Error>) -> Void) { self.sink = sink }
	func makeOffer() async throws -> String { "offer" }
	func apply(answer _: String) async throws {}
	func sendSessionConfiguration(_ data: Data) throws {
		if configurationSendFails { throw SyntheticError() }
		configurationPayloads.append(data)
	}
	func sendProductionCommand(_ command: ProductionCommand) throws {
		let root = try JSONSerialization.jsonObject(with: command.encoded()) as? [String: Any]
		commandTypes.append(root?["type"] as? String ?? "")
		if commandSendFails { throw SyntheticError() }
	}
	func setLocalAudioState(_ state: WebRTCLocalAudioState) { audioStates.append(state) }
	func disableAudioForMediaQuiescence() -> UInt64? {
		if !audioStates.contains(.disabled) { audioStates.append(.disabled) }
		return nil
	}
	func waitForMediaQuiescence(through _: UInt64?) async {
	}
	func closeAndSettle() async { closeCount += 1 }
	func emit(_ event: WebRTCConnectorPeerBackingEvent) { sink?(.success(event)) }
	func emitRaw(_ json: String) {
		emit(.rawInbound(Data(json.utf8), configurationDispatchedAtAcceptance: false))
	}
}
