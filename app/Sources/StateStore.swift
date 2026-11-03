import AppKit
import Foundation

/// 一条规则的实时状态快照（来自 status/*.run.json 与 *.last.json）
struct RuleSnapshot {
    let name: String
    let run: [String: Any]?
    let last: [String: Any]?

    var isRunning: Bool { run != nil }
    var failedUnacked: Bool {
        guard let last = last else { return false }
        return (last["result"] as? String) == "failed" && (last["acked"] as? Bool) == false
    }
}

/// 轮询状态目录（0.5 秒）和规则配置（配置文件变化时），通知界面与浮动状态条。
final class StateStore {
    static let shared = StateStore()

    private(set) var rulesJSON: [String: Any] = [:]
    private(set) var snapshots: [RuleSnapshot] = []
    private var configStamp = ""
    private var lastRulesLoad = Date.distantPast
    private var loadingRules = false
    private var timer: Timer?
    var listeners: [(StateStore) -> Void] = []

    func start() {
        reloadRules(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func reloadRules(force: Bool = false) {
        if loadingRules { return }
        loadingRules = true
        CLI.runAsync(["rules", "--json"], timeout: 30) { [weak self] r in
            guard let self = self else { return }
            self.loadingRules = false
            self.lastRulesLoad = Date()
            if r.code == 0, let d = r.out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                self.rulesJSON = obj
            } else {
                self.rulesJSON = ["error": (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines), "rules": []]
            }
            self.tick()
        }
    }

    private func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path), !d.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    var ruleNames: [String] {
        ((rulesJSON["rules"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    var daemonRunning: Bool {
        let pidPath = CLI.stateDir + "/daemon.pid"
        guard let s = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    func tick() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: CLI.configPath)
        let stamp = "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attrs?[.size] ?? 0)"
        if stamp != configStamp {
            configStamp = stamp
            reloadRules(force: true)
        } else if Date().timeIntervalSince(lastRulesLoad) > 30 {
            reloadRules()
        }
        let dir = CLI.stateDir + "/status/"
        var names = ruleNames
        // 规则列表还没加载时，从状态目录里补出正在运行的规则
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".run.json") {
                let n = String(f.dropLast(".run.json".count))
                if !names.contains(n) { names.append(n) }
            }
        }
        snapshots = names.map { n in
            RuleSnapshot(name: n, run: readJSON(dir + n + ".run.json"), last: readJSON(dir + n + ".last.json"))
        }
        for l in listeners { l(self) }
    }

    /// 推给网页的完整状态
    func payload() -> [String: Any] {
        var obj = rulesJSON
        var rules = (rulesJSON["rules"] as? [[String: Any]]) ?? []
        for i in rules.indices {
            if let n = rules[i]["name"] as? String, let s = snapshots.first(where: { $0.name == n }) {
                rules[i]["run"] = s.run ?? NSNull()
                rules[i]["last"] = s.last ?? NSNull()
            }
        }
        obj["rules"] = rules
        obj["daemon_running"] = daemonRunning
        obj["now"] = Date().timeIntervalSince1970
        obj["settings"] = Settings.dict()
        obj["version"] = Update.version
        obj["update"] = Update.dict()
        return obj
    }
}

/// 应用自身的设置（浮动状态条）
enum Settings {
    static let d = UserDefaults.standard
    static var overlayDelay: Double {
        get { d.object(forKey: "overlayDelay") as? Double ?? 2 }
        set { d.set(newValue, forKey: "overlayDelay") }
    }
    /// 状态条上「跳过」按钮的出现阈值：程序内部固定 5 秒，不开放配置
    static let skipAfter: Double = 5
    static var overlayCorner: String {
        get { d.string(forKey: "overlayCorner") ?? "bottomRight" }
        set { d.set(newValue, forKey: "overlayCorner"); d.removeObject(forKey: "overlayAnchor") }
    }
    static var overlayEnabled: Bool {
        get { d.object(forKey: "overlayEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "overlayEnabled") }
    }
    static func dict() -> [String: Any] {
        ["overlayDelay": overlayDelay, "overlayCorner": overlayCorner, "overlayEnabled": overlayEnabled]
    }
    static func apply(_ v: [String: Any]) {
        if let x = v["overlayDelay"] as? Double { overlayDelay = max(0, x) }
        if let x = v["overlayCorner"] as? String { overlayCorner = x }
        if let x = v["overlayEnabled"] as? Bool { overlayEnabled = x }
    }
}
