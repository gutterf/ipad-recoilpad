import SwiftUI
import ReplayKit

enum Theme {
    static let bg      = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let panel   = Color(red: 0.086, green: 0.094, blue: 0.114)
    static let sunken  = Color(red: 0.043, green: 0.047, blue: 0.059)
    static let stroke  = Color.white.opacity(0.07)
    static let accent  = Color(red: 1.00, green: 0.54, blue: 0.24)
    static let danger  = Color(red: 1.00, green: 0.33, blue: 0.33)
    static let ok      = Color(red: 0.36, green: 0.82, blue: 0.52)
    static let text    = Color(red: 0.91, green: 0.91, blue: 0.90)
    static let dim     = Color.white.opacity(0.40)

    static let mono = Font.system(.body, design: .monospaced)
    static func m(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private struct PanelBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }
}

private extension View {
    func panel() -> some View { modifier(PanelBox()) }
}

// MARK: - 主界面

struct ControlPanel: View {

    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    capabilityBanner
                    levelCard
                    trajectoryCard
                    telemetryCard
                    broadcastCard
                    advancedCard
                    templateCard
                }
                .padding(18)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RECOIL PAD").font(Theme.m(15, .semibold)).foregroundStyle(Theme.text)
                Text("和平精英 · 后坐力控制").font(Theme.m(11)).foregroundStyle(Theme.dim)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isBroadcasting ? Theme.ok : Theme.dim)
                    .frame(width: 7, height: 7)
                Text(model.isBroadcasting ? "采集中" : "未采集")
                    .font(Theme.m(11))
                    .foregroundStyle(model.isBroadcasting ? Theme.ok : Theme.dim)
            }
        }
    }

    // MARK: 能力状态

    private var capabilityBanner: some View {
        let ok = model.capability.isAvailable
        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ok ? Theme.ok : Theme.danger)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.capability.title)
                    .font(Theme.m(13, .medium))
                    .foregroundStyle(Theme.text)
                Text(model.capability.detail)
                    .font(Theme.m(11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .panel()
    }

    // MARK: 滑块

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("后坐力强度").font(Theme.m(12)).foregroundStyle(Theme.dim)
                Spacer()
                Text(model.settings.levelLabel)
                    .font(Theme.m(12, .medium))
                    .foregroundStyle(Theme.accent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.1f", model.settings.level))
                    .font(Theme.m(54, .semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text("/ 10").font(Theme.m(16)).foregroundStyle(Theme.dim)
            }

            Slider(value: $model.settings.level, in: 0...10, step: 0.5)
                .tint(Theme.accent)

            HStack {
                Text("0 · 无后座").font(Theme.m(10)).foregroundStyle(Theme.dim)
                Spacer()
                Text("10 · 游戏原始").font(Theme.m(10)).foregroundStyle(Theme.dim)
            }

            Divider().overlay(Theme.stroke)

            HStack(spacing: 4) {
                Text("补偿比例").font(Theme.m(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.0f%%", model.settings.compensationRatio * 100))
                    .font(Theme.m(11, .medium))
                    .foregroundStyle(Theme.text)
            }

            // 不能注入时，这个滑块的实际含义变了 —— 它不再是"自动压多少"，
            // 而是"这把枪需要你手动压多少"。不说清楚，用户会盯着灰色开关发懵。
            if !model.capability.isAvailable {
                Text("当前档位不会自动补偿。它显示的是这把枪在理想压枪下的目标弹道，\n配合上面的曲线图，用来在训练场练手动压枪的手感。")
                    .font(Theme.m(10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .panel()
    }

    // MARK: 弹道预览

    private var trajectoryCard: some View {
        let profile = model.activeProfile
        let drift = profile.maxHorizontalDrift

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("弹道").font(Theme.m(12)).foregroundStyle(Theme.dim)
                Spacer()
                Text(profile.displayName)
                    .font(Theme.m(12, .medium))
                    .foregroundStyle(Theme.text)
                Text("\(Int(profile.rpm)) RPM")
                    .font(Theme.m(11))
                    .foregroundStyle(Theme.dim)
            }

            TrajectoryView(profile: profile, ratio: model.settings.compensationRatio)
                .frame(height: 130)

            HStack(spacing: 14) {
                legend(color: Theme.dim, label: "原始")
                legend(color: Theme.accent, label: "补偿后")
                Spacer()
                if let weapon = model.detectedWeaponName {
                    Text("已识别 \(weapon)")
                        .font(Theme.m(10))
                        .foregroundStyle(Theme.ok)
                }
            }

            HStack(spacing: 4) {
                Text("峰值横摆").font(Theme.m(10)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.2f%%", drift * 100))
                    .font(Theme.m(10, .medium))
                    .foregroundStyle(drift > 0.01 ? Theme.accent : Theme.ok)
                Text(drift > 0.01 ? "· 需要横向纠正" : "· 接近纯垂直")
                    .font(Theme.m(10))
                    .foregroundStyle(Theme.dim)
            }
        }
        .panel()
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2.5)
            Text(label).font(Theme.m(10)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: 遥测

    private var telemetryCard: some View {
        let profile = model.activeProfile
        let measured = Double(model.measuredFireRate)
        let rateFill = measured > 0 ? measured / profile.rpm : 0

        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("遥测").font(Theme.m(12)).foregroundStyle(Theme.dim)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isFiring ? Theme.accent : Theme.dim)
                        .frame(width: 7, height: 7)
                    Text(model.isFiring ? "开火中" : "待机")
                        .font(Theme.m(10))
                        .foregroundStyle(model.isFiring ? Theme.accent : Theme.dim)
                }
            }

            metric("实测射速",
                   value: measured > 0 ? String(format: "%.0f", measured) : "—",
                   unit: "RPM",
                   note: String(format: "标称 %.0f", profile.rpm),
                   fill: rateFill)

            metric("匹配距离",
                   value: model.detectedWeaponName == nil ? "—" : String(format: "%.1f", model.matchConfidence),
                   unit: "",
                   note: model.detectedWeaponName == nil ? "未识别" : "越小越像",
                   fill: model.detectedWeaponName == nil
                        ? 0
                        : 1.0 - min(Double(model.matchConfidence) / 20.0, 1.0))

            metric("音频通量",
                   value: String(format: "%.4f", model.audioLevel),
                   unit: "",
                   note: "枪声判定量",
                   fill: min(log10(1 + Double(model.audioLevel) * 100) / 2.0, 1.0))
        }
        .panel()
    }

    private func metric(_ label: String, value: String, unit: String,
                        note: String, fill: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).font(Theme.m(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(note).font(Theme.m(10)).foregroundStyle(Theme.dim)
                Text(value).font(Theme.m(12, .medium)).foregroundStyle(Theme.text)
                if !unit.isEmpty {
                    Text(unit).font(Theme.m(10)).foregroundStyle(Theme.dim)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sunken)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * CGFloat(min(max(fill, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: 采集

    private var broadcastCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("屏幕与音频采集").font(Theme.m(12)).foregroundStyle(Theme.dim)

            Text("识别武器和判定开火都依赖 ReplayKit 广播。点下面的按钮，\n在系统弹窗里选择 RecoilPad 并开始直播。")
                .font(Theme.m(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                BroadcastPickerButton(extensionID: AppModel.broadcastExtensionID)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isBroadcasting ? "正在采集" : "点击开始")
                        .font(Theme.m(13, .medium))
                        .foregroundStyle(model.isBroadcasting ? Theme.ok : Theme.text)
                    Text("视频 \(model.videoFrames) 帧 · 音频 \(model.audioFrames) 块 · 开火 \(model.fireCount) 次")
                        .font(Theme.m(10))
                        .foregroundStyle(Theme.dim)
                    Text(pathLabel)
                        .font(Theme.m(10))
                        .foregroundStyle(model.usingSharedMemory ? Theme.dim : Theme.accent)
                }
                Spacer()
            }

            // 免费账号签不了 App Group，这里会显示 loopback 回退通路。
            // 如果一直停在"等待连接"，说明扩展连不上主 App 的监听端口 ——
            // 那 App 仍能手动选枪使用，但拿不到自动识别和开火检测。
            if !model.usingSharedMemory, !model.loopbackConnected {
                Text("扩展未连上主 App。若长时间如此，自动识别与开火检测不可用，\n可在下方手动选择武器。")
                    .font(Theme.m(10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    private var pathLabel: String {
        if model.usingSharedMemory {
            return "通路：App Group 共享内存"
        }
        return model.loopbackConnected
            ? "通路：loopback（App Group 不可用）"
            : "通路：loopback 等待连接"
    }

    // MARK: 高级参数

    private var advancedCard: some View {
        let enabled = model.capability.isAvailable

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("注入参数").font(Theme.m(12)).foregroundStyle(Theme.dim)
                Spacer()
                if !enabled {
                    Text("不可用")
                        .font(Theme.m(10, .medium))
                        .foregroundStyle(Theme.danger)
                }
            }

            Toggle(isOn: $model.settings.injectionEnabled) {
                Text("启用自动压枪").font(Theme.m(12)).foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)
            .disabled(!enabled)

            paramSlider("标定系数", value: $model.settings.baseScale, range: 0.2...3.0, step: 0.05)
            paramSlider("垂直增益", value: $model.settings.verticalGain, range: 0.2...2.5, step: 0.05)
            paramSlider("水平增益", value: $model.settings.horizontalGain, range: 0.0...2.5, step: 0.05)
            paramSlider("开火灵敏度", value: $model.settings.onsetSensitivity, range: 0.0...1.0, step: 0.05)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 4) {
                Text("虚拟手指锚点").font(Theme.m(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "x %.2f  y %.2f", model.settings.anchor.x, model.settings.anchor.y))
                    .font(Theme.m(11))
                    .foregroundStyle(Theme.text)
            }
        }
        .panel()
        .disabled(!enabled && false)
        .opacity(enabled ? 1 : 0.5)
    }

    private func paramSlider(_ label: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Theme.m(11)).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(Theme.m(11))
                    .foregroundStyle(Theme.text)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
        }
    }

    // MARK: 模板

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("武器模板").font(Theme.m(12)).foregroundStyle(Theme.dim)
                Spacer()
                Text("\(model.templateCount) 个")
                    .font(Theme.m(11, .medium))
                    .foregroundStyle(model.templateCount > 0 ? Theme.text : Theme.danger)
            }

            Text("在游戏里切到某把枪，点「抓取当前画面」，回到这里给它指定武器名。\n至少做一个模板之后，自动识别才会生效。")
                .font(Theme.m(11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.requestCapture()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "camera.viewfinder")
                    Text("抓取当前画面").font(Theme.m(12, .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(!model.isBroadcasting)

            if !model.captures.isEmpty {
                Divider().overlay(Theme.stroke)
                Text("待标注").font(Theme.m(11)).foregroundStyle(Theme.dim)
                ForEach(model.captures, id: \.self) { url in
                    CaptureRow(url: url) { weaponID in
                        model.assignCapture(url, to: weaponID)
                    }
                }
            }
        }
        .panel()
    }
}

// MARK: - 抓帧行

private struct CaptureRow: View {

    let url: URL
    let onAssign: (String) -> Void
    @State private var image: UIImage?
    @State private var selection: String = WeaponLibrary.all[0].id

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.sunken)
                }
            }
            .frame(width: 84, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke))

            Picker("", selection: $selection) {
                ForEach(WeaponLibrary.all) { w in
                    Text(w.displayName).tag(w.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.text)

            Spacer(minLength: 0)

            Button("保存") { onAssign(selection) }
                .font(Theme.m(12, .medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
        .task {
            image = await Task.detached {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }.value
        }
    }
}

// MARK: - 弹道绘制

struct TrajectoryView: View {

    let profile: WeaponProfile
    let ratio: Double

    var body: some View {
        Canvas { context, size in
            let points = profile.cumulative2D()
            guard points.count > 1 else { return }

            let maxY = points.map { $0.dy }.max() ?? 0
            let maxX = points.map { abs($0.dx) }.max() ?? 0
            guard maxY > 0 else { return }

            // 水平与垂直共用同一个比例尺。弹道的左右漂移本来就远小于上跳
            // （AKM 30 发横摆约 1.3% 屏高，上跳接近 98%），分开缩放会把漂移
            // 视觉放大，看起来像在扫射，那是假象 —— 真实手感里它就是接近垂直的。
            let inset: CGFloat = 10
            let usableHeight = size.height - inset * 2
            let span = max(maxY, maxX * 2)
            let scale = usableHeight / CGFloat(span)
            let origin = CGPoint(x: size.width / 2, y: size.height - inset)

            func project(_ p: RecoilPoint, factor: Double) -> CGPoint {
                CGPoint(x: origin.x + CGFloat(p.dx * factor) * scale,
                        y: origin.y - CGFloat(p.dy * factor) * scale)
            }

            // 理想直线：压枪的目标就是让弹道贴着这条垂线走
            var axis = Path()
            axis.move(to: origin)
            axis.addLine(to: CGPoint(x: origin.x, y: inset))
            context.stroke(axis, with: .color(Theme.stroke),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

            // 原始弹道：含左右漂移
            var raw = Path()
            for (i, p) in points.enumerated() {
                let pt = project(p, factor: 1)
                if i == 0 { raw.move(to: pt) } else { raw.addLine(to: pt) }
            }
            context.stroke(raw, with: .color(Theme.dim),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

            // 当前档位下补偿后的弹道
            var corrected = Path()
            for (i, p) in points.enumerated() {
                let pt = project(p, factor: 1 - ratio)
                if i == 0 { corrected.move(to: pt) } else { corrected.addLine(to: pt) }
            }
            context.stroke(corrected, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // 最后一发的落点
            if let last = points.last {
                let end = project(last, factor: 1 - ratio)
                let dot = CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(Theme.accent))
            }
        }
    }
}

// MARK: - 系统广播选择器

struct BroadcastPickerButton: UIViewRepresentable {

    let extensionID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        view.preferredExtension = extensionID
        view.showsMicrophoneButton = false
        if let button = view.subviews.compactMap({ $0 as? UIButton }).first {
            button.imageView?.tintColor = .white
        }
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
