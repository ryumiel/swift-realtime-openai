import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor public protocol Connector: Sendable {
	var status: RealtimeAPI.Status { get }
	var events: AsyncThrowingStream<WebRTCInboundEvent, Error> { get }

	func disconnect()
	func send(event: ClientEvent) async throws
}
