import Cocoa
import WebKit

// MARK: - DSHWebView（接收拖拽 + 粘贴快捷键）

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

// MARK: - 粘贴 / 拖拽 / 图片注入桥

final class BridgeController {
    static let clipboardImageHandlerName = "dshClipboardImage"
    static let updaterHandlerName = "dshLocalUpdater"

    private weak var webView: DSHWebView?
    private let homeDirectory: URL

    init(webView: DSHWebView, homeDirectory: URL) {
        self.webView = webView
        self.homeDirectory = homeDirectory
    }

    // MARK: 注入到网页的脚本

    static func pasteBridgeScript() -> String {
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

    /// Expose the desktop-managed runtime version to web plugins and keep older
    /// Bloom releases from suggesting a global npm install/downgrade. The native
    /// bridge accepts one fixed action only; no arbitrary shell command crosses it.
    static func versionBadgeScript(version: String) -> String {
        let versionJSON = (try? JSONSerialization.data(withJSONObject: [version]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"未知\"]"
        return """
        (() => {
          const runtimeVersion = \(versionJSON)[0];
          let scheduled = false;

          const requestUpdateCheck = () => {
            window.webkit?.messageHandlers?.\(updaterHandlerName)?.postMessage({
              action: 'checkOfficialUpdate',
            });
          };

          const metadata = Object.freeze({
            runtimeVersion,
            updateManagedBy: 'DSH Local',
            updateMode: 'native',
            requestUpdateCheck,
          });
          try {
            Object.defineProperty(window, '__DSH_LOCAL__', {
              value: metadata,
              writable: false,
              configurable: false,
            });
          } catch {
            // A future DSH host may reserve the property. Keep the DOM metadata
            // fallback available without replacing a host-owned object.
          }

          function exposeDocumentMetadata() {
            const root = document.documentElement;
            if (!root) return;
            root.dataset.dshRuntimeVersion = runtimeVersion;
            root.dataset.dshUpdateManagedBy = 'DSH Local';
          }

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
            }
          }

          function patchLegacyBloomUpdater() {
            const root = document.querySelector('.dsh-bloom-dsh-update');
            if (!(root instanceof HTMLElement)) return;
            if (root.dataset.updateManagedBy === 'DSH Local') return;

            root.dataset.dshLocalManaged = 'true';
            const current = root.querySelector('[data-dsh-current]');
            const latest = root.querySelector('[data-dsh-latest]');
            const state = root.querySelector('[data-dsh-state]');
            const hint = root.querySelector('[data-dsh-hint]');
            const refresh = root.querySelector('[data-act="refresh"]');
            const copy = root.querySelector('[data-act="copy"]');

            if (current && current.textContent !== runtimeVersion) current.textContent = runtimeVersion;
            if (latest && latest.textContent !== '由桌面端检查') latest.textContent = '由桌面端检查';
            if (state) {
              if (state.textContent !== 'DSH Local 管理更新') state.textContent = 'DSH Local 管理更新';
              if (state.getAttribute('data-state') !== 'managed') state.setAttribute('data-state', 'managed');
            }
            if (hint instanceof HTMLElement) {
              hint.hidden = true;
              if (hint.textContent) hint.textContent = '';
            }
            if (refresh instanceof HTMLButtonElement) {
              if (refresh.textContent !== '检查更新') refresh.textContent = '检查更新';
              refresh.disabled = false;
              refresh.title = '由 DSH Local 检查并安装 DeepSeek Harness 官方 Release';
            }
            if (copy instanceof HTMLButtonElement) {
              copy.hidden = true;
              copy.disabled = true;
              copy.title = '运行时更新由 DSH Local 管理';
            }
          }

          document.addEventListener('click', (event) => {
            const target = event.target;
            if (!(target instanceof Element)) return;
            const button = target.closest('.dsh-bloom-dsh-update [data-act="refresh"], .dsh-bloom-dsh-update [data-act="copy"]');
            if (!(button instanceof HTMLButtonElement)) return;
            const root = button.closest('.dsh-bloom-dsh-update');
            if (!(root instanceof HTMLElement) || root.dataset.updateManagedBy === 'DSH Local') return;
            event.preventDefault();
            event.stopImmediatePropagation();
            requestUpdateCheck();
          }, true);

          function applyCompatibility() {
            exposeDocumentMetadata();
            replaceCommitBadge();
            patchLegacyBloomUpdater();
          }

          const observer = new MutationObserver(() => {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(() => {
              scheduled = false;
              applyCompatibility();
            });
          });

          function beginObserving() {
            const root = document.documentElement;
            if (!root) {
              document.addEventListener('DOMContentLoaded', beginObserving, { once: true });
              return;
            }
            applyCompatibility();
            observer.observe(root, { childList: true, subtree: true });
          }

          beginObserving();
        })();
        """
    }

    // MARK: 粘贴（图片 / 文本）

    func deliverClipboardImageFromPasteboard() -> Bool {
        guard let pngData = clipboardImagePNGData() else { return false }
        injectImage(
            base64: pngData.base64EncodedString(),
            mediaType: "image/png",
            fileName: "剪贴板图片-\(Int(Date().timeIntervalSince1970)).png"
        )
        return true
    }

    func deliverClipboardTextFromPasteboard() -> Bool {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return false }
        injectText(value)
        return true
    }

    @objc func pasteFromClipboard(_ sender: Any?) {
        if deliverClipboardImageFromPasteboard() { return }
        if deliverClipboardTextFromPasteboard() { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    // MARK: 拖拽

    /// Copy each dropped file or folder whole into `~/DSH_Drops/` (folder structure
    /// preserved) and tell the user where it landed, so the agent's OCR skill can
    /// read it. Nothing is injected into the composer — the web page's own drop
    /// handling creates attachments/references.
    func deliverDroppedFiles(_ urls: [URL]) -> Bool {
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

    // MARK: 内部工具

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
        webView?.evaluateJavaScript(
            "window.__dshLocalPasteImage?.(\(json).base64, \(json).mediaType, \(json).fileName)"
        )
    }

    private func injectText(_ text: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__dshLocalPasteText?.(\(json)[0])")
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
}
