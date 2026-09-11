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

/// 主 App 与 Broadcast 扩展之间的无锁共享状态。
///
/// 扩展只写，主 App 只读（onsetSensitivity 反向）。单写者单读者，
/// 定长字段写入在 arm64 上不会撕裂，不需要上锁。
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

    public init?(url: URL? = SharedStore.ringURL) {
        guard let url else { return nil }
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard ftruncate(fd, off_t(Self.byteSize)) == 0 else { return nil }

        let mapped = mmap(nil, Self.byteSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let pointer = mapped,
              let sentinel = UnsafeMutableRawPointer(bitPattern: -1),
              pointer != sentinel
        else { return nil }

        base = pointer
        mappedSize = Self.byteSize

        if magicValue != Self.magic {
            memset(base, 0, Self.byteSize)
            magicValue = Self.magic
        }
    }

    deinit {
        munmap(base, mappedSize)
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
    public func commit(at time: Double = HostClock.now()) {
        set(F.updatedAt, time)
        set(F.writeCount, writeCount &+ 1)
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
