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

/// 左上角设置菜单 (长按状态条弹出): 镜头 / 推理帧率 / 分辨率
private struct SettingsPanel: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("镜头").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                settingButton("后置", selected: camera.cameraPosition == .back) {
                    camera.switchCamera(to: .back)
                }
                settingButton("前置", selected: camera.cameraPosition == .front) {
                    camera.switchCamera(to: .front)
                }
            }
            Text("推理帧率").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                ForEach([5, 10, 15, 30], id: \.self) { v in
                    settingButton("\(v)", selected: Int(camera.fpsLimit) == v) {
                        camera.setFPSLimit(Double(v))
                    }
                }
            }
            Text("分辨率").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                settingButton("流畅", selected: camera.resolutionPreset == .hd1280x720) {
                    camera.setResolution(.hd1280x720)
                }
                settingButton("高清", selected: camera.resolutionPreset == .hd1920x1080) {
                    camera.setResolution(.hd1920x1080)
                }
                settingButton("超清", selected: camera.resolutionPreset == .hd4K3840x2160) {
                    camera.setResolution(.hd4K3840x2160)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.72))
        .cornerRadius(12)
    }

    private func settingButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.green : Color.white.opacity(0.15))
                .foregroundColor(selected ? .black : .white)
                .cornerRadius(8)
        }
    }
}

/// 右下角变焦二级菜单 (默认收拢, 点开展开)
private struct ZoomControl: View {
    @ObservedObject var camera: CameraManager
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 8) {
            if expanded {
                ForEach([5, 3, 2, 1], id: \.self) { z in
                    zoomButton("\(z)x") {
                        camera.setZoom(CGFloat(z))
                        expanded = false
                    }
                }
            }
            zoomButton(zoomLabel) {
                expanded.toggle()
            }
        }
    }

    private var zoomLabel: String {
        let z = camera.zoomFactor
        return z == floor(z) ? "\(Int(z))x" : String(format: "%.1fx", z)
    }

    private func zoomButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.55))
                .foregroundColor(.white)
                .clipShape(Circle())
        }
    }
}

struct ContentView: View {
    @StateObject private var camera: CameraManager
    private let preview: PreviewUIView
    @State private var showSettings = false
    @State private var showZoomMenu = false

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

                // 菜单展开时, 点空白处收起
                if showSettings || showZoomMenu {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showSettings = false
                            showZoomMenu = false
                        }
                }

                // 左上: 状态条 (长按弹出设置菜单)
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Int(camera.fps)) fps")
                                Text("\(camera.detections.count) 个目标")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.45))
                            .cornerRadius(8)
                            .onLongPressGesture {
                                showSettings.toggle()
                            }
                            if showSettings {
                                SettingsPanel(camera: camera)
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 54)
                    .padding(.horizontal, 12)
                    Spacer()
                }

                // 右下: 变焦二级菜单
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ZoomControl(camera: camera, expanded: $showZoomMenu)
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 34)
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
