import Foundation

public protocol DownloadDestination {
    /// Runs after finalization begins. Consume the temporary URL before invoking completion.
    func save(_ temporaryFile: URL, completion: @escaping (Result<[String: String], TransferFailure>) -> Void)
}

public struct FileDestination: DownloadDestination {
    public let url: URL
    public init(url: URL) throws {
        guard url.isFileURL else { throw TransferFailure("invalid_destination") }
        self.url = url
    }
    public func save(_ temporaryFile: URL, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) {
        let staged = url.deletingLastPathComponent().appendingPathComponent(".trasivo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            // Stage on the destination volume; link publishes a complete file without
            // replacing an existing path. The destination must be app-owned local storage.
            try FileManager.default.copyItem(at: temporaryFile, to: staged)
            try FileManager.default.linkItem(at: staged, to: url)
            completion(.success(["uri": url.absoluteString]))
        } catch { completion(.failure(TransferFailure("destination_failed"))) }
    }
}

public enum HTTPTransfers {
    public typealias RequestProvider = () throws -> URLRequest
    public typealias ResponseHandler = (HTTPURLResponse, Data) throws -> [String: String]

    public static func download(request: @escaping RequestProvider, destination: DownloadDestination) -> TransferOperation {
        DownloadOperation(request: request, destination: destination)
    }
    /// The provider returns a fresh file-backed body. The caller retains ownership of that file.
    public static func upload(request: @escaping RequestProvider, file: @escaping () throws -> URL,
                              validateResponse: @escaping ResponseHandler) -> TransferOperation {
        UploadOperation(request: request, file: file, validate: validateResponse)
    }
}

private final class DownloadOperation: TransferOperation {
    let request: HTTPTransfers.RequestProvider
    let destination: DownloadDestination
    init(request: @escaping HTTPTransfers.RequestProvider, destination: DownloadDestination) {
        self.request = request; self.destination = destination
    }
    func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation? {
        let request = try self.request()
        guard request.httpMethod == nil || request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Range") == nil else { throw TransferFailure("invalid_request") }
        try validateURL(request.url); try context.checkCanceled()
        let worker = DownloadWorker(context: context, destination: destination, completion: completion)
        worker.start(request); return worker
    }
}

private func validateURL(_ url: URL?) throws {
    guard let url = url, let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else {
        throw TransferFailure("invalid_url")
    }
}

private final class DownloadWorker: NSObject, URLSessionDownloadDelegate, TransferCancellation, @unchecked Sendable {
    let context: TransferContext
    let destination: DownloadDestination
    let completion: (Result<[String: String], TransferFailure>) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    private var deliveredFile = false
    init(context: TransferContext, destination: DownloadDestination,
         completion: @escaping (Result<[String: String], TransferFailure>) -> Void) {
        self.context = context; self.destination = destination; self.completion = completion
    }
    func start(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: request); task.resume()
    }
    func cancel() { task.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do { try context.progress(completedBytes: totalBytesWritten, totalBytes: max(-1, totalBytesExpectedToWrite)) }
        catch { task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        deliveredFile = true
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            completion(.failure(TransferFailure("http_\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)"))); return
        }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("trasivo-\(UUID().uuidString).part")
        do {
            try context.beginFinalization()
            try FileManager.default.moveItem(at: location, to: owned)
            destination.save(owned) { result in
                try? FileManager.default.removeItem(at: owned)
                self.completion(result)
            }
        } catch {
            try? FileManager.default.removeItem(at: owned)
            completion(.failure((error as? TransferFailure) ?? TransferFailure("download_failed")))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !deliveredFile { completion(.failure(TransferFailure(error == nil ? "empty_response" : "network_failed"))) }
        session.finishTasksAndInvalidate()
    }
}

private final class UploadOperation: TransferOperation {
    let request: HTTPTransfers.RequestProvider
    let file: () throws -> URL
    let validate: HTTPTransfers.ResponseHandler
    init(request: @escaping HTTPTransfers.RequestProvider, file: @escaping () throws -> URL,
         validate: @escaping HTTPTransfers.ResponseHandler) { self.request = request; self.file = file; self.validate = validate }
    func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation? {
        let request = try self.request(), file = try self.file()
        try validateURL(request.url)
        guard let method = request.httpMethod, !["GET", "HEAD"].contains(method), request.httpBody == nil,
              request.httpBodyStream == nil, file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else {
            throw TransferFailure("invalid_upload")
        }
        try context.checkCanceled()
        let worker = UploadWorker(context: context, validate: validate, completion: completion)
        worker.start(request, file: file); return worker
    }
}

private final class UploadWorker: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, TransferCancellation, @unchecked Sendable {
    let context: TransferContext
    let validate: HTTPTransfers.ResponseHandler
    let completion: (Result<[String: String], TransferFailure>) -> Void
    private var session: URLSession!
    private var task: URLSessionUploadTask!
    private var data = Data()
    private var failure: TransferFailure?
    init(context: TransferContext, validate: @escaping HTTPTransfers.ResponseHandler,
         completion: @escaping (Result<[String: String], TransferFailure>) -> Void) {
        self.context = context; self.validate = validate; self.completion = completion
    }
    func start(_ request: URLRequest, file: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.uploadTask(with: request, fromFile: file); task.resume()
    }
    func cancel() { task.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        do { try context.progress(completedBytes: totalBytesSent, totalBytes: max(-1, totalBytesExpectedToSend)) }
        catch { task.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > 1024 * 1024 {
            failure = TransferFailure("response_too_large"); task.cancel()
        } else { self.data.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let failure = failure { completion(.failure(failure)); return }
        if error != nil { completion(.failure(TransferFailure("network_failed"))); return }
        guard let response = task.response as? HTTPURLResponse else { completion(.failure(TransferFailure("empty_response"))); return }
        guard (200..<300).contains(response.statusCode) else {
            completion(.failure(TransferFailure("http_\(response.statusCode)"))); return
        }
        do {
            try context.beginFinalization()
            let result = try validate(response, data)
            completion(.success(result))
        } catch { completion(.failure((error as? TransferFailure) ?? TransferFailure("response_rejected"))) }
    }
}
