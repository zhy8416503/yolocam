import AVFoundation
import QuartzCore
import UIKit

/// 相机 + 实时检测。App 锁定竖屏。
final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [Detection] = []
    @Published var fps: Double = 0
    @Published var orientedAspect: CGFloat = 9.0 / 16.0  // 扶正后图像宽高比
    @Published var status: String = "启动中…"
    // 设置项 (UI 绑定)
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var fpsLimit: Double = 30
    @Published var resolutionPreset: AVCaptureSession.Preset = .hd1920x1080
    @Published var zoomFactor: CGFloat = 1.0

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let output = AVCaptureVideoDataOutput()
    private var detector: Detector?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoInput: AVCaptureDeviceInput?
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
        output.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            guard self.addVideoInput(position: .back) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "找不到相机" }
                return
            }
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // 实时场景: 消费不过来的旧帧直接丢, 不积压
            self.output.alwaysDiscardsLateVideoFrames = true
            guard self.session.canAddOutput(self.output) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.status = "相机输出配置失败" }
                return
            }
            self.session.addOutput(self.output)
            self.session.commitConfiguration()

            // 预览层: 竖屏显示 + 填满 + 不镜像 (主线程配置)
            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.configurePreviewConnection()
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "检测中" }
        }
    }

    /// 在 session 配置锁内添加视频输入, 返回是否成功
    private func addVideoInput(position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        videoInput = input
        currentDevice = device
        detector?.isFrontCamera = (position == .front)
        return true
    }

    private func configurePreviewConnection() {
        previewLayer?.videoGravity = .resizeAspectFill
        if let c = previewLayer?.connection {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }
    }

    // MARK: - 设置

    /// 切换前后镜头
    func switchCamera(to position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self = self, position != self.cameraPosition else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput {
                self.session.removeInput(old)
                self.videoInput = nil
            }
            var finalPosition = position
            if !self.addVideoInput(position: position) {
                // 失败则回滚到原来的镜头
                let fallback: AVCaptureDevice.Position = (position == .back) ? .front : .back
                if self.addVideoInput(position: fallback) {
                    finalPosition = fallback
                }
            }
            self.session.commitConfiguration()
            // 变焦重置为 1x
            if let device = self.currentDevice {
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = 1.0
                    device.unlockForConfiguration()
                } catch { }
            }
            DispatchQueue.main.async {
                self.cameraPosition = finalPosition
                self.zoomFactor = 1.0
                self.configurePreviewConnection()
            }
        }
    }

    /// 切换分辨率
    func setResolution(_ preset: AVCaptureSession.Preset) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            var applied = false
            if self.session.canSetSessionPreset(preset) {
                self.session.sessionPreset = preset
                applied = true
            }
            self.session.commitConfiguration()
            if applied {
                DispatchQueue.main.async { self.resolutionPreset = preset }
            }
        }
    }

    /// 推理帧率上限 (每秒最多跑几次检测)
    func setFPSLimit(_ limit: Double) {
        sessionQueue.async { [weak self] in self?.fpsLimitValue = limit }
        DispatchQueue.main.async { [weak self] in self?.fpsLimit = limit }
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
