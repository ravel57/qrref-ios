//
//  APIClient.swift
//  HTTP-ручки бэкенда qrRef (см. MainController).
//

import Foundation
import UniformTypeIdentifiers

nonisolated struct APIError: Error {
    let code: Int
}

final class APIClient {

    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func sendText(key: String, text: String) async throws {
        try await post(["text", key], json: ["text": text])
    }

    func sendFile(key: String, fileURL: URL, name: String, mime: String) async throws {
        try await upload(["file", key], fileURL: fileURL, name: name, mime: mime)
    }

    /// Файл собеседнику по мосту: он получит сообщение с путём для скачивания.
    func sendRoomFile(key: String, fileURL: URL, name: String, mime: String) async throws {
        try await upload(["room", "file", key], fileURL: fileURL, name: name, mime: mime)
    }

    private func upload(_ segments: [String], fileURL: URL, name: String, mime: String) async throws {
        let boundary = "qrref-\(UUID().uuidString)"
        let body = try await Task.detached {
            try Self.makeMultipartFile(source: fileURL, name: name, mime: mime, boundary: boundary)
        }.value
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: segments.reduce(baseURL) { $0.appendingPathComponent($1) })
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        try check(response)
    }

    /// Создаёт мост между двумя ключами и возвращает roomId из ответа сервера.
    @discardableResult
    func createBridge(a: String, b: String) async throws -> String? {
        let data = try await post(["bridge"], json: ["a": a, "b": b])
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let room = (json?["room"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return room.isEmpty ? nil : room
    }

    /// roomId, если ключ уже сопряжён, иначе nil.
    func roomOf(key: String) async throws -> String? {
        let (data, response) = try await URLSession.shared.data(from: url("room", key))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let room = (json?["room"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return room.isEmpty ? nil : room
    }

    /// Завершает чат: сервер расформировывает комнату и сообщает об этом обоим участникам.
    @discardableResult
    func leaveRoom(key: String) async throws -> Bool {
        var request = URLRequest(url: url("room", "leave", key))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return true
    }

    func sendRoomText(key: String, text: String) async throws {
        try await post(["room", "text", key], json: ["text": text])
    }

    /// Скачивает файл по пути вида `file/<secret>` в Documents/Received (видно в приложении «Файлы»).
    func download(path: String) async throws -> URL {
        let target = path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        let (temp, response) = try await URLSession.shared.download(from: target)
        try check(response)
        let name = Self.fileName(fromContentDisposition: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"))
        return try Self.moveToReceived(temp, name: name)
    }

    // MARK: - Внутреннее

    private func url(_ segments: String...) -> URL {
        segments.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    @discardableResult
    private func post(_ segments: [String], json: [String: String]) async throws -> Data {
        var request = URLRequest(url: segments.reduce(baseURL) { $0.appendingPathComponent($1) })
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return data
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw APIError(code: http.statusCode) }
    }

    nonisolated static func mimeType(forFileName name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Собирает multipart-тело на диске, чтобы большие файлы не попадали в память целиком.
    nonisolated private static func makeMultipartFile(source: URL, name: String, mime: String, boundary: String) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        let safeName = name
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n"
        try writer.write(contentsOf: Data(head.utf8))
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return output
    }

    /// Предпочитает `filename*=UTF-8''...` (с кириллицей), иначе берёт обычный `filename=`.
    nonisolated static func fileName(fromContentDisposition header: String?) -> String {
        guard let header else { return "qrref-file" }
        func value(of pattern: String) -> String? {
            guard let match = header.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                  let eq = header[match].firstIndex(of: "=") else { return nil }
            let raw = String(header[match][header[match].index(after: eq)...])
            return raw.replacingOccurrences(of: "UTF-8''", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        let encoded = value(of: #"filename\*=(?:UTF-8'')?"?[^";]+"?"#).flatMap { $0.removingPercentEncoding }
        let raw = encoded ?? value(of: #"filename=(?:UTF-8'')?"?[^";]+"?"#) ?? ""
        let safe = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return (safe.isEmpty || safe == "..") ? "qrref-file" : safe
    }

    nonisolated private static func moveToReceived(_ temp: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = dir.appendingPathComponent(name)
        var counter = 1
        while fm.fileExists(atPath: target.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            target = dir.appendingPathComponent(numbered)
            counter += 1
        }
        try fm.moveItem(at: temp, to: target)
        return target
    }
}
