@preconcurrency import AVFoundation
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private nonisolated(unsafe) let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var configured = false
    private var isVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delivered = false
        isVisible = true
        startSessionIfReady()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.session.stopRunning() }
    }

    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureCamera() : self.showCameraMessage(
                        "相机权限未开启",
                        detail: "请在系统设置中允许 ModelHub 使用相机，或返回手动粘贴配对码。",
                        offersSettings: true
                    )
                }
            }
        case .denied, .restricted:
            showCameraMessage(
                "相机权限未开启",
                detail: "请在系统设置中允许 ModelHub 使用相机，或返回手动粘贴配对码。",
                offersSettings: true
            )
        @unknown default:
            showCameraMessage("无法使用相机", detail: "请返回手动粘贴配对码。", offersSettings: false)
        }
    }

    private func configureCamera() {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            showCameraMessage("无法使用相机", detail: "请返回手动粘贴配对码。", offersSettings: false)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showCameraMessage("无法启动扫码", detail: "请返回手动粘贴配对码。", offersSettings: false)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
        configured = true
        startSessionIfReady()
    }

    private func startSessionIfReady() {
        guard configured, isVisible, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }

    private func showCameraMessage(_ title: String, detail: String, offersSettings: Bool) {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.textColor = .secondaryLabel
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        if offersSettings {
            let button = UIButton(type: .system)
            button.setTitle("打开系统设置", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.addAction(UIAction { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self, !delivered else { return }
            delivered = true
            onCode?(code)
        }
    }
}
