import AVFoundation
import SwiftUI
import UIKit

/// 扫 Mac 在 设置 › 远程控制 里显示的配对二维码。扫到 uTerm 的配对码就交给调用方，别的码提示一句继续扫。
struct RemotePairingScanner: View {
    let onScanned: (RemotePairingInvitation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var note: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("扫码配对 Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .authorized:
            if AVCaptureDevice.default(for: .video) == nil {
                message("这台设备没有可用的相机")
            } else {
                ZStack(alignment: .bottom) {
                    QRCodeCamera { text in
                        guard let invitation = RemotePairingInvitation(scanned: text) else {
                            note = "这不是 uTerm 的配对码"
                            return false
                        }
                        onScanned(invitation)
                        return true
                    }
                    .ignoresSafeArea()
                    Text(note ?? "对准 Mac 上 设置 › 远程控制 › 扫码配对 的二维码")
                        .font(M.sans(14, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 40).padding(.horizontal, 24)
                }
            }
        case .notDetermined:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 16) {
                message("没有相机权限，请在系统设置里允许 uTerm 使用相机")
                MBtn(title: "打开设置", kind: .primary, height: 42) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(M.sans(15))
            .foregroundStyle(M.text2)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 后置相机取景 + 二维码识别。`onCode` 返回 true = 收下了，停止识别。
private struct QRCodeCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onCode = onCode
    }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Bool)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        /// 取景画面的旋转：按相机装在机身上的方向和此刻的姿态（含屏幕方向）算角度，跟着转。
        /// 不设时预览一直是传感器的原始方向，横握或倒握时画面是歪的。
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var finished = false
        /// 同一个不认识的码不反复提示。
        private var lastRejected: String?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.preview = preview
            let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
            self.rotation = rotation
            applyRotation(rotation.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
                [weak self] _, change in
                guard let angle = change.newValue else { return }
                DispatchQueue.main.async { self?.applyRotation(angle) }
            }
        }

        private func applyRotation(_ angle: CGFloat) {
            guard let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !finished,
                  let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  text != lastRejected else { return }
            if onCode?(text) == true {
                finished = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                lastRejected = text
            }
        }
    }
}
