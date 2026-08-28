import Foundation

package enum OpenAIProductionEvent: Sendable, Equatable {
	case sessionCreated
	case sessionAcknowledged
	case userTranscript(String)
	case assistantTranscript(String)
	case responseStarted
	case responseFinished
	case cancellationTerminalObserved
}

/// Peer-local, content-discarding OpenAI event policy. Operation deadlines and
/// predecessor-output quiescence deliberately remain caller-owned.
package struct OpenAIProductionStateMachine: Sendable {
	private enum Phase: Sendable { case awaitingCreation, awaitingAcknowledgement, active, invalidated }
	private enum Epoch: Sendable { case none, creating, active(String), cancelling(String, terminalObserved: Bool) }
	private let language: String
	private var phase: Phase = .awaitingCreation
	private var epoch: Epoch = .none
	private var eventCount = 0
	private var aggregateBytes = 0
	private var seenResponseIDs: Set<String> = []

	package init(language: String) throws {
		guard ["en", "ko", "ja"].contains(language) else { throw WebRTCTransportFailure.invalidRequest }
		self.language = language
	}

	package var acknowledgementAccepted: Bool { phase == .active }

	package mutating func invalidate() {
		phase = .invalidated
		epoch = .none
		seenResponseIDs.removeAll(keepingCapacity: false)
	}

	package mutating func consume(_ data: Data) throws -> OpenAIProductionEvent? {
		guard phase != .invalidated else { return nil }
		guard data.count <= 256 * 1024 else { throw WebRTCTransportFailure.responseTooLarge }
		guard eventCount < 4_096, aggregateBytes <= 16 * 1024 * 1024 - data.count else {
			throw WebRTCTransportFailure.responseTooLarge
		}
		eventCount += 1
		aggregateBytes += data.count
		let root = try StrictJSON.parse(data).requiredObject()
		let type = try root.requiredString("type", maximumBytes: 256 * 1024, nonempty: true)
		guard !root.containsFlattenedConflict(namedPaths: Self.namedPaths) else { throw WebRTCTransportFailure.malformedEvent }
		if type == "error" {
			try validateProviderError(root)
			throw WebRTCTransportFailure.providerError
		}
		switch phase {
		case .awaitingCreation:
			guard type == "session.created" else { throw phaseFailure(for: type) }
			phase = .awaitingAcknowledgement
			return .sessionCreated
		case .awaitingAcknowledgement:
			guard type == "session.updated" else { throw phaseFailure(for: type) }
			try validateAcknowledgement(root)
			phase = .active
			return .sessionAcknowledged
		case .active:
			return try consumeActive(type: type, root: root)
		case .invalidated:
			return nil
		}
	}

	package mutating func prepareCreateResponse() throws {
		guard phase == .active, case .none = epoch else { throw WebRTCTransportFailure.invalidRequest }
		epoch = .creating
	}

	package mutating func prepareCancelResponse() throws {
		guard phase == .active, case let .active(id) = epoch else { throw WebRTCTransportFailure.invalidRequest }
		epoch = .cancelling(id, terminalObserved: false)
	}

	package mutating func settleCancelledResponse() throws {
		guard phase == .active, case .cancelling = epoch else { throw WebRTCTransportFailure.invalidRequest }
		epoch = .none
	}

	private func phaseFailure(for type: String) -> WebRTCTransportFailure {
		Self.knownTypes.contains(type) ? .malformedEvent : .unsupportedEvent
	}

	private mutating func consumeActive(type: String, root: [String: StrictJSON]) throws -> OpenAIProductionEvent? {
		switch type {
		case "session.created", "session.updated":
			throw WebRTCTransportFailure.malformedEvent
		case "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped",
			"input_audio_buffer.committed", "input_audio_buffer.cleared",
			"output_audio_buffer.started", "output_audio_buffer.stopped", "output_audio_buffer.cleared":
			return nil
		case "conversation.item.added", "conversation.item.created", "conversation.item.done":
			try validateConversationItem(root, done: type == "conversation.item.done")
			return nil
		case "conversation.item.input_audio_transcription.completed":
			_ = try root.requiredIdentifier("item_id")
			_ = try root.requiredNonnegativeInteger("content_index")
			return .userTranscript(try root.requiredString("transcript", maximumBytes: 8 * 1024, nonempty: false))
		case "conversation.item.input_audio_transcription.delta":
			_ = try root.requiredIdentifier("item_id")
			_ = try root.requiredNonnegativeInteger("content_index")
			_ = try root.requiredString("delta", maximumBytes: 8 * 1024, nonempty: true)
			return nil
		case "response.created":
			let response = try root.requiredObject("response")
			let id = try response.requiredIdentifier("id")
			let mayOpen: Bool
			switch epoch { case .none, .creating: mayOpen = true; case .active, .cancelling: mayOpen = false }
			guard mayOpen, !seenResponseIDs.contains(id) else { throw WebRTCTransportFailure.providerError }
			guard seenResponseIDs.count < 4_096 else { throw WebRTCTransportFailure.responseTooLarge }
			seenResponseIDs.insert(id)
			epoch = .active(id)
			return .responseStarted
		case "response.output_item.added", "response.output_item.done":
			let id = try root.requiredIdentifier("response_id")
			_ = try requireCorrelated(id)
			_ = try root.requiredNonnegativeInteger("output_index")
			try validateAssistantItem(try root.requiredObject("item"), done: type.hasSuffix(".done"))
			return nil
		case "response.content_part.added", "response.content_part.done":
			let id = try root.requiredIdentifier("response_id")
			_ = try requireCorrelated(id)
			_ = try root.requiredIdentifier("item_id")
			_ = try root.requiredNonnegativeInteger("output_index")
			_ = try root.requiredNonnegativeInteger("content_index")
			try validateAudioPart(try root.requiredObject("part"))
			return nil
		case "response.output_audio.delta", "response.audio.delta":
			try validateResponseCoordinates(root)
			let delta = try root.requiredString("delta", maximumBytes: 256 * 1024, nonempty: true)
			guard Self.isStandardBase64(delta) else { throw WebRTCTransportFailure.malformedEvent }
			return nil
		case "response.output_audio.done":
			try validateResponseCoordinates(root)
			return nil
		case "response.output_audio_transcript.delta":
			try validateResponseCoordinates(root)
			_ = try root.requiredString("delta", maximumBytes: 8 * 1024, nonempty: true)
			return nil
		case "response.output_audio_transcript.done":
			let id = try root.requiredIdentifier("response_id")
			let disposition = try requireCorrelated(id)
			_ = try root.requiredIdentifier("item_id")
			_ = try root.requiredNonnegativeInteger("output_index")
			_ = try root.requiredNonnegativeInteger("content_index")
			let transcript = try root.requiredString("transcript", maximumBytes: 8 * 1024, nonempty: false)
			return disposition == .deliver ? .assistantTranscript(transcript) : nil
		case "rate_limits.updated":
			try validateRateLimits(root)
			return nil
		case "response.done":
			return try consumeResponseDone(root)
		default:
			throw WebRTCTransportFailure.unsupportedEvent
		}
	}

	private enum CorrelationDisposition { case deliver, suppress }

	private func requireCorrelated(_ id: String) throws -> CorrelationDisposition {
		switch epoch {
		case let .active(active) where active == id: return .deliver
		case let .cancelling(active, _) where active == id: return .suppress
		default: throw WebRTCTransportFailure.providerError
		}
	}

	private mutating func consumeResponseDone(_ root: [String: StrictJSON]) throws -> OpenAIProductionEvent {
		let response = try root.requiredObject("response")
		let id = try response.requiredIdentifier("id")
		let status = try response.requiredString("status", maximumBytes: 64, nonempty: true)
		guard ["completed", "cancelled", "failed", "incomplete"].contains(status) else {
			throw WebRTCTransportFailure.malformedEvent
		}
		let code = try response.optionalObject("status_details")?.optionalObject("error")?.optionalBoundedString("code", maximumBytes: 128)
		if status == "completed" || status == "cancelled" {
			guard code == nil else { throw WebRTCTransportFailure.malformedEvent }
		} else if code == "" {
			throw WebRTCTransportFailure.malformedEvent
		}
		switch epoch {
		case let .active(active) where active == id:
			if status == "failed" || status == "incomplete" { throw WebRTCTransportFailure.providerError }
			epoch = .none
			return .responseFinished
		case let .cancelling(active, terminalObserved) where active == id:
			guard !terminalObserved else { throw WebRTCTransportFailure.providerError }
			if status == "failed" || status == "incomplete" { throw WebRTCTransportFailure.providerError }
			epoch = .cancelling(active, terminalObserved: true)
			return .cancellationTerminalObserved
		default:
			throw WebRTCTransportFailure.providerError
		}
	}

	private func validateAcknowledgement(_ root: [String: StrictJSON]) throws {
		let session = try root.requiredObject("session")
		let audio = try session.requiredObject("audio")
		let input = try audio.requiredObject("input")
		let transcription = try input.requiredObject("transcription")
		let vad = try input.requiredObject("turn_detection")
		let output = try audio.requiredObject("output")
		guard try session.requiredString("type", maximumBytes: 256 * 1024, nonempty: true) == "realtime",
			try session.requiredString("model", maximumBytes: 256 * 1024, nonempty: true) == "gpt-realtime-2.1",
			try transcription.requiredString("model", maximumBytes: 256 * 1024, nonempty: true) == "gpt-4o-mini-transcribe",
			try transcription.requiredString("language", maximumBytes: 256 * 1024, nonempty: true) == language,
			try vad.requiredString("type", maximumBytes: 256 * 1024, nonempty: true) == "server_vad",
			try vad.requiredFiniteNumber("threshold") == 0.5,
			try vad.requiredNonnegativeInteger("prefix_padding_ms") == 300,
			try vad.requiredNonnegativeInteger("silence_duration_ms") == 500,
			try vad.requiredBool("create_response"), try vad.requiredBool("interrupt_response"),
			try output.requiredString("voice", maximumBytes: 256 * 1024, nonempty: true) == "marin"
		else { throw WebRTCTransportFailure.providerError }
	}

	private func validateProviderError(_ root: [String: StrictJSON]) throws {
		let error = try root.requiredObject("error")
		_ = try error.requiredString("type", maximumBytes: 128, nonempty: true)
		for key in ["code", "param", "event_id"] { _ = try error.optionalNullableBoundedString(key, maximumBytes: 128, nonempty: true) }
	}

	private func validateConversationItem(_ root: [String: StrictJSON], done: Bool) throws {
		let item = try root.requiredObject("item")
		_ = try item.requiredIdentifier("id")
		guard try item.requiredString("type", maximumBytes: 256 * 1024, nonempty: true) == "message" else { throw WebRTCTransportFailure.unsupportedEvent }
		let role = try item.requiredString("role", maximumBytes: 256 * 1024, nonempty: true)
		let status = try item.optionalBoundedString("status", maximumBytes: 256 * 1024)
		guard status == nil || status == "in_progress" || status == "completed", !done || status == "completed" else { throw WebRTCTransportFailure.unsupportedEvent }
		let content = try item.requiredArray("content")
		guard role == "user" || role == "assistant", role == "assistant" || !content.isEmpty else { throw WebRTCTransportFailure.unsupportedEvent }
		for value in content {
			let object = try value.requiredObject()
			let type = try object.requiredString("type", maximumBytes: 256 * 1024, nonempty: true)
			guard role == "user" ? type == "input_audio" : (type == "audio" || type == "output_audio") else { throw WebRTCTransportFailure.unsupportedEvent }
		}
	}

	private func validateAssistantItem(_ item: [String: StrictJSON], done: Bool) throws {
		_ = try item.requiredIdentifier("id")
		guard try item.requiredString("type", maximumBytes: 256 * 1024, nonempty: true) == "message",
			try item.requiredString("role", maximumBytes: 256 * 1024, nonempty: true) == "assistant"
		else { throw WebRTCTransportFailure.unsupportedEvent }
		let status = try item.optionalBoundedString("status", maximumBytes: 256 * 1024)
		guard status == nil || status == "in_progress" || status == "completed", !done || status == "completed" else { throw WebRTCTransportFailure.unsupportedEvent }
		for value in try item.requiredArray("content") { try validateAudioPart(value.requiredObject()) }
	}

	private func validateAudioPart(_ part: [String: StrictJSON]) throws {
		let type = try part.requiredString("type", maximumBytes: 256 * 1024, nonempty: true)
		guard type == "audio" || type == "output_audio" else { throw WebRTCTransportFailure.unsupportedEvent }
	}

	private func validateResponseCoordinates(_ root: [String: StrictJSON]) throws {
		_ = try requireCorrelated(root.requiredIdentifier("response_id"))
		_ = try root.requiredIdentifier("item_id")
		_ = try root.requiredNonnegativeInteger("output_index")
		_ = try root.requiredNonnegativeInteger("content_index")
	}

	private func validateRateLimits(_ root: [String: StrictJSON]) throws {
		let limits = try root.requiredArray("rate_limits")
		guard limits.count <= 64 else { throw WebRTCTransportFailure.responseTooLarge }
		for value in limits {
			let limit = try value.requiredObject()
			_ = try limit.requiredString("name", maximumBytes: 64, nonempty: true)
			_ = try limit.requiredNonnegativeInteger("limit")
			_ = try limit.requiredNonnegativeInteger("remaining")
			guard try limit.requiredFiniteNumber("reset_seconds") >= 0 else { throw WebRTCTransportFailure.malformedEvent }
		}
	}

	private static func isStandardBase64(_ value: String) -> Bool {
		let bytes = Array(value.utf8)
		guard !bytes.isEmpty, bytes.count.isMultiple(of: 4) else { return false }
		for (index, byte) in bytes.enumerated() {
			let alphabet = (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47
			if alphabet { continue }
			guard byte == 61, index >= bytes.count - 2 else { return false }
		}
		if bytes[bytes.count - 2] == 61 { return bytes.last == 61 && bytes[bytes.count - 3] != 61 }
		if bytes.last == 61 { return bytes[bytes.count - 2] != 61 }
		return true
	}

	private static let knownTypes: Set<String> = [
		"session.created", "session.updated", "error",
		"input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed", "input_audio_buffer.cleared",
		"output_audio_buffer.started", "output_audio_buffer.stopped", "output_audio_buffer.cleared",
		"conversation.item.added", "conversation.item.created", "conversation.item.done",
		"conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.delta",
		"response.created", "response.output_item.added", "response.output_item.done", "response.content_part.added", "response.content_part.done",
		"response.output_audio.delta", "response.audio.delta", "response.output_audio.done", "response.output_audio_transcript.delta", "response.output_audio_transcript.done",
		"rate_limits.updated", "response.done"
	]

	private static let namedPaths: Set<String> = [
		"session.type", "session.model", "session.audio.input.transcription.model", "session.audio.input.transcription.language",
		"session.audio.input.turn_detection.type", "session.audio.input.turn_detection.threshold",
		"session.audio.input.turn_detection.prefix_padding_ms", "session.audio.input.turn_detection.silence_duration_ms",
		"session.audio.input.turn_detection.create_response", "session.audio.input.turn_detection.interrupt_response",
		"session.audio.output.voice", "error.type", "error.code", "error.param", "error.event_id",
		"item.id", "item.type", "item.status", "item.role", "item.content.type", "part.type",
		"response.id", "response.status", "response.status_details.error.code",
		"transcript", "item_id", "response_id", "output_index", "content_index", "delta", "rate_limits"
	]
}

package enum StrictJSON: Sendable {
	case object([String: StrictJSON]), array([StrictJSON]), string(String), number(String), bool(Bool), null

	package static func parse(_ data: Data) throws -> StrictJSON {
		var parser = Parser(bytes: Array(data))
		let value = try parser.value(depth: 0)
		parser.skipWhitespace()
		guard parser.index == parser.bytes.count else { throw WebRTCTransportFailure.malformedEvent }
		return value
	}

	package func requiredObject() throws -> [String: StrictJSON] {
		guard case let .object(value) = self else { throw WebRTCTransportFailure.malformedEvent }
		return value
	}

	private struct Parser {
		let bytes: [UInt8]
		var index = 0
		mutating func skipWhitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
		mutating func value(depth: Int) throws -> StrictJSON {
			guard depth <= 64 else { throw WebRTCTransportFailure.malformedEvent }
			skipWhitespace(); guard index < bytes.count else { throw WebRTCTransportFailure.malformedEvent }
			switch bytes[index] {
			case 123: return try object(depth: depth)
			case 91: return try array(depth: depth)
			case 34: return .string(try string())
			case 116: try literal("true"); return .bool(true)
			case 102: try literal("false"); return .bool(false)
			case 110: try literal("null"); return .null
			case 45, 48...57: return .number(try number())
			default: throw WebRTCTransportFailure.malformedEvent
			}
		}
		mutating func object(depth: Int) throws -> StrictJSON {
			index += 1; skipWhitespace(); var result: [String: StrictJSON] = [:]
			if consume(125) { return .object(result) }
			while true {
				skipWhitespace(); guard index < bytes.count, bytes[index] == 34 else { throw WebRTCTransportFailure.malformedEvent }
				let key = try string(); guard result[key] == nil else { throw WebRTCTransportFailure.malformedEvent }
				skipWhitespace(); guard consume(58) else { throw WebRTCTransportFailure.malformedEvent }
				result[key] = try value(depth: depth + 1); skipWhitespace()
				if consume(125) { return .object(result) }
				guard consume(44) else { throw WebRTCTransportFailure.malformedEvent }
			}
		}
		mutating func array(depth: Int) throws -> StrictJSON {
			index += 1; skipWhitespace(); var result: [StrictJSON] = []
			if consume(93) { return .array(result) }
			while true {
				result.append(try value(depth: depth + 1)); skipWhitespace()
				if consume(93) { return .array(result) }
				guard consume(44) else { throw WebRTCTransportFailure.malformedEvent }
			}
		}
		mutating func string() throws -> String {
			let start = index; index += 1; var escaped = false
			while index < bytes.count {
				let byte = bytes[index]
				if byte < 32 { throw WebRTCTransportFailure.malformedEvent }
				if escaped { escaped = false; index += 1; continue }
				if byte == 92 { escaped = true; index += 1; continue }
				if byte == 34 {
					index += 1
					do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
					catch { throw WebRTCTransportFailure.malformedEvent }
				}
				index += 1
			}
			throw WebRTCTransportFailure.malformedEvent
		}
		mutating func number() throws -> String {
			let start = index
			if consume(45) {}
			guard index < bytes.count else { throw WebRTCTransportFailure.malformedEvent }
			if consume(48) { if index < bytes.count, (48...57).contains(bytes[index]) { throw WebRTCTransportFailure.malformedEvent } }
			else { guard consumeDigits(firstMustBeNonzero: true) else { throw WebRTCTransportFailure.malformedEvent } }
			if consume(46) { guard consumeDigits(firstMustBeNonzero: false) else { throw WebRTCTransportFailure.malformedEvent } }
			if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
				index += 1; if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
				guard consumeDigits(firstMustBeNonzero: false) else { throw WebRTCTransportFailure.malformedEvent }
			}
			return String(decoding: bytes[start..<index], as: UTF8.self)
		}
		mutating func consumeDigits(firstMustBeNonzero: Bool) -> Bool {
			let start = index
			if firstMustBeNonzero { guard index < bytes.count, (49...57).contains(bytes[index]) else { return false } }
			while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
			return index > start
		}
		mutating func literal(_ literal: StaticString) throws {
			let target = Array(String(describing: literal).utf8)
			guard index + target.count <= bytes.count, Array(bytes[index..<index + target.count]) == target else { throw WebRTCTransportFailure.malformedEvent }
			index += target.count
		}
		mutating func consume(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
	}
}

private extension Dictionary where Key == String, Value == StrictJSON {
	func containsFlattenedConflict(namedPaths: Set<String>, prefix: String = "") -> Bool {
		contains { key, value in
			let path = prefix.isEmpty ? key : "\(prefix).\(key)"
			if key.contains("."), namedPaths.contains(path) { return true }
			switch value {
			case let .object(object): return object.containsFlattenedConflict(namedPaths: namedPaths, prefix: path)
			case let .array(values):
				return values.contains { value in
					if case let .object(object) = value {
						return object.containsFlattenedConflict(namedPaths: namedPaths, prefix: path)
					}
					return false
				}
			case .string, .number, .bool, .null: return false
			}
		}
	}
	func requiredObject(_ key: String) throws -> [String: StrictJSON] { guard let value = self[key] else { throw WebRTCTransportFailure.malformedEvent }; return try value.requiredObject() }
	func optionalObject(_ key: String) throws -> [String: StrictJSON]? { guard let value = self[key] else { return nil }; return try value.requiredObject() }
	func requiredArray(_ key: String) throws -> [StrictJSON] { guard case let .array(value)? = self[key] else { throw WebRTCTransportFailure.malformedEvent }; return value }
	func requiredString(_ key: String, maximumBytes: Int, nonempty: Bool) throws -> String {
		guard case let .string(value)? = self[key] else { throw WebRTCTransportFailure.malformedEvent }
		guard value.utf8.count <= maximumBytes else { throw WebRTCTransportFailure.responseTooLarge }
		guard !nonempty || !value.isEmpty else { throw WebRTCTransportFailure.malformedEvent }
		return value
	}
	func optionalBoundedString(_ key: String, maximumBytes: Int) throws -> String? { guard self[key] != nil else { return nil }; return try requiredString(key, maximumBytes: maximumBytes, nonempty: true) }
	func optionalNullableBoundedString(_ key: String, maximumBytes: Int, nonempty: Bool) throws -> String? { guard let value = self[key] else { return nil }; if case .null = value { return nil }; return try requiredString(key, maximumBytes: maximumBytes, nonempty: nonempty) }
	func requiredIdentifier(_ key: String) throws -> String { try requiredString(key, maximumBytes: 128, nonempty: true) }
	func requiredNonnegativeInteger(_ key: String) throws -> Int64 {
		guard case let .number(token)? = self[key], !token.contains("."), !token.contains("e"), !token.contains("E"), let value = Int64(token), value >= 0 else { throw WebRTCTransportFailure.malformedEvent }
		return value
	}
	func requiredFiniteNumber(_ key: String) throws -> Double { guard case let .number(token)? = self[key], let value = Double(token), value.isFinite else { throw WebRTCTransportFailure.malformedEvent }; return value }
	func requiredBool(_ key: String) throws -> Bool { guard case let .bool(value)? = self[key] else { throw WebRTCTransportFailure.malformedEvent }; return value }
}

private extension Optional where Wrapped == [String: StrictJSON] {
	func optionalObject(_ key: String) throws -> [String: StrictJSON]? { try self?.optionalObject(key) }
	func optionalBoundedString(_ key: String, maximumBytes: Int) throws -> String? { try self?.optionalBoundedString(key, maximumBytes: maximumBytes) }
}
