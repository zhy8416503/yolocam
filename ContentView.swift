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

/// 左上角设置菜单 (长按状态条弹出): 镜头 / 分辨率 / FPS / 片门全开 / 推理帧率 / 天线
private struct SettingsPanel: View {
    @ObservedObject var camera: CameraManager
    @State private var fpsSlider: Double = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("镜头").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                ForEach(camera.availableLenses, id: \.self) { l in
                    settingButton(l.rawValue, selected: camera.lens == l) {
                        camera.setLens(l)
                    }
                }
            }
            Text("分辨率").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                ForEach(camera.availableResolutions, id: \.self) { r in
                    settingButton(r.rawValue, selected: camera.videoResolution == r && !camera.openGateEnabled) {
                        camera.setVideoResolution(r)
                    }
                }
            }
            .opacity(camera.openGateEnabled ? 0.4 : 1.0)
            .disabled(camera.openGateEnabled)
            HStack {
                Text("FPS").font(.caption2).foregroundColor(.gray)
                Spacer()
                Text("\(camera.videoFPS)").font(.caption2).foregroundColor(.white)
            }
            Slider(value: $fpsSlider, in: 1...60, step: 1) {
                Text("FPS")
            } onEditingChanged: { editing in
                if !editing {
                    camera.setVideoFPS(Int(fpsSlider))
                }
            }
            .onAppear { fpsSlider = Double(camera.videoFPS) }
            .onChange(of: camera.videoFPS) { newValue in
                fpsSlider = Double(newValue)
            }
            settingButton(
                camera.openGateEnabled ? "片门全开：已开启" : "尝试开启片门全开",
                selected: camera.openGateEnabled
            ) {
                camera.setOpenGateEnabled(!camera.openGateEnabled)
            }
            Text("推理帧率").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                ForEach([5, 10, 15, 30], id: \.self) { v in
                    settingButton("\(v)", selected: Int(camera.fpsLimit) == v) {
                        camera.setFPSLimit(Double(v))
                    }
                }
            }
            Text("天线").font(.caption2).foregroundColor(.gray)
            HStack(spacing: 8) {
                settingButton("开", selected: camera.antennaEnabled) {
                    camera.setAntennaEnabled(true)
                }
                settingButton("关", selected: !camera.antennaEnabled) {
                    camera.setAntennaEnabled(false)
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

                // 天线: 仅对人物, 从屏幕顶部中心连到框顶边中点
                if camera.antennaEnabled {
                    ForEach(camera.detections.indices, id: \.self) { i in
                        let d = camera.detections[i]
                        if d.label == "person" {
                            let r = mapBox(d, viewSize: geo.size, aspect: camera.orientedAspect)
                            Path { path in
                                path.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                                path.addLine(to: CGPoint(x: r.midX, y: r.minY))
                            }
                            .stroke(Color.yellow, lineWidth: 1.5)
                        }
                    }
                }

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

                // 左上: 状态条 (长按弹出设置菜单) + 录制指示
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if camera.isRecording {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                    }
                                    Text("\(Int(camera.fps)) fps")
                                }
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

                // 底部: 录像按钮 (中) + 变焦 (右下)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        // 录像按钮
                        Button(action: { camera.toggleRecording() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.55))
                                    .frame(width: 64, height: 64)
                                if camera.isRecording {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red)
                                        .frame(width: 26, height: 26)
                                } else {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 52, height: 52)
                                }
                            }
                        }
                        Spacer()
                        ZoomControl(camera: camera, expanded: $showZoomMenu)
                    }
                    .padding(.horizontal, 18)
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
