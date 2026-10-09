//
//  AppModel.swift
//  Состояние и логика приложения (аналог MainViewModel в Android-версии).
//

import SwiftUI
import UIKit

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Два режима: принимать на это устройство (показываем свой QR) или отправлять с него (сканируем чужой).
enum AppScreen: Hashable {
    case receive, send
}

/// Шаги режима отправки: сканирование → действия над отсканированным устройством → отправка / второй QR.
enum SendStep {
    case scan, options, compose, scanSecond
}

enum ReceivedItem: Identifiable {
    case text(id: UUID, ts: Date, text: String)
    case downloading(id: UUID, ts: Date)
    case file(id: UUID, ts: Date, name: String, url: URL)

    var id: UUID {
        switch self {
        case .text(let id, _, _), .downloading(let id, _), .file(let id, _, _, _): id
        }
    }
}

/// Файл, присланный в чат: `path` — путь для скачивания на сервере (`room/file/<id>`).
struct ChatFile {
    enum Status { case idle, downloading, saved }

    let name: String
    let size: Int64
    let path: String
    var status: Status = .idle
    var savedURL: URL?
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let mine: Bool
    let ts: Date
    var file: ChatFile?
}

struct PickedFile: Identifiable, Equatable {
    let id = UUID()
    /// Копия файла внутри песочницы приложения — из неё идёт отправка.
    let url: URL
    let name: String
    let size: Int64
    let mime: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@Observable
final class AppModel {

    // MARK: Настройки
    private(set) var serverURL: String
    private(set) var key: String
    var autoOpenURL: Bool { didSet { defaults.set(autoOpenURL, forKey: Keys.autoOpen) } }
    var theme: ThemeMode { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }

    // MARK: Состояние
    var screen: AppScreen = .send
    private(set) var connected = false
    var toast: Toast?

    // Прием
    var received: [ReceivedItem] = []

    // Отправка
    var draftText = ""
    var files: [PickedFile] = []
    var fromShare = false
    var sending = false
    var sendStep: SendStep = .scan
    var scannedKey = ""

    // Чат
    var roomID: String?
    var chat: [ChatMessage] = []
    var chatDraft = ""
    var uploadingChatFile: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let stomp = StompClient()
    @ObservationIgnored private var api: APIClient
    @ObservationIgnored private var lastScan = ""
    @ObservationIgnored private var lastScanAt = Date.distantPast
    @ObservationIgnored private var consumingShare = false

    private enum Keys {
        static let server = "server_url"
        static let key = "key"
        static let autoOpen = "auto_open_url"
        static let theme = "theme_mode"
    }

    static let defaultServer = "https://qrref.io"

