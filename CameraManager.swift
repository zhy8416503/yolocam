import AVFoundation
import QuartzCore
import UIKit
import Photos

/// 镜头 (全焦段)
enum CameraLens: String, CaseIterable {
    case front = "前置"
    case ultrawide = "超广角"
    case wide = "广角"
    case telephoto = "长焦"
}

/// 录制规格 (片门全开 = OpenGate, 调用整个 CMOS 录 4:3)
enum RecordingQuality: String, CaseIterable {
    case p1080 = "1080p30"
    case k4_30 = "4K30"
    case k4_60 = "4K60"
    case openGate = "片门全开"
}

/// 相机 + 实时检测 + 录像。App 锁定竖屏。
final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [Detection] = []
    @Published var fps: Double = 0
    @Published var orientedAspect: CGFloat = 9.0 / 16.0  // 扶正后图像宽高比
    @Published var status: String = "启动中…"
    // 设置项 (UI 绑定)
    @Published var lens: CameraLens = .wide
    @Published var availableLenses: [CameraLens] = [.wide]
    @Published var recordingQuality: RecordingQuality = .k4_30
    @Published var isRecording = false
    @Published var antennaEnabled = true
    @Published var fpsLimit: Double = 30
    @Published var zoomFactor: CGFloat = 1.0

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var detector: Detector?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInputAdded = false
    private var currentDevice: AVCaptureDevice?

    // 推理门控: 同一时间只跑一帧推理, 跑不完的新帧直接丢掉 (sessionQueue 上串行访问)
    private var detecting = false
    private var fpsLimitValue: Double = 30
    private var lastInferenceTime: CFTimeInterval = 0
    private var lastStatTime = CACurrentMediaTime()
    private var statCount = 0

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init()
        do {
            self.detector = try Detector()
        } catch {
            DispatchQueue.main.async { self.status = "模型加载失败" }
        }
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            // 手动管理设备格式 (录制规格/片门全开需要), session 不自动选格式
            self.session.sessionPreset = .inputPriority

            let lenses = self.discoverLenses()
            DispatchQueue.main.async { self.availableLenses = lenses }

            guard self.applyLens(.wide, quality: .k4_30) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "找不到相机" }
                return
            }

            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            guard self.session.canAddOutput(self.videoOutput) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "相机输出配置失败" }
                return
            }
            self.session.addOutput(self.videoOutput)

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.configurePreviewConnection()
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "检测中" }
        }
    }

    // MARK: - 镜头与录制规格

    private func device(for lens: CameraLens) -> AVCaptureDevice? {
        switch lens {
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .ultrawide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .telephoto:
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
    }

    private func discoverLenses() -> [CameraLens] {
        var result: [CameraLens] = []
        for l in [CameraLens.ultrawide, .wide, .telephoto] {
            if device(for: l) != nil { result.append(l) }
        }
        if device(for: .front) != nil { result.append(.front) }
        return result.isEmpty ? [.wide] : result
    }

    /// 为指定规格找最合适的设备格式, 返回 (格式, 帧率)
    private func findFormat(for device: AVCaptureDevice, quality: RecordingQuality) -> (AVCaptureDevice.Format, Int)? {
        let want43: Bool
        let minWidth: Int32
        let wantFPS: Int
        switch quality {
        case .p1080:
            want43 = false; minWidth = 1920; wantFPS = 30
        case .k4_30:
            want43 = false; minWidth = 3840; wantFPS = 30
        case .k4_60:
            want43 = false; minWidth = 3840; wantFPS = 60
        case .openGate:
            want43 = true; minWidth = 3000; wantFPS = 30
        }
        var best: (AVCaptureDevice.Format, Int, Int32)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let is43 = abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.02
            if want43 != is43 { continue }
            if dims.width < minWidth { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if maxFPS < Double(wantFPS) { continue }
            if want43 {
                // 片门全开: 取最大的 4:3 (整个 CMOS)
                if best == nil || dims.width > best!.2 { best = (format, wantFPS, dims.width) }
            } else {
                // 普通: 取满足要求的最小分辨率 (避免杀鸡用牛刀)
                if best == nil || dims.width < best!.2 { best = (format, wantFPS, dims.width) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func fallbackQualities(for quality: RecordingQuality) -> [RecordingQuality] {
        switch quality {
        case .k4_60: return [.k4_60, .k4_30, .p1080]
        case .k4_30: return [.k4_30, .p1080]
        case .p1080: return [.p1080]
        case .openGate: return [.openGate, .k4_30, .p1080]
        }
    }

    /// 在 session 配置锁内应用镜头+规格 (带降级), 返回实际生效的 (镜头, 规格)
    private func applyLens(_ newLens: CameraLens, quality: RecordingQuality) -> (CameraLens, RecordingQuality)? {
        var targetLens = newLens
        var targetDevice = device(for: targetLens)
        if targetDevice == nil {
            targetLens = .wide
            targetDevice = device(for: .wide)
        }
        guard let dev = targetDevice else { return nil }
        var appliedQuality: RecordingQuality?
        for q in fallbackQualities(for: quality) {
            if let (format, fps) = findFormat(for: dev, quality: q) {
                do {
                    try dev.lockForConfiguration()
                    dev.activeFormat = format
                    let duration = CMTimeMake(value: 1, timescale: Int32(fps))
                    dev.activeVideoMinFrameDuration = duration
                    dev.activeVideoMaxFrameDuration = duration
                    dev.videoZoomFactor = 1.0
                    dev.unlockForConfiguration()
                    appliedQuality = q
                    break
                } catch { continue }
            }
        }
        guard let aq = appliedQuality,
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        videoInput = input
        currentDevice = dev
        detector?.isFrontCamera = (targetLens == .front)
        return (targetLens, aq)
    }

    /// 切换镜头
    func setLens(_ newLens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // 取当前规格 (从主线程的已发布值读, 仅用于发起请求)
            var currentQuality = RecordingQuality.k4_30
            DispatchQueue.main.sync { currentQuality = self.recordingQuality }
            self.session.beginConfiguration()
            if let old = self.videoInput {
                self.session.removeInput(old)
                self.videoInput = nil
            }
            guard let (appliedLens, appliedQuality) = self.applyLens(newLens, quality: currentQuality) else {
                self.session.commitConfiguration()
                return
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                self.lens = appliedLens
                self.recordingQuality = appliedQuality
                self.zoomFactor = 1.0
                self.configurePreviewConnection()
            }
        }
    }

    /// 切换录制规格
    func setRecordingQuality(_ quality: RecordingQuality) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            var currentLens = CameraLens.wide
            DispatchQueue.main.sync { currentLens = self.lens }
            self.session.beginConfiguration()
            if let old = self.videoInput {
                self.session.removeInput(old)
                self.videoInput = nil
            }
            guard let (appliedLens, appliedQuality) = self.applyLens(currentLens, quality: quality) else {
                self.session.commitConfiguration()
                return
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                self.lens = appliedLens
                self.recordingQuality = appliedQuality
                self.zoomFactor = 1.0
                self.configurePreviewConnection()
            }
        }
    }

    private func configurePreviewConnection() {
        previewLayer?.videoGravity = .resizeAspectFill
        if let c = previewLayer?.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }
    }

    // MARK: - 录像

    private func addAudioInput() {
        guard !audioInputAdded,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInputAdded = true
    }

    /// 确保音频输入就绪 (首次会弹麦克风权限), 完成后回调 (仍在 sessionQueue)
    private func ensureAudio(completion: @escaping () -> Void) {
        if audioInputAdded { completion(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            session.beginConfiguration()
            addAudioInput()
            session.commitConfiguration()
            completion()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self = self else { return }
                self.sessionQueue.async {
                    if granted {
                        self.session.beginConfiguration()
                        self.addAudioInput()
                        self.session.commitConfiguration()
                    }
                    completion()
                }
            }
        default:
            completion()  // 拒绝则只录画面
        }
    }

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            self.ensureAudio {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("YOLOCam_\(Int(Date().timeIntervalSince1970)).mov")
                try? FileManager.default.removeItem(at: url)
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { _, _ in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 其他设置

    /// 推理帧率上限 (每秒最多跑几次检测)
    func setFPSLimit(_ limit: Double) {
        sessionQueue.async { [weak self] in self?.fpsLimitValue = limit }
        DispatchQueue.main.async { [weak self] in self?.fpsLimit = limit }
    }

    /// 天线开关
    func setAntennaEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.antennaEnabled = enabled }
    }

    /// 变焦 (自动钳制到设备允许范围)
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                let maxZ = min(device.activeFormat.videoMaxZoomFactor, 8)
                device.videoZoomFactor = max(1.0, min(factor, maxZ))
                let actual = device.videoZoomFactor
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = actual }
            } catch { }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let detector = detector,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard !detecting else { return }   // 上一帧推理还没完, 丢掉这一帧
        let now = CACurrentMediaTime()
        guard now - lastInferenceTime >= (1.0 / fpsLimitValue) else { return }  // 帧率上限
        detecting = true
        lastInferenceTime = now
        defer { detecting = false }

        let dets = (try? detector.detect(pixelBuffer: pixelBuffer)) ?? []
        let aspect = detector.orientedAspect

        statCount += 1
        let dt = now - lastStatTime
        var currentFps: Double?
        if dt >= 1.0 {
            currentFps = Double(statCount) / dt
            statCount = 0
            lastStatTime = now
        }
        DispatchQueue.main.async {
            self.detections = dets
            if let f = currentFps { self.fps = f }
            if abs(self.orientedAspect - aspect) > 0.0005 { self.orientedAspect = aspect }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        if error == nil {
            saveToPhotos(url: outputFileURL)
        } else {
            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }
}
