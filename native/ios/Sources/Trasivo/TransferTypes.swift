import Foundation

public enum TransferDirection: String { case upload, download }
public enum TransferState: String { case queued, running, finalizing, succeeded, failed, canceled }

public struct TransferRequest {
    public let title: String
    public let direction: TransferDirection
    public init(title: String, direction: TransferDirection) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TransferFailure("invalid_title") }
        self.title = title; self.direction = direction
    }
}

public struct TransferSnapshot {
    public let id: String
    public let attemptID: String
    public let title: String
    public let direction: TransferDirection
    public let state: TransferState
    public let completedBytes: Int64
    /// -1 means the response has no known length.
    public let totalBytes: Int64
    public let attempt: Int
    public let errorCode: String?
    public let result: [String: String]
    public var isActive: Bool { state == .queued || state == .running || state == .finalizing }
    public var canRetry: Bool { state == .failed || state == .canceled }
    public var canCancel: Bool { state == .queued || state == .running }
}

public struct TransferFailure: Error {
    public let code: String
    public init(_ code: String) { self.code = code.isEmpty ? "operation_failed" : code }
}

public protocol TransferCancellation { func cancel() }
public protocol TransferOperation {
    /// Start fresh on each call. Returning or calling completion synchronously is supported.
    func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation?
}

public final class TransferSubscription {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    public func cancel() {
        lock.lock(); let action = cancellation; cancellation = nil; lock.unlock(); action?()
    }
    deinit { cancel() }
}

public final class TransferContext {
    public let taskID: String
    public let attemptID: String
    private let center: TransferCenter
    init(center: TransferCenter, taskID: String, attemptID: String) {
        self.center = center; self.taskID = taskID; self.attemptID = attemptID
    }
    public var isCanceled: Bool { !center.isCurrent(self) }
    public func checkCanceled() throws { if isCanceled { throw TransferFailure("canceled") } }
    public func progress(completedBytes: Int64, totalBytes: Int64 = -1) throws {
        guard completedBytes >= 0, totalBytes >= -1, totalBytes < 0 || completedBytes <= totalBytes else {
            throw TransferFailure("invalid_progress")
        }
        center.progress(self, bytes: completedBytes, total: totalBytes)
    }
    /// Cancellation is disabled once externally visible result publication starts.
    public func beginFinalization() throws { try center.beginFinalization(self) }
}
