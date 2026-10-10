import XCTest
@testable import Trasivo

final class TransferCenterTests: XCTestCase {
    final class Manual: TransferOperation {
        private let lock = NSLock()
        private var contexts: [TransferContext] = []
        private var completions: [(Result<[String: String], TransferFailure>) -> Void] = []
        var started: XCTestExpectation?
        func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation? {
            lock.lock(); contexts.append(context); completions.append(completion); lock.unlock()
            started?.fulfill(); return nil
        }
        func context(_ index: Int) -> TransferContext { lock.lock(); defer { lock.unlock() }; return contexts[index] }
        func complete(_ index: Int, _ value: Result<[String: String], TransferFailure>) {
            lock.lock(); let callback = completions[index]; lock.unlock(); callback(value)
        }
    }
    private func request() throws -> TransferRequest { try TransferRequest(title: "sample.bin", direction: .download) }
    func testSynchronousCompletionDoesNotCancelFinishedOperation() throws {
        final class Immediate: TransferOperation, TransferCancellation {
            var canceled = false
            func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation? {
                completion(.success([:])); return self
            }
            func cancel() { canceled = true }
        }
        let workers = DispatchQueue(label: "test.immediate"), operation = Immediate()
        let center = try TransferCenter(workers: workers)
        center.enqueue(try request(), operation: operation)
        workers.sync {}
        XCTAssertEqual(center.snapshot()[0].state, .succeeded)
        XCTAssertFalse(operation.canceled)
    }
    func testRetryIgnoresOldProgressAndCompletion() throws {
        let center = try TransferCenter(concurrency: 1), operation = Manual()
        operation.started = expectation(description: "started")
        let id = center.enqueue(try request(), operation: operation)
        wait(for: [operation.started!], timeout: 2)
        try operation.context(0).progress(completedBytes: 80, totalBytes: 100)
        XCTAssertTrue(center.cancel(id)); operation.started = expectation(description: "retried")
        XCTAssertTrue(center.retry(id)); wait(for: [operation.started!], timeout: 2)
        try operation.context(0).progress(completedBytes: 100, totalBytes: 100)
        operation.complete(0, .success(["uri": "wrong"]))
        XCTAssertEqual(center.snapshot()[0].state, .running); XCTAssertEqual(center.snapshot()[0].completedBytes, 0)
        XCTAssertNotEqual(operation.context(0).attemptID, operation.context(1).attemptID)
        operation.complete(1, .success(["uri": "correct"]))
        XCTAssertEqual(center.snapshot()[0].result["uri"], "correct")
    }
    func testFinalizationRejectsCancellationAndDoesNotCompleteEarly() throws {
        let center = try TransferCenter(), operation = Manual()
        operation.started = expectation(description: "started")
        let id = center.enqueue(try request(), operation: operation)
        wait(for: [operation.started!], timeout: 2)
        try operation.context(0).beginFinalization()
        XCTAssertEqual(center.snapshot()[0].state, .finalizing); XCTAssertFalse(center.cancel(id))
        XCTAssertFalse(center.retry(id)); operation.complete(0, .failure(TransferFailure("destination_failed")))
        XCTAssertEqual(center.snapshot()[0].state, .failed)
    }
    func testCanceledQueuedTaskNeverStarts() throws {
        let workers = DispatchQueue(label: "test.workers")
        let center = try TransferCenter(concurrency: 1, workers: workers), first = Manual(), second = Manual()
        first.started = expectation(description: "first")
        center.enqueue(try request(), operation: first)
        let id = center.enqueue(try request(), operation: second)
        wait(for: [first.started!], timeout: 2)
        XCTAssertTrue(center.cancel(id)); first.complete(0, .success([:]))
        workers.sync {}
        XCTAssertEqual(center.snapshot()[1].state, .canceled)
    }
    func testUnsubscribeDropsPendingCallbacksWithoutCancelingTask() throws {
        let callbacks = DispatchQueue(label: "test.callbacks"); callbacks.suspend()
        let center = try TransferCenter(callbacks: callbacks)
        var received = 0
        let subscription = center.observe { _ in received += 1 }
        center.enqueue(try request(), operation: Manual())
        subscription.cancel(); callbacks.resume(); callbacks.sync {}
        XCTAssertEqual(received, 0); XCTAssertTrue(center.snapshot()[0].isActive)
    }
    func testTerminalResultCannotBeOverwritten() throws {
        let center = try TransferCenter(), operation = Manual()
        operation.started = expectation(description: "started")
        center.enqueue(try request(), operation: operation)
        wait(for: [operation.started!], timeout: 2)
        operation.complete(0, .success(["uri": "saved"])); operation.complete(0, .failure(TransferFailure("late_error")))
        XCTAssertEqual(center.snapshot()[0].state, .succeeded)
    }
    func testIndependentObserversReattachToTheSameRetriedTask() throws {
        let callbacks = DispatchQueue(label: "test.observers"), workers = DispatchQueue(label: "test.operations")
        let center = try TransferCenter(callbacks: callbacks, workers: workers), operation = Manual()
        let id = center.enqueue(try request(), operation: operation)
        workers.sync {}
        var resource: [[TransferSnapshot]] = [], panel: [[TransferSnapshot]] = []
        var resourceSubscription = center.observe { resource.append($0) }
        var panelSubscription = center.observe { panel.append($0) }
        try operation.context(0).progress(completedBytes: 40, totalBytes: 100)
        callbacks.sync {
            XCTAssertEqual(resource.last?.first?.completedBytes, 40)
            XCTAssertEqual(panel.last?.first?.completedBytes, 40)
        }
        panelSubscription.cancel()
        let detachedCount = callbacks.sync { panel.count }
        XCTAssertTrue(center.cancel(id)); XCTAssertTrue(center.retry(id)); workers.sync {}
        callbacks.sync { XCTAssertEqual(panel.count, detachedCount) }
        panelSubscription = center.observe { panel.append($0) }
        callbacks.sync {
            XCTAssertEqual(panel.last?.first?.id, id)
            XCTAssertEqual(panel.last?.first?.attempt, 2)
            XCTAssertEqual(resource.last?.first?.attemptID, panel.last?.first?.attemptID)
        }
        resourceSubscription.cancel()
        let hiddenCount = callbacks.sync { resource.count }
        operation.complete(1, .success(["uri": "saved"]))
        callbacks.sync {
            XCTAssertEqual(resource.count, hiddenCount)
            XCTAssertEqual(panel.last?.first?.state, .succeeded)
        }
        resourceSubscription = center.observe { resource.append($0) }
        callbacks.sync { XCTAssertEqual(resource.last?.first?.result["uri"], "saved") }
        XCTAssertEqual(center.snapshot().count, 1)
        XCTAssertEqual(center.snapshot()[0].attempt, 2)
        resourceSubscription.cancel(); panelSubscription.cancel()
    }
    func testMultipartWritesLargeBodyWithoutChangingSource() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 0x61, count: 192 * 1024)
        try payload.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let body = try MultipartBody(file: source, field: "file", filename: "sample.bin", mimeType: "application/octet-stream", fields: ["caption": "测试"])
        let output = try Data(contentsOf: body.fileURL)
        XCTAssertNotNil(output.range(of: payload)); XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertNotNil(output.range(of: Data("测试".utf8)))
        XCTAssertThrowsError(try MultipartBody(file: source, field: "file\r\nInjected", filename: "a", mimeType: "text/plain"))
    }
    func testFileDestinationRefusesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), target = directory.appendingPathComponent("target")
        try Data("replacement".utf8).write(to: source); try Data("original".utf8).write(to: target)
        try FileDestination(url: target).save(source) { result in
            if case .success = result { XCTFail("Overwrote existing file") }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }
}
