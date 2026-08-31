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
		#expect(try english.encoded() == Data(#"{"type":"session.update","session":{"type":"realtime","model":"gpt-realtime-2.1","audio":{"input":{"transcription":{"model":"gpt-4o-mini-transcribe","language":"en"},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500,"create_response":true,"interrupt_response":true}},"output":{"voice":"marin"}}}}"#.utf8))
		let koreanData = try korean.encoded()
		let englishData = try english.encoded()
		#expect(koreanData != englishData)
		#expect(throws: WebRTCTransportFailure.invalidRequest) {
			_ = try WebRTCSessionConfiguration.openAI(language: "fr")
		}
	}

	@Test("creation sends one update and exact acknowledgement gates audio")
	func strictHandshakeAndAudioGate() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		#expect(try await events.next() == .ready)
		try peer.configure(.openAI(language: "en"))
		#expect(backing.configurationPayloads.isEmpty)
		backing.emitRaw(#"{"type":"session.created","session":{"id":"synthetic"}}"#)
		#expect(try await events.next() == .openAISessionCreated)
		#expect(backing.configurationPayloads.count == 1)
		backing.emitRaw(Self.acknowledgement(language: "en"))
		#expect(try await events.next() == .openAISessionConfigured(language: "en"))
		#expect(backing.audioStates == [.disabled])
		peer.setLocalAudioState(.enabled)
		#expect(backing.audioStates == [.disabled, .enabled])
		await peer.closeAndJoin()
	}

	@Test("creation and acknowledgement fit the fixed two-slot production stream")
	func handshakeBurstFitsBoundedStream() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
		var events = peer.events.makeAsyncIterator()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		_ = try await events.next()
		try peer.configure(.openAI(language: "en"))
		backing.emitRaw(#"{"type":"session.created"}"#)
		backing.emitRaw(Self.acknowledgement(language: "en"))
		#expect(try await events.next() == .openAISessionCreated)
		#expect(try await events.next() == .openAISessionConfigured(language: "en"))
		try peer.createResponse()
		#expect(backing.commandTypes == ["response.create"])
		await peer.closeAndJoin()
	}

	@Test("session update send failure stays content free")
	func configurationSendFailureIsContentFree() async throws {
		let backing = OpenAIBacking(configurationSendFails: true)
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
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
			#expect(try machine.consume(Data(Self.acknowledgement(language: "en", threshold: threshold).utf8)) == .sessionAcknowledged)
		}
		for threshold in [
			"0.5000000000000000000000000000000000000001",
			"0.4999999999999999999999999999999999999999"
		] {
			var machine = try OpenAIProductionStateMachine(language: "en")
			_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
			#expect(throws: WebRTCTransportFailure.providerError) {
				_ = try machine.consume(Data(Self.acknowledgement(language: "en", threshold: threshold).utf8))
			}
		}

		let malformedRows = [
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":9223372036854775808,"remaining":0,"reset_seconds":0}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1.0,"remaining":0,"reset_seconds":0}]}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-1e-9999}]}"#
		]
		for json in malformedRows {
			var machine = try activeMachine()
			#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		var exactZero = try activeMachine()
		#expect(try exactZero.consume(Data(#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-0.0}]}"#.utf8)) == nil)
	}

	@Test("RT-OE-022 covers one malformed case per required schema dimension")
	func schemaDimensionMatrix() throws {
		let overlongIdentifier = String(repeating: "x", count: 129)
		let rows = [
			#"{"type":"session.updated","session":{"type":"realtime"}}"#,
			#"{"type":"session.updated","session":{"type":1}}"#,
			#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(overlongIdentifier)","content_index":0,"transcript":""}"#,
			#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u","content_index":0.5,"transcript":""}"#,
			#"{"type":"rate_limits.updated","rate_limits":[{"name":"requests","limit":1,"remaining":0,"reset_seconds":-1e-9999}]}"#,
			#"{"type":"response.output_audio.done","response_id":"other","item_id":"a","output_index":0,"content_index":0}"#
		]
		for (index, json) in rows.enumerated() {
			if index < 2 {
				var machine = try OpenAIProductionStateMachine(language: "en")
				_ = try machine.consume(Data(#"{"type":"session.created"}"#.utf8))
				#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
			} else if index == 5 {
				var machine = try activeResponseMachine()
				#expect(throws: WebRTCTransportFailure.providerError) { _ = try machine.consume(Data(json.utf8)) }
			} else if index == 2 {
				var machine = try activeMachine()
				#expect(throws: WebRTCTransportFailure.responseTooLarge) { _ = try machine.consume(Data(json.utf8)) }
			} else {
				var machine = try activeMachine()
				#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
			}
		}
	}

	@Test("OpenAI construction requires initially disabled audio")
	func openAIRejectsInitiallyEnabledAudio() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .enabled, makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		#expect(throws: WebRTCTransportFailure.invalidRequest) { try peer.configure(.openAI(language: "en")) }
		await peer.closeAndJoin()
		#expect(backing.configurationPayloads.isEmpty)
		#expect(backing.audioStates == [.enabled, .disabled])
	}

	@Test("construction-bound provider rejects a LocalAI configuration on the OpenAI path")
	func openAIConstructionRejectsLocalAIConfiguration() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
		_ = try await peer.makeOffer()
		try await peer.apply(remoteAnswer: "answer")
		backing.emit(.ready)
		#expect(throws: WebRTCTransportFailure.invalidRequest) {
			try peer.configure(.localAI(voice: "Ono_Anna", language: "ja"))
		}
		await peer.closeAndJoin()
		#expect(backing.configurationPayloads.isEmpty)
	}

	@Test("handshake preserves structural semantic and unsupported failure partitions")
	func handshakeFailurePartitions() throws {
		var premature = try OpenAIProductionStateMachine(language: "en")
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
			_ = try premature.consume(Data(#"{"type":"response.created","response":{"id":"r"}}"#.utf8))
		}

		var unknown = try OpenAIProductionStateMachine(language: "en")
		#expect(throws: WebRTCTransportFailure.unsupportedEvent) {
			_ = try unknown.consume(Data(#"{"type":"function.call"}"#.utf8))
		}

		var duplicate = try OpenAIProductionStateMachine(language: "en")
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
			_ = try duplicate.consume(Data(#"{"type":"session.created","type":"session.created"}"#.utf8))
		}

		var conflictingPath = try OpenAIProductionStateMachine(language: "en")
		_ = try conflictingPath.consume(Data(#"{"type":"session.created","metadata.value":"ignored"}"#.utf8))
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
			let acknowledgement = String(Self.acknowledgement(language: "en").dropLast())
			_ = try conflictingPath.consume(Data((acknowledgement + #", "session.type":"realtime"}"#).utf8))
		}

		var nested = try OpenAIProductionStateMachine(language: "en")
		let deeplyNested = #"{"type":"session.created","default":"# + String(repeating: "[", count: 1_024) + "null" + String(repeating: "]", count: 1_024) + "}"
		#expect(try nested.consume(Data(deeplyNested.utf8)) == .sessionCreated)

		var provider = try OpenAIProductionStateMachine(language: "en")
		#expect(throws: WebRTCTransportFailure.providerError) {
			_ = try provider.consume(Data(#"{"type":"error","error":{"type":"synthetic","code":null,"param":"bounded","event_id":null}}"#.utf8))
		}

		var mismatch = try OpenAIProductionStateMachine(language: "en")
		_ = try mismatch.consume(Data(#"{"type":"session.created"}"#.utf8))
		#expect(throws: WebRTCTransportFailure.providerError) {
			_ = try mismatch.consume(Data(Self.acknowledgement(language: "ko").utf8))
		}

		var longMismatch = try OpenAIProductionStateMachine(language: "en")
		_ = try longMismatch.consume(Data(#"{"type":"session.created"}"#.utf8))
		#expect(throws: WebRTCTransportFailure.providerError) {
			_ = try longMismatch.consume(Data(Self.acknowledgement(language: "not-the-selected-language").utf8))
		}
	}

	@Test("flattened conflicts are event specific and done stages are strict")
	func eventSpecificPathsAndDoneStages() throws {
		var unrelated = try OpenAIProductionStateMachine(language: "en")
		#expect(try unrelated.consume(Data(#"{"type":"session.created","response.id":"provider-default"}"#.utf8)) == .sessionCreated)
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
			_ = try unrelated.consume(Data((String(Self.acknowledgement(language: "en").dropLast()) + #", "session.audio":"conflict"}"#).utf8))
		}

		for json in [
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","content":[{"type":"audio"}]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[{"type":"audio"}]}}"#,
			#"{"type":"conversation.item.done","item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[]}}"#
		] {
			var machine = try activeMachine()
			#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		for json in [
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","content":[{"type":"audio"}]}}"#,
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[{"type":"audio"}]}}"#,
			#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[]}}"#
		] {
			var machine = try activeResponseMachine()
			#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
		var rate = try activeMachine()
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
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
			#expect(try machine.consume(Data(json.utf8)) == nil)
		}
		#expect(try machine.consume(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u","content_index":0,"transcript":"hello"}"#.utf8)) == .userTranscript("hello"))
	}

	@Test("response identity correlation cancellation drain and reuse stay bounded")
	func responseCorrelationAndCancellation() throws {
		var machine = try activeMachine()
		try machine.prepareCreateResponse()
		#expect(try machine.consume(Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8)) == .responseStarted)
		#expect(try machine.consume(Data(#"{"type":"response.output_item.added","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"in_progress","content":[]}}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.content_part.added","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"part":{"type":"audio"}}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YQ=="}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YWJj"}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.output_audio.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.output_audio_transcript.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"partial"}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.content_part.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"part":{"type":"output_audio"}}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.output_item.done","response_id":"r1","output_index":0,"item":{"id":"a","type":"message","role":"assistant","status":"completed","content":[{"type":"audio"}]}}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"answer"}"#.utf8)) == .assistantTranscript("answer"))
		try machine.prepareCancelResponse()
		#expect(try machine.consume(Data(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"suppressed"}"#.utf8)) == nil)
		#expect(try machine.consume(Data(#"{"type":"response.done","response":{"id":"r1","status":"cancelled"}}"#.utf8)) == .cancellationTerminalObserved)
		#expect(throws: WebRTCTransportFailure.invalidRequest) { try machine.prepareCreateResponse() }
		try machine.settleCancelledResponse()
		try machine.prepareCreateResponse()
		#expect(throws: WebRTCTransportFailure.providerError) {
			_ = try machine.consume(Data(#"{"type":"response.created","response":{"id":"r1"}}"#.utf8))
		}
	}

	@Test("peer exposes only bounded cancellation and settlement primitives")
	func peerCancellationPrimitives() async throws {
		let backing = OpenAIBacking()
		let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
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
		#expect(try await events.next() == .responseStarted)
		try peer.cancelResponse()
		try peer.clearOutputAudio()
		backing.emitRaw(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"transcript":"not-delivered"}"#)
		backing.emitRaw(#"{"type":"response.done","response":{"id":"r1","status":"completed"}}"#)
		#expect(try await events.next() == .responseCancellationTerminalObserved)
		try peer.settleCancelledResponse()
		try peer.createResponse()
		#expect(backing.commandTypes == ["response.cancel", "output_audio_buffer.clear", "response.create"])
		await peer.closeAndJoin()
	}

	@Test("all OpenAI command send failures settle content free")
	func openAICommandFailuresSettle() async throws {
		for command in OpenAICommandCase.allCases {
			let backing = OpenAIBacking(commandSendFails: true)
			let peer = try WebRTCConnectorPeerFactory(initialAudioState: .disabled, makePeer: { backing }).makePeer()
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
			#expect(throws: WebRTCTransportFailure.requestFailed) { try command.invoke(peer) }
			await peer.closeAndJoin()
			do { _ = try await events.next(); Issue.record("failed command must terminate") }
			catch { #expect(error as? WebRTCTransportFailure == .requestFailed) }
			#expect(backing.closeCount == 1)
		}
	}

	@Test("server VAD may open a response without an explicit create command")
	func serverVADOpensResponseEpoch() throws {
		var machine = try activeMachine()
		#expect(try machine.consume(Data(#"{"type":"response.created","response":{"id":"server-vad"}}"#.utf8)) == .responseStarted)
		#expect(try machine.consume(Data(#"{"type":"response.done","response":{"id":"server-vad","status":"completed"}}"#.utf8)) == .responseFinished)
	}

	@Test("malformed oversized and correlation failures remain distinct")
	func inboundFailurePartitions() throws {
		var invalidBase64 = try activeResponseMachine()
		#expect(throws: WebRTCTransportFailure.malformedEvent) {
			_ = try invalidBase64.consume(Data(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a","output_index":0,"content_index":0,"delta":"YQ-_"}"#.utf8))
		}

		var mismatch = try activeResponseMachine()
		#expect(throws: WebRTCTransportFailure.providerError) {
			_ = try mismatch.consume(Data(#"{"type":"response.output_audio.done","response_id":"other","item_id":"a","output_index":0,"content_index":0}"#.utf8))
		}

		var oversized = try activeResponseMachine()
		let identifier = String(repeating: "x", count: 129)
		#expect(throws: WebRTCTransportFailure.responseTooLarge) {
			_ = try oversized.consume(Data(#"{"type":"response.output_audio.done","response_id":"r1","item_id":"\#(identifier)","output_index":0,"content_index":0}"#.utf8))
		}

		var raw = try OpenAIProductionStateMachine(language: "en")
		#expect(throws: WebRTCTransportFailure.responseTooLarge) {
			_ = try raw.consume(Data(repeating: 0x20, count: 256 * 1024 + 1))
		}
	}

	@Test("event and aggregate caps are exact and stale invalidated input is a no-op")
	func sessionBoundsAndStaleGeneration() throws {
		var count = try activeMachine()
		for _ in 0..<(4_096 - 2) {
			_ = try count.consume(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8))
		}
		#expect(throws: WebRTCTransportFailure.responseTooLarge) {
			_ = try count.consume(Data(#"{"type":"input_audio_buffer.committed"}"#.utf8))
		}

		var stale = try activeMachine()
		stale.invalidate()
		#expect(try stale.consume(Data(repeating: 0, count: 256 * 1024 + 1)) == nil)
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
		#expect(throws: WebRTCTransportFailure.responseTooLarge) {
			_ = try machine.consume(maximumEvent)
		}
	}

	@Test("unsupported item shapes never become tool or text capability")
	func rejectsExpandedItemCapability() throws {
		var machine = try activeMachine()
		#expect(throws: WebRTCTransportFailure.unsupportedEvent) {
			_ = try machine.consume(Data(#"{"type":"conversation.item.added","item":{"id":"f","type":"function_call","role":"assistant","content":[]}}"#.utf8))
		}
		var text = try activeMachine()
		#expect(throws: WebRTCTransportFailure.unsupportedEvent) {
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
			#expect(throws: WebRTCTransportFailure.malformedEvent) { _ = try machine.consume(Data(json.utf8)) }
		}
	}

	@Test("near-cap nesting has no semantic depth limit or recursive lifetime")
	func nearCapNestingIsIterative() throws {
		var machine = try OpenAIProductionStateMachine(language: "en")
		let prefix = #"{"type":"session.created","default":"#
		let suffix = "}"
		let depth = (256 * 1024 - prefix.utf8.count - suffix.utf8.count - 4) / 2
		let json = prefix + String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth) + suffix
		#expect(json.utf8.count <= 256 * 1024)
		#expect(try machine.consume(Data(json.utf8)) == .sessionCreated)
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
	func closeAndSettle() async { closeCount += 1 }
	func emit(_ event: WebRTCConnectorPeerBackingEvent) { sink?(.success(event)) }
	func emitRaw(_ json: String) { emit(.rawInbound(Data(json.utf8))) }
}
