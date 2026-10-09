//
//  ReceiveView.swift
//  Вкладка «Прием»: мой QR и полученные данные.
//

import SwiftUI
import QuickLook

struct ReceiveView: View {
    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 16) {
                MyQRBlock(hint: "Отсканируйте этот QR-код другим устройством: ему будет предложено отправить сюда текст или файл либо начать чат")

                Toggle("Авто переход по ссылке", isOn: $model.autoOpenURL)

                if model.received.isEmpty {
                    Text("Пока ничего не получено")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ForEach(model.received) { item in
                        ReceivedCard(item: item, preview: $previewURL)
                    }
                }
            }
            .padding()
        }
        .qrrefToolbar()
        .quickLookPreview($previewURL)
    }
}

private struct ReceivedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: ReceivedItem
    @Binding var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item {
            case .text(_, _, let text):
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    Button("Копировать") {
                        UIPasteboard.general.string = text
                        model.message("Скопировано")
                    }
                    ShareLink("Поделиться", item: text)
                    if let url = QrLink.asWebURL(text) {
                        Button("Открыть") { openURL(url) }
                    }
                }
                .font(.subheadline)

            case .downloading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Скачивание файла…")
                }

            case .file(_, _, let name, let url):
                Text(name)
                Text("Сохранено в приложении «Файлы» → qrRef")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Открыть") { preview = url }
                    ShareLink("Поделиться", item: url)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
