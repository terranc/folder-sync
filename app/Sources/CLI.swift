import AppKit
import Foundation

/// 定位 folder-sync 命令与状态目录，并以子进程方式调用 CLI。
enum CLI {
    /// 隔离测试实例：通过环境变量指定 CLI 时，应用不做任何安装 / 卸载 / 结束其他实例的动作
    static var isolated: Bool { ProcessInfo.processInfo.environment["FOLDER_SYNC_CLI"] != nil }

    static var scriptPath: String {
        if let p = ProcessInfo.processInfo.environment["FOLDER_SYNC_CLI"], !p.isEmpty { return p }
        // 优先用应用自带的脚本（与应用版本一致）；没打包进去时（开发调试）用已安装的
        if let p = Bundle.main.path(forResource: "folder-sync", ofType: nil) { return p }
        return NSHomeDirectory() + "/.local/bin/folder-sync"
    }

    static var stateDir: String {
        if let p = ProcessInfo.processInfo.environment["FOLDER_SYNC_STATE"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/.local/state/folder-sync"
    }

    static var configPath: String {
        if let p = ProcessInfo.processInfo.environment["FOLDER_SYNC_CONFIG"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/.config/folder-sync/config.conf"
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    struct Result { let code: Int32; let out: String; let err: String }

    /// 同步执行（在后台队列调用）。
    static func run(_ args: [String], timeout: TimeInterval = 120) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath] + args
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch {
            return Result(code: 127, out: "", err: "无法执行 \(scriptPath): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        group.wait()
        return Result(code: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// 后台执行，不等待（同步 / 下载等长任务；进度通过状态文件呈现）。
    static func spawn(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath] + args
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func runAsync(_ args: [String], timeout: TimeInterval = 120, done: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = run(args, timeout: timeout)
            DispatchQueue.main.async { done(r) }
        }
    }
}
