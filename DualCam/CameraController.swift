import AVFoundation
import Combine
import UIKit

enum CameraSlot: String, CaseIterable, Identifiable {
    case back
    case front

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: return "后置"
        case .front: return "前置"
        }
    }

    var position: AVCaptureDevice.Position {
        switch self {
        case .back: return .back
        case .front: return .front
        }
    }
}

enum CameraState: Equatable {
    case idle
    case starting
    case running
    case unavailable(String)
}

enum CamLog {
    static func d(_ message: String) {
        print("[DualCam] \(message)")
    }
}

enum CameraError: LocalizedError {
    case deviceMissing(CameraSlot)
    case cannotAddInput(CameraSlot)
    case cannotAddOutput(CameraSlot)
    case cannotAddConnection(CameraSlot)
    case composeFailed

    var errorDescription: String? {
        switch self {
        case .deviceMissing(let slot): return "找不到\(slot.title)摄像头"
        case .cannotAddInput(let slot): return "无法添加\(slot.title)摄像头输入"
        case .cannotAddOutput(let slot): return "无法添加\(slot.title)摄像头输出"
        case .cannotAddConnection(let slot): return "无法建立\(slot.title)摄像头连接"
        case .composeFailed: return "画面合成失败"
        }
    }
}

final class CameraController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var toast: String?
    /// 没有可用双摄时（模拟器、旧机型），只展示布局，不能拍照录像。
    @Published private(set) var isDemoMode = false

    /// 供 SwiftUI 预览视图挂载的分层，只有会话跑起来后才有值。
    private(set) var previewLayers: [CameraSlot: AVCaptureVideoPreviewLayer] = [:]

    let session = AVCaptureMultiCamSession()

    private var inputs: [CameraSlot: AVCaptureDeviceInput] = [:]
    private var dataOutputs: [CameraSlot: AVCaptureVideoDataOutput] = [:]
    private var photoOutputs: [CameraSlot: AVCapturePhotoOutput] = [:]
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private let compositor = Compositor.shared
    private let sessionQueue = DispatchQueue(label: "com.dualcamera.session")

    private var recorder: VideoRecorder?
    private var photoCapture: DualPhotoCapture?
    private var requestStarted = false
    private var configured = false

    /// 拍照/录像时使用的布局快照。
    private(set) var layout = LayoutConfig()

    func updateLayout(_ config: LayoutConfig) {
        layout = config
    }

    // MARK: - 生命周期

    func start() {
        guard !requestStarted else { return }
        requestStarted = true

        CamLog.d("start, multiCamSupported=\(AVCaptureMultiCamSession.isMultiCamSupported)")
        // 先判断硬件能力，避免在模拟器/旧机型上弹出无意义的权限请求。
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            enterDemoMode()
            return
        }
        guard CameraSlot.allCases.allSatisfy({ slot in
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: slot.position) != nil
        }) else {
            enterDemoMode()
            return
        }

        state = .starting

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.setState(.unavailable("没有相机权限。请到「设置 > 隐私与安全性 > 相机」中允许本 App 使用相机。"))
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.configureAndRun()
            }
        }
    }

    /// 权限被拒绝后，用户从系统设置授权返回时可以重试。
    func retry() {
        requestStarted = false
        state = .idle
        start()
    }

    /// App 进入后台时暂停采集，释放摄像头给系统。
    func pause() {
        guard configured else { return }
        // 后台无法继续取流，先把正在进行的录像收尾保存。
        if isRecording {
            stopRecording()
        }
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// App 回到前台时恢复采集。
    func resume() {
        guard configured else { return }
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func configureAndRun() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            setState(.unavailable("这台设备不支持前后摄像头同时采集。\n需要 iPhone XS / XR 及更新机型（A12 芯片起），模拟器没有摄像头。"))
            return
        }

        sessionQueue.async {
            do {
                try self.configureSession()
            } catch CameraError.deviceMissing {
                // 模拟器或没有前后摄像头的设备：进入演示模式，只保留布局体验。
                self.enterDemoMode()
                return
            } catch {
                self.setState(.unavailable(error.localizedDescription))
                return
            }

            self.session.startRunning()
            CamLog.d("session running=\(self.session.isRunning) inputs=\(self.inputs.count) dataOutputs=\(self.dataOutputs.count) photoOutputs=\(self.photoOutputs.count) audio=\(self.audioOutput != nil)")
            DispatchQueue.main.async {
                self.configured = true
                self.state = .running
            }
        }
    }

    private func enterDemoMode() {
        DispatchQueue.main.async {
            self.isDemoMode = true
            self.state = .running
        }
    }

    // MARK: - 会话配置

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        for slot in CameraSlot.allCases {
            try addCamera(slot)
        }
        addMicrophone()
    }

    private func addCamera(_ slot: CameraSlot) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: slot.position) else {
            throw CameraError.deviceMissing(slot)
        }

        CamLog.d("camera \(slot.rawValue): \(device.localizedName) type=\(device.deviceType.rawValue)")
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput(slot) }
        session.addInputWithNoConnections(input)
        inputs[slot] = input

        guard let port = input.ports(for: .video,
                                     sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else {
            throw CameraError.cannotAddConnection(slot)
        }

        // 1) 视频数据输出：录像合成用
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        dataOutput.alwaysDiscardsLateVideoFrames = true
        dataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.dualcamera.frames.\(slot.rawValue)"))
        guard session.canAddOutput(dataOutput) else { throw CameraError.cannotAddOutput(slot) }
        session.addOutputWithNoConnections(dataOutput)
        dataOutputs[slot] = dataOutput

        let dataConnection = AVCaptureConnection(inputPorts: [port], output: dataOutput)
        guard session.canAddConnection(dataConnection) else { throw CameraError.cannotAddConnection(slot) }
        session.addConnection(dataConnection)
        if dataConnection.isVideoRotationAngleSupported(90) {
            dataConnection.videoRotationAngle = 90
        }

        // 2) 照片输出：拍全分辨率照片
        let photoOutput = AVCapturePhotoOutput()
        if session.canAddOutput(photoOutput) {
            session.addOutputWithNoConnections(photoOutput)
            let photoConnection = AVCaptureConnection(inputPorts: [port], output: photoOutput)
            if session.canAddConnection(photoConnection) {
                session.addConnection(photoConnection)
                photoOutput.maxPhotoQualityPrioritization = .quality
                if photoConnection.isVideoRotationAngleSupported(90) {
                    photoConnection.videoRotationAngle = 90
                }
                photoOutputs[slot] = photoOutput
            }
        }

        // 3) 预览层
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        if session.canAddConnection(previewConnection) {
            session.addConnection(previewConnection)
            if previewConnection.isVideoRotationAngleSupported(90) {
                previewConnection.videoRotationAngle = 90
            }
            previewConnection.automaticallyAdjustsVideoMirroring = true
        }
        previewLayers[slot] = layer
    }

    private func addMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInputWithNoConnections(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.dualcamera.audio"))
        guard session.canAddOutput(output) else { return }
        session.addOutputWithNoConnections(output)

        if let port = input.ports(for: .audio,
                                  sourceDeviceType: nil,
                                  sourceDevicePosition: .unspecified).first {
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            if session.canAddConnection(connection) {
                session.addConnection(connection)
            }
        }

        audioInput = input
        audioOutput = output
    }

    // MARK: - 拍照

    func capturePhoto() {
        guard state == .running, !isBusy else { return }
        guard !isDemoMode else {
            showToast("演示模式：需要真机才能双摄拍照")
            return
        }
        guard photoOutputs.count == CameraSlot.allCases.count else {
            showToast("前置或后置摄像头不可用，无法双摄拍照")
            return
        }

        CamLog.d("photo capture")
        isBusy = true
        let capture = DualPhotoCapture(outputs: photoOutputs, layout: layout, compositor: compositor)
        photoCapture = capture

        capture.capture { [weak self] result in
            guard let self else { return }
            self.photoCapture = nil
            self.isBusy = false

            switch result {
            case .success(let image):
                PhotoLibrary.save(image: image) { saveResult in
                    switch saveResult {
                    case .success: self.showToast("照片已保存到相册")
                    case .failure(let error): self.showToast("保存失败：\(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                self.showToast("拍照失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 录像

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard state == .running, !isBusy, !isRecording else { return }
        guard !isDemoMode else {
            showToast("演示模式：需要真机才能双摄录像")
            return
        }
        guard let recorder = VideoRecorder(layout: layout, canvas: LayoutConfig.videoCanvas) else {
            showToast("无法创建录像文件")
            return
        }

        CamLog.d("record start")
        self.recorder = recorder
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        isRecording = false
        isBusy = true
        UIApplication.shared.isIdleTimerDisabled = false
        CamLog.d("record stop requested")

        // 兜底：写入 8 秒还没结束就恢复界面，避免一直转圈。
        var didFinish = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !didFinish else { return }
            CamLog.d("record finish TIMEOUT")
            self.isBusy = false
            self.showToast("录像保存超时，请重试")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)

        recorder.finish { [weak self] url in
            guard let self else { return }
            didFinish = true
            watchdog.cancel()
            self.isBusy = false

            CamLog.d("record finish url=\(url?.lastPathComponent ?? "nil")")
            guard let url else {
                self.showToast("录像保存失败")
                return
            }
            PhotoLibrary.save(videoAt: url) { result in
                try? FileManager.default.removeItem(at: url)
                switch result {
                case .success: self.showToast("录像已保存到相册")
                case .failure(let error): self.showToast("保存失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 工具

    private func setState(_ newState: CameraState) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.toast == text {
                    self?.toast = nil
                }
            }
        }
    }
}

// MARK: - 采集回调

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }

        guard let slot = dataOutputs.first(where: { $0.value === output })?.key,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        recorder?.appendVideo(buffer,
                              slot: slot,
                              at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
