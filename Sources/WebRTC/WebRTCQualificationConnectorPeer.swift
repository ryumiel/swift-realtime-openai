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

/// Qualification-only media shape for a connector created outside the product path.
@_spi(AirbridgeQualification) public enum WebRTCConnectorQualificationMediaMode: Sendable, Equatable {
	/// Preserve the production connector's local microphone track and ordinary playout.
	case production
	/// Negotiate receive-only audio, create no local track, and suppress device playout.
	case receiveOnlyAudioEvidence
}

/// Capped, content-free evidence derived from inbound WebRTC statistics.
@_spi(AirbridgeQualification) public struct WebRTCConnectorQualificationAudioEvidence: Sendable, Equatable {
	public static let maximumReportedByteCount: UInt64 = 16 * 1024 * 1024
	public static let maximumReportedSampleCount: UInt64 = 1_000_000

	public let receivedByteCount: UInt64
	public let receivedSampleCount: UInt64
	public let limitExceeded: Bool

	public var hasReceivedAudio: Bool {
		receivedByteCount > 0 || receivedSampleCount > 0
	}

	public init(receivedByteCount: UInt64, receivedSampleCount: UInt64, limitExceeded: Bool) {
		self.receivedByteCount = min(receivedByteCount, Self.maximumReportedByteCount)
		self.receivedSampleCount = min(receivedSampleCount, Self.maximumReportedSampleCount)
		self.limitExceeded = limitExceeded
			|| receivedByteCount > Self.maximumReportedByteCount
			|| receivedSampleCount > Self.maximumReportedSampleCount
	}
}

/// Fixed, content-free milestones intended only for Airbridge's local qualification.
@_spi(AirbridgeQualification) public enum WebRTCConnectorDiagnosticMilestone: String, Sendable, Equatable, CaseIterable {
	case peerCreated
	case offerCreated
	case localDescriptionInstalled
	case iceGatheringComplete
	case iceGatheringTimedOut
	case remoteDescriptionInstalled
	case iceChecking
	case iceConnected
	case iceCompleted
	case iceDisconnected
	case iceFailed
	case iceClosed
	case peerConnecting
	case peerConnected
	case peerDisconnected
	case peerFailed
	case peerClosed
	case dataChannelConnecting
	case dataChannelOpen
	case dataChannelClosing
	case dataChannelClosed
	case remoteAudioTrackObserved
	case teardownBegan
	case teardownCompleted
}

@_spi(AirbridgeQualification) @MainActor public protocol WebRTCConnectorQualificationPeer: Sendable {
	var qualificationEvents: AsyncThrowingStream<WebRTCConnectorQualificationEvent, any Error> { get }
	func makeOffer() async throws -> String
	func apply(answer: String) async throws
	func send(event: ClientEvent) async throws
	func sendSessionUpdate(voice: String, language: String) async throws
	func remoteAudioEvidence() async throws -> WebRTCConnectorQualificationAudioEvidence
	func disconnect()
	func closeAndSettle() async
}

@_spi(AirbridgeQualification) @MainActor public extension WebRTCConnectorQualificationPeer {
	func sendSessionUpdate(voice _: String, language _: String) async throws {
		throw WebRTCTransportFailure.invalidRequest
	}

	func remoteAudioEvidence() async throws -> WebRTCConnectorQualificationAudioEvidence {
		throw WebRTCTransportFailure.invalidRequest
	}

	func closeAndSettle() async {
		disconnect()
	}
}

@_spi(AirbridgeQualification) @MainActor public struct WebRTCConnectorQualificationPeerFactory: Sendable {
	private let makePeerClosure: @MainActor @Sendable () throws -> any WebRTCConnectorQualificationPeer

	public init(
		session: any WebRTCSignalingSession = URLSessionWebRTCSignalingSession(),
		mediaMode: WebRTCConnectorQualificationMediaMode = .production,
		diagnosticSink: @escaping @Sendable (WebRTCConnectorDiagnosticMilestone) -> Void = { _ in }
	) {
		makePeerClosure = {
			try WebRTCConnector.createQualification(
				session: session,
				mediaMode: mediaMode,
				diagnosticSink: diagnosticSink
			)
		}
	}

	public init(makePeer: @escaping @MainActor @Sendable () throws -> any WebRTCConnectorQualificationPeer) {
		makePeerClosure = makePeer
	}

	public func makePeer() throws -> any WebRTCConnectorQualificationPeer {
		try makePeerClosure()
	}
}

@_spi(AirbridgeQualification) extension WebRTCConnector: WebRTCConnectorQualificationPeer {}
