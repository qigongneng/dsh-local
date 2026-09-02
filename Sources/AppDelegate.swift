import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let port = 3080
    private let supportName = "DSHLocalOfficial"

    private var window: NSWindow!
    private var webView: DSHWebView!
    private var bridge: BridgeController!
    private var updater: UpdateManager!

    private var harnessProcess: Process?
    private var harnessLogHandle: FileHandle?
    private var harnessOutputPipe: Pipe?
    private let harnessOutputQueue = DispatchQueue(label: "local.codex.dsh-local.harness-output")
    private var harnessOutputBuffer = ""
    private var harnessLaunchURL: URL?
    private var readinessAttempt = 0
    private var isQuitting = false
    private var didLoadHarness = false
    private var didCheckPendingReleaseNotes = false

    // MARK: 路径 / 版本

    private var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private var supportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportName, isDirectory: true)
    }

    private var applicationVersion: String {
        let version = shortApplicationVersion
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "未知"
        return "\(version) (Build \(build))"
    }

    private var shortApplicationVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var runtimeVersion: String {
        let versionFile = supportDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("current-version")
        if let version = try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }
        let packageFile = supportDirectory
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String,
           !version.isEmpty {
            return version
        }
        return "未知"
    }

    private var bundledNode: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node")
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        updater = UpdateManager(
            supportDirectory: supportDirectory,
            environment: processEnvironment(),
            runtimeVersion: runtimeVersion,
            showAlert: { [weak self] title, message in
                self?.alert(title: title, message: message)
            }
        )
        configureMenu()
        createWindow()
        installBundledSupportScripts()
        startOrAttachHarness()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        if let process = harnessProcess, process.isRunning {
            process.terminate()
        }
        harnessOutputPipe?.fileHandleForReading.readabilityHandler = nil
        harnessOutputQueue.sync {
            flushHarnessOutputBuffer()
        }
        try? harnessLogHandle?.close()
    }

    // MARK: 窗口

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: BridgeController.clipboardImageHandlerName)
        configuration.userContentController.add(self, name: BridgeController.updaterHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BridgeController.pasteBridgeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BridgeController.versionBadgeScript(version: runtimeVersion),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = DSHWebView(frame: .zero, configuration: configuration)
        bridge = BridgeController(webView: webView, homeDirectory: homeDirectory)
        webView.handleImagePaste = { [weak self] in
            self?.bridge.deliverClipboardImageFromPasteboard() ?? false
        }
        webView.handleDroppedFiles = { [weak self] urls in
            self?.bridge.deliverDroppedFiles(urls) ?? false
        }
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "DSH Local \(shortApplicationVersion)"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        showStatus(title: "正在启动 DSH Local", detail: "正在连接 DeepSeek Harness 官方运行时…")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        if message.name == BridgeController.clipboardImageHandlerName {
            _ = bridge.deliverClipboardImageFromPasteboard()
            return
        }
        guard message.name == BridgeController.updaterHandlerName,
              let body = message.body as? [String: Any],
              body["action"] as? String == "checkOfficialUpdate" else { return }
        updater.checkForUpdates()
    }

    // MARK: 菜单

    private func configureMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "关于 DSH Local \(shortApplicationVersion)", action: #selector(showAbout), keyEquivalent: "")
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "检查官方更新…", action: #selector(checkForUpdates), keyEquivalent: "u")
        applicationMenu.addItem(withTitle: "查看当前版本更新内容…", action: #selector(showCurrentReleaseNotes), keyEquivalent: "")
        applicationMenu.addItem(withTitle: "回滚到上一版本…", action: #selector(rollbackVersion), keyEquivalent: "")
        applicationMenu.addItem(withTitle: "打开更新日志", action: #selector(openUpdateLog), keyEquivalent: "")
        applicationMenu.addItem(NSMenuItem.separator())
        applicationMenu.addItem(withTitle: "退出 DSH Local", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(pasteFromClipboard(_:)), keyEquivalent: "v")
        pasteItem.target = self
        editMenu.addItem(pasteItem)
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: 菜单动作（转发给桥 / 更新管理器）

    @objc private func pasteFromClipboard(_ sender: Any?) {
        bridge.pasteFromClipboard(sender)
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func showCurrentReleaseNotes() {
        updater.showCurrentReleaseNotes()
    }

    @objc private func rollbackVersion() {
        updater.rollbackVersion()
    }

    @objc private func openUpdateLog() {
        updater.openUpdateLog()
    }

    @objc private func showAbout() {
        alert(
            title: "DSH Local",
            message: "版本 \(applicationVersion)\n\n本机源码构建的非官方桌面壳。运行时仅跟踪 deepseek-ai/deepseek-harness 官方 Release，不代表 DeepSeek 官方背书。"
        )
    }

    // MARK: 脚本 / harness

    private func installBundledSupportScripts() {
        let fileManager = FileManager.default
        let bundledScripts = Bundle.main.resourceURL!.appendingPathComponent("scripts", isDirectory: true)
        let installedScripts = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try? fileManager.createDirectory(at: installedScripts, withIntermediateDirectories: true)

        for name in ["start-current.sh", "update.sh", "rollback.sh", "patch-market-compat.mjs"] {
            let source = bundledScripts.appendingPathComponent(name)
            let destination = installedScripts.appendingPathComponent(name)
            guard let sourceData = try? Data(contentsOf: source) else { continue }
            let destinationData = try? Data(contentsOf: destination)
            if sourceData != destinationData {
                try? sourceData.write(to: destination, options: .atomic)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    private func startOrAttachHarness() {
        checkEndpoint { [weak self] ready in
            guard let self else { return }
            if ready {
                self.loadHarness()
                return
            }
            let currentCLI = self.supportDirectory
                .appendingPathComponent("current", isDirectory: true)
                .appendingPathComponent("apps/cli/lib/bin.js")
            if !FileManager.default.fileExists(atPath: currentCLI.path) {
                self.showStatus(title: "正在构建官方版本", detail: "首次构建需要下载依赖，通常需要几分钟。完成后应用会自动启动。")
                self.updater.runUpdater { success in
                    if success {
                        self.launchHarnessProcess()
                    } else {
                        self.showStatus(title: "官方版本构建失败", detail: "请通过菜单打开更新日志查看原因。旧版本没有被替换。")
                    }
                }
                return
            }
            self.launchHarnessProcess()
        }
    }

    private func launchHarnessProcess() {
        let launcher = supportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("start-current.sh")
        guard FileManager.default.fileExists(atPath: launcher.path) else {
            showStatus(title: "启动脚本不存在", detail: launcher.path)
            return
        }

        let logsDirectory = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("harness.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
        harnessLogHandle = logHandle

        let process = Process()
        let outputPipe = Pipe()
        harnessOutputPipe = outputPipe
        harnessOutputBuffer = ""
        harnessLaunchURL = nil
        didLoadHarness = false
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.harnessOutputQueue.async { [weak self] in
                    self?.flushHarnessOutputBuffer()
                }
                return
            }
            self?.consumeHarnessOutput(data)
        }

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path, bundledNode.path, String(port)]
        process.environment = processEnvironment()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, !self.isQuitting, self.readinessAttempt < 1 else { return }
                self.showStatus(title: "Harness 进程已退出", detail: "退出码：\(process.terminationStatus)。请通过菜单打开日志。")
            }
        }

        do {
            try process.run()
            harnessProcess = process
            readinessAttempt = 0
            waitForHarness()
        } catch {
            showStatus(title: "无法启动 Harness", detail: error.localizedDescription)
        }
    }

    private func waitForHarness() {
        readinessAttempt += 1
        if let launchURL = harnessLaunchURL {
            loadHarness(at: launchURL)
            return
        }
        if readinessAttempt >= 180 {
            showStatus(title: "Harness 启动超时", detail: "请通过菜单打开更新日志或 Harness 日志。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForHarness()
        }
    }

    private func checkEndpoint(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let ready = (statusCode == 200
                    && body.contains("__DSH_BOOT__")
                    && body.contains("@deepseek-ai/dsh-client-modules"))
                || statusCode == 401
            DispatchQueue.main.async { completion(ready) }
        }.resume()
    }

    private func loadHarness(at launchURL: URL? = nil) {
        guard !didLoadHarness else { return }
        didLoadHarness = true
        let url = launchURL ?? URL(string: "http://127.0.0.1:\(port)/")!
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        guard !didCheckPendingReleaseNotes else { return }
        didCheckPendingReleaseNotes = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updater.presentReleaseNotes(onlyIfNew: true)
        }
    }

    /// Preserve normal Harness output while ensuring the one-time browser token
    /// never lands in a persistent log. A complete readiness line is parsed
    /// before redaction and handed directly to WebKit for the cookie exchange.
    private func consumeHarnessOutput(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        harnessOutputQueue.async { [weak self] in
            guard let self else { return }
            self.harnessOutputBuffer.append(chunk)
            while let newline = self.harnessOutputBuffer.firstIndex(of: "\n") {
                let line = String(self.harnessOutputBuffer[..<newline])
                self.harnessOutputBuffer.removeSubrange(...newline)
                self.recordHarnessOutputLine(line)
            }
        }
    }

    private func flushHarnessOutputBuffer() {
        guard !harnessOutputBuffer.isEmpty else { return }
        let line = harnessOutputBuffer
        harnessOutputBuffer = ""
        recordHarnessOutputLine(line)
    }

    private func recordHarnessOutputLine(_ rawLine: String) {
        let redactedLine = rawLine.replacingOccurrences(
            of: "([?&]token=)[A-Za-z0-9_-]+",
            with: "$1<redacted>",
            options: .regularExpression
        )
        if let data = "\(redactedLine)\n".data(using: .utf8) {
            try? harnessLogHandle?.write(contentsOf: data)
        }

        guard let launchURL = validatedHarnessLaunchURL(in: rawLine) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isQuitting, self.harnessLaunchURL == nil else { return }
            self.harnessLaunchURL = launchURL
            self.loadHarness(at: launchURL)
        }
    }

    private func validatedHarnessLaunchURL(in line: String) -> URL? {
        let marker = "dsh web: "
        guard let markerRange = line.range(of: marker) else { return nil }
        let remainder = line[markerRange.upperBound...]
        guard let candidate = remainder.split(whereSeparator: { $0.isWhitespace }).first,
              let components = URLComponents(string: String(candidate)),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port == port,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        if !queryItems.isEmpty {
            guard queryItems.count == 1,
                  queryItems[0].name == "token",
                  let token = queryItems[0].value,
                  token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
                return nil
            }
        }
        return components.url
    }

    // MARK: 状态 / 弹窗 / 环境

    private func showStatus(title: String, detail: String) {
        let escapedTitle = htmlEscaped(title)
        let escapedDetail = htmlEscaped(detail)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:light dark}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f}.card{max-width:680px;padding:42px;border-radius:22px;background:white;box-shadow:0 18px 60px rgba(0,0,0,.12);text-align:center}h1{font-size:28px;margin:0 0 14px}p{font-size:16px;line-height:1.6;color:#666;white-space:pre-wrap}@media(prefers-color-scheme:dark){body{background:#111;color:#f5f5f7}.card{background:#1c1c1e}p{color:#aaa}}</style></head>
        <body><div class="card"><h1>\(escapedTitle)</h1><p>\(escapedDetail)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = homeDirectory.path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(Bundle.main.resourceURL!.appendingPathComponent("bin").path):\(home)/.local/bin:\(home)/.hermes/node/bin:\(home)/.nvm/versions/node/v26.2.0/bin:/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
        environment["DSH_HOME"] = "\(home)/.dsh"
        environment["DSH_LOCAL_NODE_BIN"] = bundledNode.path
        environment["DSH_LOCAL_SUPPORT_ROOT"] = supportDirectory.path
        return environment
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
