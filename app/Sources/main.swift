import AppKit
import UniformTypeIdentifiers
import WebKit

// ============================== 网页界面（浮层 / 独立窗口共用） ==============================

final class WebBridge: NSObject, WKScriptMessageHandler {
    weak var app: AppDelegate?
    var webViews: [WKWebView] = []

    func makeWebView(mode: String, route: String? = nil) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "fs")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        // 没有 uiDelegate 时，网页里的 confirm() 不弹框、直接返回"取消"，alert() 也不显示
        wv.uiDelegate = self
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "mode", value: mode)]
            if let r = route, !r.isEmpty { comps.queryItems?.append(URLQueryItem(name: "route", value: r)) }
            if let q = ProcessInfo.processInfo.environment["FS_DEBUG_QUERY"], let eq = q.firstIndex(of: "=") {
                comps.queryItems?.append(URLQueryItem(name: String(q[..<eq]), value: String(q[q.index(after: eq)...])))
            }
            wv.loadFileURL(comps.url!, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        webViews.append(wv)
        return wv
    }

    func pushState() {
        guard let data = try? JSONSerialization.data(withJSONObject: StateStore.shared.payload()),
              let s = String(data: data, encoding: .utf8) else { return }
        for wv in webViews where wv.window?.isVisible == true {
            wv.evaluateJavaScript("window.__fsState && window.__fsState(\(s))", completionHandler: nil)
        }
    }

    private func reply(_ wv: WKWebView?, _ id: Any, _ obj: [String: Any]) {
        guard let wv = wv, let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        let idJSON = (id as? String).map { "\"\($0)\"" } ?? "\(id)"
        wv.evaluateJavaScript("window.__fsReply && window.__fsReply(\(idJSON), \(s))", completionHandler: nil)
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = body["id"] ?? 0
        let wv = message.webView
        switch cmd {
        case "run":
            let args = (body["args"] as? [String]) ?? []
            CLI.runAsync(args, timeout: (body["timeout"] as? Double) ?? 120) { [weak self] r in
                self?.reply(wv, id, ["code": Int(r.code), "out": r.out, "err": r.err])
                StateStore.shared.tick()
                if args.first.map({ $0.hasPrefix("rule-") || $0 == "global-set" || $0 == "import" }) == true {
                    StateStore.shared.reloadRules(force: true)
                }
            }
        case "spawn":
            CLI.spawn((body["args"] as? [String]) ?? [])
            reply(wv, id, ["code": 0])
        case "state":
            if let d = try? JSONSerialization.data(withJSONObject: StateStore.shared.payload()),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                reply(wv, id, o)
            }
        case "refresh":
            StateStore.shared.reloadRules(force: true)
            reply(wv, id, ["code": 0])
        case "expand":
            app?.openWindow(route: body["route"] as? String)
            reply(wv, id, ["code": 0])
        case "chooseFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            if let start = body["start"] as? String, !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
            NSApp.activate(ignoringOtherApps: true)
            let ok = panel.runModal() == .OK
            reply(wv, id, ["path": ok ? (panel.url?.path ?? "") : ""])
        case "chooseFile":
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
            NSApp.activate(ignoringOtherApps: true)
            let ok = panel.runModal() == .OK
            reply(wv, id, ["path": ok ? (panel.url?.path ?? "") : ""])
        case "reveal":
            if let p = body["path"] as? String { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
            reply(wv, id, ["code": 0])
        case "openFile":
            if let p = body["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
            reply(wv, id, ["code": 0])
        case "openLog":
            let log = NSHomeDirectory() + "/Library/Logs/folder-sync.log"
            let fallback = CLI.stateDir + "/folder-sync.log"
            let path = FileManager.default.fileExists(atPath: log) ? log : fallback
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"), configuration: NSWorkspace.OpenConfiguration())
            reply(wv, id, ["code": 0])
        case "exportConfig":
            // 导出：配置文件原文由命令行导出，应用再把本页设置和开机自启补进同一个 JSON 文件
            let panel = NSSavePanel()
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            panel.nameFieldStringValue = "folder-sync-config-\(df.string(from: Date())).json"
            panel.canCreateDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { reply(wv, id, ["cancelled": true]); return }
            CLI.runAsync(["export"], timeout: 30) { [weak self] r in
                guard r.code == 0, let data = r.out.data(using: .utf8),
                      var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.reply(wv, id, ["code": 1, "err": msg.isEmpty ? "导出失败" : msg])
                    return
                }
                obj["app_version"] = Update.version
                obj["settings"] = Settings.dict()
                obj["autostart"] = !FileManager.default.fileExists(atPath: CLI.stateDir + "/autostart.off")
                guard let json = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
                    self?.reply(wv, id, ["code": 1, "err": "无法生成导出文件"]); return
                }
                do {
                    try json.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    self?.reply(wv, id, ["code": 0, "path": url.path])
                } catch {
                    self?.reply(wv, id, ["code": 1, "err": "写入失败：\(error.localizedDescription)"])
                }
            }
        case "importConfig":
            // 导入：先让命令行算出将发生的变化（预览），由网页弹确认后再真正写入
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { reply(wv, id, ["cancelled": true]); return }
            guard let data = FileManager.default.contents(atPath: url.path),
                  let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reply(wv, id, ["code": 1, "err": "不是有效的配置文件"]); return
            }
            CLI.runAsync(["import", url.path, "--preview"], timeout: 30) { [weak self] r in
                guard r.code == 0, let d = r.out.data(using: .utf8),
                      var preview = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                    let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.reply(wv, id, ["code": 1, "err": msg.isEmpty ? "这个文件不是 FolderSync 的配置备份" : msg])
                    return
                }
                // 应用设置来自导出文件本身（命令行不解析这一项）
                if let s = file["settings"] as? [String: Any] { preview["settings"] = s }
                if let a = file["autostart"] as? Bool { preview["autostart"] = a }
                self?.reply(wv, id, ["code": 0, "path": url.path, "preview": preview])
            }
        case "settings":
            if let v = body["value"] as? [String: Any] { Settings.apply(v) }
            reply(wv, id, Settings.dict())
        case "update":
            if (body["action"] as? String) == "install" { Update.install() } else { Update.check(force: true) }
            reply(wv, id, Update.dict())
        case "previewOverlay":
            if let c = body["corner"] as? String { app?.overlay.preview(corner: c) }
            reply(wv, id, ["code": 0])
        case "doctor":
            CLI.runAsync(["doctor", "--json", "--app-path", Setup.appPath], timeout: 30) { [weak self] r in
                if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    self?.reply(wv, id, o)
                } else {
                    self?.reply(wv, id, ["error": (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)])
                }
            }
        case "setupInstall":
            Setup.install { [weak self] r in
                StateStore.shared.reloadRules(force: true)
                self?.reply(wv, id, ["code": Int(r.code), "out": r.out, "err": r.err])
            }
        case "copyText":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
            reply(wv, id, ["code": 0])
        case "openURL":
            if let s = body["url"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
            reply(wv, id, ["code": 0])
        case "uninstall":
            app?.confirmUninstall()
            reply(wv, id, ["code": 0])
        case "drag":
            // 顶部区域被网页覆盖：用最近一次鼠标按下事件交给原生窗口拖动
            if let w = wv?.window, let ev = app?.lastMouseDown, ev.window === w { w.performDrag(with: ev) }
        case "zoom":
            wv?.window?.zoom(nil)
        case "quit":
            NSApp.terminate(nil)
        default:
            reply(wv, id, ["code": 1, "err": "unknown command \(cmd)"])
        }
    }
}

