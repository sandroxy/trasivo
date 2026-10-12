import Foundation
import UIKit
import Trasivo
import TrasivoStorage
import TrasivoUI

/// Owns one RN runtime's center. Mutable bridge state is confined to the main queue.
@objc public final class TrasivoReactNativeCoordinator: NSObject {
    // Fixed positive native defaults cannot fail validation.
    fileprivate let center = try! TransferCenter()
    private let emitEvent: (String) -> Void
    private let presenter: () -> UIViewController?
    private var subscription: TransferSubscription?
    private var clients: [String: String] = [:]
    private var pending: [String: Pending] = [:]
    private var session: String?
    private var revision = 0
    fileprivate var closed = false
    private var overlay: TransferOverlay?

    @objc(initWithEmit:presenter:)
    public init(emit: @escaping (String) -> Void, presenter: @escaping () -> UIViewController?) {
        self.emitEvent = emit; self.presenter = presenter
        super.init()
        subscription = center.observe { [weak self] _ in
            guard let self = self, !self.closed, self.session != nil else { return }
            self.emit(self.snapshot())
        }
    }

    @objc public func execute(_ payload: String, completion: @escaping (String?, String?) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard !closed, payload.utf8.count <= 2 * 1024 * 1024,
                  let command = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw BridgeError.invalid }
            let op = try string(command, "op"), owner = try string(command, "session", limit: 200)
            if op == "open", session == nil { session = owner }
            guard owner == session else { completion(nil, "runtime_mismatch"); return }
            let result: Any
            switch op {
            case "open", "snapshot": result = snapshot()
            case "enqueue":
                let client = try string(command, "clientId", limit: 240)
                guard !clients.values.contains(client),
                      let direction = TransferDirection(rawValue: try string(command, "direction")) else { throw BridgeError.invalid }
                let request = try TransferRequest(title: string(command, "title", limit: 512), direction: direction)
                let id = center.enqueue(request, operation: BridgeOperation(owner: self, client: client, upload: direction == .upload))
                clients[id] = client; result = ["id": id, "snapshot": snapshot()] as [String: Any]
            case "reply":
                if let callback = pending.removeValue(forKey: try string(command, "token")) {
                    callback.timeout.cancel()
                    if let error = command["errorCode"] as? String {
                        callback.attempt.fail(error.range(of: "^[a-z][a-z0-9_]{0,127}$", options: .regularExpression) != nil ? error : "operation_failed")
                    } else {
                        do { try callback.accept(object(command, "value")) }
                        catch { callback.attempt.fail(callback.kind == "prepare" ? "request_failed" : "response_rejected") }
                    }
                    result = true
                } else { result = false }
            case "retry": result = center.retry(try string(command, "id"))
            case "cancel": result = center.cancel(try string(command, "id"))
            case "remove": result = center.remove(try string(command, "id"))
            case "clear":
                guard !center.snapshot().contains(where: { $0.isActive }) else { completion(nil, "tasks_active"); return }
                for task in center.snapshot() { _ = center.remove(task.id) }
                result = NSNull()
            case "mediaPermission":
                PhotoLibraryAccess.request { allowed in
                    DispatchQueue.main.async { completion(allowed ? "true" : "false", nil) }
                }
                return
            case "presentation":
                guard let visible = command["visible"] as? Bool else { throw BridgeError.invalid }
                let configuration = try uiConfiguration(object(command, "configuration"))
                if visible {
                    if overlay == nil {
                        guard let controller = presenter(), let window = controller.view.window else { throw BridgeError.invalid }
                        overlay = TransferOverlay(center: center, parent: window, presenter: controller, configuration: configuration)
                    } else { overlay?.updateConfiguration(configuration) }
                } else { overlay?.close(); overlay = nil }
                result = NSNull()
            case "panel":
                guard let overlay = overlay else { throw BridgeError.invalid }
                overlay.showPanel(); result = NSNull()
            default: throw BridgeError.invalid
            }
            completion(try encode(result), nil)
        } catch { completion(nil, "invalid_operation") }
    }

    private func snapshot() -> [String: Any] {
        let tasks = center.snapshot()
        let ids = Set(tasks.map(\.id)); clients = clients.filter { ids.contains($0.key) }
        revision += 1
        return ["kind": "snapshot", "revision": revision, "tasks": tasks.map { task -> [String: Any] in
            ["id": task.id, "attemptId": task.attemptID, "clientId": clients[task.id] ?? "",
             "title": task.title, "direction": task.direction.rawValue, "state": task.state.rawValue,
             "completedBytes": task.completedBytes,
             "totalBytes": task.totalBytes < 0 ? NSNull() : NSNumber(value: task.totalBytes),
             "attempt": task.attempt, "errorCode": task.errorCode.map { $0 as Any } ?? NSNull(),
             "result": task.result, "canRetry": task.canRetry, "canCancel": task.canCancel, "isActive": task.isActive]
        }]
    }
    fileprivate func emit(_ value: [String: Any]) {
        guard !closed, let session = session else { return }
        var event = value; event["session"] = session
        if let json = try? encode(event) { emitEvent(json) }
    }
    private struct Pending {
        let attempt: BridgeAttempt
        let kind: String
        let timeout: DispatchWorkItem
        let accept: ([String: Any]) throws -> Void
    }
    fileprivate func ask(_ attempt: BridgeAttempt, kind: String, response: [String: Any]?, accept: @escaping ([String: Any]) throws -> Void) {
        guard !attempt.finished else { return }
        guard !closed else { attempt.fail("host_unavailable"); return }
        guard !attempt.context.isCanceled else { attempt.cancel(); return }
        let token = UUID().uuidString
        let timeout = DispatchWorkItem { [weak self, weak attempt] in
            guard let self = self, self.pending.removeValue(forKey: token) != nil else { return }
            self.emit(["kind": "expired", "token": token]); attempt?.fail("host_timeout")
        }
        pending[token] = Pending(attempt: attempt, kind: kind, timeout: timeout, accept: accept)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        emit(["kind": kind, "token": token, "clientId": attempt.client,
              "taskId": attempt.context.taskID, "attemptId": attempt.context.attemptID,
              "response": response.map { $0 as Any } ?? NSNull()])
    }
    fileprivate func release(_ attempt: BridgeAttempt) {
        let tokens = pending.filter { $0.value.attempt === attempt }.map(\.key)
        for token in tokens {
            pending.removeValue(forKey: token)?.timeout.cancel()
            emit(["kind": "expired", "token": token])
        }
    }
    @objc public func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true; overlay?.close(); overlay = nil; subscription?.cancel(); subscription = nil
        for task in center.snapshot() where task.canCancel { _ = center.cancel(task.id) }
        for callback in Array(pending.values) { callback.attempt.fail("host_unavailable") }
        pending.removeAll(); clients.removeAll()
    }
}

