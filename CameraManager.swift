import AVFoundation
import QuartzCore
import UIKit

/// Owns the AVCaptureSession and runs YOLOv8 inference on incoming frames
/// (one inference at a time on a background queue; late frames are dropped).
final class CameraManager: NSObject, ObservableObject {
    @Published var detections: [Detection] = []
    @Published var inferFPS: Double = 0
    @Published var status: String = "正在启动…"

    let session = AVCaptureSession()

    private var detector: Detector?
    private let sessionQueue = DispatchQueue(label: "yolocam.session")
    private let inferQueue = DispatchQueue(label: "yolocam.infer")
    private var inferring = false

    override init() {
        super.init()
        do {
            detector = try Detector()
        } catch {
            status = "模型加载失败：\(error.localizedDescription)"
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupSession()
                } else {
                    DispatchQueue.main.async {
                        self.status = "请在系统设置中允许 YOLOCam 访问相机"
                    }
                }
            }
        default:
            status = "请在系统设置中允许 YOLOCam 访问相机"
        }
    }

    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                DispatchQueue.main.async { self.status = "找不到可用相机" }
                return
            }
            self.session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.sessionQueue)
            guard self.session.canAddOutput(output) else {
                DispatchQueue.main.async { self.status = "相机输出配置失败" }
                return
            }
            self.session.addOutput(output)
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "" }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection)
    {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let detector = detector,
              !inferring
        else { return }
        inferring = true
        inferQueue.async {
            let t0 = CACurrentMediaTime()
            let dets = detector.detect(pixelBuffer: pixelBuffer)
            let dt = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                self.detections = dets
                self.inferFPS = 1.0 / max(dt, 0.001)
                self.inferring = false
            }
        }
    }
}
