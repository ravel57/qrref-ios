//
//  ChatView.swift
//  Окно чата между устройствами.
//

import SwiftUI
import QuickLook

/// Окно чата между устройствами: показывается поверх любого режима, пока устройства связаны.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var attaching = false
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var model = model
        content
            .qrrefToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть чат") { model.leaveChat() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                if model.chat.isEmpty {
                    Text("Сообщений пока нет")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(model.chat) { Bubble(message: $0, preview: $previewURL).id($0.id) }
                    }
                    .padding()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.chat.count) {
                if let last = model.chat.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .quickLookPreview($previewURL)
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.sendChatFiles(urls) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let name = model.uploadingChatFile {
                    Text("Отправка файла «\(name)»…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attaching = true } label: {
                    Image(systemName: "paperclip").font(.title2)
                }
                .disabled(model.uploadingChatFile != nil)
                .accessibilityLabel("Прикрепить файл")
                TextField("Сообщение", text: $model.chatDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button { model.sendChat() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Отправить")
            }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct Bubble: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @Binding var preview: URL?

    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 2) {
                if let file = message.file {
                    fileContent(file)
                } else {
                    Text(message.text)
                }
                Text(message.ts, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.mine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            // удержание копирует текст сообщения (у файла — его имя)
            .onLongPressGesture {
                UIPasteboard.general.string = message.file?.name ?? message.text
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.message("Скопировано")
            }
            if !message.mine { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func fileContent(_ file: ChatFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("📎 \(file.name)")
            if file.size >= 0 {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch file.status {
            case .idle:
                Button("Скачать") { model.downloadChatFile(message.id) }.font(.subheadline)
            case .downloading:
                Text("Скачивание…").font(.caption).foregroundStyle(.secondary)
            case .saved:
                if let url = file.savedURL {
                    Button("Открыть") { preview = url }.font(.subheadline)
                }
            }
        }
    }
}
