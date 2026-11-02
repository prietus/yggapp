import Combine
import SwiftUI
import WebKit

/// Owns the WKWebView and mirrors its state for SwiftUI.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var addressText = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published var error: String?

    private var bag: Set<AnyCancellable> = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self

        webView.publisher(for: \.url).receive(on: RunLoop.main)
            .sink { [weak self] url in if let url { self?.addressText = Self.display(url) } }
            .store(in: &bag)
        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoBack = $0 }.store(in: &bag)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canGoForward = $0 }.store(in: &bag)
        webView.publisher(for: \.isLoading).receive(on: RunLoop.main)
            .sink { [weak self] in self?.isLoading = $0 }.store(in: &bag)
        webView.publisher(for: \.estimatedProgress).receive(on: RunLoop.main)
            .sink { [weak self] in self?.progress = $0 }.store(in: &bag)
    }

    func open(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        error = nil
        webView.load(URLRequest(url: url))
    }

    func goHome() { open(AlfisDNS.directoryURL.absoluteString) }

    // MARK: - Address parsing

    /// Turns what people type into a URL: "forum.ygg", "21a:…:66e8",
    /// "[21a:…]/path" or a full URL. Yggdrasil services are plain http.
    static func url(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("://") { return URL(string: s) }
        if isIPv6(s) { return URL(string: "http://[\(s)]/") }
        return URL(string: "http://" + s)
    }

    static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    /// Hide "http://" and a lone trailing slash, like Safari does.
    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        let rootOnly = (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
        if rootOnly, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.show(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.show(error) }
    }

    private func show(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        let host = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? ""
        switch ns.code {
        case NSURLErrorCannotFindHost where AlfisDNS.zones.contains(where: { host.hasSuffix("." + $0) }):
            self.error = "\(host) isn't in the directory yet. Try “Update from directory” on the Network tab, or use its IPv6 address."
        case NSURLErrorCannotFindHost:
            self.error = "Can't find \(host)."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            self.error = "\(host.isEmpty ? "The site" : host) didn't respond. It may be offline, or your peers can't reach it."
        default:
            self.error = ns.localizedDescription
        }
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @StateObject private var model = BrowserModel()
    @FocusState private var editing: Bool
    @State private var names: [String] = []
    @State private var started = false

    private var suggestions: [String] {
        let q = model.addressText.lowercased()
        guard editing, !q.isEmpty else { return [] }
        return names.filter { $0.contains(q) && $0 != q }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                WebView(webView: model.webView)
                if model.isLoading {
                    ProgressView(value: model.progress).progressViewStyle(.linear)
                }
                if let error = model.error {
                    banner(error)
                }
                if !tunnel.isConnected {
                    offline
                }
            }
            if !suggestions.isEmpty {
                List(suggestions, id: \.self) { name in
                    Button(name) {
                        model.addressText = name
                        submit()
                    }
                    .font(.callout.monospaced())
                }
                .listStyle(.plain)
                .frame(maxHeight: 220)
            }
            toolbar
        }
        .onAppear {
            names = SharedStore.hostNames()
            if !started, tunnel.isConnected {
                started = true
                model.goHome()
            }
        }
        .onChange(of: tunnel.isConnected) { connected in
            if connected, !started {
                started = true
                model.goHome()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)

            TextField("forum.ygg or IPv6 address", text: $model.addressText)
                .focused($editing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(submit)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .onTapGesture { names = SharedStore.hostNames() }

            Button {
                if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            Button { model.goHome() } label: { Image(systemName: "house") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(!tunnel.isConnected)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark") }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var offline: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Connect to Yggdrasil on the Network tab to browse.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func submit() {
        editing = false
        model.open(model.addressText)
    }
}

extension SharedStore {
    /// Sorted names from the local ALFIS table, for address-bar suggestions.
    static func hostNames() -> [String] {
        guard let json = SharedStore().alfisHostsJSON,
              let dict = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        else { return [] }
        return dict.keys.sorted()
    }
}
