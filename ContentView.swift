import AVFoundation
import SwiftUI
import UIKit

/// UIView whose backing layer is the camera preview layer.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

/// Bounding-box overlay. `videoRect` is where the 16:9 camera frame is drawn
/// (aspect-fit) inside the view; detections are normalized to that frame.
struct DetectionOverlay: View {
    let detections: [Detection]
    let videoRect: CGRect

    var body: some View {
        ZStack {
            ForEach(detections.indices, id: \.self) { i in
                let d = detections[i]
                let bw = d.rect.width * videoRect.width
                let bh = d.rect.height * videoRect.height
                let bx = videoRect.minX + d.rect.minX * videoRect.width
                let by = videoRect.minY + d.rect.minY * videoRect.height
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: max(bw, 2), height: max(bh, 2))
                    Text("\(d.label) \(Int(d.confidence * 100))%")
                        .font(.caption2)
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .offset(y: by < 24 ? bh + 2 : -20)
                }
                .position(x: bx + bw / 2, y: by + bh / 2)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                // 16:9 camera frame, aspect-fit, centered.
                let w = geo.size.width
                let h = w * 9 / 16
                let y0 = (geo.size.height - h) / 2
                let videoRect = CGRect(x: 0, y: y0, width: w, height: h)
                PreviewView(session: camera.session)
                    .frame(width: w, height: h)
                    .position(x: w / 2, y: y0 + h / 2)
                    .clipped()
                DetectionOverlay(detections: camera.detections, videoRect: videoRect)
            }
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.0f fps", camera.inferFPS))
                        Text("\(camera.detections.count) 个目标")
                        if !camera.status.isEmpty {
                            Text(camera.status).foregroundColor(.yellow)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(8)
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .onAppear { camera.start() }
    }
}
