import Foundation

/// The single-consumer, bounded event sequence for a production connector peer.
///
/// The sequence owns the peer's only semantic mailbox. Terminal selection clears
/// queued events and prevents later delivery. Cancelling a suspended `next()`
/// joins peer settlement before the cancellation is returned to the caller.
public struct WebRTCConnectorEventStream: AsyncSequence, Sendable {
	public typealias Element = WebRTCConnectorEvent

	public struct AsyncIterator: AsyncIteratorProtocol {
		fileprivate let storage: Storage
		fileprivate let claimed: Bool

		public mutating func next() async throws -> WebRTCConnectorEvent? {
			guard claimed else { throw WebRTCTransportFailure.invalidRequest }
			let storage = storage
			let delivery = await withTaskCancellationHandler {
				await storage.nextDelivery()
			} onCancel: {
				storage.cancelIterator()
			}
			defer { storage.complete(delivery) }
			switch delivery.value {
			case let .event(event): return event
			case let .failure(failure): throw failure
			case .cancelled:
				await storage.joinCancellationSettlement()
				throw WebRTCTransportFailure.cancelled
			case .end: return nil
			}
		}
	}

	package let storage: Storage

	package init(storage: Storage) { self.storage = storage }

	public func makeAsyncIterator() -> AsyncIterator {
		AsyncIterator(storage: storage, claimed: storage.claimIterator())
	}
}

extension WebRTCConnectorEventStream {
	package final class Storage: @unchecked Sendable {
		fileprivate enum Value {
			case event(WebRTCConnectorEvent)
			case failure(WebRTCTransportFailure)
			case cancelled
			case end
		}

		fileprivate struct Delivery {
			let value: Value
			let admitted: Bool
			let ownsNext: Bool

			init(value: Value, admitted: Bool, ownsNext: Bool = true) {
				self.value = value
				self.admitted = admitted
				self.ownsNext = ownsNext
			}
		}

		private enum Phase {
			case open
			case closing
			case terminal(failure: WebRTCTransportFailure?, delivered: Bool)
		}

		private static let capacity = 2
		private let lock = NSLock()
		private var phase: Phase = .open
		private var pending: [WebRTCConnectorEvent] = []
		private var waiter: CheckedContinuation<Delivery, Never>?
		private var admittedDeliveries = 0
		private var admittedDrainWaiter: CheckedContinuation<Void, Never>?
		private var iteratorClaimed = false
		private var nextInFlight = false
		private var iteratorCancelled = false
		private var cancellationSettlement: Task<Void, Never>?
		private var cancellationHandler: (@Sendable () -> Task<Void, Never>)?
		private var ownerProvider: (@Sendable () -> AnyObject?)?
		private var suspendedOwner: AnyObject?

		func installCancellationHandler(
			owner: @escaping @Sendable () -> AnyObject?,
			_ handler: @escaping @Sendable () -> Task<Void, Never>
		) {
			lock.withLock {
				ownerProvider = owner
				cancellationHandler = handler
			}
		}

		func claimIterator() -> Bool {
			lock.withLock {
				guard !iteratorClaimed else { return false }
				iteratorClaimed = true
				return true
			}
		}

		func offer(_ event: WebRTCConnectorEvent) -> Bool {
			var resume: CheckedContinuation<Delivery, Never>?
			let accepted = lock.withLock { () -> Bool in
				guard case .open = phase, !iteratorCancelled else { return false }
				if let waiting = waiter {
					waiter = nil
					admittedDeliveries += 1
					resume = waiting
					return true
				}
				guard pending.count < Self.capacity else { return false }
				pending.append(event)
				return true
			}
			resume?.resume(returning: Delivery(value: .event(event), admitted: true))
			return accepted
		}

		func beginTerminalSelection() {
			lock.withLock {
				guard case .open = phase else { return }
				phase = .closing
				pending.removeAll(keepingCapacity: false)
			}
		}

		func finish(failure: WebRTCTransportFailure?) {
			var resume: CheckedContinuation<Delivery, Never>?
			let delivery = Delivery(value: failure.map(Value.failure) ?? .event(.closed), admitted: false)
			lock.withLock {
				guard case .terminal = phase else {
					phase = .terminal(failure: failure, delivered: waiter != nil)
					pending.removeAll(keepingCapacity: false)
					resume = waiter
					waiter = nil
					return
				}
			}
			resume?.resume(returning: delivery)
		}

		fileprivate func nextDelivery() async -> Delivery {
			await withCheckedContinuation { continuation in
				var immediate: Delivery?
				lock.withLock {
					guard !nextInFlight else {
						immediate = Delivery(value: .failure(.invalidRequest), admitted: false, ownsNext: false)
						return
					}
					nextInFlight = true
					if iteratorCancelled {
						immediate = Delivery(value: .cancelled, admitted: false)
						return
					}
					if !pending.isEmpty {
						let event = pending.removeFirst()
						admittedDeliveries += 1
						immediate = Delivery(value: .event(event), admitted: true)
						return
					}
					switch phase {
					case .open, .closing:
						suspendedOwner = ownerProvider?()
						waiter = continuation
					case let .terminal(failure, delivered):
						if delivered { immediate = Delivery(value: .end, admitted: false) }
						else {
							phase = .terminal(failure: failure, delivered: true)
							immediate = Delivery(value: failure.map(Value.failure) ?? .event(.closed), admitted: false)
						}
					}
				}
				if let immediate { continuation.resume(returning: immediate) }
			}
		}

		fileprivate func complete(_ delivery: Delivery) {
			guard delivery.ownsNext else { return }
			var resumeDrain: CheckedContinuation<Void, Never>?
			lock.withLock {
				nextInFlight = false
				suspendedOwner = nil
				if delivery.admitted {
					admittedDeliveries = Swift.max(0, admittedDeliveries - 1)
					if admittedDeliveries == 0 {
						resumeDrain = admittedDrainWaiter
						admittedDrainWaiter = nil
					}
				}
			}
			resumeDrain?.resume()
		}

		func waitForAdmittedDeliveries() async {
			await withCheckedContinuation { continuation in
				let immediate = lock.withLock { () -> Bool in
					guard admittedDeliveries != 0 else { return true }
					admittedDrainWaiter = continuation
					return false
				}
				if immediate { continuation.resume() }
			}
		}

		func cancelIterator() {
			var resume: CheckedContinuation<Delivery, Never>?
			var handler: (@Sendable () -> Task<Void, Never>)?
			lock.withLock {
				guard !iteratorCancelled else { return }
				iteratorCancelled = true
				if case .open = phase { phase = .closing }
				pending.removeAll(keepingCapacity: false)
				resume = waiter
				waiter = nil
				handler = cancellationHandler
			}
			let task = handler?()
			if let task { lock.withLock { cancellationSettlement = task } }
			resume?.resume(returning: Delivery(value: .cancelled, admitted: false))
		}

		func joinCancellationSettlement() async {
			let task = lock.withLock { cancellationSettlement }
			await task?.value
		}
	}
}