private final class BridgeOperation: TransferOperation {
    weak var owner: TrasivoReactNativeCoordinator?
    let client: String, upload: Bool
    init(owner: TrasivoReactNativeCoordinator, client: String, upload: Bool) { self.owner = owner; self.client = client; self.upload = upload }
    func start(context: TransferContext, completion: @escaping (Result<[String: String], TransferFailure>) -> Void) throws -> TransferCancellation? {
        let attempt = BridgeAttempt(owner: owner, client: client, upload: upload, context: context, completion: completion)
        DispatchQueue.main.async { attempt.prepare() }
        return attempt
    }
}

fileprivate final class BridgeAttempt: TransferCancellation {
    weak var owner: TrasivoReactNativeCoordinator?
    let client: String, upload: Bool, context: TransferContext
    let completion: (Result<[String: String], TransferFailure>) -> Void
    var finished = false
    private var network: TransferCancellation?
    init(owner: TrasivoReactNativeCoordinator?, client: String, upload: Bool, context: TransferContext,
         completion: @escaping (Result<[String: String], TransferFailure>) -> Void) {
        self.owner = owner; self.client = client; self.upload = upload; self.context = context; self.completion = completion
    }
    func prepare() {
        guard let owner = owner else { fail("host_unavailable"); return }
        owner.ask(self, kind: "prepare", response: nil) { value in
            DispatchQueue.global(qos: .utility).async { self.start(value) }
        }
    }
    private func start(_ value: [String: Any]) {
        do {
            try context.checkCanceled()
            var request = try httpRequest(value)
            let operation: TransferOperation
            var body: MultipartBody?
            var response: [String: Any]?
            if upload {
                let input = try object(value, "body"), source = try fileURL(string(input, "uri"))
                guard FileManager.default.isReadableFile(atPath: source.path) else { throw BridgeError.invalid }
                let mime = try string(input, "mimeType", limit: 200)
                guard mime.contains("/"), mime.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw BridgeError.invalid }
                let method: String
                if value["method"] == nil { method = "POST" }
                else { method = try string(value, "method", limit: 10) }
                guard ["POST", "PUT", "PATCH"].contains(method) else { throw BridgeError.invalid }
                request.httpMethod = method
                var file = source
                if input["multipart"] != nil {
                    let form = try object(input, "multipart")
                    let multipart = try MultipartBody(file: source, field: string(form, "fieldName", limit: 200),
                        filename: filename(string(form, "filename")), mimeType: mime, fields: strings(form["fields"]))
                    body = multipart; file = multipart.fileURL
                    request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
                } else { request.setValue(mime, forHTTPHeaderField: "Content-Type") }
                let prepared = request, uploadFile = file
                operation = HTTPTransfers.upload(request: { prepared }, file: { uploadFile }) { result, data in
                    var headers: [String: String] = [:]
                    for (key, value) in result.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
                    response = ["status": result.statusCode, "headers": headers, "body": String(decoding: data, as: UTF8.self)]
                    return [:]
                }
            } else {
                request.httpMethod = "GET"
                let output = try object(value, "destination"), kind = try string(output, "kind")
                let destination: DownloadDestination
                if kind == "file" { destination = try FileDestination(url: fileURL(string(output, "uri"))) }
                else if kind == "media" {
                    let media = try string(output, "media"), mime = try string(output, "mimeType", limit: 200)
                    guard ["image", "video"].contains(media), mime.hasPrefix(media + "/") else { throw BridgeError.invalid }
                    destination = try PhotoLibraryDestination(media: media == "image" ? .image : .video, filename: filename(string(output, "filename")))
                } else { throw BridgeError.invalid }
                let prepared = request
                operation = HTTPTransfers.download(request: { prepared }, destination: destination)
            }
            // Retain the file-backed multipart body until URLSession completes, including cancellation.
            let retainedBody = body
            let running = try operation.start(context: context) { result in
                withExtendedLifetime(retainedBody) {
                    DispatchQueue.main.async {
                        guard !self.finished else { return }
                        switch result {
                        case .failure(let error): self.fail(error.code)
                        case .success(let result):
                            if self.upload {
                                guard let owner = self.owner else { self.fail("host_unavailable"); return }
                                owner.ask(self, kind: "validate", response: response) { self.succeed(try strings($0)) }
                            } else { self.succeed(result) }
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                if self.finished || self.context.isCanceled { running?.cancel() }
                else { self.network = running }
            }
        } catch { DispatchQueue.main.async { self.fail("request_failed") } }
    }
    func fail(_ code: String) {
        guard !finished else { return }
        finished = true; network = nil; owner?.release(self); completion(.failure(TransferFailure(code)))
    }
    func succeed(_ result: [String: String]) {
        guard !finished else { return }
        finished = true; network = nil; owner?.release(self); completion(.success(result))
    }
    func cancel() {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true; self.network?.cancel(); self.network = nil; self.owner?.release(self)
        }
    }
}

private enum BridgeError: Error { case invalid }
private func encode(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
}
private func string(_ object: [String: Any], _ key: String, limit: Int = 16_384) throws -> String {
    guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.utf8.count <= limit else { throw BridgeError.invalid }
    return value
}
private func object(_ value: [String: Any], _ key: String) throws -> [String: Any] {
    guard let result = value[key] as? [String: Any] else { throw BridgeError.invalid }; return result
}
private func strings(_ value: Any?) throws -> [String: String] {
    guard let value = value else { return [:] }
    guard let result = value as? [String: String], result.count <= 64,
          result.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 200 && $0.value.utf8.count <= 4096 }),
          try encode(result).utf8.count <= 16_384 else { throw BridgeError.invalid }
    return result
}
private func filename(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 255, value != ".", value != "..",
          !value.contains("/"), !value.contains("\\"), value.rangeOfCharacter(from: .controlCharacters) == nil else { throw BridgeError.invalid }
    return value
}
private func fileURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "",
          url.query == nil, url.fragment == nil else { throw BridgeError.invalid }
    return url
}
private func httpRequest(_ value: [String: Any]) throws -> URLRequest {
    guard let url = URL(string: try string(value, "url")), let scheme = url.scheme,
          ["http", "https"].contains(scheme), url.host != nil, url.user == nil, url.password == nil else { throw BridgeError.invalid }
    var request = URLRequest(url: url)
    for (key, value) in try strings(value["headers"]) {
        guard !["range", "content-length", "content-type", "host", "transfer-encoding"].contains(key.lowercased()),
              key.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
              value.rangeOfCharacter(from: .newlines) == nil else { throw BridgeError.invalid }
        request.setValue(value, forHTTPHeaderField: key)
    }
    return request
}
private func uiConfiguration(_ value: [String: Any]) throws -> TransferUIConfiguration {
    let tag: String
    if value["language"] == nil { tag = "zh-Hans" }
    else { tag = try string(value, "language", limit: 20) }
    guard let language = TransferLanguage(rawValue: tag) else { throw BridgeError.invalid }
    let theme = try strings(value["theme"])
    func color(_ key: String, _ fallback: UIColor) throws -> UIColor {
        guard let hex = theme[key] else { return fallback }
        guard hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { throw BridgeError.invalid }
        return TransferTheme.color(rgb)
    }
    let defaults = TransferTheme()
    let colors = try TransferTheme(primary: color("primary", defaults.primary), background: color("background", defaults.background),
        surface: color("surface", defaults.surface), text: color("text", defaults.text), mutedText: color("mutedText", defaults.mutedText),
        border: color("border", defaults.border), success: color("success", defaults.success), danger: color("danger", defaults.danger))
    return try TransferUIConfiguration(language: language, theme: colors, title: value["title"] == nil ? nil : string(value, "title", limit: 200))
}
