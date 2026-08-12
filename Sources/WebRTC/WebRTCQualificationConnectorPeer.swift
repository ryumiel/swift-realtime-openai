import Core
import Foundation

/// SPI used only by Airbridge's hermetic qualification adapter. The default
/// factory creates the real `WebRTCConnector`; injected peers drive the same
/// offer/answer, event, command, and teardown boundary in focused tests.
@_spi(AirbridgeQualification) public enum WebRTCConnectorQualificationEvent: Sendable, Equatable {
	case connected
	case inbound(WebRTCInboundEvent)
	case terminal
}

@_spi(AirbridgeQualification) @MainActor public protocol WebRTCConnectorQualificationPeer: Sendable {
	var qualificationEvents: AsyncThrowingStream<WebRTCConnectorQualificationEvent, any Error> { get }
	func makeOffer() async throws -> String
	func apply(answer: String) async throws
	func send(event: ClientEvent) async throws
	func disconnect()
}

@_spi(AirbridgeQualification) @MainActor public struct WebRTCConnectorQualificationPeerFactory: Sendable {
	private let makePeerClosure: @MainActor @Sendable () throws -> any WebRTCConnectorQualificationPeer

	public init(session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession()) {
		makePeerClosure = { try WebRTCConnector.create(session: session) }
	}

	public init(makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorQualificationPeer) {
		makePeerClosure = makePeer
	}

	public func makePeer() throws -> any WebRTCConnectorQualificationPeer {
		try makePeerClosure()
	}
}

@_spi(AirbridgeQualification) extension WebRTCConnector: WebRTCConnectorQualificationPeer {}
