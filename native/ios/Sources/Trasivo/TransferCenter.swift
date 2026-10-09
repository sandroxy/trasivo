import Foundation

/// Own one center per application/account lifetime. Task history is in-process only.
public final class TransferCenter {
    private final class Entry {
        let id = UUID().uuidString
        let request: TransferRequest
        let operation: TransferOperation
        var attemptID = UUID().uuidString
        var state: TransferState = .queued
        var bytes: Int64 = 0, total: Int64 = -1
        var attempt = 1
        var error: String?
        var result: [String: String] = [:]
        var cancellation: TransferCancellation?
        var lastProgress: UInt64 = 0
        init(_ request: TransferRequest, _ operation: TransferOperation) { self.request = request; self.operation = operation }
        var snapshot: TransferSnapshot {
            TransferSnapshot(id: id, attemptID: attemptID, title: request.title, direction: request.direction,
                             state: state, completedBytes: bytes, totalBytes: total, attempt: attempt,
                             errorCode: error, result: result)
        }
    }
    private final class Watch {
        private let lock = NSLock()
        private var active = true
        let observer: ([TransferSnapshot]) -> Void
        init(_ observer: @escaping ([TransferSnapshot]) -> Void) { self.observer = observer }
        func cancel() { lock.lock(); active = false; lock.unlock() }
        func send(_ tasks: [TransferSnapshot]) {
            lock.lock(); let enabled = active; lock.unlock()
            if enabled { observer(tasks) }
        }
    }
    private let queue = DispatchQueue(label: "io.github.sandroxy.trasivo.state")
    private let workers: DispatchQueue
    private let callbacks: DispatchQueue
    private let concurrency: Int
    private let historyLimit: Int
    private var entries: [Entry] = []
    private var watches: [UUID: Watch] = [:]

    public init(concurrency: Int = 3, historyLimit: Int = 200,
                callbacks: DispatchQueue = .main, workers: DispatchQueue = .global(qos: .utility)) throws {
        guard concurrency > 0, historyLimit > 0 else { throw TransferFailure("invalid_limits") }
        self.concurrency = concurrency; self.historyLimit = historyLimit
        self.callbacks = callbacks; self.workers = workers
    }
    @discardableResult public func enqueue(_ request: TransferRequest, operation: TransferOperation) -> String {
        let entry = Entry(request, operation)
        queue.sync { entries.append(entry); schedule() }
        return entry.id
    }
    public func snapshot() -> [TransferSnapshot] { queue.sync { entries.map(\.snapshot) } }
    public func observe(_ observer: @escaping ([TransferSnapshot]) -> Void) -> TransferSubscription {
        let id = UUID(), watch = Watch(observer)
        queue.sync { watches[id] = watch; dispatch(watch, entries.map(\.snapshot)) }
        return TransferSubscription { [weak self] in
            watch.cancel()
            self?.queue.async { [weak self] in self?.watches.removeValue(forKey: id) }
        }
    }
    @discardableResult public func retry(_ id: String) -> Bool {
        queue.sync {
            guard let entry = entries.first(where: { $0.id == id }), entry.snapshot.canRetry else { return false }
            entry.attempt += 1; entry.attemptID = UUID().uuidString
            entry.state = .queued; entry.bytes = 0; entry.total = -1; entry.error = nil
            entry.result = [:]; entry.cancellation = nil; entry.lastProgress = 0
            schedule(); return true
        }
    }
    @discardableResult public func cancel(_ id: String) -> Bool {
        var cancellation: TransferCancellation?
        let accepted = queue.sync { () -> Bool in
            guard let entry = entries.first(where: { $0.id == id }), entry.snapshot.canCancel else { return false }
            entry.state = .canceled; cancellation = entry.cancellation; entry.cancellation = nil
            schedule(); return true
        }
        cancellation?.cancel(); return accepted
    }
    @discardableResult public func remove(_ id: String) -> Bool {
        queue.sync {
            guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].snapshot.isActive else { return false }
            entries.remove(at: index); emit(); return true
        }
    }
    private func current(_ context: TransferContext) -> Entry? {
        entries.first { $0.id == context.taskID && $0.attemptID == context.attemptID && ($0.state == .running || $0.state == .finalizing) }
    }
    func isCurrent(_ context: TransferContext) -> Bool { queue.sync { current(context) != nil } }
    func progress(_ context: TransferContext, bytes: Int64, total: Int64) {
        queue.sync {
            guard let entry = current(context), entry.state == .running, bytes >= entry.bytes else { return }
            entry.bytes = bytes; entry.total = total
            let now = DispatchTime.now().uptimeNanoseconds
            if now - entry.lastProgress >= 150_000_000 { entry.lastProgress = now; emit() }
        }
    }
    func beginFinalization(_ context: TransferContext) throws {
        try queue.sync {
            guard let entry = current(context) else { throw TransferFailure("canceled") }
            entry.state = .finalizing; emit()
        }
    }
    private func schedule() {
        var active = entries.filter { $0.state == .running || $0.state == .finalizing }.count
        for entry in entries where entry.state == .queued {
            if active >= concurrency { break }
            active += 1; entry.state = .running
            let context = TransferContext(center: self, taskID: entry.id, attemptID: entry.attemptID)
            workers.async { self.start(entry.operation, context: context) }
        }
        var excess = entries.filter { !$0.snapshot.isActive }.count - historyLimit
        entries.removeAll { entry in
            if excess > 0 && !entry.snapshot.isActive { excess -= 1; return true }
            return false
        }
        emit()
    }
    private func start(_ operation: TransferOperation, context: TransferContext) {
        guard isCurrent(context) else { return }
        let completionLock = NSLock()
        var completed = false
        do {
            let cancellation = try operation.start(context: context) {
                completionLock.lock(); completed = true; completionLock.unlock()
                self.finish(context, result: $0)
            }
            let ended = queue.sync { () -> Bool in
                guard let entry = current(context) else { return true }
                entry.cancellation = cancellation; return false
            }
            completionLock.lock(); let needsCancellation = ended && !completed; completionLock.unlock()
            if needsCancellation { cancellation?.cancel() }
        } catch { finish(context, result: .failure((error as? TransferFailure) ?? TransferFailure("operation_failed"))) }
    }
    private func finish(_ context: TransferContext, result: Result<[String: String], TransferFailure>) {
        queue.sync {
            guard let entry = current(context) else { return }
            entry.cancellation = nil
            switch result {
            case .success(let value): entry.state = .succeeded; entry.result = value
            case .failure(let error): entry.state = .failed; entry.error = error.code
            }
            schedule()
        }
    }
    private func emit() {
        let tasks = entries.map(\.snapshot)
        for watch in watches.values { dispatch(watch, tasks) }
    }
    private func dispatch(_ watch: Watch, _ tasks: [TransferSnapshot]) { callbacks.async { watch.send(tasks) } }
}
