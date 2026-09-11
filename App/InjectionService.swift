import Foundation
import CoreGraphics

/// 把"扩展识别出的开火事件"翻译成"实际注入的触摸位移"。
///
/// 时序模型：
///   扩展从音频流里检测枪声 onset，把时刻写进 SharedRing。
///   本服务读 fireCount 变化 -> 认定连发开始 -> 用 onset 时刻作为时间轴原点。
///   之后的时间轴由武器射速推进，不再依赖每一次 onset（漏检某一发也不会错位）。
///   超过 fireTimeout 没有新 onset -> 认定停火，收起手势。
public final class InjectionService {

    public private(set) var capability: InjectionCapability
    public var onStateChange: (() -> Void)?

    private let ring: SharedRing?
    private var injector: HIDInjector?
    private var engine: RecoilEngine
    private var settings: RecoilSettings

    private let queue = DispatchQueue(label: "yg.recoilpad.inject", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // 手势状态
    private let fingerID: UInt32 = 0x5245   // "RE"，避免和真人手指撞 id
    private var touching = false
    private var cursor = CGPoint.zero
    private var pendingRestart = false

    // 开火状态
    private var seenFireCount: UInt64 = 0
    private var lastOnset: Double = 0
    private var active = false

    /// 最近一次注入的位移，供界面波形显示。
    public private(set) var lastDelta: CGPoint = .zero
    public private(set) var isFiring = false

    /// ring 由外部注入，不在这里自己建。
    /// 主 App 侧只能有一个 consumer 实例 —— loopback 回退模式下它要监听固定端口，
    /// 建两个会撞端口，第二个静默失败。
    public init(settings: RecoilSettings, capability: InjectionCapability, ring: SharedRing?) {
        self.settings = settings
        self.capability = capability
        self.ring = ring
        let profile = WeaponLibrary.profile(id: settings.selectedWeaponID) ?? WeaponLibrary.all[0]
        self.engine = RecoilEngine(profile: profile, settings: settings)
        self.injector = capability.isAvailable ? HIDInjector() : nil
    }

    // MARK: - 生命周期

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            // 能注入时才需要贴着 120Hz 跑；不能注入时只维持 UI 状态，降频省电。
            let ms = self.capability.isAvailable ? 8 : 100
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(),
                       repeating: .milliseconds(ms),
                       leeway: .milliseconds(self.capability.isAvailable ? 1 : 20))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.endStroke()
            self.engine.reset()
            self.active = false
            self.isFiring = false
            self.ring?.resetTransient()
        }
    }

    // MARK: - 设置同步

    public func apply(settings: RecoilSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            let weaponChanged = settings.selectedWeaponID != self.settings.selectedWeaponID
            self.settings = settings
            self.engine.update(settings: settings)

            if weaponChanged, !settings.autoDetectWeapon,
               let p = WeaponLibrary.profile(id: settings.selectedWeaponID) {
                self.engine.update(profile: p)
            }

            self.ring?.sensitivity = Float(settings.onsetSensitivity)

            if !settings.injectionEnabled {
                self.endStroke()
                self.active = false
            }
        }
    }

    // MARK: - 主循环

    private func tick() {
        let now = HostClock.now()
        guard let ring else { return }

        syncProfile(ring)
        syncFireState(ring, now: now)
        pump(now: now)
    }

    private func syncProfile(_ ring: SharedRing) {
        guard settings.autoDetectWeapon, ring.weaponIndex > 0,
              let detected = WeaponLibrary.profile(ringIndex: ring.weaponIndex)
        else { return }
        guard detected.id != engine.profile.id else { return }
        engine.update(profile: detected)
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }

    private func syncFireState(_ ring: SharedRing, now: Double) {
        let count = ring.fireCount

        if count != seenFireCount {
            seenFireCount = count
            // 扩展写的是 onset 时刻；为 0 说明它没带时间戳，退回当前时刻
            let onset = ring.lastFireHostTime > 0 ? ring.lastFireHostTime : now
            lastOnset = onset

            if !active {
                active = true
                isFiring = true
                engine.begin(at: onset - settings.onsetLatency)
                restartStroke()
                DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
            }
        }

        if active, now - lastOnset > settings.fireTimeout {
            active = false
            isFiring = false
            engine.reset()
            endStroke()
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }
    }

    private func pump(now: Double) {
        guard active, settings.injectionEnabled, capability.isAvailable, injector != nil else { return }

        if pendingRestart {
            pendingRestart = false
            cursor = settings.anchor
            injector?.send(id: fingerID, at: cursor, phase: .began)
            touching = true
            return
        }

        let delta = engine.sample(at: now)
        lastDelta = delta
        guard delta != .zero else { return }
        push(delta)
    }

    /// 手指单向滑动会跑到屏幕边缘或压到开火键，累积超过 maxTravel 就抬起复位。
    ///
    /// 不能直接把坐标瞬移回锚点 —— 同一手指的坐标跳变会被游戏当成一次
    /// 巨大位移，视角会猛甩。只能抬起再重新按下，中间空一拍。
    private func push(_ delta: CGPoint) {
        guard let injector else { return }

        var next = CGPoint(x: cursor.x + delta.x, y: cursor.y + delta.y)
        next.x = min(max(next.x, 0.02), 0.98)
        next.y = min(max(next.y, 0.02), 0.98)

        let driftX = abs(next.x - settings.anchor.x)
        let driftY = abs(next.y - settings.anchor.y)

        if driftX > settings.maxTravel || driftY > settings.maxTravel {
            injector.send(id: fingerID, at: cursor, phase: .ended)
            touching = false
            pendingRestart = true
            return
        }

        cursor = next
        injector.send(id: fingerID, at: cursor, phase: .moved)
    }

    private func restartStroke() {
        guard settings.injectionEnabled, let injector, capability.isAvailable else { return }
        cursor = settings.anchor
        injector.send(id: fingerID, at: cursor, phase: .began)
        touching = true
        pendingRestart = false
    }

    private func endStroke() {
        guard touching, let injector else {
            touching = false
            return
        }
        injector.send(id: fingerID, at: cursor, phase: .ended)
        touching = false
        pendingRestart = false
    }
}
