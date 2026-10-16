import CoreML
import Vision
import CoreVideo
import CoreImage
import Foundation

struct Detection: Identifiable {
    let id = UUID()
    // 归一化坐标 (0~1), 以 Vision 扶正后的图像为基准, 原点左上
    let x, y, width, height: CGFloat
    let label: String
    let confidence: Float
}

enum ModelVariant: String {
    case n = "yolo26n"  // 常规精度 (唯一模型)
    var displayName: String { return "常规精度" }
}

enum DetectorError: Error {
    case modelNotFound
}

final class Detector {
    private let request: VNCoreMLRequest
    private let ciContext = CIContext()
    private var letterboxBuffer: CVPixelBuffer?
    // 扶正后图像的宽高比 (Wo/Ho), 由最近一帧的 pixelBuffer 尺寸决定
    var orientedAspect: CGFloat = 9.0 / 16.0
    let variant: ModelVariant

    init(variant: ModelVariant = .n) throws {
        self.variant = variant
        let bundle = Bundle.main
        // Xcode 把 yolo26n.mlpackage / yolo26x.mlpackage 编译成 .mlmodelc
        var modelURL = bundle.url(forResource: variant.rawValue, withExtension: "mlmodelc")
        if modelURL == nil {
            modelURL = bundle.url(forResource: variant.rawValue, withExtension: "mlpackage")
        }
        guard let url = modelURL else { throw DetectorError.modelNotFound }

        let config = MLModelConfiguration()
        config.computeUnits = .all   // ANE / GPU / CPU 自动选最快的
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        let vnModel = try VNCoreMLModel(for: mlModel)

        let req = VNCoreMLRequest(model: vnModel)
        // 输入已经是手动 letterbox 好的 640x640, 这里不再裁剪
        req.imageCropAndScaleOption = .scaleFit
        self.request = req
    }

    /// 对一帧做检测。pixelBuffer 是相机原始 buffer (sensor 横屏尺寸)。
    /// 先扶正 + letterbox 成 640x640, 返回扶正后竖屏图像的归一化坐标。
    func detect(pixelBuffer: CVPixelBuffer) throws -> [Detection] {
        guard let (lb, Wo, Ho) = letterbox(pixelBuffer) else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: lb, orientation: .up, options: [:])
        try handler.perform([request])

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let out = results.first?.featureValue.multiArrayValue else { return [] }
        return decode(out, Wo: Wo, Ho: Ho)
    }

    /// 扶正 (顺时针 90°) + letterbox (等比 fit + 灰边) 到 640x640。
    private func letterbox(_ pixelBuffer: CVPixelBuffer) -> (CVPixelBuffer, CGFloat, CGFloat)? {
        if letterboxBuffer == nil {
            letterboxBuffer = makeBuffer()
        }
        guard let dest = letterboxBuffer else { return nil }

        let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let Wo = upright.extent.width
        let Ho = upright.extent.height
        guard Wo > 0, Ho > 0 else { return nil }
        orientedAspect = Wo / Ho

        let s = min(640 / Wo, 640 / Ho)
        let dx = (640 - Wo * s) / 2
        let dy = (640 - Ho * s) / 2
        let placed = upright
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let gray = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        ciContext.render(placed.composited(over: gray), to: dest)
        return (dest, Wo, Ho)
    }

    private func makeBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 640,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    // YOLO26 端到端输出 [1,300,6]: [x1,y1,x2,y2,conf,class_id], 无需 NMS
    // 坐标为 0~640 像素
    private func decode(_ ma: MLMultiArray, Wo: CGFloat, Ho: CGFloat) -> [Detection] {
        let shape = ma.shape.map { $0.intValue }
        // 可能是 [1,300,6] 或 [300,6]
        var n = 300, dims = 6
        var baseOffset = 0
        if shape.count == 3 {
            // [1,300,6]
            n = shape[1]; dims = shape[2]
        } else if shape.count == 2 {
            // [300,6]
            n = shape[0]; dims = shape[1]
        } else {
            return []
        }
        guard dims >= 6, n > 0 else { return [] }

        let strides = ma.strides.map { $0.intValue }
        let ptr = ma.dataPointer

        @inline(__always)
        func val(_ i: Int, _ k: Int) -> Float {
            // 计算索引: shape [1,n,6] -> idx = i*s1 + k*s2; shape [n,6] -> idx = i*s0 + k*s1
            let idx: Int
            if shape.count == 3 {
                idx = i * strides[1] + k * strides[2]
            } else {
                idx = i * strides[0] + k * strides[1]
            }
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

        var boxes: [(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, label: String, conf: Float)] = []
        for i in 0..<n {
            let conf = val(i, 4)
            guard conf >= 0.25 else { continue }
            let cls = Int(val(i, 5))
            guard cls >= 0, cls < 80 else { continue }
            boxes.append((CGFloat(val(i, 0)), CGFloat(val(i, 1)),
                         CGFloat(val(i, 2)), CGFloat(val(i, 3)),
                         cocoLabels[cls], conf))
            if boxes.count >= 50 { break }
        }

        // 640 模型坐标 -> 扶正后图像归一化坐标 (letterbox 逆变换)
        let lb = min(640 / Wo, 640 / Ho)
        let offX = (640 - Wo * lb) / 2
        let offY = (640 - Ho * lb) / 2
        return boxes.map { b in
            let x1n = ((b.x1 - offX) / lb) / Wo
            let y1n = ((b.y1 - offY) / lb) / Ho
            let x2n = ((b.x2 - offX) / lb) / Wo
            let y2n = ((b.y2 - offY) / lb) / Ho
            return Detection(
                x: max(0, min(1, x1n)),
                y: max(0, min(1, y1n)),
                width: max(0, min(1, x2n - x1n)),
                height: max(0, min(1, y2n - y1n)),
                label: b.label,
                confidence: b.conf
            )
        }
    }
}
