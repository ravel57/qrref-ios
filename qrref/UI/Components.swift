//
//  Components.swift
//  Общие элементы интерфейса.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

enum QrImage {
    /// QR-код всегда чёрный на белом, независимо от темы — иначе его не отсканировать.
    static func make(_ content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QRCodeView: View {
    let content: String

    var body: some View {
        if let image = QrImage.make(content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Мой QR-код со статусом соединения и подсказкой.
struct MyQRBlock: View {
    @Environment(AppModel.self) private var model
    let hint: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            QRCodeView(content: QrLink.build(serverURL: model.serverURL, key: model.key))
            Text(model.connected ? LocalizedStringKey("На связи") : LocalizedStringKey("Нет соединения"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConnectionDot: View {
    let connected: Bool

    var body: some View {
        Circle()
            .fill(connected ? Color.green : Color.red)
            .frame(width: 10, height: 10)
            .accessibilityLabel(connected ? LocalizedStringKey("На связи") : LocalizedStringKey("Нет соединения"))
    }
}

/// Кнопка настроек и индикатор соединения в панели навигации.
struct QrrefToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .navigationTitle("qrRef")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        ConnectionDot(connected: model.connected)
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Настройки")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

extension View {
    func qrrefToolbar() -> some View { modifier(QrrefToolbar()) }
}
