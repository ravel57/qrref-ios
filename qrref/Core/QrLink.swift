//
//  QrLink.swift
//  Разбор и сборка ссылок вида https://qrref.io/?key=... (повторяет Scanner.vue на сайте).
//

import Foundation

nonisolated struct ScannedQR: Equatable {
    var key: String
    var a: String
    var b: String
    var bridge: Bool

    var hasPair: Bool { !a.isEmpty && !b.isEmpty }
}

nonisolated enum QrLink {

    static func build(serverURL: String, key: String) -> String {
        var base = serverURL
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/?key=\(key)"
    }

    /// Возвращает nil, если содержимое QR не похоже на URL.
    static func parse(_ raw: String) -> ScannedQR? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let withScheme = hasWebScheme(text) ? text : "https://\(text)"
        guard let components = validComponents(withScheme) else { return nil }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] where params[item.name] == nil {
            params[item.name] = item.value ?? ""
        }
        func param(_ name: String) -> String {
            let value = (params[name] ?? "").trimmingCharacters(in: .whitespaces)
            return isSafeKey(value) ? value : ""
        }

        let a = param("a")
        let b = param("b")
        let key = param("key").isEmpty ? param("k") : param("key")
        let bridge = components.path.lowercased().contains("/bridge")
            || (!a.isEmpty && !b.isEmpty)
            || params["bridge"] == "1"
        return ScannedQR(key: key, a: a, b: b, bridge: bridge)
    }

    /// Если весь текст — одна http(s)-ссылка, возвращает её.
    static func asWebURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasWebScheme(trimmed), let components = validComponents(trimmed) else { return nil }
        return components.url
    }

    /// Приводит введённый адрес сервера к виду `https://host[:port][/path]` без завершающего слэша.
    static func normalizeServerURL(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://\(text)" }
        guard hasWebScheme(text), validComponents(text) != nil else { return nil }
        return text
    }

    // MARK: - Внутреннее

    private static func hasWebScheme(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func validComponents(_ text: String) -> URLComponents? {
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { return nil }
        return components
    }

    private static func isSafeKey(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-"
        }
    }
}

/// Тот же алфавит, что и у сервера (KeyService).
nonisolated enum KeyGenerator {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890")

    static func generate(length: Int = 20) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