extension WebBridge: WKUIDelegate {
    /// 第一行作为标题，其余作为说明文字
    private func makeAlert(_ message: String) -> NSAlert {
        let a = NSAlert()
        if let nl = message.firstIndex(of: "\n") {
            a.messageText = String(message[..<nl])
            a.informativeText = String(message[message.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            a.messageText = message
        }
        return a
    }

    private func present(_ a: NSAlert, for wv: WKWebView, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = wv.window, w === app?.window, w.isVisible {
            a.beginSheetModal(for: w, completionHandler: done)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            done(a.runModal())
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = makeAlert(message)
        a.addButton(withTitle: "好")
        present(a, for: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = makeAlert(message)
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        present(a, for: webView) { r in completionHandler(r == .alertFirstButtonReturn) }
    }
}

// ============================== 应用主体 ==============================

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var window: NSWindow?
    let bridge = WebBridge()
    let overlay = OverlayController()
    var popoverWeb: WKWebView!
    var spin = 0
    var lastMouseDown: NSEvent?

    func applicationDidFinishLaunching(_ n: Notification) {
        Setup.takeOverOtherInstances()
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Logo.appIcon()
        NSApp.mainMenu = buildMainMenu()
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.lastMouseDown = e; return e }
        bridge.app = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        updateIcon(running: false, failed: false)

        popoverWeb = bridge.makeWebView(mode: "popover")
        let vc = NSViewController()
        vc.view = popoverWeb
        vc.preferredContentSize = NSSize(width: 460, height: 620)
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self

        NSApp.servicesProvider = ServicesProvider()
        NSUpdateDynamicServices()

        overlay.model.open = { [weak self] route in
            if self?.overlay.isPreviewing == true { return }   // 预览条只是示意，不响应点击
            self?.openWindow(route: route)
        }
        StateStore.shared.listeners.append { [weak self] s in self?.stateChanged(s) }
        StateStore.shared.start()
        Setup.run(self)
        Update.start()
        if let r = ProcessInfo.processInfo.environment["FS_DEBUG_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openWindow(route: r) }
        }
        if ProcessInfo.processInfo.environment["FS_DEBUG_SNAPSHOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.debugSnapshot() }
        }
        // 调试：在窗口页面里执行一段 JS，结果写到 /tmp/foldersync-eval.txt（只在设置了环境变量时生效）
        if let js = ProcessInfo.processInfo.environment["FS_DEBUG_EVAL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let wv = self.window?.contentView as? WKWebView else { return }
                wv.evaluateJavaScript(js) { r, e in
                    let text = "\(r.map { "\($0)" } ?? "nil")\(e.map { " ERROR \($0)" } ?? "")"
                    try? text.write(toFile: "/tmp/foldersync-eval.txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// 卸载：停止后台同步、删除开机启动项和命令行工具，再把应用移到废纸篓并退出；配置与记录保留
    func confirmUninstall() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "卸载 FolderSync？"
        a.informativeText = "将停止后台同步，删除开机启动项和命令行工具，并把 FolderSync 移到废纸篓。\n\n配置（~/.config/folder-sync）和同步记录（~/.local/state/folder-sync）会保留，重新安装后继续使用。"
        a.addButton(withTitle: "卸载")
        a.addButton(withTitle: "取消")
        let proceed: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            CLI.runAsync(["uninstall", "--keep-app"], timeout: 60) { res in
                if res.code != 0 {
                    let e = NSAlert()
                    e.messageText = "卸载失败"
                    e.informativeText = (res.err + res.out).trimmingCharacters(in: .whitespacesAndNewlines)
                    e.runModal()
                    return
                }
                guard !CLI.isolated else { NSApp.terminate(nil); return }
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, err in
                    if err != nil {
                        let m = NSAlert()
                        m.messageText = "已卸载后台服务"
                        m.informativeText = "请手动把 FolderSync 从\"应用程序\"拖到废纸篓。"
                        m.runModal()
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window, w.isVisible { a.beginSheetModal(for: w, completionHandler: proceed) } else { proceed(a.runModal()) }
    }

    func stateChanged(_ s: StateStore) {
        let running = s.snapshots.contains { $0.isRunning }
        let failed = s.snapshots.contains { $0.failedUnacked }
        updateIcon(running: running, failed: failed)
        overlay.update(s)
        bridge.pushState()
    }

    func updateIcon(running: Bool, failed: Bool) {
        guard let b = statusItem.button else { return }
        if failed {
            b.image = Logo.menuBarImage(color: .systemRed)
        } else if running {
            // 同步中：同一图形轻微闪烁
            spin = (spin + 1) % 2
            b.image = Logo.menuBarImage(alpha: spin == 0 ? 1 : 0.45)
        } else {
            b.image = Logo.menuBarImage()
        }
    }

    /// 主菜单：没有"编辑"菜单时，输入框里的 ⌘A / ⌘C / ⌘V / ⌘Z 都不生效
    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 FolderSync", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 FolderSync", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FolderSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.windowsMenu = win
        return main
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        guard let b = statusItem.button else { return }
        StateStore.shared.tick()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        bridge.pushState()
    }

    func openWindow(route: String?) {
        popover.performClose(nil)
        let created = window == nil
        if window == nil {
            // 宽度贴合"侧边栏 + 编辑表单"，高度尽量多显示表单
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let h = min(880, vf.height - 40), w = min(920, vf.width - 40)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            win.title = "FolderSync"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 760, height: 520)
            win.contentView = bridge.makeWebView(mode: "window", route: route)
            win.center()
            win.setFrameAutosaveName("FolderSyncMainV2")
            win.delegate = self
            window = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
        if !created, let r = route, let wv = window?.contentView as? WKWebView {
            let js = "window.__fsRoute && window.__fsRoute(\(String(reflecting: r)))"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wv.evaluateJavaScript(js, completionHandler: nil) }
        }
        bridge.pushState()
    }

    /// 红黄绿按钮：离边框更远，并在 52pt 高的顶部栏里垂直居中（与侧边栏的 logo、应用名对齐）
    func layoutTrafficLights() {
        guard let w = window, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let barHeight: CGFloat = 52, left: CGFloat = 20, spacing: CGFloat = 22
        var f = container.frame
        f.size.height = barHeight
        f.origin.y = w.frame.height - barHeight
        container.frame = f
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, t) in buttons.enumerated() {
            guard let b = w.standardWindowButton(t), let sv = b.superview else { continue }
            let y = (sv.frame.height - b.frame.height) / 2
            b.setFrameOrigin(NSPoint(x: left + CGFloat(i) * spacing, y: y))
        }
    }
    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        // 关闭窗口后回到"只有菜单栏图标"的形态
        NSApp.setActivationPolicy(.accessory)
    }

    /// foldersync://window[/edit:规则] 打开管理窗口；foldersync://popover 打开浮层
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "foldersync" {
            let route = u.path.isEmpty ? nil : String(u.path.dropFirst())
            if u.host == "debug-snapshot" { debugSnapshot(); continue }
            if u.host == "popover" {
                if !popover.isShown { togglePopover(nil) }
            } else {
                openWindow(route: route)
            }
        }
    }

    /// 调试：把各网页视图渲染成 /tmp/foldersync-<n>.png，并导出页面状态
    func debugSnapshot() {
        overlay.snapshot(to: "/tmp/foldersync-overlay.png")
        for (i, wv) in bridge.webViews.enumerated() {
            wv.evaluateJavaScript("document.body.className + ' | ' + document.querySelectorAll('.card').length + ' cards | ' + (document.querySelector('#main')||{}).innerText.slice(0,200)") { r, e in
                try? "\(r ?? "") \(e.map { "\($0)" } ?? "")".write(toFile: "/tmp/foldersync-\(i).txt", atomically: true, encoding: .utf8)
            }
            wv.takeSnapshot(with: nil) { img, _ in
                guard let img = img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: "/tmp/foldersync-\(i).png"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// ============================== Finder 快速操作 ==============================

final class ServicesProvider: NSObject {
    private func paths(_ pboard: NSPasteboard) -> [String] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path }
    }

    private func alert(_ title: String, _ text: String, buttons: [String] = ["好"]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal()
    }

    @objc func downloadFromRemote(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let ps = paths(pboard)
        guard !ps.isEmpty else { return }
        CLI.runAsync(["pull", "--preview", "--"] + ps, timeout: 300) { r in
            guard r.code == 0, let d = r.out.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (o["ok"] as? Bool) == true else {
                var msg = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let e = o["error"] as? String { msg = e }
                _ = self.alert("无法从远端下载", msg.isEmpty ? "未知错误" : msg)
                return
            }
            let rule = o["rule"] as? String ?? ""
            let newC = o["new_count"] as? Int ?? 0, overC = o["overwrite_count"] as? Int ?? 0
            if newC + overC == 0 {
                _ = self.alert("本地已是最新", "规则 [\(rule)] 下所选内容与远端一致，无需下载。")
                return
            }
            var text = "规则 [\(rule)]：将新增 \(newC) 个、覆盖本地 \(overC) 个文件。\n不会删除任何本地文件。"
            let over = (o["overwrite"] as? [String]) ?? []
            if !over.isEmpty {
                text += "\n\n将被覆盖：\n" + over.prefix(12).joined(separator: "\n")
                if over.count > 12 { text += "\n…等 \(overC) 个" }
            }
            if self.alert("从远端下载？", text, buttons: ["下载", "取消"]) == .alertFirstButtonReturn {
                CLI.spawn(["pull", "--yes", "--"] + ps)
            }
        }
    }

    @objc func uploadToRemote(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let ps = paths(pboard)
        guard !ps.isEmpty else { return }
        CLI.runAsync(["push", "--no-wait", "--"] + ps, timeout: 3600) { r in
            if r.code != 0 && r.code != 75 {
                let msg = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.contains("不属于任何同步规则") || msg.contains("不同规则") {
                    _ = self.alert("无法上传", msg)
                }
            } else if r.code == 75 {
                _ = self.alert("该项目正在同步", "请等当前同步结束后再上传，或先在状态条上停止。")
            }
        }
    }
}

// ============================== 入口 ==============================

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
