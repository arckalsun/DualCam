import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    // 布局偏好：默认上下平分，比例和方向都会被记住。
    @AppStorage("layout.mode") private var modeRaw: String = LayoutMode.vertical.rawValue
    @AppStorage("layout.ratio") private var ratio: Double = 0.5

    @Environment(\.scenePhase) private var scenePhase
    @State private var recordingStartedAt: Date?

    private var mode: LayoutMode { LayoutMode(rawValue: modeRaw) ?? .vertical }
    private var config: LayoutConfig { LayoutConfig(mode: mode, ratio: CGFloat(ratio)) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.state {
            case .idle, .starting:
                loadingView
            case .unavailable(let message):
                unavailableView(message)
            case .running:
                stage
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            syncLayout()
            camera.start()
        }
        .onChange(of: modeRaw) { _, _ in syncLayout() }
        .onChange(of: ratio) { _, _ in syncLayout() }
        .onChange(of: camera.isRecording) { _, recording in
            recordingStartedAt = recording ? Date() : nil
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.resume()
            case .background: camera.pause()
            default: break
            }
        }
    }

    // MARK: - 主画面

    private var stage: some View {
        GeometryReader { geo in
            let size = geo.size
            let frames = config.frames(in: size)

            ZStack(alignment: .topLeading) {
                ZStack {
                    placeholder(for: .back)
                    CameraPreviewView(layer: camera.previewLayers[.back])
                }
                .frame(width: frames.0.width, height: frames.0.height)
                .overlay(alignment: .topTrailing) { badge(for: .back).padding(10) }
                .offset(x: frames.0.minX, y: frames.0.minY)

                ZStack {
                    placeholder(for: .front)
                    CameraPreviewView(layer: camera.previewLayers[.front])
                }
                .frame(width: frames.1.width, height: frames.1.height)
                .overlay(alignment: .topTrailing) { badge(for: .front).padding(10) }
                .offset(x: frames.1.minX, y: frames.1.minY)

                divider(in: size)
            }
            .coordinateSpace(.named("stage"))
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { controls }
            .overlay { if camera.isBusy { busyOverlay } }
        }
        .ignoresSafeArea()
    }

    private func badge(for slot: CameraSlot) -> some View {
        Text(slot.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
    }

    /// 没有真实摄像头时（模拟器 / 演示模式）显示的占位画面。
    private func placeholder(for slot: CameraSlot) -> some View {
        ZStack {
            LinearGradient(
                colors: slot == .back
                    ? [Color(white: 0.20), Color(white: 0.07)]
                    : [Color(white: 0.15), Color(white: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "camera")
                    .font(.system(size: 26, weight: .light))
                Text(camera.isDemoMode ? "演示画面 · 无摄像头" : "无信号")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - 分割线

    private func divider(in size: CGSize) -> some View {
        let r = config.clampedRatio
        let isVertical = config.mode == .vertical

        return Group {
            if isVertical {
                ZStack {
                    Rectangle().fill(.white.opacity(0.001))
                    Rectangle().fill(.white.opacity(0.8)).frame(height: 2)
                    Capsule().fill(.white).frame(width: 54, height: 5)
                }
                .frame(width: size.width, height: 44)
                .position(x: size.width / 2, y: size.height * r)
                .gesture(ratioGesture(size: size, isVertical: true))
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.001))
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 2)
                    Capsule().fill(.white).frame(width: 5, height: 54)
                }
                .frame(width: 44, height: size.height)
                .position(x: size.width * r, y: size.height / 2)
                .gesture(ratioGesture(size: size, isVertical: false))
            }
        }
    }

    private func ratioGesture(size: CGSize, isVertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
            .onChanged { value in
                let raw = isVertical
                    ? value.location.y / max(size.height, 1)
                    : value.location.x / max(size.width, 1)
                let clamped = min(max(raw, LayoutConfig.ratioRange.lowerBound),
                                  LayoutConfig.ratioRange.upperBound)
                ratio = Double(clamped)
            }
    }

    // MARK: - 顶部状态

    private var topBar: some View {
        HStack(spacing: 8) {
            if camera.isRecording {
                recordingBadge
            }
            if camera.isDemoMode {
                Text("演示模式 · 可拖分割线")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.8), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var recordingBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(elapsedText(at: context.date))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private func elapsedText(at date: Date) -> String {
        guard let start = recordingStartedAt else { return "REC" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 底部控制

    private var controls: some View {
        HStack(spacing: 38) {
            photoButton
            recordButton
            layoutButton
        }
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top,
                           endPoint: .bottom)
                .frame(height: 200)
                .allowsHitTesting(false)
        }
    }

    private var photoButton: some View {
        Button {
            camera.capturePhoto()
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: 58, height: 58)
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.isBusy || camera.isRecording)
        .opacity(camera.isRecording ? 0.35 : 1)
    }

    private var recordButton: some View {
        Button {
            camera.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 78, height: 78)
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.isBusy)
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
    }

    private var layoutButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                modeRaw = mode.toggled.rawValue
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.toggled.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                Text(mode.toggled.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(.white.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 其它状态

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            ProgressView().tint(.white).scaleEffect(1.3)
        }
        .allowsHitTesting(false)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("正在启动双摄…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.65))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 36)
            Button("重试") {
                camera.retry()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.9))
            .foregroundStyle(.black)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = camera.toast {
            Text(toast)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(.bottom, 140)
                .transition(.opacity)
        }
    }

    private func syncLayout() {
        camera.updateLayout(config)
    }
}

#Preview {
    ContentView()
}
