import Cocoa
import WebKit

final class DSHWebView: WKWebView {
    var handleImagePaste: (() -> Bool)?
    var handleDroppedFiles: (([URL]) -> Bool)?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           handleImagePaste?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - File drag & drop bridge

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        return handleDroppedFiles?(urls) ?? false
    }

    private func droppedFileURLs(from info: NSDraggingInfo) -> [URL] {
        // Read all URL objects (both files and folders) so folder drops register.
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL]
        return urls ?? []
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let port = 3080
    private let supportName = "DSHLocalOfficial"
    private let clipboardImageHandlerName = "dshClipboardImage"
    private var window: NSWindow!
    private var webView: DSHWebView!
    private var harnessProcess: Process?
    private var updaterProcess: Process?
    private var harnessLogHandle: FileHandle?
    private var readinessAttempt = 0
    private var isQuitting = false
    private var didCheckPendingReleaseNotes = false

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureMenu()
        createWindow()
        installBundledSupportScripts()
        startOrAttachHarness()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running after the window is hidden (X hides, Cmd+Q quits).
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of closing so the harness (and the session) keeps running;
        // clicking the Dock icon brings the window back.
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
        try? harnessLogHandle?.close()
    }

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: clipboardImageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: nativeImagePasteBridgeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: runtimeVersionBadgeScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        webView = DSHWebView(frame: .zero, configuration: configuration)
        webView.handleImagePaste = { [weak self] in
            self?.deliverClipboardImageFromPasteboard() ?? false
        }
        webView.handleDroppedFiles = { [weak self] urls in
            self?.deliverDroppedFiles(urls) ?? false
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

    private func nativeImagePasteBridgeScript() -> String {
        """
        (() => {
          const supportedImageTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif']);

          const findComposer = () => {
            const active = document.activeElement;
            if (active instanceof HTMLTextAreaElement && active.closest('[data-composer-card]')) return active;
            const composer = document.querySelector('[data-composer-card] textarea');
            return composer instanceof HTMLTextAreaElement ? composer : null;
          };

          window.__dshLocalPasteImage = (base64, mediaType, fileName) => {
            const target = findComposer();
            if (target === null) return false;
            target.focus();
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
            const transfer = new DataTransfer();
            transfer.items.add(new File([bytes], fileName, { type: mediaType }));
            target.dispatchEvent(new ClipboardEvent('paste', {
              clipboardData: transfer,
              bubbles: true,
              cancelable: true,
            }));
            return true;
          };

          window.__dshLocalPasteText = (text) => {
            const target = findComposer();
            if (target === null) return false;
            target.focus();
            const transfer = new DataTransfer();
            transfer.setData('text/plain', text);
            target.dispatchEvent(new ClipboardEvent('paste', {
              clipboardData: transfer,
              bubbles: true,
              cancelable: true,
            }));
            return true;
          };

          document.addEventListener('paste', (event) => {
            const target = event.target;
            if (!(target instanceof HTMLTextAreaElement) || !target.closest('[data-composer-card]')) return;
            const clipboard = event.clipboardData;
            if (clipboard === null) return;
            const items = Array.from(clipboard.items);
            const fileItems = items.filter(item => item.kind === 'file');
            if (fileItems.some(item => supportedImageTypes.has(item.type))) return;

            const advertisedTypes = Array.from(clipboard.types);
            const hasImageHint = fileItems.some(item => item.type.startsWith('image/'))
              || advertisedTypes.some(type => type.startsWith('image/'));
            const hasPlainText = clipboard.getData('text/plain') !== '';
            if (hasImageHint || (!hasPlainText && advertisedTypes.length === 0)) {
              event.preventDefault();
              event.stopImmediatePropagation();
            }
            window.webkit?.messageHandlers?.dshClipboardImage?.postMessage({ source: 'composer-paste' });
          }, true);
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == clipboardImageHandlerName else { return }
        _ = deliverClipboardImageFromPasteboard()
    }

    private func deliverClipboardImageFromPasteboard() -> Bool {
        guard let pngData = clipboardImagePNGData() else { return false }
        injectImage(
            base64: pngData.base64EncodedString(),
            mediaType: "image/png",
            fileName: "剪贴板图片-\(Int(Date().timeIntervalSince1970)).png"
        )
        return true
    }

    /// Handle items dropped onto the web view: copy each dropped file or folder
    /// whole into `~/DSH_Drops/` (folder structure preserved) and tell the user
    /// where it landed, so the agent's OCR skill can read it. Nothing is injected
    /// into the composer — the web page's own drop handling creates attachments /
    /// references — which avoids clipboard side-effects and does not trigger the
    /// text-only "model does not support images" error.
    private func deliverDroppedFiles(_ urls: [URL]) -> Bool {
        let dropsDir = homeDirectory.appendingPathComponent("DSH_Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dropsDir, withIntermediateDirectories: true)
        let fileManager = FileManager.default
        var savedNames: [String] = []

        for url in urls {
            let destination = uniqueDestinationURL(in: dropsDir, for: url)
            do {
                try fileManager.copyItem(at: url, to: destination)
                savedNames.append(destination.lastPathComponent)
            } catch {
                // Skip any item that could not be copied.
            }
        }

        guard !savedNames.isEmpty else { return false }

        let names = savedNames.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "已接收拖入内容"
        alert.informativeText = "已保存到：\n\(dropsDir.path)\n\n\(names)\n\n在聊天框里把上面的路径发给助手，即可 OCR 识别。"
        alert.addButton(withTitle: "好")
        alert.runModal()
        return true
    }

    private func uniqueDestinationURL(in directory: URL, for url: URL) -> URL {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = directory.appendingPathComponent(url.lastPathComponent)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private func injectImage(base64: String, mediaType: String, fileName: String) {
        let payload: [String: String] = [
            "base64": base64,
            "mediaType": mediaType,
            "fileName": fileName,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.__dshLocalPasteImage?.(\(json).base64, \(json).mediaType, \(json).fileName)"
        )
    }

    private func injectText(_ text: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__dshLocalPasteText?.(\(json)[0])")
    }

    private func deliverClipboardTextFromPasteboard() -> Bool {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty,
              let jsonData = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: jsonData, encoding: .utf8) else { return false }
        webView.evaluateJavaScript("window.__dshLocalPasteText?.(\(json)[0])")
        return true
    }

    @objc private func pasteFromClipboard(_ sender: Any?) {
        if deliverClipboardImageFromPasteboard() { return }
        if deliverClipboardTextFromPasteboard() { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    private func clipboardImagePNGData() -> Data? {
        let pasteboard = NSPasteboard.general
        if let pngData = pasteboard.data(forType: .png) { return pngData }
        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let pngData = pngData(from: image) {
            return pngData
        }
        if let image = NSImage(pasteboard: pasteboard), let pngData = pngData(from: image) {
            return pngData
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url), let pngData = pngData(from: image) {
                    return pngData
                }
            }
        }
        return nil
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func runtimeVersionBadgeScript() -> String {
        let version = runtimeVersion
        let versionJSON = (try? JSONSerialization.data(withJSONObject: [version]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"未知\"]"
        return """
        (() => {
          const runtimeVersion = \(versionJSON)[0];
          let done = false;
          let scheduled = false;

          function replaceCommitBadge() {
            for (const element of document.querySelectorAll('button span')) {
              const text = (element.textContent || '').trim();
              if (element.children.length !== 0 || !/^[0-9a-f]{7,40}$/i.test(text)) continue;
              const button = element.closest('button');
              if (!button || !button.textContent.includes('DSH Local Build')) continue;
              element.textContent = runtimeVersion;
              element.style.whiteSpace = 'nowrap';
              element.style.flex = 'none';
              element.style.fontSize = '7px';
              element.style.padding = '0 3px';
              element.style.letterSpacing = '-0.1px';
              if (element.parentElement) element.parentElement.style.gap = '3px';
              element.title = `DeepSeek Harness ${runtimeVersion}`;
              element.setAttribute('aria-label', `DeepSeek Harness 版本 ${runtimeVersion}`);
              done = true;
            }
          }

          // Debounced: scan at most once per animation frame, and stop watching
          // once the badge is replaced — a subtree MutationObserver running a
          // full querySelectorAll on every DOM change would throttle streaming.
          const observer = new MutationObserver(() => {
            if (done || scheduled) return;
            scheduled = true;
            requestAnimationFrame(() => {
              scheduled = false;
              replaceCommitBadge();
              if (done) observer.disconnect();
            });
          });

          replaceCommitBadge();
          observer.observe(document.documentElement, { childList: true, subtree: true });
          if (done) observer.disconnect();
        })();
        """
    }

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

    private func installBundledSupportScripts() {
        let fileManager = FileManager.default
        let bundledScripts = Bundle.main.resourceURL!.appendingPathComponent("scripts", isDirectory: true)
        let installedScripts = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try? fileManager.createDirectory(at: installedScripts, withIntermediateDirectories: true)

        for name in ["start-current.sh", "update.sh", "rollback.sh"] {
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
                self.runUpdater { success in
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
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path, bundledNode.path, String(port)]
        process.environment = processEnvironment()
        process.standardOutput = logHandle
        process.standardError = logHandle
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
        checkEndpoint { [weak self] ready in
            guard let self else { return }
            if ready {
                self.loadHarness()
                return
            }
            if self.readinessAttempt >= 180 {
                self.showStatus(title: "Harness 启动超时", detail: "请通过菜单打开更新日志或 Harness 日志。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForHarness()
            }
        }
    }

    private func checkEndpoint(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let ready = (response as? HTTPURLResponse)?.statusCode == 200
                && body.contains("__DSH_BOOT__")
                && body.contains("@deepseek-ai/dsh-client-modules")
            DispatchQueue.main.async { completion(ready) }
        }.resume()
    }

    private func loadHarness() {
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        guard !didCheckPendingReleaseNotes else { return }
        didCheckPendingReleaseNotes = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.presentReleaseNotes(onlyIfNew: true)
        }
    }

    private func releaseNotesFile(for version: String) -> URL {
        supportDirectory
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("release-notes-zh.md")
    }

    private func releasePageURL(for version: String) -> URL? {
        URL(string: "https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v\(version)")
    }

    private func plainReleaseNotes(_ markdown: String) -> String {
        var lines: [String] = []
        var contentLineCount = 0
        let maximumContentLines = 12

        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
                continue
            }
            line = line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "\\[([^]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "^[*-]\\s+", with: "• ", options: .regularExpression)
            guard !line.isEmpty else { continue }
            lines.append(line)
            contentLineCount += 1
            if contentLineCount >= maximumContentLines {
                lines.append("")
                lines.append("更多内容请查看官方发布页。")
                break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentReleaseNotes(onlyIfNew: Bool) {
        let version = runtimeVersion
        guard version != "未知",
              let markdown = try? String(contentsOf: releaseNotesFile(for: version), encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !onlyIfNew {
                alert(title: "暂无中文更新说明", message: "当前官方版本：\(version)\n请稍后再次检查官方更新。")
            }
            return
        }

        let notifiedFile = supportDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("last-notified-version")
        let lastNotified = (try? String(contentsOf: notifiedFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if onlyIfNew && lastNotified == version { return }

        let releaseAlert = NSAlert()
        releaseAlert.messageText = onlyIfNew
            ? "DeepSeek Harness 已更新到 \(version)"
            : "DeepSeek Harness \(version) 更新内容"
        releaseAlert.informativeText = "主要更新内容：\n\n\(plainReleaseNotes(markdown))"
        releaseAlert.addButton(withTitle: "知道了")
        releaseAlert.addButton(withTitle: "查看官方发布页")
        let response = releaseAlert.runModal()

        if onlyIfNew {
            try? version.write(to: notifiedFile, atomically: true, encoding: .utf8)
        }
        if response == .alertSecondButtonReturn, let releaseURL = releasePageURL(for: version) {
            NSWorkspace.shared.open(releaseURL)
        }
    }

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

    private func runUpdater(completion: @escaping (Bool) -> Void) {
        if updaterProcess?.isRunning == true {
            completion(false)
            return
        }
        let updater = supportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("update.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [updater.path, "--manual"]
        process.environment = processEnvironment()
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.updaterProcess = nil
                completion(process.terminationStatus == 0)
            }
        }
        do {
            try process.run()
            updaterProcess = process
        } catch {
            completion(false)
        }
    }

    @objc private func checkForUpdates() {
        if updaterProcess?.isRunning == true {
            alert(title: "更新检查正在运行", message: "完成后可在更新日志中查看结果。")
            return
        }
        alert(title: "开始检查官方更新", message: "如果发现新版本，将在后台完成源码构建和健康检查；当前会话不会被中断。")
        runUpdater { [weak self] success in
            self?.alert(
                title: success ? "更新检查完成" : "更新检查失败",
                message: success ? "如有新版本，已准备为下次启动版本。" : "旧版本未被替换，请打开更新日志查看原因。"
            )
        }
    }

    @objc private func showCurrentReleaseNotes() {
        presentReleaseNotes(onlyIfNew: false)
    }

    @objc private func rollbackVersion() {
        let confirmation = NSAlert()
        confirmation.messageText = "回滚到上一版本？"
        confirmation.informativeText = "当前会话不会立即中断；退出并重新打开 DSH Local 后生效。"
        confirmation.addButton(withTitle: "回滚")
        confirmation.addButton(withTitle: "取消")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let rollback = supportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("rollback.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [rollback.path]
        process.environment = processEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
            alert(
                title: process.terminationStatus == 0 ? "回滚已准备" : "无法回滚",
                message: process.terminationStatus == 0 ? "请退出并重新打开应用。" : "没有可用的上一版本，请查看更新日志。"
            )
        } catch {
            alert(title: "无法回滚", message: error.localizedDescription)
        }
    }

    @objc private func openUpdateLog() {
        let logURL = supportDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("update.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            alert(title: "暂无更新日志", message: "尚未执行过更新检查。")
        }
    }

    @objc private func showAbout() {
        alert(
            title: "DSH Local",
            message: "版本 \(applicationVersion)\n\n本机源码构建的非官方桌面壳。运行时仅跟踪 deepseek-ai/deepseek-harness 官方 Release，不代表 DeepSeek 官方背书。"
        )
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
