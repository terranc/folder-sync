import AppKit
import Foundation

/// 版本号展示 + 从 GitHub Releases 检查、下载并覆盖安装更新。
/// 应用为 adhoc 签名且未公证，更新包只依赖 HTTPS + GitHub Release 可信，不做包签名校验。
enum Update {
    private static let apiURL = URL(string: "https://api.github.com/repos/terranc/folder-sync/releases/latest")!
    private static let latestPage = URL(string: "https://github.com/terranc/folder-sync/releases/latest")!

    /// 当前应用版本（来自 Info.plist，发布时由 tag 覆盖）
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// idle / checking / latest / available / downloading / installing / failed
    private(set) static var state = "idle"
    private(set) static var progress: Double = 0
    private(set) static var message = ""
    private(set) static var newVersion = ""
    private static var assetURL = ""
    private static var checkedAt: TimeInterval = 0
    private static var timer: Timer?
    private static var task: URLSessionDownloadTask?
    private static var observer: NSKeyValueObservation?

    private static let checkInterval: TimeInterval = 6 * 3600
    private static let defaultsKey = "lastUpdateCheck"

    /// 安装目标：默认就是正在运行的 .app；测试时用 FOLDER_SYNC_UPDATE_TARGET 指向一次性副本，
    /// 这样验证下载 / 覆盖流程不会动到真正的「应用程序」
    private static var targetPath: String {
        ProcessInfo.processInfo.environment["FOLDER_SYNC_UPDATE_TARGET"] ?? Bundle.main.bundlePath
    }

    /// 只有装在「应用程序」里的正式版本才允许自动覆盖安装
    static var installable: Bool {
        if ProcessInfo.processInfo.environment["FOLDER_SYNC_UPDATE_TARGET"] != nil { return true }
        guard !CLI.isolated else { return false }
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") && !p.contains("/AppTranslocation/")
    }

    static func dict() -> [String: Any] {
        ["state": state, "version": newVersion, "current": version, "progress": progress,
         "message": message, "installable": installable, "checked_at": checkedAt]
    }

    // MARK: - 自动检查

