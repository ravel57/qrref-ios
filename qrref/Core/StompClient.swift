//
//  StompClient.swift
//  Минимальный STOMP-клиент поверх «чистого» WebSocket-эндпоинта Spring SockJS (/websocket/websocket).
//  Сам переподключается и восстанавливает подписки после обрыва.
//

import Foundation

nonisolated struct StompFrame: Equatable {
    var command: String
    var headers: [String: String]
    var body: String
}

/// Кодирование/разбор текстовых STOMP-кадров (по одному кадру в сообщении WebSocket).
nonisolated enum StompCodec {

    static func encode(_ command: String, headers: [(String, String)] = [], body: String = "") -> String {
        var out = command + "\n"
        for (name, value) in headers {
            out += "\(escape(name)):\(escape(value))\n"
        }
        return out + "\n" + body + "\u{0}"
    }

    /// nil для heart-beat (пустая строка).
    static func decode(_ text: String) -> StompFrame? {
        // Работаем через NSString-методы: в Swift "\r\n" — один Character, и split по "\n" его не видит.
        var raw = text
        while let first = raw.unicodeScalars.first, first == "\n" || first == "\r" {
            raw.unicodeScalars.removeFirst()
        }
        guard !raw.isEmpty else { return nil }
        if let nul = raw.range(of: "\u{0}") { raw = String(raw[..<nul.lowerBound]) }

        let lf = raw.range(of: "\n\n")
        let crlf = raw.range(of: "\r\n\r\n")
        let head: String
        let body: String
        switch (lf, crlf) {
        case let (lf?, crlf?) where crlf.lowerBound < lf.lowerBound:
            head = String(raw[..<crlf.lowerBound]); body = String(raw[crlf.upperBound...])
        case let (lf?, _):
            head = String(raw[..<lf.lowerBound]); body = String(raw[lf.upperBound...])
        case let (nil, crlf?):
            head = String(raw[..<crlf.lowerBound]); body = String(raw[crlf.upperBound...])
        default:
            head = raw; body = ""
        }

        let lines = head.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard let command = lines.first, !command.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = unescape(String(line[..<colon]))
            if headers[name] == nil {
                headers[name] = unescape(String(line[line.index(after: colon)...]))
            }
        }
        return StompFrame(command: command, headers: headers, body: body)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ":", with: "\\c")
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { out.append(c); continue }
            switch iterator.next() {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "c": out.append(":")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }
}

final class StompClient {

    private final class Subscription {
        let id: String
        var handler: (String) -> Void
        init(id: String, handler: @escaping (String) -> Void) {
            self.id = id
            self.handler = handler
        }
    }

    private var subscriptions: [String: Subscription] = [:]
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var running = false
    private var ready = false
    private var generation = 0
    private var attempt = 0
    private var nextID = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private(set) var connected = false
    var onConnectedChange: ((Bool) -> Void)?

    func start(url: URL) {
        if running && self.url == url { return }
        running = true
        self.url = url
        attempt = 0
        open()
    }

    func stop() {
        running = false
        url = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        setConnected(false)
    }

    func subscribe(_ destination: String, handler: @escaping (String) -> Void) {
        if let existing = subscriptions[destination] {
            existing.handler = handler
            return
        }
        let subscription = Subscription(id: "sub-\(nextID)", handler: handler)
        nextID += 1
        subscriptions[destination] = subscription
        if ready { sendSubscribe(destination, subscription) }
    }

    func unsubscribe(_ destination: String) {
        guard let subscription = subscriptions.removeValue(forKey: destination) else { return }
        if ready { send(StompCodec.encode("UNSUBSCRIBE", headers: [("id", subscription.id)])) }
    }

    // MARK: - Соединение

    private func open() {
        guard running, let url else { return }
        teardown()
        let current = generation
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(StompCodec.encode("CONNECT", headers: [("accept-version", "1.1,1.2"), ("heart-beat", "0,0")]))

        Task { await listen(task, generation: current) }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.generation == current else { return }
                task.sendPing { error in
                    if error != nil { task.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask, generation current: Int) async {
        while current == generation {
            do {
                let message = try await task.receive()
                guard current == generation else { return }
                if case .string(let text) = message { handle(text) }
            } catch {
                connectionLost(generation: current)
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let frame = StompCodec.decode(text) else { return }
        switch frame.command {
        case "CONNECTED":
            ready = true
            attempt = 0
            for (destination, subscription) in subscriptions { sendSubscribe(destination, subscription) }
            setConnected(true)
        case "MESSAGE":
            let id = frame.headers["subscription"]
            subscriptions.values.first { $0.id == id }?.handler(frame.body)
        case "ERROR":
            connectionLost(generation: generation)
        default:
            break
        }
    }

    private func sendSubscribe(_ destination: String, _ subscription: Subscription) {
        send(StompCodec.encode("SUBSCRIBE", headers: [("id", subscription.id), ("destination", destination)]))
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func connectionLost(generation lost: Int) {
        guard lost == generation else { return }
        teardown()
        setConnected(false)
        guard running else { return }
        let delay = min(30, 1 << min(attempt, 5))
        attempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    /// Закрывает текущее соединение; поколение меняется, чтобы старые колбэки игнорировались.
    private func teardown() {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        onConnectedChange?(value)
    }
}
