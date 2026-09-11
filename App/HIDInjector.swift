import Foundation
import CoreGraphics
import Darwin

/// 通过 IOKit 私有接口注入触摸事件。
///
/// 只在越狱环境 + 具备 event-dispatch 授权时可用，初始化失败即返回 nil。
///
/// 坐标是归一化的 (0...1)，原点左上角，和 UIView 的坐标方向一致。
public final class HIDInjector {

    public enum Phase {
        case began, moved, ended
    }

    // MARK: - 私有符号签名
    //
    // 全部按 C ABI 声明。IOFloat32 在 arm64 上是 float 不是 double，
    // 这里写成 Double 会读错寄存器低位，必须保持 Float。

    private typealias CreateSystemClientFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias CreateDigitizerFn = @convention(c) (
        CFAllocator?, UInt64,
        UInt32, UInt32, UInt32, UInt32, UInt32,
        Float, Float, Float, Float, Float,
        Int32, Int32, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFingerFn = @convention(c) (
        CFAllocator?, UInt64,
        UInt32, UInt32, UInt32,
        Float, Float, Float, Float, Float,
        Int32, Int32, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias AppendEventFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Void
    private typealias SetIntegerFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int64) -> Void
    private typealias SetFloatFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Float) -> Void
    private typealias DispatchFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias ReleaseFn = @convention(c) (UnsafeRawPointer?) -> Void

    // MARK: - 常量
    //
    // 来源：IOKit/hid/IOHIDEventTypes.h
    //   kIOHIDEventFieldBase(type) = type << 16
    //   kIOHIDEventTypeDigitizer   = 3          -> 字段基址 0x30000
    //   枚举内顺序：X,Y,Z,ButtonMask,Type,Index,Identity,EventMask,Range,Touch,
    //              Pressure,AuxiliaryPressure,Twist,TiltX,TiltY,Quality,Density,
    //              Irregularity,MajorRadius,MinorRadius,Collection,
    //              CollectionTerminal,IsDisplayIntegrated
    //
    // 越狱设备上有原始头文件，编译前核对一次，不一致以头文件为准：
    //   grep -n "IsDisplayIntegrated" /path/to/IOKit/hid/IOHIDEventTypes.h

    private enum Field {
        static let x = UInt32(0x30000)
        static let y = UInt32(0x30001)
        static let range = UInt32(0x30008)
        static let touch = UInt32(0x30009)
        static let isDisplayIntegrated = UInt32(0x30016)
    }

    private enum Transducer {
        static let hand = UInt32(3)
    }

    private enum EventMask {
        static let range = UInt32(1 << 0)
        static let touch = UInt32(1 << 1)
    }

    // MARK: - 实例

    private let client: UnsafeMutableRawPointer
    private let createDigitizer: CreateDigitizerFn
    private let createFinger: CreateFingerFn
    private let appendEvent: AppendEventFn
    private let setInteger: SetIntegerFn
    private let setFloat: SetFloatFn
    private let dispatch: DispatchFn
    private let release: ReleaseFn

    public init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }

        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        guard
            let createClient = bind("IOHIDEventSystemClientCreate", CreateSystemClientFn.self),
            let digitizer = bind("IOHIDEventCreateDigitizerEvent", CreateDigitizerFn.self),
            let finger = bind("IOHIDEventCreateDigitizerFingerEvent", CreateFingerFn.self),
            let append = bind("IOHIDEventAppendEvent", AppendEventFn.self),
            let setInt = bind("IOHIDEventSetIntegerValue", SetIntegerFn.self),
            let setFlt = bind("IOHIDEventSetFloatValue", SetFloatFn.self),
            let dispatchFn = bind("IOHIDEventSystemClientDispatchEvent", DispatchFn.self),
            let releaseFn = bind("CFRelease", ReleaseFn.self)
        else { return nil }

        guard let systemClient = createClient(kCFAllocatorDefault) else { return nil }

        self.client = systemClient
        self.createDigitizer = digitizer
        self.createFinger = finger
        self.appendEvent = append
        self.setInteger = setInt
        self.setFloat = setFlt
        self.dispatch = dispatchFn
        self.release = releaseFn
    }

    deinit {
        release(client)
    }

    /// 发送一次触摸状态。同一 id 的 began -> moved... -> ended 构成一条连续手势。
    public func send(id: UInt32, at point: CGPoint, phase: Phase) {
        let isTouching = phase != .ended
        let mask = isTouching ? (EventMask.range | EventMask.touch) : EventMask.range
        let nx = Float(min(max(point.x, 0), 1))
        let ny = Float(min(max(point.y, 0), 1))
        let timestamp = mach_absolute_time()

        guard let hand = createDigitizer(
            kCFAllocatorDefault, timestamp,
            Transducer.hand, 0, 0, mask, 0,
            0, 0, 0, 0, 0,
            1, isTouching ? 1 : 0, 0
        ) else { return }

        setInteger(hand, Field.isDisplayIntegrated, 1)
        setInteger(hand, Field.range, 1)
        setInteger(hand, Field.touch, isTouching ? 1 : 0)

        if let finger = createFinger(
            kCFAllocatorDefault, timestamp,
            0, id, mask,
            nx, ny, 0, 0, 0,
            1, isTouching ? 1 : 0, 0
        ) {
            appendEvent(hand, finger, 0)
            // finger 已被 hand 持有，交给 CF 释放
            release(finger)
        }

        dispatch(client, hand)
        release(hand)
    }
}