    static func start() {
        cleanStaleWorkdirs()
        guard !CLI.isolated else { return }
        checkedAt = UserDefaults.standard.double(forKey: defaultsKey)
        if Date().timeIntervalSince1970 - checkedAt > checkInterval {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { check(force: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in check(force: true) }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 更新过程中被强制退出（或重启太快）时，临时目录可能残留：下次启动清掉
    private static func cleanStaleWorkdirs() {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        for name in (try? fm.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("foldersync-update-") {
            try? fm.removeItem(atPath: tmp + name)
        }
    }

    static func check(force: Bool) {
        guard state != "checking", state != "downloading", state != "installing" else { return }
        if !force, Date().timeIntervalSince1970 - checkedAt < 600 { return }
        state = "checking"
        message = ""
        tick()
        apiLatest { latest, asset in
            if let latest = latest {
                apply(latest, asset)
            } else {
                // GitHub API 有未认证的每小时上限（共享出口 IP 很容易被限流），改用 releases/latest 的重定向结果
                pageLatest { l2, a2 in apply(l2, a2) }
            }
        }
    }

    private static func apiLatest(_ done: @escaping (String?, String?) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("FolderSync/\(version)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = o["tag_name"] as? String else { done(nil, nil); return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let dmg = ((o["assets"] as? [[String: Any]]) ?? []).first { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }
            done(latest, dmg?["browser_download_url"] as? String)
        }.resume()
    }

    private static func pageLatest(_ done: @escaping (String?, String?) -> Void) {
        var req = URLRequest(url: latestPage, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            guard let url = resp?.url?.absoluteString, let r = url.range(of: "/releases/tag/") else { done(nil, nil); return }
            let tag = String(url[r.upperBound...])
            guard !tag.isEmpty, !tag.contains("/") else { done(nil, nil); return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // 发布流程固定用 FolderSync-<版本>.dmg 命名
            done(latest, "https://github.com/terranc/folder-sync/releases/download/\(tag)/FolderSync-\(latest).dmg")
        }.resume()
    }

    private static func apply(_ latest: String?, _ asset: String?) {
        DispatchQueue.main.async {
            checkedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(checkedAt, forKey: defaultsKey)
            guard let latest = latest else {
                state = "failed"
                message = "无法获取更新信息（网络不可用或 GitHub 拒绝访问）"
                tick()
                return
            }
            newVersion = latest
            assetURL = asset ?? ""
            if !assetURL.isEmpty, compare(latest, version) > 0 {
                state = "available"
            } else {
                state = "latest"
            }
            message = ""
            tick()
        }
    }

    /// 逐段比较数字：2.10.0 > 2.9.3
    private static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    // MARK: - 下载并安装

    static func install() {
        guard state == "available", let url = URL(string: assetURL) else { return }
        guard installable else {
            state = "failed"
            message = "当前不是从「应用程序」里运行的，无法自动安装更新"
            tick()
            return
        }
        state = "downloading"
        progress = 0
        message = ""
        tick()
        let t = URLSession.shared.downloadTask(with: URLRequest(url: url, timeoutInterval: 120)) { tmp, _, err in
            guard let tmp = tmp else {
                DispatchQueue.main.async { fail(err?.localizedDescription ?? "无法下载更新包") }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { replace(with: tmp) }
        }
        task = t
        observer = t.progress.observe(\.fractionCompleted) { p, _ in progress = p.fractionCompleted }
        t.resume()
    }

    /// 挂载 DMG → 备份旧应用 → 覆盖安装 → 去掉隔离标记 → 重启
    private static func replace(with downloaded: URL) {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "foldersync-update-\(UUID().uuidString)"
        let mnt = work + "/mnt"
        var mounted = false
        func cleanup() {
            if mounted {
                _ = run(["/usr/bin/hdiutil", "detach", mnt, "-quiet", "-force"])
                mounted = false
            }
            try? fm.removeItem(atPath: work)
        }
        defer { cleanup() }
        do {
            try fm.createDirectory(atPath: mnt, withIntermediateDirectories: true)
            let dmg = work + "/update.dmg"
            try fm.moveItem(at: downloaded, to: URL(fileURLWithPath: dmg))

            let attach = run(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt, dmg])
            guard attach.code == 0 else { throw Fail("无法挂载更新包：\(tail(attach.err))") }
            mounted = true

            let names = (try? fm.contentsOfDirectory(atPath: mnt)) ?? []
            guard let appName = names.first(where: { $0.hasSuffix(".app") }) else { throw Fail("更新包里没有 FolderSync.app") }
            let src = mnt + "/" + appName
            let ver = (NSDictionary(contentsOfFile: src + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
            guard ver == newVersion else { throw Fail("更新包版本不一致（\(ver.isEmpty ? "未知" : ver)）") }

            let dest = targetPath
            guard fm.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
                throw Fail("没有权限写入「应用程序」，请手动下载安装包")
            }
            let backup = work + "/FolderSync-old.app"
            try fm.moveItem(atPath: dest, toPath: backup)
            let copy = run(["/usr/bin/ditto", src, dest])
            let copied = (NSDictionary(contentsOfFile: dest + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
            guard copy.code == 0, copied == newVersion else {
                // 回滚：删掉可能写了一半的新版本，再把旧版本放回去
                try? fm.removeItem(atPath: dest)
                try? fm.moveItem(atPath: backup, toPath: dest)
                throw Fail("覆盖安装失败：\(copy.code == 0 ? "版本校验不通过" : tail(copy.err))")
            }
            _ = run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", dest])
            cleanup()   // 先卸载 DMG、清掉临时目录，再交给主线程去重启
            DispatchQueue.main.async {
                state = "installing"
                message = ""
                tick()
                guard dest == Bundle.main.bundlePath else { return }   // 测试覆盖了别的副本：不需要重启
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { relaunch(dest) }
            }
        } catch {
            DispatchQueue.main.async { fail((error as? Fail)?.text ?? error.localizedDescription) }
        }
    }

    private static func relaunch(_ path: String) {
        // 先退出当前实例，再由独立进程打开新版，避免"重新启动自己"被 LaunchServices 合并
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \(quoted(path))"]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func fail(_ text: String) {
        state = "failed"
        message = text
        tick()
    }

    /// 让界面立刻拿到新的更新状态（状态目录轮询本身每 0.5 秒也会推一次）
    private static func tick() { DispatchQueue.main.async { StateStore.shared.tick() } }

    private struct Fail: Error { let text: String; init(_ t: String) { text = t } }

    private struct Output { let code: Int32; let out: String; let err: String }

    private static func run(_ args: [String]) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return Output(code: 127, out: "", err: error.localizedDescription) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(code: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: "；")
    }
}