    init() {
        let server = QrLink.normalizeServerURL(defaults.string(forKey: Keys.server) ?? "") ?? Self.defaultServer
        serverURL = server
        api = APIClient(baseURL: URL(string: server)!)

        if let saved = defaults.string(forKey: Keys.key), !saved.isEmpty {
            key = saved
        } else {
            let generated = KeyGenerator.generate()
            defaults.set(generated, forKey: Keys.key)
            key = generated
        }
        autoOpenURL = defaults.object(forKey: Keys.autoOpen) as? Bool ?? true
        theme = ThemeMode(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system

        stomp.onConnectedChange = { [weak self] connected in
            guard let self else { return }
            self.connected = connected
            if connected { self.refreshRoom() }
        }
        subscribeKeyTopics(key)

        #if DEBUG
        // Для проверки интерфейса без камеры: -debug_scanned_key <ключ> сразу открывает действия над «отсканированным» устройством.
        if let scanned = defaults.string(forKey: "debug_scanned_key"), !scanned.isEmpty {
            scannedKey = scanned
            sendStep = .options
            screen = .send
        }
        #endif
    }

    // MARK: - Жизненный цикл

    /// Пока приложение на экране — держим соединение, чтобы получать данные.
    func appBecameActive() {
        stomp.start(url: webSocketURL())
        consumePendingShare()
    }

    func appEnteredBackground() {
        stomp.stop()
    }

    func handle(url: URL) {
        if url.scheme == SharedConfig.urlScheme, url.host == "share" {
            consumePendingShare()
        }
    }

    func selectScreen(_ screen: AppScreen) {
        self.screen = screen
    }

    // MARK: - «Поделиться»

    /// Забирает то, что положило Share Extension, и готовит к отправке.
    func consumePendingShare() {
        guard !consumingShare, let pending = PendingShareStore.load() else { return }
        consumingShare = true
        Task {
            var staged: [PickedFile] = []
            for url in pending.fileURLs {
                if let file = try? await Self.stage(url, scoped: false) { staged.append(file) }
            }
            // Файлы скопированы в песочницу приложения — контейнер App Group можно очищать.
            PendingShareStore.clear()
            files.forEach(Self.discard)
            draftText = pending.share.text ?? ""
            files = staged
            fromShare = true
            sendStep = .scan
            scannedKey = ""
            screen = .send
            consumingShare = false
        }
    }

    func importFiles(_ urls: [URL]) {
        Task {
            var added: [PickedFile] = []
            for url in urls {
                if let file = try? await Self.stage(url, scoped: true) {
                    added.append(file)
                } else {
                    message("Не удалось прочитать файл")
                }
            }
            files.append(contentsOf: added)
        }
    }

    func removeFile(_ file: PickedFile) {
        files.removeAll { $0 == file }
        Self.discard(file)
    }

    // MARK: - Отправка: сканирование и действия над отсканированным устройством

    func onScanned(_ raw: String) {
        let now = Date()
        if raw == lastScan, now.timeIntervalSince(lastScanAt) < 4 { return }
        lastScan = raw
        lastScanAt = now
        guard !sending else { return }

        guard let link = QrLink.parse(raw) else { return message("Невалидный QR (не URL).") }
        guard !link.key.isEmpty else { return message("В QR нет параметра key.") }

        switch sendStep {
        case .scan:
            scannedKey = link.key
            sendStep = .options
        case .scanSecond:
            pairComputers(first: scannedKey, second: link.key)
        case .options, .compose:
            break
        }
    }

    func openCompose() { sendStep = .compose }
    func backToOptions() { sendStep = .options }
    func startSecondScan() { sendStep = .scanSecond }

    func rescan() {
        sendStep = .scan
        scannedKey = ""
    }

    /// Отправляет введённый текст и выбранные файлы на отсканированное устройство.
    func sendToScanned() {
        let key = scannedKey
        guard !key.isEmpty, !sending else { return }
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
            return message("Введите текст или прикрепите файл")
        }
        sending = true
        Task {
            defer { sending = false }
            do {
                if !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await api.sendText(key: key, text: draftText)
                    draftText = ""
                }
                for file in files {
                    try await api.sendFile(key: key, fileURL: file.url, name: file.name, mime: file.mime)
                    files.removeAll { $0 == file }
                    Self.discard(file)
                }
                fromShare = false
                sendStep = .options
                message("Отправлено")
            } catch {
                messageText(describe(error))
            }
        }
    }

    /// Чат с отсканированным устройством: свой ключ + ключ устройства = мост.
    func startChat() {
        let peer = scannedKey
        guard !peer.isEmpty, !sending else { return }
        guard peer != key else { return message("Это QR-код этого же устройства") }
        sending = true
        Task {
            defer { sending = false }
            do {
                let room = try await api.createBridge(a: key, b: peer)
                // roomId есть в ответе — не ждём сообщения по сокету, оно могло потеряться при переподключении
                if let room { attachRoom(room) }
                rescan()
            } catch {
                message("Не удалось начать чат")
            }
        }
    }

