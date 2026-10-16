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
/// 主路走系统 preset (稳定), 只有片门全开/1440p 走手动格式。
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
    @Published var drawFPS: Int = 30          // 绘制帧速率 (框/天线刷新)
    @Published var openGateEnabled: Bool = false
    @Published var isRecording = false
    @Published var antennaEnabled = true
    @Published var fpsLimit: Double = 30      // 推理帧率上限
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

    // sessionQueue 本地设置 (避免跨线程读 @Published)
    private var lensValue: CameraLens = .wide
    private var resolutionValue: VideoResolution = .p1080
    private var fpsValue: Int = 30
    private var openGateValue: Bool = false
    private var drawFPSValue: Int = 30
    private var fpsLimitValue: Double = 30

    // 推理门控 (sessionQueue 串行访问)
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

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let lenses = self.discoverLenses()
            DispatchQueue.main.async { self.availableLenses = lenses }
            // 默认: 后置广角, 1080p30
            _ = self.reconfigure(lens: .wide, resolution: .p1080, fps: 30, openGate: false)

            self.session.beginConfiguration()
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.configurePreviewConnection()
                self.status = self.videoInput == nil ? "找不到相机" : "检测中"
            }
            if self.videoInput != nil {
                self.session.startRunning()
            }
        }
    }

    // MARK: - 设备与格式

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

    /// 探测设备是否支持 1440p (2560x1440) 与 OpenGate 4:3
    private func probeCapabilities(for device: AVCaptureDevice) -> (has1440p: Bool, hasOpenGate: Bool) {
        var has1440p = false
        var hasOpenGate = false
        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if d.width == 2560 && d.height == 1440 { has1440p = true }
            let is43 = abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.02
            if is43 && d.width >= 3000 {
                let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                if maxFPS >= 15 { hasOpenGate = true }
            }
            if has1440p && hasOpenGate { break }
        }
        return (has1440p, hasOpenGate)
    }

    /// 核心重配置 (sessionQueue 上调用)。返回实际生效值, 保证不崩。
    /// 策略: 优先系统 preset; 1440p/OpenGate 才走手动格式; 全部失败则保底 1080p。
    @discardableResult
    private func reconfigure(lens newLens: CameraLens, resolution newRes: VideoResolution, fps newFPS: Int, openGate newGate: Bool) -> (CameraLens, VideoResolution, Int, Bool) {
        // 1. 选设备 (失败回退到后置广角)
        var lens = newLens
        var dev = device(for: lens)
        if dev == nil {
            lens = .wide
            dev = device(for: .wide)
        }
        guard let device = dev else {
            return (.wide, .p1080, 30, false)
        }

        var res = newRes
        var fps = max(1, min(60, newFPS))
        var gate = newGate

        // 2. 决定走 preset 还是手动
        //    手动仅用于: OpenGate, 或 1440p(有格式才行)
        var useManual = false
        var manualFormat: AVCaptureDevice.Format?
        if gate {
            if let f = findOpenGateFormat(for: device) {
                useManual = true
                manualFormat = f
            } else {
                gate = false  // 设备不支持 OpenGate, 回落
            }
        }
        if !useManual && res == .p1440 {
            if find1440pFormat(for: device) != nil {
                useManual = true
                manualFormat = find1440pFormat(for: device)
            } else {
                res = .p1080  // 不支持 1440p, 回落
            }
        }

        session.beginConfiguration()
        if let old = videoInput {
            session.removeInput(old)
            videoInput = nil
        }

        var inputOK = false
        if useManual, let format = manualFormat {
            // 手动格式
            session.sessionPreset = .inputPriority
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.videoZoomFactor = 1.0
                device.unlockForConfiguration()
            } catch {
                // 手动失败, 回落到 preset
                useManual = false
                gate = false
                if res == .p1440 { res = .p1080 }
            }
        }
        if !useManual {
            let preset: AVCaptureSession.Preset = (res == .k4) ? .hd4K3840x2160 : .hd1920x1080
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            } else if res == .k4 {
                // 4K 不支持, 回落 1080p
                res = .p1080
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                }
            }
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            currentDevice = device
            inputOK = true
        }
        session.commitConfiguration()

        // 3. 设置帧率 (按设备实际格式钳制)
        if inputOK {
            fps = applyFrameRate(device: device, targetFPS: fps)
        } else {
            // 极端情况: 连输入都加不上, 保持现状
            return (lensValue, resolutionValue, fpsValue, openGateValue)
        }

        // 4. 同步本地与 UI
        lensValue = lens
        resolutionValue = res
        fpsValue = fps
        openGateValue = gate
        detector?.isFrontCamera = (lens == .front)
        let caps = probeCapabilities(for: device)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lens = lens
            self.videoResolution = res
            self.videoFPS = fps
            self.openGateEnabled = gate
            self.zoomFactor = 1.0
            var avail: [VideoResolution] = [.p1080]
            if caps.has1440p { avail.append(.p1440) }
            // 4K 是否支持按 preset 探测 (保守: 默认提供, 失败会自动回落)
            avail.append(.k4)
            self.availableResolutions = avail
            self.configurePreviewConnection()
        }
        return (lens, res, fps, gate)
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

    /// 按设备实际能力设置帧率, 返回实际生效的 fps
    private func applyFrameRate(device: AVCaptureDevice, targetFPS: Int) -> Int {
        let maxFPS = Int(device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
        let actual = max(1, min(targetFPS, maxFPS))
        do {
            try device.lockForConfiguration()
            let duration = CMTimeMake(value: 1, timescale: Int32(actual))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // 锁失败就不改, 用设备默认
        }
        return actual
    }

    private func configurePreviewConnection() {
        previewLayer?.videoGravity = .resizeAspectFill
        if let c = previewLayer?.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }
    }

    // MARK: - 设置入口 (全部在 sessionQueue 上串行执行)

    func setLens(_ newLens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconfigure(lens: newLens, resolution: self.resolutionValue, fps: self.fpsValue, openGate: self.openGateValue)
        }
    }

    func setVideoResolution(_ resolution: VideoResolution) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconfigure(lens: self.lensValue, resolution: resolution, fps: self.fpsValue, openGate: self.openGateValue)
        }
    }

    func setVideoFPS(_ fps: Int) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconfigure(lens: self.lensValue, resolution: self.resolutionValue, fps: fps, openGate: self.openGateValue)
        }
    }

    func setOpenGateEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconfigure(lens: self.lensValue, resolution: self.resolutionValue, fps: self.fpsValue, openGate: enabled)
        }
    }

    /// 绘制帧速率 (1-60): 框/天线刷新上限
    func setDrawFPS(_ fps: Int) {
        let clamped = max(1, min(60, fps))
        sessionQueue.async { [weak self] in self?.drawFPSValue = clamped }
        DispatchQueue.main.async { [weak self] in self?.drawFPS = clamped }
    }

    /// 推理帧率上限
    func setFPSLimit(_ limit: Double) {
        sessionQueue.async { [weak self] in self?.fpsLimitValue = limit }
        DispatchQueue.main.async { [weak self] in self?.fpsLimit = limit }
    }

    func setAntennaEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.antennaEnabled = enabled }
    }

    /// 变焦
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
        // 推理节流
        guard now - lastInferenceTime >= (1.0 / fpsLimitValue) else { return }
        // 绘制节流: 不刷新的帧连推理都省了
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
