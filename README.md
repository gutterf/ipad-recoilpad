# Recoil Pad · iPad Pro 后坐力控制

一个跑在 iPad Pro 上的 SwiftUI App：后台常驻，通过 ReplayKit 拿到游戏的屏幕画面和音频，
自动识别你手上是哪把枪，用一个 0–10 的滑块设定后坐力强度。

**先说你未越狱这个前提带来的结果，这决定了它能干什么。**

| 能力 | 未越狱 | 越狱 |
|---|---|---|
| 屏幕画面采集（ReplayKit 广播） | 可用 | 可用 |
| 游戏音频采集 + 枪声开火判定 | 可用 | 可用 |
| 武器图标自动识别 | 可用 | 可用 |
| 0–10 滑块与参数下发 | 可用 | 可用 |
| **把补偿量注入回游戏** | **不可用，界面灰化** | 可用 |

iPadOS 的沙箱不允许任何 App 向其他 App 注入触摸或其他输入事件。能拿到屏幕内容
（ReplayKit 是系统给的口子）和能往游戏里回写输入，是两件完全不同的事，后者没有非越狱
的合法路径。所以注入那一整块在你现在的设备上会是灰的，`CapabilityProbe` 启动时探测，
探测不到就自动 disabled 并写明原因——不是我没接，是这个口子物理上不存在。

未越狱状态下它能给你的是：**实时告诉你当前手持哪把枪、当前档位下的完整弹道形态、
开火节拍和实测射速。** 作用是把"手感"变成可读的数字，配枪和灵敏度调试时比盲试快很多。

---

## 工程搭建

`project.yml` 是唯一事实来源，一条命令出工程：

```bash
brew install xcodegen
cd ipad-recoilpad && xcodegen generate
open RecoilPad.xcodeproj
```

生成三个 target：

| target | 类型 | 源目录 |
|---|---|---|
| `RecoilPad` | App | `App/`, `Shared/` |
| `RecoilPadBroadcast` | 广播扩展 | `Broadcast/`, `Shared/` |
| `RecoilPadTests` | 单元测试 | `Tests/` |

不手写 `.xcodeproj` 的原因：两个 target 的文件归属、App Group、扩展内嵌关系全靠
pbxproj 里的 UUID 维系，手改极易出现"文件在但没编进去"或"扩展没被 embed"这类
静默故障——编译过得去，跑起来扩展不出现，很难查。改归属只改 `project.yml`。

`Shared/` 同时编进主 App 和扩展，两边各编译一份自己的副本，靠 App Group 共享
运行时数据。这是有意的：不走 module 边界，省掉一层 public 接口约束。

**三个必须对齐的地方，错一个都是静默故障：**

`WeaponMatcher` 必须在 `Shared/` 而不是 `Broadcast/`。主 App 制作模板也要用它，
放扩展目录只加扩展 target 会直接编译不过。`tools/verify.py` 专门检查这类跨 target
不可达引用。

`AppModel.broadcastExtensionID` 必须等于扩展的 `PRODUCT_BUNDLE_IDENTIFIER`，
对不上系统广播选择器里不会出现 RecoilPad。

App Group `group.com.yg.recoilpad` 必须**两个 target 的 entitlements 都有**。
只配一边，扩展写的数据主 App 读不到，表现是"采集在跑但武器和开火计数一直是 0"。

**签名**：自签侧载（AltStore / Sideloadly / Xcode 直装）都行。App Group 权限
免费开发者账号受限，请用付费账号签名，否则扩展和主 App 共享不了容器。

---

## 装机路径：当前设备的现实

目标设备是 **iPadOS 27.0 / 不越狱**。这个组合把大部分路径砍掉了，先摆清楚，省得一条条试。

