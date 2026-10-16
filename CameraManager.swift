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

/// 分辨率
enum VideoResolution: String, CaseIterable {
    case p1080 = "1080p"
    case p1440 = "1440p"
    case k4 = "4K"
}

/// 相机 + 实时检测 + 录像。App 锁定竖屏。
/// 启动流程与 v3 完全一致 (极简 preset), 确保不闪退。
final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [Detection] = []
    @Published var fps: Double = 0
    @Published var orientedAspect: CGFloat = 9.0 / 16.0
    @Published var status: String = "启动中…"
    // 设置项 (UI 绑定, 主线程)
    @Published var lens: CameraLens = .wide
    @Published var availableLenses: [CameraLens] = [.wide]
    @Published var videoResolution: VideoResolution = .p1080
    @Published var availableResolutions: [VideoResolution] = [.p1080]
    @Published var videoFPS: Int = 30
    @Published var drawFPS: Int = 30
    @Published var openGateEnabled: Bool = false
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

    // sessionQueue 本地值 (推理节流用)
    private var drawFPSValue: Int = 30
    private var fpsLimitValue: Double = 30

    // 当前生效的设置 (sessionQueue 上维护, 用于设置变更时保持)
    private var curLens: CameraLens = .wide
    private var curRes: VideoResolution = .p1080
    private var curFPS: Int = 30
    private var curGate: Bool = false

    private var detecting = false
    private var lastInferenceTime: CFTimeInterval = 0
    private var lastDrawTime: CFTimeInterval = 0
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

    /// 启动: 与 v3 完全一致的极简流程。
    /// v9: 移除 movieOutput、镜头探测、分辨率探测, 彻底回到 v3。
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "找不到相机" }
                return
            }
            self.session.addInput(input)
            self.videoInput = input
            self.currentDevice = device
            self.detector?.isFrontCamera = false

            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.configurePreviewConnection()
                self.status = "检测中"
            }
            self.session.startRunning()
        }
    }

    // MARK: - 设置变更 (用户操作时触发, 与启动隔离)

    /// 应用新的相机设置。全部走 preset, 只有 OpenGate 走手动 (且失败自动回落)。
    private func applySettings(lens: CameraLens, resolution: VideoResolution, fps: Int, openGate: Bool) {
        // 1. 选设备
        var newLens = lens
        var dev = device(for: newLens)
        if dev == nil {
            newLens = .wide
            dev = device(for: .wide)
        }
        guard let device = dev else { return }

        var newRes = resolution
        var newFPS = max(1, min(60, fps))
        var newGate = openGate

        session.beginConfiguration()
        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }

        // 2. OpenGate: 尝试手动 4:3, 失败则回落
        var manualOK = false
        if newGate {
            if let format = findOpenGateFormat(for: device) {
                session.sessionPreset = .inputPriority
                if (try? device.lockForConfiguration()) != nil {
                    device.activeFormat = format
                    device.videoZoomFactor = 1.0
                    device.unlockForConfiguration()
                    manualOK = true
                }
            }
            if !manualOK { newGate = false }
        }
        // 3. 1440p: 目前无系统 preset, 若设备无原生格式则回落 1080p
        if !manualOK && newRes == .p1440 {
            if find1440pFormat(for: device) != nil {
                session.sessionPreset = .inputPriority
                if (try? device.lockForConfiguration()) != nil,
                   let format = find1440pFormat(for: device) {
                    device.activeFormat = format
                    device.videoZoomFactor = 1.0
                    device.unlockForConfiguration()
                    manualOK = true
                }
            }
            if !manualOK { newRes = .p1080 }
        }
        // 4. 普通: 系统 preset
        if !manualOK {
            let preset: AVCaptureSession.Preset = (newRes == .k4) ? .hd4K3840x2160 : .hd1920x1080
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            } else {
                newRes = .p1080
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                }
            }
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()

        // 5. 帧率 (按格式能力钳制, 防御式)
        newFPS = applyFrameRateSafely(device: device, targetFPS: newFPS)

        videoInput = input
        currentDevice = device
        detector?.isFrontCamera = (newLens == .front)
        curLens = newLens
        curRes = newRes
        curFPS = newFPS
        curGate = newGate
        let availRes = probeResolutions(for: device)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lens = newLens
            self.videoResolution = newRes
            self.videoFPS = newFPS
            self.openGateEnabled = newGate
            self.availableResolutions = availRes
            self.zoomFactor = 1.0
            self.configurePreviewConnection()
        }
    }

    /// 防御式设置帧率: 只读不写异常, 失败返回当前值
    private func applyFrameRateSafely(device: AVCaptureDevice, targetFPS: Int) -> Int {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return targetFPS }
        let maxFPS = Int(ranges.map(\.maxFrameRate).max() ?? 30)
        let minFPS = Int(ranges.map(\.minFrameRate).min() ?? 1)
        let actual = max(minFPS, min(targetFPS, maxFPS))
        // 若已是目标值则跳过, 减少锁操作
        let cur = device.activeVideoMinFrameDuration
        if cur.value > 0 && Int(Int64(cur.timescale) / cur.value) == actual { return actual }
        guard (try? device.lockForConfiguration()) != nil else { return actual }
        device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(actual))
        device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(actual))
        device.unlockForConfiguration()
        return actual
    }

    private func findOpenGateFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: (AVCaptureDevice.Format, Int32)?
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let is43 = abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.02
            if !is43 || d.width < 3000 { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if maxFPS < 15 { continue }
            if best == nil || d.width > best!.1 { best = (format, d.width) }
        }
        return best?.0
    }

    private func find1440pFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if d.width == 2560 && d.height == 1440 { return format }
        }
        return nil
    }

    private func probeResolutions(for device: AVCaptureDevice) -> [VideoResolution] {
        let dims = Set(device.formats.map {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return "\(d.width)x\(d.height)"
        })
        var r: [VideoResolution] = [.p1080]
        if dims.contains("2560x1440") { r.append(.p1440) }
        r.append(.k4)  // 4K 用 preset, 基本都有; 不支持会自动回落
        return r
    }

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

    private func configurePreviewConnection() {
        previewLayer?.videoGravity = .resizeAspectFill
        if let c = previewLayer?.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }
    }

    // MARK: - 设置入口

    func setLens(_ newLens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.applySettings(lens: newLens, resolution: self.curRes, fps: self.curFPS, openGate: self.curGate)
        }
    }

    func setVideoResolution(_ resolution: VideoResolution) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.applySettings(lens: self.curLens, resolution: resolution, fps: self.curFPS, openGate: self.curGate)
        }
    }

    func setVideoFPS(_ fps: Int) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.applySettings(lens: self.curLens, resolution: self.curRes, fps: fps, openGate: self.curGate)
        }
    }

    func setOpenGateEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.applySettings(lens: self.curLens, resolution: self.curRes, fps: self.curFPS, openGate: enabled)
        }
    }

    func setDrawFPS(_ fps: Int) {
        let clamped = max(1, min(60, fps))
        sessionQueue.async { [weak self] in self?.drawFPSValue = clamped }
        DispatchQueue.main.async { [weak self] in self?.drawFPS = clamped }
    }

    func setFPSLimit(_ limit: Double) {
        sessionQueue.async { [weak self] in self?.fpsLimitValue = limit }
        DispatchQueue.main.async { [weak self] in self?.fpsLimit = limit }
    }

    func setAntennaEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.antennaEnabled = enabled }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.currentDevice else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            let maxZ = min(device.activeFormat.videoMaxZoomFactor, 8)
            device.videoZoomFactor = max(1.0, min(factor, maxZ))
            let actual = device.videoZoomFactor
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = actual }
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
            completion()
        }
    }

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            // v9: movieOutput 懒加载, 启动时不加入 session
            if !self.session.outputs.contains(self.movieOutput) {
                self.session.beginConfiguration()
                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }
                self.session.commitConfiguration()
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
        guard !detecting else { return }
        let now = CACurrentMediaTime()
        guard now - lastInferenceTime >= (1.0 / fpsLimitValue) else { return }
        guard now - lastDrawTime >= (1.0 / Double(drawFPSValue)) else { return }
        detecting = true
        lastInferenceTime = now
        lastDrawTime = now
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
