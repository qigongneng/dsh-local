import Cocoa

/// 官方运行时更新：检查、回滚、发布说明、更新日志。
final class UpdateManager {
    private let supportDirectory: URL
    private let environment: [String: String]
    private let runtimeVersion: String
    private let showAlert: (_ title: String, _ message: String) -> Void

    private var updaterProcess: Process?

    init(
        supportDirectory: URL,
        environment: [String: String],
        runtimeVersion: String,
        showAlert: @escaping (_ title: String, _ message: String) -> Void
    ) {
        self.supportDirectory = supportDirectory
        self.environment = environment
        self.runtimeVersion = runtimeVersion
        self.showAlert = showAlert
    }

    // MARK: 检查更新

    func runUpdater(completion: @escaping (Bool) -> Void) {
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
        process.environment = environment
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

    func checkForUpdates() {
        if updaterProcess?.isRunning == true {
            showAlert("更新检查正在运行", "完成后可在更新日志中查看结果。")
            return
        }
        showAlert("开始检查官方更新", "如果发现新版本，将在后台完成源码构建和健康检查；当前会话不会被中断。")
        runUpdater { [weak self] success in
            self?.showAlert(
                success ? "更新检查完成" : "更新检查失败",
                success ? "如有新版本，已准备为下次启动版本。" : "旧版本未被替换，请打开更新日志查看原因。"
            )
        }
    }

    func rollbackVersion() {
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
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            showAlert(
                process.terminationStatus == 0 ? "回滚已准备" : "无法回滚",
                process.terminationStatus == 0 ? "请退出并重新打开应用。" : "没有可用的上一版本，请查看更新日志。"
            )
        } catch {
            showAlert("无法回滚", error.localizedDescription)
        }
    }

    func openUpdateLog() {
        let logURL = supportDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("update.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            showAlert("暂无更新日志", "尚未执行过更新检查。")
        }
    }

    // MARK: 发布说明

    func presentReleaseNotes(onlyIfNew: Bool) {
        let version = runtimeVersion
        guard version != "未知",
              let markdown = try? String(contentsOf: releaseNotesFile(for: version), encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !onlyIfNew {
                showAlert("暂无中文更新说明", "当前官方版本：\(version)\n请稍后再次检查官方更新。")
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

    func showCurrentReleaseNotes() {
        presentReleaseNotes(onlyIfNew: false)
    }

    // MARK: 内部工具

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
}
