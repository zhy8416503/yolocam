import AVFoundation
import QuartzCore
import UIKit

/// 相机 + 实时检测。App 锁定竖屏, 只处理后置相机。
/// 单模型: YOLO26-N (常规精度)。
final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [Detection] = []
    @Published var fps: Double = 0
    @Published var orientedAspect: CGFloat = 9.0 / 16.0  // 扶正后图像宽高比
    @Published var status: String = "启动中…"

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let output = AVCaptureVideoDataOutput()
    private var detector: Detector?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // 推理门控: 同一时间只跑一帧推理, 跑不完的新帧直接丢掉 (sessionQueue 上串行访问)
    private var detecting = false
    private var lastStatTime = CACurrentMediaTime()
    private var statCount = 0

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init()
        do {
            self.detector = try Detector(variant: .n)
        } catch {
            DispatchQueue.main.async { self.status = "模型加载失败" }
        }
        output.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.session.beginConfiguration()
            // 默认 1080p 60fps (拍照视角预览)
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.status = "找不到后置相机" }
                return
            }
            // 尝试 60fps (失败则保持默认)
            do {
                try device.lockForConfiguration()
                let targetFps = 60.0
                var bestFormat: AVCaptureDevice.Format?
                var bestRange: AVFrameRateRange?
                for format in device.formats {
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    if dims.width == 1920 && dims.height == 1080 {
                        for range in format.videoSupportedFrameRateRanges {
                            if range.maxFrameRate >= targetFps {
                                bestFormat = format
                                bestRange = range
                                break
                            }
                        }
                        if bestFormat != nil { break }
                    }
                }
                if let format = bestFormat, let range = bestRange {
                    device.activeFormat = format
                    let duration = CMTime(value: 1, timescale: 60)
                    if range.minFrameDuration.timescale != 0 {
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                    }
                }
                device.unlockForConfiguration()
            } catch {
                // 保持默认帧率
            }
            self.session.addInput(input)
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // 实时场景: 消费不过来的旧帧直接丢, 不积压
            self.output.alwaysDiscardsLateVideoFrames = true
            guard self.session.canAddOutput(self.output) else {
                DispatchQueue.main.async { self.status = "相机输出配置失败" }
                return
            }
            self.session.addOutput(self.output)
            self.session.commitConfiguration()

            // 预览层: 竖屏显示 + 填满 (主线程配置, session 已挂上, connection 一定存在)
            DispatchQueue.main.async {
                self.previewLayer?.session = self.session
                self.previewLayer?.videoGravity = .resizeAspectFill
                if let c = self.previewLayer?.connection, c.isVideoOrientationSupported {
                    c.videoOrientation = .portrait
                }
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "检测中" }
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
        // X 模型慢: 节流到 10fps, N 模型 60fps
        // (简单起见, 都用门控, X 自然慢)
        guard !detecting else { return }   // 上一帧推理还没完, 丢掉这一帧
        detecting = true
        defer { detecting = false }

        let dets = (try? detector.detect(pixelBuffer: pixelBuffer)) ?? []
        let aspect = detector.orientedAspect

        statCount += 1
        let now = CACurrentMediaTime()
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
