import Foundation
import CoreGraphics

/// 连发过程中把后坐力曲线转换成"这一 tick 该往下压多少"。
///
/// 采样是按时间连续插值的，不是按发数离散跳变 —— 离散跳变在
/// 120Hz 的 ProMotion 屏上会看到明显的阶梯感。
public final class RecoilEngine {

    public private(set) var profile: WeaponProfile
    public var settings: RecoilSettings

    private var cumX: [Double] = []
    private var cumY: [Double] = []
    private var interval: Double = 0.1

    private var origin: Double?
    private var emitted = CGPoint.zero

    public init(profile: WeaponProfile, settings: RecoilSettings) {
        self.profile = profile
        self.settings = settings
        rebuild()
    }

    public func update(profile: WeaponProfile) {
        self.profile = profile
        rebuild()
    }

    public func update(settings: RecoilSettings) {
        self.settings = settings
    }

    private func rebuild() {
        interval = 60.0 / max(profile.rpm, 1)
        cumX = [0]
        cumY = [0]
        var x = 0.0
        var y = 0.0
        for p in profile.pattern {
            x += p.dx
            y += p.dy
            cumX.append(x)
            cumY.append(y)
        }
    }

    /// 时间轴起点。传 onset 检测到的开火时刻，不是"当前时刻"。
    public func begin(at time: Double) {
        origin = time
        emitted = .zero
    }

    public func reset() {
        origin = nil
        emitted = .zero
    }

    public var isActive: Bool { origin != nil }

    /// 有效补偿强度：同时受滑块档位和标定系数影响。
    public var effectiveScale: Double {
        settings.baseScale * settings.compensationRatio
    }

    /// 返回相对上一次采样的**增量**位移（归一化单位）。
    public func sample(at time: Double) -> CGPoint {
        guard let start = origin else { return .zero }

        let elapsed = max(time - start, 0)
        let raw = curve(at: elapsed)
        let scale = effectiveScale

        var targetX = raw.x * scale * settings.horizontalGain
        var targetY = raw.y * scale * settings.verticalGain

        let cap = settings.maxStep
        targetX = min(max(targetX, -cap * 100), cap * 100)
        targetY = min(max(targetY, -cap * 100), cap * 100)

        let delta = CGPoint(x: targetX - emitted.x, y: targetY - emitted.y)
        emitted = CGPoint(x: targetX, y: targetY)

        // 单次增量限幅，异常值不至于把视角甩出去
        let step = hypot(delta.x, delta.y)
        if step > cap {
            let k = cap / step
            return CGPoint(x: delta.x * k, y: delta.y * k)
        }
        return delta
    }

    /// 第 t 秒时应该达到的累积补偿量。
    private func curve(at t: Double) -> CGPoint {
        guard !profile.pattern.isEmpty else { return .zero }

        let n = t / interval
        let depth = profile.pattern.count

        if n <= 0 { return .zero }

        if n >= Double(depth) {
            // 弹匣打完后按末发的速率继续压，不然第 31 发开始就回弹
            let over = n - Double(depth)
            let last = profile.pattern[depth - 1]
            return CGPoint(x: cumX[depth] + last.dx * over,
                           y: cumY[depth] + last.dy * over)
        }

        let i = Int(n)
        let f = n - Double(i)
        let x0 = cumX[i], x1 = cumX[i + 1]
        let y0 = cumY[i], y1 = cumY[i + 1]
        return CGPoint(x: x0 + (x1 - x0) * f, y: y0 + (y1 - y0) * f)
    }

    /// 界面弹道缩略图用：当前档位下前 depth 发的累计补偿曲线。
    public func previewCurve() -> [CGPoint] {
        let scale = effectiveScale
        return (0..<cumY.count).map { i in
            CGPoint(x: cumX[i] * scale, y: cumY[i] * scale)
        }
    }
}
