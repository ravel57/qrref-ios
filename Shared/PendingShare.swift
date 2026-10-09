//
//  PendingShare.swift
//  Общий код приложения и Share Extension: передача данных через App Group.
//

import Foundation

nonisolated enum SharedConfig {
    static let appGroup = "group.ru.ravel.qrref"
    static let urlScheme = "qrref"
    static let shareURL = URL(string: "qrref://share")!

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}

/// То, что пользователь отправил через «Поделиться»: текст/ссылка и/или файлы.
nonisolated struct PendingShare: Codable {
    struct File: Codable {
        var name: String
        /// Путь относительно папки `pending` в контейнере App Group.
        var path: String
    }

    var text: String?
    var files: [File]
}

nonisolated enum PendingShareStore {
    private static let manifestName = "manifest.json"

    private static var directory: URL? {
        SharedConfig.containerURL?.appendingPathComponent("pending", isDirectory: true)
    }

    /// Сохраняет данные для основного приложения. Возвращает false, если App Group недоступна.
    static func save(text: String?, files: [(name: String, url: URL)]) -> Bool {
        guard let dir = directory else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var stored: [PendingShare.File] = []
            for (index, file) in files.enumerated() {
                let folder = String(index)
                try fm.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
                let relative = "\(folder)/\(file.name)"
                try fm.copyItem(at: file.url, to: dir.appendingPathComponent(relative))
                stored.append(.init(name: file.name, path: relative))
            }
            let data = try JSONEncoder().encode(PendingShare(text: text, files: stored))
            try data.write(to: dir.appendingPathComponent(manifestName))
            return true
        } catch {
            try? fm.removeItem(at: dir)
            return false
        }
    }

    /// Читает сохранённое: сам манифест и абсолютные URL файлов.
    static func load() -> (share: PendingShare, fileURLs: [URL])? {
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)),
              let share = try? JSONDecoder().decode(PendingShare.self, from: data)
        else { return nil }
        return (share, share.files.map { dir.appendingPathComponent($0.path) })
    }

    static func clear() {
        if let dir = directory { try? FileManager.default.removeItem(at: dir) }
    }
}
