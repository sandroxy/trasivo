import Foundation

/// A bounded-memory multipart/form-data body. This is HTTP encoding, not resumable chunk upload.
public final class MultipartBody {
    public let fileURL: URL
    public let contentType: String
    public init(file: URL, field: String, filename: String, mimeType: String, fields: [String: String] = [:]) throws {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 34 && $0.value != 127 }
        }
        guard file.isFileURL, safe(field), safe(filename), safe(mimeType), fields.keys.allSatisfy(safe) else {
            throw TransferFailure("invalid_multipart")
        }
        let boundary = "Trasivo-\(UUID().uuidString)"
        contentType = "multipart/form-data; boundary=\(boundary)"
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("trasivo-body-\(UUID().uuidString)")
        guard let input = InputStream(url: file), let output = OutputStream(url: fileURL, append: false) else { throw TransferFailure("file_unavailable") }
        output.open(); input.open()
        var succeeded = false
        defer { output.close(); input.close(); if !succeeded { try? FileManager.default.removeItem(at: fileURL) } }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var offset = 0
                while offset < data.count {
                    let n = output.write(base.advanced(by: offset), maxLength: data.count - offset)
                    guard n > 0 else { throw TransferFailure("file_write_failed") }; offset += n
                }
            }
        }
        for key in fields.keys.sorted() {
            try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
        }
        try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = input.read(&buffer, maxLength: buffer.count)
            guard n >= 0 else { throw TransferFailure("file_read_failed") }
            if n == 0 { break }
            try write(Data(buffer[0..<n]))
        }
        try write(Data("\r\n--\(boundary)--\r\n".utf8)); succeeded = true
    }
    /// Keep this object alive until all attempts finish using its file.
    deinit { try? FileManager.default.removeItem(at: fileURL) }
}
