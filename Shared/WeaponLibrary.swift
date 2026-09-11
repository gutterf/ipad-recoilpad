import Foundation

/// 一发子弹的原始视角上跳。
///
/// 单位是归一化屏幕比例（横屏下相对屏幕高度）：
///   dy = 0.028 表示这一发会把视角打高 2.8% 屏高，需要等量往下压回去。
///   dx 是同一发的水平漂移，正 = 向右。
public struct RecoilPoint: Codable, Hashable {
    public var dx: Double
    public var dy: Double

    public init(_ dx: Double, _ dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public struct WeaponProfile: Codable, Identifiable, Hashable {
    public var id: String
    public var displayName: String
    public var category: Category
    public var rpm: Double
    /// 逐发后坐力，长度即弹匣深度
    public var pattern: [RecoilPoint]

    public enum Category: String, Codable, CaseIterable {
        case assaultRifle, submachineGun, lightMachineGun, marksman, sniper

        public var label: String {
            switch self {
            case .assaultRifle:   return "突击步枪"
            case .submachineGun:  return "冲锋枪"
            case .lightMachineGun: return "轻机枪"
            case .marksman:       return "精确射手"
            case .sniper:         return "狙击枪"
            }
        }
    }

    /// 前 N 发的累积上跳，用于界面上的缩略弹道图。
    public func cumulative() -> [Double] {
        var acc = 0.0
        return pattern.map { acc += $0.dy; return acc }
    }

    /// 二维累积弹道。含水平漂移，这是画真实弹道图必须用的 ——
    /// 只看 cumulative() 的话每条枪都长得一样垂直，看不出左右摆。
    /// 返回的数组比 pattern 多一个元素，第 0 个是原点 (0, 0)。
    public func cumulative2D() -> [RecoilPoint] {
        var x = 0.0
        var y = 0.0
        var out = [RecoilPoint(0, 0)]
        out.reserveCapacity(pattern.count + 1)
        for p in pattern {
            x += p.dx
            y += p.dy
            out.append(RecoilPoint(x, y))
        }
        return out
    }

    /// 水平漂移的最大绝对值，用于判断这把枪"直不直"。
    public var maxHorizontalDrift: Double {
        pattern.reduce(0) { max($0, abs($1.dx)) }
    }

    public var totalKick: Double {
        pattern.reduce(0) { $0 + $1.dy }
    }
}

public enum WeaponLibrary {

    /// 构造：只给垂直序列，水平漂移按"前段收敛、后段发散"的通用形态叠加。
    private static func make(
        _ id: String,
        _ name: String,
        _ category: WeaponProfile.Category,
        _ rpm: Double,
        _ dy: [Double],
        drift: Double = 0
    ) -> WeaponProfile {
        let n = dy.count
        let points = dy.enumerated().map { index, value -> RecoilPoint in
            guard drift != 0, n > 1 else { return RecoilPoint(0, value) }
            // 前 40% 几乎无漂移，之后按正弦形态左右摆，幅度随 drift 缩放
            let progress = Double(index) / Double(n - 1)
            let ramp = progress < 0.4 ? 0 : (progress - 0.4) / 0.6
            let swing = sin(progress * .pi * 3.2)
            return RecoilPoint(drift * ramp * swing, value)
        }
        return WeaponProfile(id: id, displayName: name, category: category, rpm: rpm, pattern: points)
    }

    public static let all: [WeaponProfile] = [
        make("M416", "M416", .assaultRifle, 660,
             [0.028, 0.030, 0.030, 0.028, 0.026,
              0.024, 0.022, 0.020, 0.019, 0.018,
              0.017, 0.016, 0.016, 0.015, 0.015,
              0.014, 0.014, 0.013, 0.013, 0.012,
              0.012, 0.012, 0.011, 0.011, 0.011,
              0.010, 0.010, 0.010, 0.010, 0.010],
             drift: 0.004),

        make("AKM", "AKM", .assaultRifle, 600,
             [0.040, 0.046, 0.048, 0.047, 0.045,
              0.043, 0.041, 0.039, 0.038, 0.036,
              0.035, 0.034, 0.033, 0.032, 0.031,
              0.030, 0.030, 0.029, 0.028, 0.028,
              0.027, 0.027, 0.026, 0.026, 0.025,
              0.025, 0.024, 0.024, 0.024, 0.023],
             drift: 0.010),

        make("SCAR-L", "SCAR-L", .assaultRifle, 600,
             [0.031, 0.035, 0.036, 0.035, 0.033,
              0.031, 0.030, 0.028, 0.027, 0.026,
              0.025, 0.024, 0.023, 0.022, 0.021,
              0.021, 0.020, 0.019, 0.019, 0.018,
              0.018, 0.017, 0.017, 0.016, 0.016,
              0.015, 0.015, 0.015, 0.014, 0.014],
             drift: 0.007),

        make("M762", "Beryl M762", .assaultRifle, 600,
             [0.047, 0.054, 0.056, 0.055, 0.053,
              0.050, 0.048, 0.046, 0.044, 0.043,
              0.041, 0.040, 0.038, 0.037, 0.036,
              0.035, 0.034, 0.033, 0.032, 0.031,
              0.030, 0.030, 0.029, 0.028, 0.028,
              0.027, 0.026, 0.026, 0.025, 0.025],
             drift: 0.013),

        make("G36C", "G36C", .assaultRifle, 660,
             [0.029, 0.032, 0.033, 0.032, 0.030,
              0.028, 0.027, 0.025, 0.024, 0.023,
              0.022, 0.021, 0.020, 0.019, 0.019,
              0.018, 0.017, 0.017, 0.016, 0.016,
              0.015, 0.015, 0.014, 0.014, 0.014,
              0.013, 0.013, 0.013, 0.012, 0.012],
             drift: 0.005),

        make("QBZ", "QBZ95", .assaultRifle, 660,
             [0.027, 0.030, 0.031, 0.030, 0.028,
              0.026, 0.025, 0.023, 0.022, 0.021,
              0.020, 0.019, 0.018, 0.018, 0.017,
              0.016, 0.016, 0.015, 0.015, 0.014,
              0.014, 0.013, 0.013, 0.013, 0.012,
              0.012, 0.012, 0.011, 0.011, 0.011],
             drift: 0.004),

        make("UMP45", "UMP45", .submachineGun, 670,
             [0.018, 0.020, 0.020, 0.019, 0.018,
              0.017, 0.016, 0.015, 0.014, 0.014,
              0.013, 0.013, 0.012, 0.012, 0.011,
              0.011, 0.010, 0.010, 0.010, 0.009,
              0.009, 0.009, 0.009, 0.008, 0.008,
              0.008, 0.008, 0.008, 0.007, 0.007],
             drift: 0.003),

        make("Vector", "Vector", .submachineGun, 1100,
             [0.012, 0.013, 0.013, 0.012, 0.012,
              0.011, 0.011, 0.010, 0.010, 0.009,
              0.009, 0.009, 0.008, 0.008, 0.008,
              0.008, 0.007, 0.007, 0.007, 0.007,
              0.007, 0.006, 0.006, 0.006, 0.006,
              0.006, 0.006, 0.006, 0.006, 0.006],
             drift: 0.002),

        make("DP28", "DP-28", .lightMachineGun, 550,
             [0.034, 0.038, 0.039, 0.038, 0.036,
              0.034, 0.033, 0.031, 0.030, 0.029,
              0.028, 0.027, 0.026, 0.025, 0.024,
              0.023, 0.022, 0.022, 0.021, 0.020,
              0.020, 0.019, 0.019, 0.018, 0.018,
              0.017, 0.017, 0.017, 0.016, 0.016],
             drift: 0.006),

        make("Mini14", "Mini 14", .marksman, 300,
             [0.036, 0.028, 0.024, 0.022, 0.020,
              0.019, 0.018, 0.017, 0.016, 0.016,
              0.015, 0.015, 0.014, 0.014, 0.014,
              0.013, 0.013, 0.013, 0.013, 0.012],
             drift: 0.003),

        make("SKS", "SKS", .marksman, 400,
             [0.033, 0.030, 0.028, 0.026, 0.025,
              0.024, 0.023, 0.022, 0.021, 0.020,
              0.020, 0.019, 0.019, 0.018, 0.018,
              0.017, 0.017, 0.017, 0.016, 0.016],
             drift: 0.005),
    ]

    public static func profile(id: String) -> WeaponProfile? {
        all.first { $0.id == id }
    }

    /// SharedRing 里的存储格式是 库下标 + 1，0 保留给"未识别"。
    public static func index(of id: String) -> UInt32? {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        return UInt32(i + 1)
    }

    public static func profile(ringIndex: UInt32) -> WeaponProfile? {
        guard ringIndex > 0, Int(ringIndex) <= all.count else { return nil }
        return all[Int(ringIndex) - 1]
    }
}
