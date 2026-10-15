import CoreML
import CoreVideo
import Foundation
import Vision

/// A single object detection. `rect` is normalized (0...1) in the full
/// camera-frame space, origin top-left. The model input is the whole frame
/// stretched to 640x640 (Vision `.scaleFill`), so model space == frame space.
struct Detection {
    let rect: CGRect
    let label: String
    let confidence: Float
}

enum DetectorError: Error {
    case modelNotFound
}

/// YOLOv8n Core ML wrapper: Vision handles pixel-format conversion and
/// scaling, we decode the raw [84, 8400] output tensor and run NMS by hand.
final class Detector {
    private let vnModel: VNCoreMLModel
    private let scoreThreshold: Float = 0.25
    private let iouThreshold: CGFloat = 0.45

    init() throws {
        let bundle = Bundle.main
        // Xcode compiles yolov8n.mlpackage into yolov8n.mlmodelc inside the bundle.
        var modelURL = bundle.url(forResource: "yolov8n", withExtension: "mlmodelc")
        if modelURL == nil,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: bundle.bundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            modelURL = urls.first(where: { $0.pathExtension == "mlmodelc" })
        }
        // Fallback: raw .mlpackage, in case Xcode copied it as a resource instead.
        if modelURL == nil {
            modelURL = bundle.url(forResource: "yolov8n", withExtension: "mlpackage")
        }
        guard let url = modelURL else { throw DetectorError.modelNotFound }
        var config = MLModelConfiguration()
        config.computeUnits = .all // ANE + GPU + CPU
        let model = try MLModel(contentsOf: url, configuration: config)
        vnModel = try VNCoreMLModel(for: model)
    }

    func detect(pixelBuffer: CVPixelBuffer) -> [Detection] {
        var detections: [Detection] = []
        let request = VNCoreMLRequest(model: vnModel) { req, _ in
            guard let results = req.results as? [VNCoreMLFeatureValueObservation],
                  let ma = results.first?.featureValue.multiArrayValue
            else { return }
            detections = self.decode(ma)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        return detections
    }

    // MARK: - YOLOv8 output decoding ([cx, cy, w, h, 80 class scores] x 8400)

    private func decode(_ ma: MLMultiArray) -> [Detection] {
        let shape = ma.shape.map { $0.intValue }
        let strides = ma.strides.map { $0.intValue }
        guard let chDim = shape.firstIndex(of: 84),
              let anDim = shape.firstIndex(of: 8400),
              shape.count == strides.count
        else { return [] }
        let anchors = 8400
        let ptr = ma.dataPointer

        func value(channel c: Int, anchor a: Int) -> Float {
            var idx = [Int](repeating: 0, count: shape.count)
            idx[chDim] = c
            idx[anDim] = a
            var lin = 0
            for d in 0..<shape.count { lin += idx[d] * strides[d] }
            switch ma.dataType {
            case .float16:
                return Float(Float16(bitPattern: ptr.assumingMemoryBound(to: UInt16.self)[lin]))
            case .float32:
                return ptr.assumingMemoryBound(to: Float.self)[lin]
            case .double:
                return Float(ptr.assumingMemoryBound(to: Double.self)[lin])
            @unknown default:
                return 0
            }
        }

        var dets: [Detection] = []
        dets.reserveCapacity(64)
        for a in 0..<anchors {
            let cx = value(channel: 0, anchor: a)
            let cy = value(channel: 1, anchor: a)
            let w = value(channel: 2, anchor: a)
            let h = value(channel: 3, anchor: a)
            var bestClass = -1
            var bestScore = scoreThreshold
            for c in 0..<80 {
                let s = value(channel: 4 + c, anchor: a)
                if s > bestScore {
                    bestScore = s
                    bestClass = c
                }
            }
            if bestClass >= 0 {
                let rect = CGRect(
                    x: CGFloat((cx - w / 2) / 640),
                    y: CGFloat((cy - h / 2) / 640),
                    width: CGFloat(w / 640),
                    height: CGFloat(h / 640))
                dets.append(Detection(rect: rect, label: cocoLabels[bestClass], confidence: bestScore))
            }
        }
        return nms(dets)
    }

    private func nms(_ dets: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        let groups = Dictionary(grouping: dets, by: { $0.label })
        for (_, var cls) in groups {
            cls.sort { $0.confidence > $1.confidence }
            while let best = cls.first {
                cls.removeFirst()
                kept.append(best)
                cls.removeAll { self.iou($0.rect, best.rect) >= self.iouThreshold }
            }
        }
        return kept.sorted { $0.confidence > $1.confidence }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}
