import Foundation

/// 注入能力的探测结果。UI 全部据此决定是否灰化。
public enum InjectionCapability: Equatable {
    case available(via: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .available:  return "自动压枪可用"
        case .unavailable: return "自动压枪不可用"
        }
    }

    public var detail: String {
        switch self {
        case .available(let via):
            return "已接入 \(via)"
        case .unavailable(let reason):
            return reason
        }
    }
}

/// 探测能否向系统注入触摸事件。
///
/// 结论只有三种：
///   1. 未越狱                  -> 沙箱拦截，HID 客户端创建不出来
///   2. 越狱但缺 entitlement    -> 同上
///   3. 越狱且 entitlement 就位 -> 可用
///
/// 光看设备上有没有 Cydia 不足以判断第 2 种情况，所以这里直接尝试创建
/// HID 客户端：能拿到非空指针才算可用。
public enum CapabilityProbe {

    private static let iokitHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    /// 常见越狱痕迹，只用于生成更具体的提示文案，不参与可用性判定。
    private static func jailbreakTraces() -> [String] {
        [
            "/var/jb",
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/var/lib/dpkg/status",
            "/usr/sbin/sshd",
            "/usr/lib/libhooker.dylib",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static func inspect() -> InjectionCapability {
        let traces = jailbreakTraces()
        let hinted = !traces.isEmpty

        guard let handle = iokitHandle else {
            return .unavailable(reason: "IOKit 私有符号不可达")
        }

        guard let symbol = dlsym(handle, "IOHIDEventSystemClientCreate") else {
            return .unavailable(reason: hinted
                ? "设备有越狱痕迹，但 IOKit 未导出 HID 客户端符号"
                : "系统沙箱未开放 HID 事件系统")
        }

        typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        let create = unsafeBitCast(symbol, to: CreateFn.self)

        guard let client = create(kCFAllocatorDefault) else {
            return .unavailable(reason: hinted
                ? "越狱环境存在，但 App 缺少 com.apple.private.hid.client.event-dispatch 授权"
                : "未越狱。iPadOS 不允许任何 App 向其他 App 注入触摸事件")
        }

        // 探测阶段创建的客户端直接释放，真正注入时由 HIDInjector 自建。
        if let release = dlsym(handle, "CFRelease") {
            typealias ReleaseFn = @convention(c) (UnsafeRawPointer?) -> Void
            unsafeBitCast(release, to: ReleaseFn.self)(client)
        }

        return .available(via: "IOHIDEventSystemClient")
    }
}
