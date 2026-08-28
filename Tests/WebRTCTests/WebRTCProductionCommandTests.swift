@testable import WebRTC
import Foundation
import XCTest

final class WebRTCProductionCommandTests: XCTestCase {
	func testCommandsEncodeOnlyTheFourPermittedProviderIntents() throws {
		let commands: [(ProductionCommand, String)] = [
			(.userText("hello"), "conversation.item.create"),
			(.createResponse, "response.create"),
			(.cancelResponse, "response.cancel"),
			(.clearOutputAudio, "output_audio_buffer.clear"),
		]

		for (command, expectedType) in commands {
			let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: command.encoded()) as? [String: Any])
			XCTAssertEqual(object["type"] as? String, expectedType)
			if expectedType == "conversation.item.create" {
				let item = try XCTUnwrap(object["item"] as? [String: Any])
				XCTAssertEqual(item["role"] as? String, "user")
				XCTAssertEqual(item["type"] as? String, "message")
				XCTAssertEqual(item["status"] as? String, "completed")
				let identifier = try XCTUnwrap(item["id"] as? String)
				XCTAssertEqual(identifier.utf8.count, 36)
				XCTAssertNotNil(UUID(uuidString: identifier))
				let content = try XCTUnwrap(item["content"] as? [[String: String]])
				XCTAssertEqual(content, [["type": "input_text", "text": "hello"]])
			}
		}
	}
}
