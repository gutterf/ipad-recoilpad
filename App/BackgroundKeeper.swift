import Foundation
import AVFoundation

/// 后台保活。
///
/// ReplayKit 的广播扩展是独立进程，系统会一直喂它屏幕帧，不需要保活。
/// 需要保活的是主 App —— 它得活着才能跑注入循环。
///
/// 用 audio 后台模式播一段全零 PCM：不发声、不打断游戏音频
/// （.mixWithOthers + volume 0），但能让进程持续持有后台执行权。
public final class BackgroundKeeper {

    private var player: AVAudioPlayer?
    private let session = AVAudioSession.sharedInstance()

    public private(set) var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }

        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])

        let url = try Self.silentFileURL()
        let p = try AVAudioPlayer(contentsOf: url)
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        p.play()

        player = p
        isRunning = true
    }

    public func stop() {
        player?.stop()
        player = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    /// 生成 1 秒 16bit 单声道全零 WAV，只做一次，缓存在 tmp。
    private static func silentFileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keepalive_silence.wav")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate = 44_100
        let frames = sampleRate          // 1 秒
        let bytesPerFrame = 2
        let dataSize = frames * bytesPerFrame

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))                 // PCM
        appendLE(UInt16(1))                 // 单声道
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * bytesPerFrame))
        appendLE(UInt16(bytesPerFrame))
        appendLE(UInt16(16))

        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(dataSize))
        data.append(Data(count: dataSize))

        try data.write(to: url, options: .atomic)
        return url
    }
}
