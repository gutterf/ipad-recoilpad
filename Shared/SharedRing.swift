import Foundation
import Darwin

/// 跨进程统一时基。
///
/// 用 mach_continuous_time 而不是 CFAbsoluteTimeGetCurrent：
/// 前者是硬件单调钟，不受系统对时和休眠影响，扩展与主 App 算出来的值一致。
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> Double {
        let ticks = mach_continuous_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}

/// 这一端在数据的哪一侧。
/// 决定 loopback 回退时谁当服务端：主 App（consumer）常驻后台，所以由它监听。
public enum RingRole {
    case producer   // 广播扩展：写状态，推给主 App
    case consumer   // 主 App：接收状态
}

/// 主 App 与 Broadcast 扩展之间的无锁共享状态。
///
/// 两套通路，按可用性自动选择：
///
///   1. **App Group 共享内存**（mmap）—— 首选。需要付费开发者账号，
///      免费 Personal Team 签不了 App Group，带这个 entitlement 的包
///      在签名阶段就会失败。
///   2. **loopback socket** —— 回退。不依赖任何 entitlement，
///      把同一块内存的字节原样搬运。代价是有了推送延迟和一次连接握手。
///
/// 对上层来说两者完全一样：都是同一组属性读写。上层代码不需要知道
/// 现在跑在哪条路上，`isUsingSharedMemory` 只是给界面显示用的。
///
/// 单写者单读者，定长字段写入在 arm64 上不会撕裂，不需要上锁。
public final class SharedRing {

    public static let byteSize = 4096
    public static let magic: UInt32 = 0x5250_4431   // "RPD1"

    // 字段偏移。所有 8 字节字段都落在 8 字节边界上。
    private enum F {
        static let magic       = 0     // UInt32
        static let writeCount  = 4     // UInt32  每次写入自增，读方据此判断更新
        static let weaponIndex = 8     // UInt32  0 = 未识别，n = 库下标 + 1
        static let confidence  = 12    // Float
        static let lastFire    = 16    // Double  HostClock 秒
        static let fireCount   = 24    // UInt64
        static let audioFlux   = 32    // Float   最近一次 onset 强度
        static let fireRateHz  = 36    // Float   实测射速
        static let videoFrames = 40    // UInt32
        static let audioFrames = 44    // UInt32
        static let updatedAt   = 48    // Double
        static let sensitivity = 56    // Float   主 App 写入，扩展读取
        static let captureReq  = 60    // UInt32  主 App 写入：抓帧请求序号
        static let captureAck  = 64    // UInt32  扩展写入：已完成的抓帧序号
    }

    private let base: UnsafeMutableRawPointer
    private let mappedSize: Int
    private let isShared: Bool
    private let role: RingRole

    private var loopbackServer: LoopbackServer?
    private var loopbackClient: LoopbackClient?

    public init?(url: URL? = SharedStore.ringURL, role: RingRole = .consumer) {
        self.role = role

        if let url, let mapped = Self.mapShared(url) {
            base = mapped
            mappedSize = Self.byteSize
            isShared = true
        } else {
            // 没有 App Group（免费账号签名时必然如此）。
            // 退回本地内存，两边靠 loopback 对齐。
            guard let local = malloc(Self.byteSize) else { return nil }
            memset(local, 0, Self.byteSize)
            base = local
            mappedSize = Self.byteSize
            isShared = false
        }

        if magicValue != Self.magic {
            memset(base, 0, Self.byteSize)
            magicValue = Self.magic
        }

        if !isShared {
            startLoopback()
        }
    }

    deinit {
        loopbackServer?.stop()
        loopbackClient?.stop()
        if isShared {
            munmap(base, mappedSize)
        } else {
            free(base)
        }
    }

    /// 走的是共享内存还是 loopback 回退。界面用它显示当前通路。
    public var isUsingSharedMemory: Bool { isShared }

    /// loopback 模式下对端是否已连接。
    public var loopbackPeerConnected: Bool {
        if let server = loopbackServer { return server.peerConnected }
        if let client = loopbackClient { return client.connected }
        return false
    }

    // MARK: - 通路

    private static func mapShared(_ url: URL) -> UnsafeMutableRawPointer? {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard ftruncate(fd, off_t(Self.byteSize)) == 0 else { return nil }

        let mapped = mmap(nil, Self.byteSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let pointer = mapped,
              let sentinel = UnsafeMutableRawPointer(bitPattern: -1),
              pointer != sentinel
        else { return nil }

        return pointer
    }

    private func startLoopback() {
        switch role {
        case .producer:
            let client = LoopbackClient()
            client.start()
            loopbackClient = client

        case .consumer:
            let server = LoopbackServer()
            server.onPacket = { [weak self] data in
                self?.applyPacket(data)
            }
            // 反向通道：把灵敏度回传给扩展，否则用户在界面上调它不会有反应
            server.controlProvider = { [weak self] in
                guard let self else { return nil }
                var value = self.sensitivity
                return Data(bytes: &value, count: MemoryLayout<Float>.size)
            }
            server.start()
            loopbackServer = server
        }
    }

    /// 整块状态内存原样导出。两端字段布局完全一致，所以不需要任何序列化格式。
    private func outboundPacket() -> Data {
        Data(bytes: base, count: LoopbackConfig.packetSize)
    }

    private func applyPacket(_ data: Data) {
        guard data.count == LoopbackConfig.packetSize else { return }
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(base, src, LoopbackConfig.packetSize)
        }
    }

