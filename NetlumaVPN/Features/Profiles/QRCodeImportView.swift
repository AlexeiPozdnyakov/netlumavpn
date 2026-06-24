import AVFoundation
import SwiftUI
import UIKit

struct QRCodeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cameraState: CameraPermissionState = .checking
    @State private var scanErrorMessage: String?
    @State private var scanSessionID = UUID()

    let onImport: (String) async throws -> Void

    var body: some View {
        ZStack {
            NetlumaVPNTheme.backgroundGradient
                .ignoresSafeArea()

            switch cameraState {
            case .checking:
                ProgressView()
                    .controlSize(.large)
            case .authorized:
                if let scanErrorMessage {
                    scanFailureView(message: scanErrorMessage)
                } else {
                    QRScannerRepresentable { value in
                        importProfile(from: value)
                    }
                    .id(scanSessionID)
                    .ignoresSafeArea(edges: .bottom)
                    scannerOverlay
                }
            case .denied:
                ContentUnavailableView(
                    "Camera Access Needed",
                    systemImage: "camera.fill",
                    description: Text("Allow camera access in Settings to scan a configuration QR code.")
                )
            case .unavailable:
                ContentUnavailableView(
                    "Camera Unavailable",
                    systemImage: "camera.slash.fill",
                    description: Text("This device cannot scan QR codes with the camera.")
                )
            }
        }
        .navigationTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .task {
            await requestCameraAccess()
        }
    }

    private var scannerOverlay: some View {
        VStack {
            Spacer()

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white, lineWidth: 3)
                .frame(width: 240, height: 240)
                .shadow(radius: 4)

            Spacer()

            Text("Point the camera at a VLESS, VMess, Trojan, or WireGuard QR code.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
    }

    private func scanFailureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Import", systemImage: "qrcode")
        } description: {
            Text(message)
        } actions: {
            Button {
                scanErrorMessage = nil
                scanSessionID = UUID()
            } label: {
                Label("Scan Again", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") {
                dismiss()
            }
        }
    }

    private func requestCameraAccess() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraState = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraState = granted ? .authorized : .denied
        case .denied, .restricted:
            cameraState = .denied
        @unknown default:
            cameraState = .denied
        }
    }

    private func importProfile(from value: String) {
        Task {
            do {
                try await onImport(value)
                dismiss()
            } catch {
                scanErrorMessage = error.localizedDescription
            }
        }
    }
}

private enum CameraPermissionState {
    case checking
    case authorized
    case denied
    case unavailable
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onCodeScanned: onCodeScanned)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onCodeScanned: (String) -> Void
    private let captureSession = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let sessionQueue = DispatchQueue(label: "com.alekseipozdiakov.NetlumaVPN.qr-scanner")
    private var didScanCode = false

    init(onCodeScanned: @escaping (String) -> Void) {
        self.onCodeScanned = onCodeScanned
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCaptureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didScanCode = false
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScanCode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue?.nilIfBlank else {
            return
        }

        didScanCode = true
        stopScanning()
        onCodeScanned(value)
    }

    private func configureCaptureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            return
        }

        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    private func startScanning() {
        sessionQueue.async { [captureSession] in
            guard !captureSession.isRunning else {
                return
            }
            captureSession.startRunning()
        }
    }

    private func stopScanning() {
        sessionQueue.async { [captureSession] in
            guard captureSession.isRunning else {
                return
            }
            captureSession.stopRunning()
        }
    }
}
