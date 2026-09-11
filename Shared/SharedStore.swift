import Foundation
import CoreGraphics

/// 全局设置。主 App 写入，Broadcast 扩展只读。
///
/// level 的语义（照你要的来）：
///   10 = 游戏原始后坐力，补偿量 0
///    0 = 完全无后座，补偿量 100%
/// 中间线性插值。
public struct RecoilSettings: Codable, Equatable {
    public var level: Double = 10

    /// 全局标定系数。一发子弹在屏幕上实际吃掉多少高度因人而异
    /// （灵敏度 / 机型 / 分辨率），这里统一缩放。默认 1.0。
    public var baseScale: Double = 1.0

    public var verticalGain: Double = 1.0
    public var horizontalGain: Double = 1.0

    /// 开火判定灵敏度 0...1，越大越容易触发。
    public var onsetSensitivity: Double = 0.5
    public var audioOnsetEnabled: Bool = true

    /// 最后一次 onset 之后多久算连发结束（秒）。
    public var fireTimeout: Double = 0.28

    /// 音频链路延迟补偿（秒）。ReplayKit 缓冲约 20~50ms。
    public var onsetLatency: Double = 0.02

    public var selectedWeaponID: String = "M416"
    public var autoDetectWeapon: Bool = true

    /// 注入总开关。能力探测失败时此项强制 false。
    public var injectionEnabled: Bool = false

    /// 压枪虚拟手指的锚点（归一化屏幕坐标）。
    public var anchor: CGPoint = CGPoint(x: 0.82, y: 0.58)

    /// 单 tick 最大位移，防止异常值把视角甩飞。
    public var maxStep: Double = 0.015

    /// 手指偏离锚点多少后抬起复位（归一化）。
    public var maxTravel: Double = 0.05

    /// 武器图标 HUD 在屏幕上的归一化区域（横屏）。
    /// 识别和抓模板都用这块区域，改了要重新抓模板。
    public var hudROI: CGRect = CGRect(x: 0.705, y: 0.605, width: 0.275, height: 0.175)

    public init() {}

    /// 补偿比例：level 10 -> 0.0，level 0 -> 1.0
    public var compensationRatio: Double {
        min(max(1.0 - level / 10.0, 0.0), 1.0)
    }

    /// 界面上展示的档位文字
    public var levelLabel: String {
        switch level {
        case ..<0.5:  return "无后座"
        case ..<2.5:  return "极轻"
        case ..<5.0:  return "较轻"
        case ..<7.5:  return "接近原版"
        case ..<9.8:  return "原版偏重"
        default:      return "游戏原始"
        }
    }
}

public enum SharedStore {
    public static let appGroupID = "group.com.yg.recoilpad"
    private static let settingsKey = "recoil.settings.v1"

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 音视频扩展与主 App 之间的共享内存文件。
    public static var ringURL: URL? {
        containerURL?.appendingPathComponent("recoil_state.bin")
    }

    public static func load() -> RecoilSettings {
        guard let data = defaults?.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(RecoilSettings.self, from: data)
        else { return RecoilSettings() }
        return decoded
    }

    public static func save(_ settings: RecoilSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults?.set(data, forKey: settingsKey)
    }
}
