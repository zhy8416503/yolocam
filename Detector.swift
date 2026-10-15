import CoreML
import Vision
import CoreVideo
import Foundation

struct Detection: Identifiable {
    let id = UUID()
    // 归一化坐标 (0~1), 以 Vision 扶正后的图像为基准, 原点左上
    let x, y, width, height: CGFloat
    let label: String
    let confidence: Float
}

enum DetectorError: Error {
    case modelNotFound
}

final class Detector {
    private let request: VNCoreMLRequest
    // 扶正后图像的宽高比 (Wo/Ho), 由最近一帧的 pixelBuffer 尺寸决定
    var orientedAspect: CGFloat = 9.0 / 16.0

    init() throws {
        let bundle = Bundle.main
        // 1. Xcode 把 yolov8n.mlpackage 编译成 yolov8n.mlmodelc 放进包里
        var modelURL = bundle.url(forResource: "yolov8n", withExtension: "mlmodelc")
        // 2. 兜底: 包里任意一个编译好的模型
        if modelURL == nil,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: bundle.bundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            modelURL = urls.first(where: { $0.pathExtension == "mlmodelc" })
        }
        // 3. 兜底: 原始 mlpackage (Xcode 没编译而是当资源拷贝的极端情况)
        if modelURL == nil {
            modelURL = bundle.url(forResource: "yolov8n", withExtension: "mlpackage")
        }
        guard let url = modelURL else { throw DetectorError.modelNotFound }

        let config = MLModelConfiguration()
        config.computeUnits = .all   // ANE / GPU / CPU 自动选最快的
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        let vnModel = try VNCoreMLModel(for: mlModel)

        let req = VNCoreMLRequest(model: vnModel)
        // 模型输入是 640x640, 用填满方式居中裁剪
        req.imageCropAndScaleOption = .scaleFill
        self.request = req
    }

    /// 对一帧做检测。pixelBuffer 是相机原始 buffer (sensor 横屏尺寸)。
    /// 返回的框是"扶正后竖屏图像"的归一化坐标, 调用方按 aspect-fill 映射到屏幕。
    /// App 锁定竖屏 + 后置相机, 因此 Vision orientation 用 .right。
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        // 后置相机 + 竖屏: buffer 是横的, 扶正需要顺时针转 90° (.right)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let out = results.first?.featureValue.multiArrayValue else { return [] }
        return decode(out, pixelBuffer: pixelBuffer)
    }

    // YOLOv8 输出 [1,84,8400]: 84 = 4 个坐标 + 80 类分数 (无 NMS, 自己做)
    private func decode(_ ma: MLMultiArray, pixelBuffer: CVPixelBuffer) -> [Detection] {
        let shape = ma.shape.map { $0.intValue }   // [1,84,8400]
        guard shape.count == 3 else { return [] }
        let rows = shape[1], cols = shape[2]
        guard rows >= 84, cols > 0 else { return [] }

        let strides = ma.strides.map { $0.intValue }  // [s0,s1,s2]
        let s1 = strides[1], s2 = strides[2]
        let ptr = ma.dataPointer

        @inline(__always)
        func val(_ r: Int, _ c: Int) -> Float {
            let idx = r * s1 + c * s2
            switch ma.dataType {
            case .float16:
                let bits = ptr.load(fromByteOffset: idx * 2, as: UInt16.self)
                return Float(Float16(bitPattern: bits))
            case .float32:
                return Float(ptr.load(fromByteOffset: idx * 4, as: Float.self))
            case .double:
                return Float(ptr.load(fromByteOffset: idx * 8, as: Double.self))
            @unknown default:
                return 0
            }
        }

        // 找每列最高分类分数 (阈值 0.25)
        var candidates: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, score: Float, cls: Int)] = []
        candidates.reserveCapacity(256)
        for c in 0..<cols {
            var bestScore: Float = 0
            var bestCls = 0
            for k in 0..<80 {
                let sc = val(4 + k, c)
                if sc > bestScore { bestScore = sc; bestCls = k }
            }
            guard bestScore >= 0.25 else { continue }
            let cx = CGFloat(val(0, c)), cy = CGFloat(val(1, c))
            let w = CGFloat(val(2, c)), h = CGFloat(val(3, c))
            candidates.append((cx - w / 2, cy - h / 2, w, h, bestScore, bestCls))
        }

        // NMS (IoU 0.45), 按分数降序
        candidates.sort { $0.score > $1.score }
        var keep: [Bool] = Array(repeating: true, count: candidates.count)
        var boxes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String, confidence: Float)] = []
        for i in 0..<candidates.count {
            guard keep[i] else { continue }
            let a = candidates[i]
            boxes.append((a.x, a.y, a.w, a.h, CocoLabels.names[a.cls], a.score))
            if boxes.count >= 50 { break }
            for j in (i + 1)..<candidates.count where keep[j] {
                let b = candidates[j]
                let ix = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
                let iy = max(0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
                let inter = ix * iy
                if inter <= 0 { continue }
                let union = a.w * a.h + b.w * b.h - inter
                if union > 0 && inter / union > 0.45 { keep[j] = false }
            }
        }

        // ---- 640 模型坐标 -> 扶正后图像的归一化坐标 ----
        // Vision 以 .scaleFill 把扶正后的图像居中裁剪为 640x640, 这里做逆变换
        let Wb = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let Hb = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let Wo = Hb, Ho = Wb            // orientation .right: 宽高互换
        orientedAspect = Wo / Ho
        let s = max(640 / Wo, 640 / Ho)
        let cropX = (Wo * s - 640) / 2
        let cropY = (Ho * s - 640) / 2
        return boxes.map { b in
            Detection(
                x: ((b.x + cropX) / s) / Wo,
                y: ((b.y + cropY) / s) / Ho,
                width: (b.w / s) / Wo,
                height: (b.h / s) / Ho,
                label: b.label,
                confidence: b.confidence
            )
        }
    }
}
