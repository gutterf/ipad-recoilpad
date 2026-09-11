import ReplayKit
import CoreMedia
import CoreVideo
import CoreImage
import UIKit

/// 广播扩展入口。
///
/// 职责边界（扩展内存上限约 50MB，这里只做轻活）：
///   视频 -> 按 ROI 跑一次 Vision 特征匹配，结果写共享内存
///   音频 -> spectral flux 检测枪声 onset，时刻写共享内存
///   抓帧 -> 主 App 请求时存一张 PNG 供制作模板
/// 所有重计算都在主 App 侧，扩展绝不常驻大缓冲。
final class SampleHandler: RPBroadcastSampleHandler {

    private var ring: SharedRing?
    private var onsetDetector: OnsetDetector?
    private var matcher: WeaponMatcher?

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var videoCounter: UInt32 = 0
    private var audioCounter: UInt32 = 0
    private var fireCount: UInt64 = 0

    private var lastVideoAnalyzed: Double = 0
    private var lastCaptureAck: UInt32 = 0
    private var lastOnsetLogged: Double = 0

    /// 射速实测。枪声间隔做指数平滑，比直接取相邻两发之倒数的瞬时值稳。
    private var lastOnsetHostTime: Double = 0
    private var smoothedInterval: Double = 0

    /// 缓存设置。每帧都读 UserDefaults 会成为扩展里的固定开销。
    private var hudROI: CGRect = CGRect(x: 0.705, y: 0.605, width: 0.275, height: 0.175)
    private var settingsRefreshAt: Double = 0

    /// 抓帧降采样后的最大宽度。模板匹配用，不必是全分辨率。
    private let captureMaxWidth: CGFloat = 1280

    /// 识别节流间隔。武器图标不会一帧一变，每帧跑 Vision 纯属浪费。
    private let videoInterval: Double = 0.35

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let settings = SharedStore.load()
        hudROI = settings.hudROI

        ring = SharedRing(role: .producer)
        ring?.sensitivity = Float(settings.onsetSensitivity)
        ring?.resetTransient()
        lastCaptureAck = ring?.captureAck ?? 0
        lastOnsetHostTime = 0
        smoothedInterval = 0

        if settings.audioOnsetEnabled, let detector = OnsetDetector() {
            detector.sensitivity = Float(settings.onsetSensitivity)
            onsetDetector = detector
        }

        if let m = WeaponMatcher() {
            let n = m.loadTemplates()
            matcher = m
            NSLog("[RecoilPad] 载入模板 \(n) 个")
        }
    }

    override func broadcastFinished() {
        ring?.resetTransient()
        ring = nil
        onsetDetector = nil
        matcher = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard let ring else { return }

        // Vision / CoreImage 会产出大量自动释放对象，扩展内存吃紧，按帧回收
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                handleVideo(sampleBuffer, ring: ring)
            case .audioApp:
                handleAudio(sampleBuffer, ring: ring)
            default:
                // audioMic 是环境音，对枪声判定只有干扰
                break
            }
        }
    }

    // MARK: - 音频

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, ring: SharedRing) {
        guard let detector = onsetDetector else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let rawData = bufferList.mBuffers.mData else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        let channelCount = max(Int(asbd.pointee.mChannelsPerFrame), 1)
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        var mono = [Float](repeating: 0, count: frameCount)
        if isFloat {
            let samples = rawData.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                mono[i] = samples[i * channelCount]
            }
        } else {
            let samples = rawData.assumingMemoryBound(to: Int16.self)
            for i in 0..<frameCount {
                mono[i] = Float(samples[i * channelCount]) / 32768.0
            }
        }

        audioCounter &+= 1
        ring.audioFrames = audioCounter

        // 主 App 调灵敏度后要能立刻生效，但不必每帧读盘
        let now = HostClock.now()
        if now - settingsRefreshAt > 1.0 {
            settingsRefreshAt = now
            detector.sensitivity = ring.sensitivity
            hudROI = SharedStore.load().hudROI
        }

        if let onsetTime = detector.ingest(mono) {
            fireCount &+= 1
            ring.fireCount = fireCount
            ring.lastFireHostTime = onsetTime
            ring.audioFlux = detector.lastFlux
            updateFireRate(onsetTime, ring: ring)
            ring.commit(at: onsetTime)
        }
    }

    /// 用相邻 onset 间隔反推射速。区间外的间隔视为换梭或误检，丢弃。
    private func updateFireRate(_ onsetTime: Double, ring: SharedRing) {
        defer { lastOnsetHostTime = onsetTime }
        guard lastOnsetHostTime > 0 else { return }

        let dt = onsetTime - lastOnsetHostTime
        // 1200 RPM -> 50ms；低于 35ms 是误检，高于 500ms 是断点
        guard dt > 0.035, dt < 0.5 else { return }

        smoothedInterval = smoothedInterval == 0 ? dt : smoothedInterval * 0.7 + dt * 0.3
        ring.fireRateHz = Float(1.0 / smoothedInterval)
    }

    // MARK: - 视频

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, ring: SharedRing) {
        let now = HostClock.now()

        videoCounter &+= 1
        ring.videoFrames = videoCounter

        if ring.captureRequest != lastCaptureAck {
            lastCaptureAck = ring.captureRequest
            performCapture(sampleBuffer, ring: ring)
        }

        guard now - lastVideoAnalyzed >= videoInterval else { return }
        guard let matcher, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVideoAnalyzed = now

        if let hit = matcher.match(pixelBuffer: pixelBuffer, region: hudROI) {
            ring.weaponIndex = WeaponLibrary.index(of: hit.id) ?? 0
            ring.confidence = hit.distance
            ring.commit(at: now)
        }
    }

    // MARK: - 抓帧

    /// 抓帧存盘，供主 App 制作识别模板。
    ///
    /// 这一步是扩展里唯一有可能顶穿内存上限的操作，必须小心：
    /// 全分辨率的一帧是 2732x2048 BGRA ≈ 22MB，再建一张同尺寸 CGImage、
    /// 再走一遍 PNG 编码，峰值轻松超过扩展的 50MB 上限。
    /// 顶爆的后果是 jetsam 直接杀进程 —— 没有异常、没有日志，
    /// 表现只是"共享莫名其妙停了"，主 App 那边完全不知道。
    ///
    /// 所以：先降采样到 ≤1280 宽，再编码，且用 JPEG 不用 PNG。
    /// 模板只用来做特征匹配，1280 宽远超需要。
    private func performCapture(_ sampleBuffer: CMSampleBuffer, ring: SharedRing) {
        defer {
            ring.captureAck = ring.captureRequest
            ring.commit(at: HostClock.now())
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = Self.downscaled(source, maxWidth: captureMaxWidth)
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }

        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82),
              let dir = SharedStore.containerURL?.appendingPathComponent("captures", isDirectory: true)
        else { return }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "pending_%.0f.jpg", HostClock.now() * 1000)
        try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// 等比缩放到不超过 maxWidth。已经够小就原样返回。
    private static func downscaled(_ image: CIImage, maxWidth: CGFloat) -> CIImage {
        let width = image.extent.width
        guard width > maxWidth, width > 0 else { return image }
        let scale = maxWidth / width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
