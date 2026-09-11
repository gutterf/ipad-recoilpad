import Foundation
import Network

/// 主 App 与广播扩展之间的备用数据通路。
///
/// 为什么需要它：App Group 在免费 Apple ID（Personal Team）上签不下来，
/// 而带不可用 capability 的包在签名阶段就会直接失败。所以没有付费账号时，
/// 主 App 和扩展是两个完全隔离的沙箱，唯一的互通方式是网络。
///
/// 用 loopback（127.0.0.1）而不是局域网：
///   - loopback 不属于"本地网络"，不需要 NSLocalNetworkUsageDescription
///     （那项权限只针对局域网/多播，申请了反而会让用户看到一个多余的系统弹窗）
///   - 流量不出设备
///
/// 传输内容是共享内存块的原始字节副本（定长 64 字节），两端结构一致，
/// 所以不需要任何序列化格式 —— 直接搬字节。`updatedAt` 字段在 offset 48，
/// 两端靠它判断数据新鲜度。
///
/// 未验证：广播扩展进程能否成功连上主 App 监听的 loopback 端口。
/// 这一点我没有设备可测。连不上不会崩，只是 SharedRing 一直读到零值，
/// 表现为"采集在跑但计数不动"。

public enum LoopbackConfig {
    /// 固定端口。没有 App Group 就没办法协商端口，只能写死。
    /// 值本身没有含义，取一个不常被占用的高位端口。
    public static let port: UInt16 = 47821
    public static let packetSize = 64
}

// MARK: - 主 App 侧

public final class LoopbackServer {

    private let queue = DispatchQueue(label: "yg.recoilpad.loopback.server", qos: .utility)
    private var listener: NWListener?
    private var connection: NWConnection?

    /// 收到扩展推来的数据包。参数是定长的原始字节。
    public var onPacket: ((Data) -> Void)?

    /// 每次收到数据后调用，返回要回传给扩展的控制包（可空）。
    public var controlProvider: (() -> Data?)?

    public private(set) var isListening = false
    public private(set) var peerConnected = false

    public init() {}

    public func start() {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: LoopbackConfig.port)!
        )

        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                self?.isListening = (state == .ready)
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            // 端口占用或系统拒绝。不抛出去：没有它 App 依然能用，
            // 只是拿不到扩展的数据（与 App Group 不可用时表现一致）。
            isListening = false
        }
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        isListening = false
        peerConnected = false
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            self?.peerConnected = (state == .ready)
            if case .failed = state { self?.peerConnected = false }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: LoopbackConfig.packetSize,
                     maximumLength: LoopbackConfig.packetSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, data.count == LoopbackConfig.packetSize {
                self.onPacket?(data)
                if let control = self.controlProvider?() {
                    conn.send(content: control, completion: .contentProcessed { _ in })
                }
            }

            if error != nil || isComplete {
                self.peerConnected = false
                return
            }
            self.receive(conn)
        }
    }
}

// MARK: - 扩展侧

public final class LoopbackClient {

    private let queue = DispatchQueue(label: "yg.recoilpad.loopback.client", qos: .utility)
    private var connection: NWConnection?
    private var isReady = false
    private var retryScheduled = false

    /// 扩展必须先当客户端（主 App 是服务端），因为扩展的生命周期由系统控制，
    /// 主 App 在后台一直活着。
    public init() {}

    public func start() {
        connect()
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        isReady = false
    }

    public var connected: Bool { isReady }

    /// 发送一个定长状态包。未连接时静默丢弃 —— 扩展里没有重试队列的价值，
    /// 下一个包马上就到。
    public func send(_ data: Data) {
        guard let connection, isReady else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func connect() {
        guard connection == nil else { return }

        let params = NWParameters.tcp
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: LoopbackConfig.port)!
        )
        let conn = NWConnection(to: endpoint, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.retryScheduled = false
            case .failed, .cancelled:
                self.isReady = false
                self.connection = nil
                self.scheduleRetry()
            case .waiting:
                self.isReady = false
                self.scheduleRetry()
            default:
                break
            }
        }

        conn.start(queue: queue)
        connection = conn
    }

    /// 扩展里不能用 Timer.scheduledTimer（那个线程没有转着的 run loop，
    /// timer 永远不会 fire），所以重连走 GCD 延时。
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        connection?.cancel()
        connection = nil
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.retryScheduled = false
            self?.connect()
        }
    }
}