    // MARK: - 原始访问

    private func u32(_ offset: Int) -> UInt32 { base.load(fromByteOffset: offset, as: UInt32.self) }
    private func f32(_ offset: Int) -> Float  { base.load(fromByteOffset: offset, as: Float.self) }
    private func f64(_ offset: Int) -> Double { base.load(fromByteOffset: offset, as: Double.self) }
    private func u64(_ offset: Int) -> UInt64 { base.load(fromByteOffset: offset, as: UInt64.self) }

    private func set(_ offset: Int, _ v: UInt32) { base.storeBytes(of: v, toByteOffset: offset, as: UInt32.self) }
    private func set(_ offset: Int, _ v: Float)  { base.storeBytes(of: v, toByteOffset: offset, as: Float.self) }
    private func set(_ offset: Int, _ v: Double) { base.storeBytes(of: v, toByteOffset: offset, as: Double.self) }
    private func set(_ offset: Int, _ v: UInt64) { base.storeBytes(of: v, toByteOffset: offset, as: UInt64.self) }

    private var magicValue: UInt32 {
        get { u32(F.magic) }
        set { set(F.magic, newValue) }
    }

    // MARK: - 字段

    public private(set) var writeCount: UInt32 {
        get { u32(F.writeCount) }
        set { set(F.writeCount, newValue) }
    }

    /// 0 表示未识别
    public var weaponIndex: UInt32 {
        get { u32(F.weaponIndex) }
        set { set(F.weaponIndex, newValue) }
    }

    public var confidence: Float {
        get { f32(F.confidence) }
        set { set(F.confidence, newValue) }
    }

    public var lastFireHostTime: Double {
        get { f64(F.lastFire) }
        set { set(F.lastFire, newValue) }
    }

    public var fireCount: UInt64 {
        get { u64(F.fireCount) }
        set { set(F.fireCount, newValue) }
    }

    public var audioFlux: Float {
        get { f32(F.audioFlux) }
        set { set(F.audioFlux, newValue) }
    }

    public var fireRateHz: Float {
        get { f32(F.fireRateHz) }
        set { set(F.fireRateHz, newValue) }
    }

    public var videoFrames: UInt32 {
        get { u32(F.videoFrames) }
        set { set(F.videoFrames, newValue) }
    }

    public var audioFrames: UInt32 {
        get { u32(F.audioFrames) }
        set { set(F.audioFrames, newValue) }
    }

    public var updatedAt: Double {
        get { f64(F.updatedAt) }
        set { set(F.updatedAt, newValue) }
    }

    /// 主 App -> 扩展的反向通道：onset 判定灵敏度。
    public var sensitivity: Float {
        get { f32(F.sensitivity) }
        set { set(F.sensitivity, newValue) }
    }

    /// 主 App -> 扩展：自增表示请求抓一帧当前画面用于制作识别模板。
    public var captureRequest: UInt32 {
        get { u32(F.captureReq) }
        set { set(F.captureReq, newValue) }
    }

    /// 扩展 -> 主 App：已完成的抓帧序号，追上 captureRequest 即表示抓完。
    public var captureAck: UInt32 {
        get { u32(F.captureAck) }
        set { set(F.captureAck, newValue) }
    }

    public func requestCapture() {
        set(F.captureReq, captureRequest &+ 1)
    }

    public var capturePending: Bool {
        captureRequest != captureAck
    }

    /// 扩展每完成一次写入调用，读方据此判断是否有新数据。
    ///
    /// loopback 回退模式下这里顺带把整块内存推给主 App —— commit 是所有
    /// 状态更新的唯一出口，挂在这里就不会漏推。
    public func commit(at time: Double = HostClock.now()) {
        set(F.updatedAt, time)
        set(F.writeCount, writeCount &+ 1)

        if !isShared, role == .producer {
            loopbackClient?.send(outboundPacket())
        }
    }

    /// 数据是否新鲜（默认 1 秒内）。
    public func isFresh(within seconds: Double = 1.0) -> Bool {
        let t = updatedAt
        guard t > 0 else { return false }
        return HostClock.now() - t < seconds
    }

    /// 主 App 收到停止广播时清零，避免读到上一轮的陈旧开火状态。
    public func resetTransient() {
        weaponIndex = 0
        confidence = 0
        lastFireHostTime = 0
        fireCount = 0
        audioFlux = 0
        fireRateHz = 0
        videoFrames = 0
        audioFrames = 0
        commit()
    }
}
