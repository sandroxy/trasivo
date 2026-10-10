#if os(macOS)
import XCTest
import Trasivo

final class HTTPTransfersTests: XCTestCase {
    private var server: Process!
    private var base: URL!
    override func setUpWithError() throws {
        let source = URL(fileURLWithPath: #filePath)
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [root.appendingPathComponent("tests/fixtures/server.py").path]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run()
        let data = pipe.fileHandleForReading.availableData
        guard let text = String(data: data, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TransferFailure("fixture_start_failed")
        }
        base = URL(string: "http://127.0.0.1:\(port)")!
    }
    override func tearDown() { if server?.isRunning == true { server.terminate(); server.waitUntilExit() } }
    private func awaitTask(_ center: TransferCenter) -> TransferSnapshot {
        let finished = expectation(description: "transfer finished")
        var result: TransferSnapshot?
        let subscription = center.observe { tasks in
            if let task = tasks.first, !task.isActive, result == nil { result = task; finished.fulfill() }
        }
        wait(for: [finished], timeout: 10); subscription.cancel()
        return result!
    }
    func testDownloadCommitsBytesBeforeSuccess() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let center = try TransferCenter()
        let url = base.appendingPathComponent("download")
        center.enqueue(try TransferRequest(title: "sample", direction: .download), operation:
            HTTPTransfers.download(request: { URLRequest(url: url) }, destination: try FileDestination(url: target)))
        XCTAssertEqual(awaitTask(center).state, .succeeded)
        XCTAssertEqual(try Data(contentsOf: target), Data(String(repeating: "trasivo-fixture\n", count: 1024).utf8))
    }
    func testHTTPFailureRetriesTheSameTaskWithAFreshRequest() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let center = try TransferCenter(), url = base.appendingPathComponent("retry")
        var requests = 0
        let id = center.enqueue(try TransferRequest(title: "sample", direction: .download), operation:
            HTTPTransfers.download(request: { requests += 1; return URLRequest(url: url) }, destination: try FileDestination(url: target)))
        let failed = awaitTask(center)
        XCTAssertEqual(failed.state, .failed); XCTAssertEqual(failed.errorCode, "http_503")
        XCTAssertTrue(failed.result.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(center.retry(id))
        let retried = awaitTask(center)
        XCTAssertEqual(retried.state, .succeeded); XCTAssertEqual(retried.id, failed.id)
        XCTAssertEqual(retried.attempt, 2); XCTAssertNotEqual(retried.attemptID, failed.attemptID)
        XCTAssertNil(retried.errorCode); XCTAssertEqual(requests, 2)
        XCTAssertEqual(try Data(contentsOf: target), Data(String(repeating: "trasivo-fixture\n", count: 1024).utf8))
    }
    func testCompletedNetworkBytesDoNotBypassDestinationFailure() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("existing file".utf8)
        try original.write(to: target); defer { try? FileManager.default.removeItem(at: target) }
        let center = try TransferCenter(), url = base.appendingPathComponent("download")
        let id = center.enqueue(try TransferRequest(title: "sample", direction: .download), operation:
            HTTPTransfers.download(request: { URLRequest(url: url) }, destination: try FileDestination(url: target)))
        let failed = awaitTask(center)
        XCTAssertEqual(failed.state, .failed); XCTAssertEqual(failed.errorCode, "destination_failed")
        XCTAssertGreaterThan(failed.completedBytes, 0); XCTAssertEqual(failed.completedBytes, failed.totalBytes)
        XCTAssertTrue(failed.result.isEmpty); XCTAssertEqual(try Data(contentsOf: target), original)
        // Remove only this test's deliberately conflicting file, then retry the same task.
        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(center.retry(id))
        let retried = awaitTask(center)
        XCTAssertEqual(retried.state, .succeeded); XCTAssertEqual(retried.id, id); XCTAssertEqual(retried.attempt, 2)
        XCTAssertEqual(try Data(contentsOf: target), Data(String(repeating: "trasivo-fixture\n", count: 1024).utf8))
    }
    func testCanceledNetworkDownloadDoesNotCommitAndCanRetry() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let center = try TransferCenter(), slow = base.appendingPathComponent("slow"), fast = base.appendingPathComponent("download")
        var requests = 0
        let id = center.enqueue(try TransferRequest(title: "sample", direction: .download), operation:
            HTTPTransfers.download(request: {
                requests += 1; return URLRequest(url: requests == 1 ? slow : fast)
            }, destination: try FileDestination(url: target)))
        let canceled = expectation(description: "cancel after actual network progress")
        var canceledOnce = false
        let subscription = center.observe { tasks in
            guard let task = tasks.first, task.state == .running, task.completedBytes > 0, !canceledOnce else { return }
            canceledOnce = true
            XCTAssertTrue(center.cancel(id)); canceled.fulfill()
        }
        wait(for: [canceled], timeout: 10); subscription.cancel()
        let first = center.snapshot()[0]
        XCTAssertEqual(first.state, .canceled)
        XCTAssertGreaterThan(first.completedBytes, 0); XCTAssertLessThan(first.completedBytes, first.totalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(center.retry(id))
        let retried = awaitTask(center)
        XCTAssertEqual(retried.state, .succeeded); XCTAssertEqual(retried.id, id); XCTAssertEqual(retried.attempt, 2)
        let expected = Data(String(repeating: "trasivo-fixture\n", count: 1024).utf8)
        XCTAssertEqual(requests, 2); XCTAssertEqual(retried.completedBytes, Int64(expected.count))
        XCTAssertEqual(try Data(contentsOf: target), expected)
    }
    func testHTTP200DoesNotBypassUploadValidation() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("upload-content".utf8).write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let center = try TransferCenter(), url = base.appendingPathComponent("rejected")
        center.enqueue(try TransferRequest(title: "sample", direction: .upload), operation:
            HTTPTransfers.upload(request: { var request = URLRequest(url: url); request.httpMethod = "POST"; return request }, file: { source }) { _, data in
                let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                guard value["success"] as? Bool == true else { throw TransferFailure("response_rejected") }
                return [:]
            })
        XCTAssertEqual(awaitTask(center).errorCode, "response_rejected")
    }
    func testFileUploadReportsServerDigestAndProgress() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 0x61, count: 192 * 1024)
        try payload.write(to: source); defer { try? FileManager.default.removeItem(at: source) }
        let center = try TransferCenter(), url = base.appendingPathComponent("upload")
        center.enqueue(try TransferRequest(title: "sample", direction: .upload), operation:
            HTTPTransfers.upload(request: { var request = URLRequest(url: url); request.httpMethod = "POST"; return request }, file: { source }) { _, data in
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["success"] as? Bool == true,
                      let digest = value["sha256"] as? String else { throw TransferFailure("response_rejected") }
                return ["sha256": digest]
            })
        let result = awaitTask(center)
        XCTAssertEqual(result.state, .succeeded)
        XCTAssertEqual(result.result["sha256"], "971c42be2544f01e31b726475ce57a67ec6b9a869a1aa084f8d4519819af0a84")
        XCTAssertEqual(result.completedBytes, Int64(payload.count)); XCTAssertEqual(result.totalBytes, Int64(payload.count))
    }
}
#endif
