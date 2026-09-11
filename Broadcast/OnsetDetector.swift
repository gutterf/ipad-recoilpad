import Foundation
import Accelerate

/// 枪声起始点检测（spectral flux onset detection）。
///
/// 用音频而不是视觉来判定开火时刻：枪声在频谱上是一个极陡的宽带能量跃变，
/// 比"看开火按钮有没有亮"可靠得多，也不受 HUD 布局改动影响。
///
/// 判定量是归一化频谱通量：
///   flux = Σ max(0, mag[i] - prevMag[i]) / (Σ prevMag[i] + ε)
/// 和自适应阈值（历史均值 × 系数 + 偏置）比较，过阈且超过不应期才算一次 onset。
final class OnsetDetector {

    private let fftSize = 1024
    private let halfSize = 512
    private let log2n: vDSP_Length = 10

    private var setup: FFTSetup
    private var window: [Float]
    private var previousMagnitude: [Float]

    /// 累积到 fftSize 个样本才跑一次 FFT
    private var pending: [Float] = []

    private var fluxHistory: [Float] = []
    private let historyLength = 43          // 约 1 秒 @ 44.1kHz / 1024

    private var lastOnsetTime: Double = 0
    private let refractory: Double = 0.035  // 约 1700 RPM 上限

    /// 用户可调 0...1。越大越敏感。
    public var sensitivity: Float = 0.5

    /// 最近一次的 flux，供界面显示电平。
    public private(set) var lastFlux: Float = 0

    public init?() {
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        setup = fftSetup
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        previousMagnitude = [Float](repeating: 0, count: halfSize)
        pending.reserveCapacity(fftSize * 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// 喂入一批单声道样本。返回检测到 onset 的时刻（HostClock 秒），没检测到返回 nil。
    public func ingest(_ samples: [Float]) -> Double? {
        pending.append(contentsOf: samples)

        var detected: Double?
        while pending.count >= fftSize {
            let frame = Array(pending[0..<fftSize])
            pending.removeFirst(fftSize)
            if let t = evaluate(frame) {
                detected = t
            }
        }
        return detected
    }

    private func evaluate(_ frame: [Float]) -> Double? {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)
        var magnitude = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    let complex = UnsafeRawPointer(wp.baseAddress!)
                        .assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(halfSize))
            }
        }

        // 半波整流频谱通量
        var flux: Float = 0
        var energy: Float = 1e-6
        for i in 0..<halfSize {
            let delta = magnitude[i] - previousMagnitude[i]
            if delta > 0 { flux += delta }
            energy += previousMagnitude[i]
        }
        previousMagnitude = magnitude

        let normalized = flux / energy
        lastFlux = normalized

        defer {
            fluxHistory.append(normalized)
            if fluxHistory.count > historyLength { fluxHistory.removeFirst() }
        }

        guard fluxHistory.count >= 8 else { return nil }

        let mean = fluxHistory.reduce(0, +) / Float(fluxHistory.count)
        // sensitivity 0 -> 激进(k 小, 好触发)；1 -> 保守？反过来：
        // sensitivity 越大，阈值越低，越容易触发
        let k = 3.4 - 2.2 * sensitivity
        let offset: Float = 0.9 - 0.6 * sensitivity
        let threshold = mean * max(k, 0.8) + offset * 0.01

        let now = HostClock.now()
        guard normalized > threshold, now - lastOnsetTime > refractory else {
            return nil
        }

        lastOnsetTime = now
        return now
    }
}
