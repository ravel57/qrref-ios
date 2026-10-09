//
//  ShareViewController.swift
//  qrrefShare
//
//  Share Extension: принимает текст, ссылки и файлы из системного меню «Поделиться»,
//  складывает их в App Group и открывает qrRef — сканировать QR получателя нужно уже там
//  (камера в расширениях недоступна).
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label.text = String(localized: "Готовлю данные…")
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = String(localized: "Готово")
        button.configuration = config
        button.isHidden = true
        button.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, label, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        spinner.startAnimating()

        Task { await process() }
    }

    // MARK: - Разбор вложений

    private func process() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var texts: [String] = []
        var files: [(name: String, url: URL)] = []
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                if let copy = copy(url, into: staging) { files.append(copy) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(text)
            } else if let file = await loadFile(from: provider, into: staging) {
                files.append(file)
            }
        }

        let text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        guard text != nil || !files.isEmpty else {
            return show(String(localized: "Нечего отправлять"), canClose: true)
        }
        guard PendingShareStore.save(text: text, files: files) else {
            return show(String(localized: "Не удалось передать данные в qrRef. Откройте qrRef хотя бы раз и повторите."), canClose: true)
        }
        try? FileManager.default.removeItem(at: staging)

        if await openHostApp() {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            show(String(localized: "Готово к отправке. Откройте qrRef и отсканируйте QR-код получателя."), canClose: true)
        }
    }

    private func copy(_ url: URL, into directory: URL) -> (name: String, url: URL)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return (url.lastPathComponent, target)
        } catch {
            return nil
        }
    }

    /// Фото, видео и прочие вложения без `fileURL`: система отдаёт временный файл только внутри колбэка.
    private func loadFile(from provider: NSItemProvider, into directory: URL) async -> (name: String, url: URL)? {
        guard let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .data) })
        else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                continuation.resume(returning: self.copy(url, into: directory))
            }
        }
    }

    // MARK: - Открытие qrRef

    /// Расширения не могут открывать приложение напрямую, поэтому пробуем официальный способ,
    /// а затем — через UIApplication из цепочки респондеров. Результат известен по колбэку.
    private func openHostApp() async -> Bool {
        let url = SharedConfig.shareURL
        if let context = extensionContext, await context.open(url) { return true }

        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)) == "UIApplication", current.responds(to: selector) {
                typealias Completion = @convention(block) (Bool) -> Void
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Completion?) -> Void
                let function = unsafeBitCast(current.method(for: selector), to: OpenFunction.self)
                return await withCheckedContinuation { continuation in
                    function(current, selector, url as NSURL, [:], { continuation.resume(returning: $0) })
                }
            }
            responder = current.next
        }
        return false
    }

    // MARK: - UI

    private func show(_ message: String, canClose: Bool) {
        spinner.stopAnimating()
        label.text = message
        button.isHidden = !canClose
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
