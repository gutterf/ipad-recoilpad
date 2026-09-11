import XCTest
@testable import RecoilPad

/// 只覆盖 Shared 里的纯逻辑，不碰 UIKit、不需要真机、不需要广播权限。
/// xcodebuild test 在模拟器上几十秒能跑完。
final class RecoilEngineTests: XCTestCase {

    // MARK: - 辅助

    private func m416() -> WeaponProfile {
        guard let p = WeaponLibrary.profile(id: "M416") else {
            fatalError("武器库里必须有 M416")
        }
        return p
    }

    /// maxStep 放大到不可能触发，避免限幅干扰累积量断言；
    /// 限幅本身由单独的用例验证。
    private func settings(level: Double, scale: Double = 1.0) -> RecoilSettings {
        var s = RecoilSettings()
        s.level = level
        s.baseScale = scale
        s.verticalGain = 1.0
        s.horizontalGain = 1.0
        s.maxStep = 999
        s.onsetLatency = 0
        return s
    }

    private var shotInterval: Double { 60.0 / m416().rpm }

    // MARK: - 滑块语义
    //
    // 这是整个 App 唯一对用户可见的契约：10 是原版，0 是无后座。

    func testLevelTenMeansNoCompensation() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 10))
        XCTAssertEqual(engine.effectiveScale, 0.0, accuracy: 1e-12)

        engine.begin(at: 0)
        let delta = engine.sample(at: 1.0)
        XCTAssertEqual(delta.x, 0.0, accuracy: 1e-12)
        XCTAssertEqual(delta.y, 0.0, accuracy: 1e-12)
    }

    func testLevelZeroMeansFullCompensation() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 0))
        XCTAssertEqual(engine.effectiveScale, 1.0, accuracy: 1e-12)
    }

    func testLevelFiveIsHalfCompensation() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 5))
        XCTAssertEqual(engine.effectiveScale, 0.5, accuracy: 1e-12)
    }

    func testLevelIsClampedOutsideRange() {
        var s = RecoilSettings()
        s.level = 24
        XCTAssertEqual(s.compensationRatio, 0.0, accuracy: 1e-12)
        s.level = -7
        XCTAssertEqual(s.compensationRatio, 1.0, accuracy: 1e-12)
    }

    func testBaseScaleMultipliesOnTopOfLevel() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 0, scale: 2.5))
        XCTAssertEqual(engine.effectiveScale, 2.5, accuracy: 1e-12)
    }

    // MARK: - 曲线采样

    /// 逐发布进的累积增量必须精确等于弹道表的总和。
    func testAccumulatedDeltasTrackPattern() {
        let profile = m416()
        let engine = RecoilEngine(profile: profile, settings: settings(level: 0))
        engine.begin(at: 0)

        var accX = 0.0
        var accY = 0.0
        for shot in 1...profile.pattern.count {
            let delta = engine.sample(at: Double(shot) * shotInterval)
            accX += delta.x
            accY += delta.y
        }

        let wantX = profile.pattern.reduce(0.0) { $0 + $1.dx }
        let wantY = profile.pattern.reduce(0.0) { $0 + $1.dy }
        XCTAssertEqual(accX, wantX, accuracy: 1e-9)
        XCTAssertEqual(accY, wantY, accuracy: 1e-9)
    }

    /// 弹匣打完后必须按末发速率继续压，否则第 31 发开始会回弹。
    func testExtrapolatesBeyondMagazineAtLastRate() {
        let profile = m416()
        let engine = RecoilEngine(profile: profile, settings: settings(level: 0))
        engine.begin(at: 0)

        let depth = profile.pattern.count
        let lastRate = profile.pattern[depth - 1].dy
        let delta = engine.sample(at: Double(depth + 10) * shotInterval)

        XCTAssertEqual(delta.y, profile.totalKick + lastRate * 10, accuracy: 1e-9)
    }

    /// 时间轴起点之前应该是零，不能出现负补偿。
    func testNoCompensationBeforeBegin() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 0))
        engine.begin(at: 100)
        let delta = engine.sample(at: 100)
        XCTAssertEqual(delta.x, 0.0, accuracy: 1e-12)
        XCTAssertEqual(delta.y, 0.0, accuracy: 1e-12)
    }

    func testResetStopsOutput() {
        let engine = RecoilEngine(profile: m416(), settings: settings(level: 0))
        engine.begin(at: 0)
        _ = engine.sample(at: 0.5)
        XCTAssertTrue(engine.isActive)

        engine.reset()
        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(engine.sample(at: 0.6).y, 0.0, accuracy: 1e-12)
    }

    func testPreviewCurveLengthMatchesCumulative() {
        let profile = m416()
        let engine = RecoilEngine(profile: profile, settings: settings(level: 0))
        XCTAssertEqual(engine.previewCurve().count, profile.pattern.count + 1)
    }

    // MARK: - 限幅

    /// 异常大的档位组合也不能让单次注入位移失控。
    func testMaxStepClampsSingleDelta() {
        var cfg = settings(level: 0, scale: 20)
        cfg.maxStep = 0.001
        let engine = RecoilEngine(profile: m416(), settings: cfg)
        engine.begin(at: 0)

        let delta = engine.sample(at: 2.0)
        XCTAssertLessThanOrEqual(hypot(delta.x, delta.y), 0.001 + 1e-9)
    }

    // MARK: - 武器库一致性

    func testAllProfilesHaveSaneParameters() {
        XCTAssertFalse(WeaponLibrary.all.isEmpty)
        for profile in WeaponLibrary.all {
            XCTAssertGreaterThan(profile.rpm, 100, profile.id)
            XCTAssertLessThan(profile.rpm, 2000, profile.id)
            XCTAssertGreaterThanOrEqual(profile.pattern.count, 20, profile.id)
            XCTAssertTrue(profile.pattern.allSatisfy { $0.dy >= 0 }, "\(profile.id) 出现负上跳")
            XCTAssertTrue(profile.pattern.allSatisfy { $0.dy < 0.5 }, "\(profile.id) 单发上跳过大")
        }
    }

    func testProfileIDsAreUnique() {
        let ids = WeaponLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "武器 id 有重复")
    }

    /// SharedRing 用「下标 + 1」编码武器，0 保留给未识别。
    func testRingIndexRoundTrip() {
        for profile in WeaponLibrary.all {
            guard let index = WeaponLibrary.index(of: profile.id) else {
                XCTFail("\(profile.id) 查不到下标")
                continue
            }
            XCTAssertGreaterThan(index, 0)
            XCTAssertEqual(WeaponLibrary.profile(ringIndex: index)?.id, profile.id)
        }
        XCTAssertNil(WeaponLibrary.profile(ringIndex: 0), "0 必须表示未识别")
        XCTAssertNil(WeaponLibrary.profile(ringIndex: UInt32(WeaponLibrary.all.count + 5)))
    }

    func testCumulativeIsMonotonic() {
        for profile in WeaponLibrary.all {
            let cumulative = profile.cumulative()
            for i in 1..<cumulative.count {
                XCTAssertGreaterThanOrEqual(cumulative[i], cumulative[i - 1], profile.id)
            }
        }
    }

    // MARK: - 共享内存

    func testSharedRingRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring_test_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let ring = SharedRing(url: url) else {
            XCTFail("SharedRing 初始化失败")
            return
        }

        ring.weaponIndex = 3
        ring.fireCount = 42
        ring.lastFireHostTime = 123.5
        ring.confidence = 9.25
        ring.requestCapture()

        XCTAssertEqual(ring.weaponIndex, 3)
        XCTAssertEqual(ring.fireCount, 42)
        XCTAssertEqual(ring.lastFireHostTime, 123.5, accuracy: 1e-9)
        XCTAssertEqual(ring.confidence, 9.25, accuracy: 1e-6)
        XCTAssertTrue(ring.capturePending)

        // 重新打开同一文件应保留数据，且 magic 校验不会清空它
        guard let reopened = SharedRing(url: url) else {
            XCTFail("SharedRing 二次打开失败")
            return
        }
        XCTAssertEqual(reopened.weaponIndex, 3)
        XCTAssertEqual(reopened.fireCount, 42)
        XCTAssertEqual(reopened.captureRequest, 1)

        reopened.captureAck = 1
        XCTAssertFalse(reopened.capturePending)
    }

    func testSharedRingResetTransient() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring_reset_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let ring = SharedRing(url: url) else {
            XCTFail("SharedRing 初始化失败")
            return
        }
        ring.weaponIndex = 5
        ring.fireCount = 99
        ring.lastFireHostTime = 50
        ring.resetTransient()

        XCTAssertEqual(ring.weaponIndex, 0)
        XCTAssertEqual(ring.fireCount, 0)
        XCTAssertEqual(ring.lastFireHostTime, 0, accuracy: 1e-12)
    }

    func testHostClockAdvances() {
        let a = HostClock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let b = HostClock.now()
        XCTAssertGreaterThan(b, a)
        XCTAssertGreaterThan(b - a, 0.005)
    }
}
