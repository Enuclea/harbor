import Foundation
import HarborLogging
import Observation

/// One upload or download shown in the flyout's transfer list.
@MainActor
@Observable
public final class Transfer: Identifiable {
    public enum Direction: Sendable { case upload, download }

    public enum State: Equatable {
        case queued, running, finished, cancelled
        case failed(String)
    }

    public let id = UUID()
    public let name: String
    public let direction: Direction
    public internal(set) var completed: Int64 = 0
    public internal(set) var total: Int64?
    public internal(set) var state: State = .queued
    /// The downloaded item, once finished.
    public internal(set) var resultURL: URL?

    @ObservationIgnored var task: Task<Void, Never>?

    init(name: String, direction: Direction) {
        self.name = name
        self.direction = direction
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return state == .finished ? 1 : nil }
        return min(1, Double(completed) / Double(total))
    }

    public var isActive: Bool { state == .queued || state == .running }
}

/// Runs transfers with bounded concurrency and publishes their progress (throttled so
/// a fast transfer can't flood the main thread).
@MainActor
@Observable
public final class TransferCenter {
    public private(set) var transfers: [Transfer] = []
    @ObservationIgnored private let maximumConcurrent: Int
    @ObservationIgnored private let log = Log(.sftp)

    public init(maximumConcurrent: Int = 3) {
        self.maximumConcurrent = maximumConcurrent
    }

    public var hasActiveTransfers: Bool { transfers.contains(where: \.isActive) }

    @discardableResult
    public func enqueue(
        name: String,
        direction: Transfer.Direction,
        operation: @escaping @Sendable (_ progress: @escaping TransferProgress) async throws -> URL?
    ) -> Transfer {
        let transfer = Transfer(name: name, direction: direction)
        transfers.insert(transfer, at: 0)
        transfer.task = Task { [weak self] in
            await self?.waitForSlot(transfer)
            guard transfer.state == .queued else { return }
            transfer.state = .running
            let throttle = ProgressThrottle()
            do {
                let url = try await operation { completed, total in
                    guard throttle.shouldReport() else { return }
                    Task { @MainActor in
                        transfer.completed = completed
                        transfer.total = total
                    }
                }
                transfer.resultURL = url
                if let total = transfer.total { transfer.completed = total }
                transfer.state = .finished
            } catch is CancellationError {
                transfer.state = .cancelled
            } catch {
                transfer.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                self?.log.warning("transfer \(name) failed: \(error.localizedDescription)")
            }
        }
        return transfer
    }

    public func cancel(_ transfer: Transfer) {
        transfer.task?.cancel()
        if transfer.state == .queued { transfer.state = .cancelled }
    }

    public func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    private func waitForSlot(_ transfer: Transfer) async {
        while transfers.filter({ $0.state == .running }).count >= maximumConcurrent, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Lets through at most ~20 progress updates per second.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldReport() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.05 else { return false }
            last = now
            return true
        }
    }
}
