import AVFoundation
import SwiftUI
import UIKit

/// 扫 Mac 在 设置 › 远程控制 里显示的配对二维码。扫到 uTerm 的配对码就交给调用方，别的码提示一句继续扫。
///
/// 不在本机 iCloud 账户里的 Mac 不自动出现在主机页的「附近的 Mac」里，要配对都从这一页走：扫它的二维码，或点底部的
/// 「附近的其他 Mac」换成一份列表（`RemoteMacDirectory.otherNearbyMacs`），挑一台后在那台 Mac 上输入 6 位数。
/// 列表和取景在同一页里切换，不往导航栈里推（sheet 里推系统导航栏会掉帧）。
struct RemotePairingScanner: View {
    let onScanned: (RemotePairingInvitation) -> Void
    /// 扫到的是中继配置（Mac 设置 › 远程控制 › 公网接入的二维码）。
    var onRelayConfig: ((RemoteRelayConfig) -> Void)? = nil
    /// 给了才有「附近的其他 Mac」入口。
    var nearby: RemoteMacDirectory? = nil
    /// 在「附近的其他 Mac」里挑了一台。
    var onNearby: ((RemoteMacDirectory.Mac) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var note: String?
    @State private var showsNearby = false

    var body: some View {
        NavigationStack {
            Group {
                if showsNearby, let nearby {
                    RemoteOtherNearbyMacsList(directory: nearby) { onNearby?($0) }
                } else {
                    content
                }
            }
            .navigationTitle(showsNearby ? Text("附近的其他 Mac") : Text("扫码配对 Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if nearby != nil, onNearby != nil { modeSwitch }
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
                        if let config = RemoteRelayConfig(scanned: text), let onRelayConfig {
                            onRelayConfig(config)
                            return true
                        }
                        guard let invitation = RemotePairingInvitation(scanned: text) else {
                            note = "这不是 uTerm 的配对码"
                            return false
                        }
                        onScanned(invitation)
                        return true
                    }
                    .ignoresSafeArea()
                    Text(note ?? "对准 Mac 上「设置 › 远程控制 › 扫码配对」中的二维码")
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
                message("uTerm 没有相机权限。前往「设置」允许 uTerm 访问相机。")
                MBtn(title: "打开设置", kind: .primary, height: 42) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 底部的切换：取景 ↔ 附近的其他 Mac。相机没权限、没有相机时也在，那时它是唯一能走的路。
    private var modeSwitch: some View {
        Button {
            showsNearby.toggle()
        } label: {
            (showsNearby ? Text("扫描二维码") : Text("没有二维码？查看附近的其他 Mac"))
                .font(M.sans(15, weight: .medium))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
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

/// 扫码页里的「附近的其他 Mac」：同一局域网里打开了远程控制、不在本机 iCloud 账户里的 Mac。
struct RemoteOtherNearbyMacsList: View {
    let directory: RemoteMacDirectory
    let onPick: (RemoteMacDirectory.Mac) -> Void

    static let footer = "同一局域网里打开了远程控制、不在你 iCloud 账户里的 Mac。点一下，在那台 Mac 上输入这里显示的 6 位数即可配对。"
    static let emptyHint = "同一局域网里没有找到其他打开了远程控制的 Mac。和这台设备登录同一个 iCloud 账户的 Mac 会直接出现在主机页的「附近的 Mac」里。"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if directory.otherNearbyMacs.isEmpty {
                    MInsetGroup(footer: Self.emptyHint) {
                        MInsetRow(icon: "mac", iconColor: M.text3, label: "没有找到其他 Mac", last: true)
                    }
                } else {
                    MInsetGroup(footer: Self.footer) {
                        ForEach(directory.otherNearbyMacs) { mac in
                            MInsetRow(icon: "mac", label: mac.name, value: "配对", chevron: true,
                                      last: mac.id == directory.otherNearbyMacs.last?.id) {
                                onPick(mac)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(M.canvas)
        // 这一页开着时也算有界面在看：名册隔一会儿重读，刚同步到的自家 Mac 会从这里挪走。
        .task { await directory.keepLiveStatusFresh() }
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
            let box = CaptureSessionBox(session: session)
            DispatchQueue.global(qos: .userInitiated).async { box.session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let box = CaptureSessionBox(session: session)
            DispatchQueue.global(qos: .userInitiated).async { box.session.stopRunning() }
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

/// `AVCaptureSession` 没标 `Sendable`，但 `startRunning()` / `stopRunning()` 会阻塞，Apple 的要求本来就是
/// 放到后台队列调——跨线程调这两个方法是它支持的用法。只为把会话带进后台闭包，别拿它跨线程改配置。
nonisolated private struct CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}
