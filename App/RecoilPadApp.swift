import SwiftUI
import Combine

/// 全局状态。UI 只读这里，一切副作用在这里收敛。
@MainActor
public final class AppModel: ObservableObject {

    /// 广播扩展的真实 bundle id —— 必须在运行时从 App 包里读，不能写死。
    ///
    /// 免费 Apple ID（Personal Team）签名时，Xcode 会自动给 bundle id 加 team 后缀：
    ///     com.yg.recoilpad          -> com.yg.recoilpad.242Y4M86DS
    ///     com.yg.recoilpad.broadcast-> com.yg.recoilpad.broadcast.242Y4M86DS
    /// 硬编码的值对不上，RPSystemBroadcastPickerView 的 preferredExtension
    /// 就找不到扩展，系统广播选择器里不会出现本 App —— 而且完全不报错。
    public static var broadcastExtensionID: String {
        let fallback = "com.yg.recoilpad.broadcast"

        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return fallback }

        for item in items where item.pathExtension == "appex" {
            let infoURL = item.appendingPathComponent("Info.plist")
            guard let dict = NSDictionary(contentsOf: infoURL),
                  let ext = dict["NSExtension"] as? [String: Any],
                  let point = ext["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.broadcast-services-upload",
                  let bundleID = dict["CFBundleIdentifier"] as? String
            else { continue }
            return bundleID
        }
        return fallback
    }

    @Published var settings: RecoilSettings {
        didSet {
            guard isReady else { return }
            SharedStore.save(settings)
            service.apply(settings: settings)
        }
    }

    @Published private(set) var capability: InjectionCapability
    @Published private(set) var isBroadcasting = false
    @Published private(set) var isFiring = false
    @Published private(set) var detectedWeaponName: String?
    @Published private(set) var videoFrames: UInt32 = 0
    @Published private(set) var audioFrames: UInt32 = 0
    @Published private(set) var fireCount: UInt64 = 0
    @Published private(set) var templateCount = 0
    @Published private(set) var captures: [URL] = []

    /// 遥测：未越狱时这是 App 唯一能提供的实际信息。
    @Published private(set) var matchConfidence: Float = 0
    @Published private(set) var measuredFireRate: Float = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastFireAge: Double = .infinity

    /// 当前走的是哪条通路。免费账号签不了 App Group，会退回 loopback。
    @Published private(set) var usingSharedMemory = true
    @Published private(set) var loopbackConnected = false

    /// 诊断用：App Group 容器本身是否可用（与上面那条通路判断互为印证）
    @Published private(set) var hasAppGroupContainer = false
    @Published private(set) var loadedTemplateCount = 0

    private let service: InjectionService
    private let keeper = BackgroundKeeper()
    private let ring: SharedRing?
    private let matcher = WeaponMatcher()

    private var poller: Timer?
    private var isReady = false

    public init() {
        let stored = SharedStore.load()
        let probed = CapabilityProbe.inspect()

        // 探测失败时强制关掉注入，避免界面上显示"已启用"却什么都不做
        var initial = stored
        initial.injectionEnabled = stored.injectionEnabled && probed.isAvailable

        // 只有一个 ring 实例：loopback 回退模式下它要监听固定端口，
        // 建两个会撞端口，第二个会静默失败。
        let ringInstance = SharedRing(role: .consumer)

        capability = probed
        settings = initial
        ring = ringInstance
        service = InjectionService(settings: initial, capability: probed, ring: ringInstance)

        service.onStateChange = { [weak self] in
            Task { @MainActor in self?.pullLiveState() }
        }

        templateCount = matcher.loadTemplates()
        loadedTemplateCount = templateCount
        hasAppGroupContainer = SharedStore.containerURL != nil
        refreshCaptures()
        isReady = true

        service.start()
        startKeepingAlive()
        startPolling()
    }

    // MARK: - 保活

    private func startKeepingAlive() {
        do {
            try keeper.start()
        } catch {
            // 保活失败不致命：前台时一切正常，切后台后注入会停
            NSLog("[RecoilPad] 后台保活启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullLiveState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func pullLiveState() {
        guard let ring else { return }
        isBroadcasting = ring.isFresh(within: 2.0)
        isFiring = service.isFiring
        videoFrames = ring.videoFrames
        audioFrames = ring.audioFrames
        fireCount = ring.fireCount
        detectedWeaponName = WeaponLibrary.profile(ringIndex: ring.weaponIndex)?.displayName

        matchConfidence = ring.confidence
        measuredFireRate = ring.fireRateHz
        audioLevel = ring.audioFlux
        lastFireAge = ring.lastFireHostTime > 0
            ? HostClock.now() - ring.lastFireHostTime
            : .infinity

        usingSharedMemory = ring.isUsingSharedMemory
        loopbackConnected = ring.loopbackPeerConnected
    }

    // MARK: - 武器

    var activeProfile: WeaponProfile {
        if settings.autoDetectWeapon, let ring,
           let detected = WeaponLibrary.profile(ringIndex: ring.weaponIndex) {
            return detected
        }
        return WeaponLibrary.profile(id: settings.selectedWeaponID) ?? WeaponLibrary.all[0]
    }

    // MARK: - 模板

    func requestCapture() {
        guard let ring, isBroadcasting else { return }
        ring.requestCapture()
    }

    func refreshCaptures() {
        guard let dir = SharedStore.containerURL?.appendingPathComponent("captures", isDirectory: true)
        else { captures = []; return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        captures = files
            .filter { $0.pathExtension == "jpg" || $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func assignCapture(_ url: URL, to weaponID: String) {
        guard let image = UIImage(contentsOfFile: url.path) else { return }
        let region = settings.hudROI
        let ok = matcher.makeTemplate(from: image, id: weaponID, region: region)
        if ok {
            try? FileManager.default.removeItem(at: url)
            templateCount = matcher.loadTemplates()
        }
        refreshCaptures()
    }

    func clearTemplates() {
        matcher.removeAllTemplates()
        templateCount = 0
    }
}

@main
struct RecoilPadApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ControlPanel()
                .environmentObject(model)
        }
    }
}
