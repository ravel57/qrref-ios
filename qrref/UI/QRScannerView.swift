//
//  QRScannerView.swift
//  Сканер QR-кодов на AVFoundation.
//

import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ru.ravel.qrref.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        onCode?(value)
    }
}

/// Квадратная панель сканера: запрашивает доступ к камере и объясняет, если его нет.
struct ScannerPanel: View {
    let hint: LocalizedStringKey
    let busy: Bool
    let onCode: (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                content
                if busy {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Отправка…").foregroundStyle(.white)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20))

            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .authorized:
            if AVCaptureDevice.default(for: .video) != nil {
                QRScannerView(onCode: onCode)
            } else {
                message("Камера недоступна на этом устройстве")
            }
        case .notDetermined:
            ProgressView().tint(.white)
        default:
            VStack(spacing: 8) {
                Text("Для сканирования QR-кода нужен доступ к камере")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding()
    }
}
