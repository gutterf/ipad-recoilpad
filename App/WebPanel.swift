import SwiftUI
import WebKit

/// 灵敏度对比与 M4 弹道模拟的网页界面。
///
/// 为什么用 WKWebView 而不是把它重写成 SwiftUI：
/// 那套界面（实时波形、角度谱、靶纸弹道图、逐档对比表）是大量 Canvas 绘制和
/// 响应式布局，重写成原生控件是一周的量，而且以后每改一次界面要改两遍。
/// 页面本身是自包含的（167 KB，零外部请求），塞进 App 包里就能离线跑。
///
/// 这里刻意不做任何 JS 桥接：页面不需要读设备数据，也不需要调用原生能力。
/// 一旦引入桥接，就得处理权限、消息大小、生命周期，而这些换不来任何东西。
struct WebPanel: View {

    /// 页面文件放在 App 包内。打不开时给出确切原因，而不是白屏。
    private static var pageURL: URL? {
        Bundle.main.url(forResource: "aim-dashboard", withExtension: "html")
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = Self.pageURL {
                    WebViewContainer(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    missingFileNotice
                }
            }
            .background(Color(red: 0.027, green: 0.039, blue: 0.047))
            .navigationTitle("灵敏度与弹道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 资源没打进包时最可能的原因，直接写出来 —— 白屏最难查。
    private var missingFileNotice: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("界面文件不在应用包里")
                .font(.headline)
                .foregroundStyle(.white)
            Text("找不到 aim-dashboard.html。\n检查 project.yml 里 RecoilPad 的 resources 是否包含这个文件，改动后需要重新 xcodegen generate。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WKWebView 封装

private struct WebViewContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 页面不联网，但保守起见仍然关掉不需要的能力。
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // 数据存储放到内存里：这个页面不写 cookie 也不用 localStorage，
        // 落到磁盘只会留下无意义的残留。
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.027, green: 0.039, blue: 0.047, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        // 页面自己要处理滚动（内部有多个滚动区），让 WebView 不要抢手势。
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 静态本地页，不需要响应 SwiftUI 的状态变化重新加载。
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// 任何非 file:// 的跳转都是意外 —— 这个页面不应该产生网络请求。
        /// 拦下来并打印，避免它变成一个查询不到来源的空白页。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let scheme = navigationAction.request.url?.scheme else {
                decisionHandler(.allow)
                return
            }
            if scheme == "file" || scheme == "about" {
                decisionHandler(.allow)
            } else {
                NSLog("[RecoilPad] 拦截了页面的外部跳转: \(navigationAction.request.url?.absoluteString ?? "?")")
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[RecoilPad] 页面加载失败: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[RecoilPad] 页面预加载失败: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("[RecoilPad] 界面已加载")
        }
    }
}
