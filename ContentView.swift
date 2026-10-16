import SwiftUI
import AVFoundation

/// 预览 UIView (AVCaptureVideoPreviewLayer 做底)
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { self.layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

private struct PreviewViewWrapper: UIViewRepresentable {
    let preview: PreviewUIView
    func makeUIView(context: Context) -> PreviewUIView { preview }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var camera: CameraManager
    private let preview: PreviewUIView

    init() {
        let pv = PreviewUIView()
        self.preview = pv
        _camera = StateObject(wrappedValue: CameraManager(previewLayer: pv.previewLayer))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PreviewViewWrapper(preview: preview)
                    .frame(width: geo.size.width, height: geo.size.height)

                // 检测框: 归一化坐标按 aspect-fill 映射到屏幕
                ForEach(camera.detections.indices, id: \.self) { i in
                    let d = camera.detections[i]
                    let r = mapBox(d, viewSize: geo.size, aspect: camera.orientedAspect)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .stroke(Color.green, lineWidth: 2)
                        Text("\(d.label) \(String(format: "%.2f", d.confidence))")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.85))
                            .foregroundColor(.black)
                            .offset(y: -20)
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                }

                // 顶部: 模型切换 (无二级菜单, 直接放最顶上)
                // iPhone 12 Pro Max (2778x1284) 适配: 避开刘海
                VStack {
                    HStack(spacing: 16) {
                        Button(action: { camera.switchModel(.n) }) {
                            Text("常规精度")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(camera.modelVariant == .n ? Color.blue : Color.gray.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(20)
                        }
                        Button(action: { camera.switchModel(.x) }) {
                            Text("超高精度")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(camera.modelVariant == .x ? Color.blue : Color.gray.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(20)
                        }
                    }
                    .padding(.top, 54)  // 避开刘海/状态栏

                    // 状态
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(camera.fps)) fps")
                            Text("\(camera.detections.count) 个目标")
                            Text(camera.status)
                                .font(.caption2)
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.45))
                        .cornerRadius(8)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    /// 扶正后图像 (宽高比 aspect) 以 aspect-fill 铺满 view, 求归一化框对应的屏幕矩形
    private func mapBox(_ d: Detection, viewSize: CGSize, aspect: CGFloat) -> CGRect {
        let scale = max(viewSize.width / aspect, viewSize.height)
        let dispW = aspect * scale
        let dispH = scale
        let offX = (dispW - viewSize.width) / 2
        let offY = (dispH - viewSize.height) / 2
        return CGRect(x: d.x * dispW - offX,
                      y: d.y * dispH - offY,
                      width: d.width * dispW,
                      height: d.height * dispH)
    }
}
