import AppKit

/// 首次打开 / 升级后的自动安装：检查依赖 → 安装命令行工具、后台守护和开机启动项。
/// 依赖不齐或直接从 DMG 里打开时，打开窗口的"安装"引导页。
enum Setup {
    static var appPath: String { Bundle.main.bundlePath }

    static func run(_ app: AppDelegate) {
        guard !CLI.isolated else { return }
        CLI.runAsync(["doctor", "--json", "--app-path", appPath], timeout: 30) { r in
            guard let d = r.out.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                app.openWindow(route: "setup")
                return
            }
            if (o["app_location_ok"] as? Bool) == false || (o["ok"] as? Bool) != true {
                app.openWindow(route: "setup")
                return
            }
            let ready = (o["cli_current"] as? Bool) == true && (o["daemon_installed"] as? Bool) == true
                && (o["app_registered"] as? Bool) == true
            if ready {
                // 关闭了开机自启时，打开应用要顺手把后台同步拉起来
                if (o["daemon_running"] as? Bool) != true {
                    CLI.runAsync(["start"], timeout: 60) { _ in StateStore.shared.reloadRules(force: true) }
                }
                return
            }
            let firstTime = (o["config_exists"] as? Bool) != true
            install { r2 in
                if r2.code != 0 { app.openWindow(route: "setup"); return }
                StateStore.shared.reloadRules(force: true)
                if firstTime { app.openWindow(route: "new") }
            }
        }
    }

    static func install(_ done: @escaping (CLI.Result) -> Void) {
        CLI.runAsync(["install", "--app-path", appPath], timeout: 120) { r in done(r) }
    }

    /// 同一时间只保留一个 FolderSync：新打开的（例如刚从 DMG 装到"应用程序"的新版本）接管
    static func takeOverOtherInstances() {
        guard !CLI.isolated, let bid = Bundle.main.bundleIdentifier else { return }
        if appPath.hasPrefix("/Volumes/") || appPath.contains("/AppTranslocation/") { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bid) where other.processIdentifier != me {
            other.terminate()
        }
    }
}