**TrollStore 已经排除。** 它能永久签名任意 IPA——不要 Apple ID、不要电脑、用 URL scheme
从浏览器直接装，是最接近"空中投送"的方案，而且能保留任意 entitlements（App Group
也就能用）。但[官方文档](https://github.com/opa334/TrollStore)把版本窗口写死了：

> Supported versions: 14.0 beta 2 - 16.6.1, 16.7 RC (20H18), 17.0
> 16.7.x（除 16.7 RC）和 17.0.1+ will NEVER be supported

iPadOS 27.0 高出十代，没有余地。

**自动压枪也排除。** 不越狱就没有 HID 注入路径，这是 iPadOS 沙箱的硬边界，不是实现问题。
`App/` 下那套注入代码会一直灰着，界面文案已经如实写明这一点。

### 剩下三条路

| 路径 | 无线？ | 有效期 | App Group | 成本 |
|---|---|---|---|---|
| 免费 Apple ID + Sideloadly | 首次需 USB 配对 | 7 天 | 很可能不支持 | 免费 |
| **付费开发者账号 + OTA** | **是** | 1 年 | 支持 | $99/年 |
| 免费 Apple ID + AltStore | 首次需 USB | 7 天 | 很可能不支持 | 免费 |

**App Group 是这里的胜负手。** 主 App 和广播扩展靠它共享内存，没有它整个采集链路读不到
任何数据（表现是"采集在跑但视频/音频计数永远是 0"）。而免费 Apple ID（Personal Team）
能不能签 App Group，苹果自己的两页文档是矛盾的——
[capabilities 表](https://developer.apple.com/support/app-capabilities/)说能，
[membership 对照表](https://developer.apple.com/support/compare-memberships/)只把它列在付费档。

### 先花十分钟验证这一条

它决定你要不要掏那 99 美元：

1. 用免费账号走一遍 Sideloadly 签名安装（`Support/RecoilPad.entitlements` 保持原样，别删）
2. 装成功后开广播，看主 App 采集卡片上"视频 / 音频"两个计数会不会跳
3. **会跳** → App Group 能签，省下 99 美元，代价是每 7 天重签一次
4. **不跳，或签名时直接报 `doesn't include the App Groups capability`** → 必须付费

### 付费之后就是真正的"空中投送"

`.github/workflows/ota.yml` 已经写好，配好证书和 profile 之后：

1. 把证书、密码、两个 Ad Hoc profile 存进仓库 Secrets（需要填的项在 workflow 头部列全了）
2. Actions 里手动跑 `OTA Build`，它归档、签名、导出 ipa、生成 `manifest.plist`
3. 把 ipa 和 manifest 传到 `IPA_BASE_URL` 指向的 HTTPS 目录
4. iPad 上用 Safari 打开一行链接，系统弹安装确认

```
itms-services://?action=download-manifest&url=https://你的域名/manifest.plist
```

之后每次改代码，push 一下、重跑一次 workflow、iPad 上重新点一次链接就是新版本。
**全程不碰数据线，也不需要 Mac。**

`tools/make_manifest.py` 能在本地生成那个 manifest 和安装链接，它会检查 URL 是不是
HTTPS——itms-services 只接受 HTTPS，用 http 会被设备直接拒掉。

### 后台配置的两个坑

两个 bundle id（`com.yg.recoilpad` 和 `com.yg.recoilpad.broadcast`）都要在 Apple
Developer 后台启用 App Groups，并分配同一个 `group.com.yg.recoilpad`，Ad Hoc profile
也要重新生成带上这个权限。否则签名能过、运行时数据不通——和前面说的同一个故障。

Ad Hoc profile 还必须包含你 iPad 的 UDID。先在后台"设备"里把这台 iPad 注册进去，
否则导出的 ipa 装上去会提示"无法安装"。

---

## 没有 Mac 怎么办

不需要 Mac 也能编译，用 GitHub Actions。

1. 把 `ipad-recoilpad/` 推到一个 GitHub 仓库（公开私有都行，Actions 的 macOS runner 有免费额度）
2. `.github/workflows/build.yml` 自动跑：工程校验 → XcodeGen 生成 → 单元测试 → 构建未签名 ipa
3. 打开仓库的 Actions 运行页，在 Artifacts 里下载 `RecoilPad-unsigned-ipa`
4. Windows 上用 [Sideloadly](https://sideloadly.io/) 签名装到 iPad（需要 Apple ID + 数据线）

四步都不需要 Mac。CI 同时也是你的**编译验证**——本机没有 Swift 工具链时，
这是唯一能告诉你"代码到底编不编得过"的地方。

**iPad 上直接开发走不通。** Swift Playgrounds 不支持 App Extension，而这套东西的
核心就是那个广播扩展。没有扩展就没有屏幕画面、没有游戏音频、没有自动识别和开火
判定，整个 App 只剩一个滑块。

本地有 Mac 时 CI 依然有用：`xcodegen generate && xcodebuild test` 和 CI 跑的是同一套命令。

---

## 真正可能卡住你的地方：App Group

这条我必须提前说，因为**它可能在最后一步毁掉整个方案**。

主 App 和广播扩展是两个进程，靠 App Group 共享内存文件、UserDefaults 和模板目录。
没有 App Group，扩展写的数据主 App 一个字节都读不到，表现是"采集在跑但武器和开火
计数永远是 0"。

而 **App Group 在免费 Apple ID（Xcode 里的 Personal Team）上能不能签下来，
苹果自己的文档是矛盾的**：

| 出处 | 说法 |
|---|---|
| [Supported capabilities](https://developer.apple.com/support/app-capabilities/) | App Groups 在 "Apple Developer" 免费那一列打了 ✓ |
| [Choosing a Membership](https://developer.apple.com/support/compare-memberships/) | "Advanced app capabilities" 只列在付费的 Developer Program 下 |

第一张表说的 "Apple Developer" 和你 Xcode 里签的那个 "Personal Team"
**很可能不是同一件事**——苹果那张表根本没有 Personal Team 这一列。
有开发者反馈 HealthKit 在 Personal Team 上签不下来，而官方那张表里 HealthKit 也是打 ✓ 的，
说明那张表不能用来预测 Personal Team 的行为。

**我没有 iPad，也没有开发者账号，这一条我无法替你验证。** 别把我的话当结论。

**按这个顺序试，失败得越早越省时间：**

1. 先只建主 App（暂时去掉 `project.yml` 里的扩展 target，以及
   `RecoilPad.entitlements` 里的 App Group），看能不能装到 iPad 上跑起来
2. 加上广播扩展，App Group 留着，看能不能签、能不能在系统广播选择器里看到
   RecoilPad、能不能开始直播
3. 能直播了，看主 App 的采集卡片上 `视频 / 音频` 两个计数会不会跳。
   会跳 = App Group 生效，整条链路通了

第 3 步不过就说明 App Group 签不下来。两条退路：

**交 99 美元办个人开发者账号。** 最省事，也是唯一确定能解决的办法。

**改成 localhost IPC 绕开 App Group。** 主 App 用 `NWListener` 监听 127.0.0.1，
扩展用 `NWConnection` 连过去发 JSON，把 `SharedRing` 的 mmap 换掉。我没把它做成
默认方案，是因为**扩展能否连上主 App 的 localhost 端口我没有验证过**，
不想给你一份没把握的代码。真走到那一步再说。

---

## 广播扩展的两个坑

下面两条来自 [一份真机踩坑实录](https://github.com/Cheiineeey/ios-app-where-it-breaks/blob/main/05-screen-share/README.md)，
我对照检查了自己的实现：

**扩展里的 `Timer` 不会触发。** `Timer.scheduledTimer` 把 timer 挂到当前线程的
run loop 上，而广播扩展那个线程**没有转着的 run loop**——timer 挂上去了、
`isValid` 也返回 `true`，但永远不会 fire。表现是"扩展明明跑着，却什么都没发生"，
而且和"扩展根本没起来"长得一模一样，极难排查。

本工程的扩展**一个 Timer 都不用**：所有周期性的活都搭在 `processSampleBuffer` 上
（系统本来就以屏幕刷新率持续调它），用时间戳节流。主 App 侧的 `Timer` 不受影响，
那边主线程 run loop 一直在转。**将来往扩展里加东西时别用 Timer。**

**扩展内存上限 50MB，一帧全分辨率画面就 22MB。** 顶爆的后果不是崩溃弹窗，是 jetsam
直接杀进程——没有异常、没有日志，表现只是共享莫名其妙停了，主 App 那边完全不知道。

抓帧（`SampleHandler.performCapture`）是唯一有可能顶穿的地方，已经按"先降采样到
≤1280 宽再编 JPEG"改过。识别路径走 Vision 的 `regionOfInterest`，只处理 ROI 那一块，
开销可控。改这块时记住这个上限。

**扩展里的 `print` 你在 Xcode 控制台多半看不到。** 本工程用的是 `NSLog`，
可以通过 Console.app 或 `idevicesyslog` 看，比 `print` 可靠。

---

## 使用流程

**首次：做武器模板**

自动识别不是开箱即用的，模板得从你自己的游戏画面里抓，因为 HUD 布局、画质、
分辨率和机型相关，用别人的模板匹配不准。

1. 启动 App，点采集卡片里的按钮，在系统弹窗中选 `RecoilPad` 开始直播
2. 切到游戏，手上拿着 M416，回到 App 点「抓取当前画面」
3. 待标注列表里会出现刚抓的图，在下拉里选 `M416`，点保存
4. 换下一把枪重复。至少做两个模板之后自动识别才会生效

模板的特征向量存在 App Group 的 `templates/` 目录，文件名就是武器 id。

**日常：**

1. 开 App，开始直播（只要不结束直播，切后台也能持续采集）
2. 拖滑块。10 = 游戏原始后坐力，0 = 无后座，中间线性
3. 弹道卡片会实时画出来：虚线是原始上跳，实线是当前档位补偿后的形态
4. 遥测卡片显示实测射速、匹配距离、音频通量。未越狱时这是主要产出——
   实测射速和标称对不上，说明识别错了枪或者 onset 漏检；匹配距离一直偏大，
   说明模板该重做。这两个数能直接把"感觉不对"定位到具体环节。

---

## 滑块语义

```
补偿比例 = 1 - level / 10
```

`level = 10` → 补偿 0%，就是游戏原样。`level = 0` → 补偿 100%，
把武器标称的每一发上跳全部压掉。

实际位移还乘了两个系数：

```
位移 = 弹道曲线 × baseScale × (1 - level/10) × 增益
```

`baseScale` 是标定系数。后坐力的世界空间角度换算到屏幕位移，取决于你的游戏内灵敏度、
机型和画质，这个换算比脚本读不到，只能标一次。手感偏轻就把 `baseScale` 往上推。

`Shared/WeaponLibrary.swift` 里的弹道数值是按常见 FPS 后坐力形态给的**合理估计**，
不是实测数据。要做准的话，训练场对着墙打一梭子，按弹孔分布反推每一发的 `dy` 修正进
`WeaponLibrary.all`。形状对了以后，换灵敏度只需要动 `baseScale`。

---

## 开火判定

不用视觉，用音频。枪声在频谱上是一个极陡的宽带能量跃变，比"看开火按钮有没有亮"
可靠得多，也不受 HUD 改动影响。

`OnsetDetector` 做的是归一化频谱通量检测：

```
flux = Σ max(0, mag[i] - prevMag[i]) / (Σ prevMag[i] + ε)
```

过自适应阈值（历史均值 × 系数 + 偏置）且超过 35ms 不应期才算一次 onset。
灵敏度用滑块调，会通过共享内存实时同步到扩展。

主 App 侧拿到 onset 时刻后，用武器射速推进时间轴，**不依赖每一次 onset 都检测到**。
漏一拍不会导致错位，只会早一点点结束。

---

## 注入的实现（越狱设备）

`HIDInjector` 通过 `dlopen` + `dlsym` 调 IOKit 的私有接口，构造 digitizer 事件
派发进去。坐标是归一化的，原点左上。

有个细节值得说明：手指单向往下滑，几十发之后必然滑到屏幕边缘或者压到开火键。
**不能把坐标直接瞬移回锚点** —— 同一手指的坐标跳变会被游戏当成一次巨大位移，
视角当场甩飞。只能抬起、空一拍、重新按下，`InjectionService.push` 里就是处理这个的。

另外一件事：`HIDInjector` 里的字段常量是从 `IOHIDEventTypes.h` 的枚举顺序推出来的
（digitizer 字段基址 `0x30000`，`IsDisplayIntegrated` 是该枚举里第 23 项）。
越狱设备上有原始头文件，开 PATCH 之前核对一次：

```bash
grep -n "IsDisplayIntegrated" /path/to/IOKit/hid/IOHIDEventTypes.h
```

不一致就以头文件为准，改 `HIDInjector.Field.isDisplayIntegrated`。

越狱环境下换用 `Support/RecoilPad-Jailbreak.entitlements` 重新签名
（`ldid -SRecoilPad-Jailbreak.entitlements RecoilPad.app/RecoilPad`），
`CapabilityProbe` 才会返回可用，界面才会解除灰化。

---

## 文件

```
Shared/SharedStore.swift      设置模型、App Group 读写、level 语义
Shared/SharedRing.swift       mmap 跨进程状态 + 统一时基
Shared/WeaponLibrary.swift    11 把枪的弹道数据
Shared/RecoilEngine.swift     时间轴 -> 逐 tick 补偿增量
Shared/WeaponMatcher.swift    Vision 特征向量模板匹配
App/ControlPanel.swift        界面，含灰化逻辑与遥测
App/RecoilPadApp.swift        入口与 AppModel
App/InjectionCapability.swift 越狱与授权探测
App/InjectionService.swift    开火时序、手势复位、注入调度
App/HIDInjector.swift         IOHID 触摸注入
App/BackgroundKeeper.swift    静音音频保活
Broadcast/SampleHandler.swift 扩展入口，音视频分流
Broadcast/OnsetDetector.swift 枪声 onset 检测
Tests/RecoilEngineTests.swift 纯逻辑单元测试，模拟器可跑
tools/verify.py               工程一致性校验
tools/make_manifest.py        生成 OTA 无线安装用的 manifest.plist
project.yml                   XcodeGen 工程定义（唯一事实来源）
.github/workflows/build.yml   CI：无 Mac 时的编译验证与出包
.github/workflows/ota.yml     CI：付费账号签名 + 无线 OTA 分发
```

---

## 验证状态

本机是 Windows，**没有管理员权限**——WSL 发行版、Docker、Visual Studio 工具链
全都装不进来，Swift 编译器进不了这台机器。所以**这套代码没有经过编译**。

能做的验证都做了：

| 层 | 手段 | 结果 |
|---|---|---|
| 语法 | tree-sitter-swift 真语法树解析 | 14 个文件 0 处语法错误 |
| 数据 | 从源码解析 11 把枪的弹道表并逐项校验 | 全部合理 |
| 配置 | `plistlib` / `yaml.safe_load` | 可解析，扩展点与 App Group 声明齐全 |
| 结构 | target 覆盖 + 跨 target 类型可达性 | 无不可达引用 |
| 标识 | bundle id / principal class 交叉比对 | 一致 |

语法检查已经从"数括号"换成了 tree-sitter 的 AST 解析——它不只数括号，
`guard let y = else` 这种缺表达式的错误能精确定位到行列。

**两个检查器都做过反向验证**，因为一个永远返回 OK 的检查器等于没有：
把 `WeaponMatcher` 放回 `Broadcast/`，跨 target 检查报出"引用不可达类型"；
往 `App/` 插一个语法坏掉的探针文件，tree-sitter 报出 `ERROR @4:5`。

**但这些都证明不了能编译。** tree-sitter 查的是语法，Swift 的类型系统它一个字都看不懂——
`@MainActor` 隔离、泛型约束、协议一致性、`Sendable` 检查，这些错误一个都拦不住。
真正的编译验证只有 CI 能做，而那需要你把仓库推上去。

**真正的编译验证在 CI 里。** 推上 GitHub 后 `.github/workflows/build.yml` 会跑
单元测试并构建 ipa，打包步骤还会检查扩展有没有被嵌进 `PlugIns/` ——
那是另一种静默故障：编译全绿但扩展就是不在，装到 iPad 上广播选择器里看不到它。

**编译阶段大概率还要处理：**

`AppModel` 的 `@MainActor` 与 `@StateObject` 初始化隔离（视 SDK 版本）、`Timer` 闭包的
`@Sendable` 警告、`contentTransition(.numericText())` 的 iOS 版本要求。这些是 Swift
并发检查的常见摩擦，不是逻辑问题，看到报错不必怀疑架构。

`Tests/RecoilEngineTests.swift` 是补上编译验证缺失的关键一步：滑块语义、曲线采样精度、
末端外推、单步限幅、武器库一致性、共享内存往返全部断言过了，模拟器上
`xcodebuild test` 几十秒跑完，不需要真机也不需要广播权限。

改完代码重跑：`python3 tools/verify.py`
