//
//  SendView.swift
//  Режим «Отправка с этого устройства»: сканируем QR другого устройства и выбираем, что с ним сделать —
//  отправить текст/файл, начать чат или связать чатом с ним другой компьютер.
//

import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.sendStep {
                case .scan:
                    if model.fromShare {
                        Text("Получено через «Поделиться». Наведите камеру на QR-код получателя.")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    ScannerPanel(
                        hint: "Наведите камеру на QR-код устройства",
                        busy: model.sending,
                        onCode: model.onScanned
                    )

                case .scanSecond:
                    ScannerPanel(
                        hint: "Наведите камеру на QR-код второго компьютера",
                        busy: model.sending,
                        onCode: model.onScanned
                    )
                    Button("Назад") { model.backToOptions() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                case .options:
                    OptionsCard()

                case .compose:
                    ComposeCard()
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .qrrefToolbar()
    }
}

private struct OptionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if model.fromShare {
                Text("Получено через «Поделиться». Выберите «Отправить текст/файл», данные уже подставлены.")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("QR-код отсканирован").font(.headline)
            Text(shortKey(model.scannedKey))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button { model.openCompose() } label: {
                Text("Отправить текст/файл").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button { model.startChat() } label: {
                Text("Начать чат").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sending)

            Button { model.startSecondScan() } label: {
                Text("Начать чат с другим компьютером (режим обмена)")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sending)

            Button { model.rescan() } label: {
                Text("Сканировать другой QR").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func shortKey(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : key
    }
}

private struct ComposeCard: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    private var canSend: Bool {
        !model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.files.isEmpty
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            TextField("Текст для пересылки", text: $model.draftText, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)

            ForEach(model.files) { file in
                FileRow(file: file)
            }

            Button { importing = true } label: {
                Text("Прикрепить файл").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button { model.sendToScanned() } label: {
                Group {
                    if model.sending { ProgressView().tint(.white) } else { Text("Отправить") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.sending || !canSend)

            Button { model.backToOptions() } label: {
                Text("Назад").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.sending)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: PickedFile

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if file.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.removeFile(file) } label: { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Убрать файл")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