    /// Чат между отсканированным устройством и вторым компьютером; у обоих откроется окно чата.
    private func pairComputers(first: String, second: String) {
        guard second != first else { return message("Отсканирован тот же QR. Нужен QR второго компьютера.") }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await api.createBridge(a: first, b: second)
                rescan()
                message("Компьютеры связаны: у обоих открылся чат")
            } catch {
                message("Ошибка создания моста.")
            }
        }
    }

    // MARK: - Чат

    /// Закрыть чат: сервер сообщит об этом и собеседнику.
    func leaveChat() {
        let key = key
        Task {
            _ = try? await api.leaveRoom(key: key)
            clearRoom()
        }
    }

    private func clearRoom() {
        if let room = roomID { stomp.unsubscribe(Self.roomTopic(room)) }
        roomID = nil
        chat = []
        chatDraft = ""
    }

    func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await api.sendRoomText(key: key, text: text)
                if chatDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text { chatDraft = "" }
            } catch {
                messageText(describe(error))
            }
        }
    }

    private func attachRoom(_ roomID: String) {
        guard !roomID.isEmpty, roomID != self.roomID else { return }
        if let old = self.roomID { stomp.unsubscribe(Self.roomTopic(old)) }
        self.roomID = roomID
        chat = []
        stomp.subscribe(Self.roomTopic(roomID)) { [weak self] in self?.onRoomMessage($0) }
    }

    private func refreshRoom() {
        let key = key
        Task {
            if let room = try? await api.roomOf(key: key) { attachRoom(room) }
        }
    }

    private func onRoomMessage(_ body: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let type = json["type"] as? String
        else { return }
        let ts = (json["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let mine = json["from"] as? String == key
        switch type {
        case "closed":
            clearRoom()
        case "text":
            chat.append(ChatMessage(text: json["text"] as? String ?? "", mine: mine, ts: ts))
        case "file":
            let file = ChatFile(
                name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "file",
                size: (json["size"] as? NSNumber)?.int64Value ?? -1,
                path: json["path"] as? String ?? ""
            )
            chat.append(ChatMessage(text: "", mine: mine, ts: ts, file: file))
        default:
            break
        }
    }

    /// Скачивает файл из чата в Documents/Received (виден в приложении «Файлы»).
    func downloadChatFile(_ messageID: UUID) {
        guard let index = chat.firstIndex(where: { $0.id == messageID }),
              let file = chat[index].file, file.status != .downloading else { return }
        chat[index].file?.status = .downloading
        Task {
            do {
                let url = try await api.download(path: file.path)
                updateChatFile(messageID) { $0.status = .saved; $0.savedURL = url }
            } catch {
                updateChatFile(messageID) { $0.status = .idle }
                message("Не удалось скачать файл")
            }
        }
    }

    private func updateChatFile(_ messageID: UUID, _ change: (inout ChatFile) -> Void) {
        guard let index = chat.firstIndex(where: { $0.id == messageID }), var file = chat[index].file else { return }
        change(&file)
        chat[index].file = file
    }

    /// Отправляет выбранные файлы собеседнику по очереди.
    func sendChatFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            defer { uploadingChatFile = nil }
            for url in urls {
                do {
                    let staged = try await Self.stage(url, scoped: true)
                    defer { Self.discard(staged) }
                    uploadingChatFile = staged.name
                    try await api.sendRoomFile(key: key, fileURL: staged.url, name: staged.name, mime: staged.mime)
                } catch {
                    messageText(describe(error))
                    return
                }
            }
        }
    }

    // MARK: - Прием

    private func onActivityMessage(_ body: String) {
        let path = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.range(of: "^file/[A-Za-z0-9]{20,64}$", options: .regularExpression) != nil {
            downloadFile(path)
            return
        }
        received.insert(.text(id: UUID(), ts: Date(), text: body), at: 0)
        if autoOpenURL, let url = QrLink.asWebURL(body) {
            UIApplication.shared.open(url)
        }
    }

    private func downloadFile(_ path: String) {
        let id = UUID()
        let started = Date()
        received.insert(.downloading(id: id, ts: started), at: 0)
        Task {
            do {
                let url = try await api.download(path: path)
                replaceReceived(id, with: .file(id: id, ts: started, name: url.lastPathComponent, url: url))
            } catch {
                replaceReceived(id, with: nil)
                message("Не удалось скачать файл")
            }
        }
    }

    private func replaceReceived(_ id: UUID, with item: ReceivedItem?) {
        guard let index = received.firstIndex(where: { $0.id == id }) else { return }
        if let item { received[index] = item } else { received.remove(at: index) }
    }

    // MARK: - Настройки

    /// Возвращает false, если адрес некорректен.
    func setServerURL(_ input: String) -> Bool {
        guard let normalized = QrLink.normalizeServerURL(input), let url = URL(string: normalized) else { return false }
        guard normalized != serverURL else { return true }
        defaults.set(normalized, forKey: Keys.server)
        serverURL = normalized
        api = APIClient(baseURL: url)
        if let room = roomID { stomp.unsubscribe(Self.roomTopic(room)) }
        roomID = nil
        chat = []
        stomp.stop()
        stomp.start(url: webSocketURL())
        return true
    }

    func regenerateKey() {
        let old = key
        // собеседник получит «чат закрыт», а не повиснет в комнате с недействительным ключом
        Task { _ = try? await api.leaveRoom(key: old) }
        stomp.unsubscribe(Self.activityTopic(old))
        stomp.unsubscribe(Self.bridgeTopic(old))
        if let room = roomID { stomp.unsubscribe(Self.roomTopic(room)) }
        key = KeyGenerator.generate()
        defaults.set(key, forKey: Keys.key)
        roomID = nil
        chat = []
        sendStep = .scan
        scannedKey = ""
        subscribeKeyTopics(key)
    }

    // MARK: - Вспомогательное

    /// Сообщение с литералом проходит через локализацию; для уже готовой строки — `messageText`.
    func message(_ text: LocalizedStringResource) {
        messageText(String(localized: text))
    }

    func messageText(_ text: String) {
        let toast = Toast(text: text)
        self.toast = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.toast == toast { self.toast = nil }
        }
    }

    private func subscribeKeyTopics(_ key: String) {
        stomp.subscribe(Self.activityTopic(key)) { [weak self] in self?.onActivityMessage($0) }
        stomp.subscribe(Self.bridgeTopic(key)) { [weak self] in
            self?.attachRoom($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func webSocketURL() -> URL {
        var components = URLComponents(string: serverURL)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += "/websocket/websocket"
        return components.url!
    }

    private func describe(_ error: Error) -> String {
        if let api = error as? APIError {
            return api.code == 409 ? String(localized: "Устройства ещё не сопряжены") : String(localized: "Ошибка сервера (\(api.code))")
        }
        if error is URLError { return String(localized: "Нет связи с сервером") }
        return String(localized: "Что-то пошло не так")
    }

    private static func activityTopic(_ key: String) -> String { "/topic/activity/\(key)" }
    private static func bridgeTopic(_ key: String) -> String { "/topic/bridge/\(key)" }
    private static func roomTopic(_ room: String) -> String { "/topic/room/\(room)" }

    // MARK: - Файлы

    nonisolated private static var outgoingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
    }

    /// Копирует файл в песочницу приложения (из Share Extension или из fileImporter).
    nonisolated private static func stage(_ source: URL, scoped: Bool) async throws -> PickedFile {
        try await Task.detached {
            let accessing = scoped && source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            let folder = outgoingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return PickedFile(url: target, name: source.lastPathComponent, size: size, mime: APIClient.mimeType(forFileName: source.lastPathComponent))
        }.value
    }

    nonisolated private static func discard(_ file: PickedFile) {
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }
}
