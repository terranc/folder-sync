import AppKit
import SwiftUI

// ============================== 浮动状态条 ==============================
// 屏幕角落的半透明黑底白字条；不抢焦点、不挡操作；悬停出现停止 / 跳过 / 重试 / 关闭。

struct OverlayRow: Identifiable, Equatable {
    enum Kind { case running, done, cancelled, failed }
    let id: String          // 规则名
    let kind: Kind
    let title: String
    let detail: String
    let file: String
    let percent: Double?    // 0...1；nil = 不显示进度条
    let canSkip: Bool
}

final class OverlayModel: ObservableObject {
    @Published var rows: [OverlayRow] = []
    /// 点击状态条（非按钮区域）时打开大窗口的某个页面
    var open: (String) -> Void = { _ in }
    /// 拖动整个状态条；Bool 表示本次拖动是否已结束
    var drag: (Bool) -> Void = { _ in }
}

struct OverlayRowView: View {
    let row: OverlayRow
    let open: (String) -> Void
    @State private var hover = false

    var icon: String {
        switch row.kind {
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch row.kind {
        case .failed: return Color(red: 1, green: 0.42, blue: 0.4)
        case .done: return Color(red: 0.45, green: 0.9, blue: 0.55)
        default: return .white
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(tint).font(.system(size: 12, weight: .semibold))
                Text(row.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(row.detail).font(.system(size: 12)).foregroundColor(.white.opacity(0.85)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                buttons
                    .opacity(hover ? 1 : 0)
                    .allowsHitTesting(hover)
            }
            .frame(height: 22)
            if let p = row.percent {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: max(2, g.size.width * CGFloat(min(1, max(0, p)))))
                    }
                }.frame(height: 3)
            }
            if !row.file.isEmpty {
                Text(row.file).font(.system(size: 11)).foregroundColor(.white.opacity(0.7)).lineLimit(1).truncationMode(.middle)
                    .opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(hover ? 1 : (row.kind == .failed ? 0.82 : 0.35))))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(row.kind == .failed ? tint.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // 失败条：点击空白处打开日志；其他状态打开该项目
        .onTapGesture { open(row.kind == .failed ? "history" : "project:" + row.id) }
    }

    @ViewBuilder var buttons: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .running:
                if row.canSkip { pill("跳过") { CLI.spawn(["skip", row.id]) } }
                pill("停止") { CLI.spawn(["cancel", row.id]) }
            case .failed:
                pill("重试") {
                    CLI.runAsync(["ack", row.id]) { _ in CLI.spawn(["sync", row.id, "--bg"]) }
                }
                pill("关闭") { CLI.spawn(["ack", row.id]) }
            default:
                EmptyView()
            }
        }
    }

    func pill(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.22)))
        }.buttonStyle(.plain)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(model.rows) { OverlayRowView(row: $0, open: model.open) }
        }
        .frame(width: 400)
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in model.drag(false) }
                .onEnded { _ in model.drag(true) }
        )
    }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController: NSObject, NSWindowDelegate {
    let model = OverlayModel()
    private var panel: OverlayPanel!
    private var host: FirstMouseHostingView<OverlayView>!
    private var shownRuns = Set<String>()
    private var finishSeen: [String: TimeInterval] = [:]
    private var programmaticMove = false
    /// 拖动位置仅在本次显示期间有效，浮层消失后恢复设置中的角落
    private var temporaryOrigin: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint?
    /// 设置里切换"位置"时的 2 秒预览：额外的样例行 + 强制角落
    private var previewRow: OverlayRow?
    private var cornerOverride: String?
    private var previewTimer: Timer?
    var isPreviewing: Bool { previewRow != nil }
    override init() {
        super.init()
        host = FirstMouseHostingView(rootView: OverlayView(model: model))
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 408, height: 60),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = host
        panel.delegate = self
        model.drag = { [weak self] ended in
            self?.movePanel(ended: ended)
        }
    }

    private func fmtSpeed(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB/s", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB/s", b / 1024) }
        return "0 KB/s"
    }

    func update(_ store: StateStore) {
        let now = Date().timeIntervalSince1970
        var rows: [OverlayRow] = []
        for s in store.snapshots {
            if let r = s.run {
                let runId = r["run_id"] as? String ?? ""
                let started = r["started_at"] as? Double ?? now
                let trigger = r["trigger"] as? String ?? "change"
                let manual = ["full", "push", "pull"].contains(trigger)
                guard manual || shownRuns.contains(runId) || now - started >= Settings.overlayDelay else { continue }
                shownRuns.insert(runId)
                let phase = r["phase"] as? String ?? ""
                let files = r["files_done"] as? Int ?? 0
                let pct = r["percent"] as? Double ?? 0
                let speed = r["speed_bps"] as? Double ?? 0
                let cur = r["current_file"] as? String ?? ""
                let curStart = r["current_started_at"] as? Double ?? 0
                let checked = r["checked"] as? Int ?? 0, total = r["check_total"] as? Int ?? 0
                let verb: String = ["full": "全量同步", "push": "上传", "pull": "下载"][trigger] ?? "推送"
                var detail: String
                switch phase {
                case "connecting": detail = "\(verb) · 连接中…"
                case "scanning": detail = "\(verb) · 比对中 \(checked)/\(total > 0 ? String(total) : "?")"
                default: detail = "\(verb) \(Int(pct))% · \(files) 个 · \(fmtSpeed(speed))"
                }
                let canSkip = phase == "transferring" && !cur.isEmpty && curStart > 0 && now - curStart >= Settings.skipAfter
                let fileLine = cur.isEmpty ? "" : "当前：\(cur)" + (curStart > 0 && now - curStart >= 2 ? "（\(Int(now - curStart)) 秒）" : "")
                rows.append(OverlayRow(id: s.name, kind: .running, title: s.name, detail: detail, file: fileLine,
                                       percent: phase == "transferring" ? pct / 100 : nil, canSkip: canSkip))
            } else if let l = s.last {
                let runId = l["run_id"] as? String ?? ""
                let result = l["result"] as? String ?? ""
                if s.failedUnacked {
                    let err = l["error"] as? String ?? "同步失败"
                    rows.append(OverlayRow(id: s.name, kind: .failed, title: s.name, detail: "同步失败 · \(err)",
                                           file: "", percent: nil, canSkip: false))
                } else if shownRuns.contains(runId) {
                    let seen = finishSeen[runId] ?? now
                    finishSeen[runId] = seen
                    if now - seen < 2 {
                        let files = l["files"] as? Int ?? 0
                        if result == "cancelled" {
                            rows.append(OverlayRow(id: s.name, kind: .cancelled, title: s.name, detail: "已停止", file: "", percent: nil, canSkip: false))
                        } else if result == "ok" {
                            let del = l["deleted"] as? Int ?? 0
                            var d = files > 0 ? "已同步 \(files) 个文件" : "已同步，无变化"
                            if del > 0 { d += "、删除 \(del) 个" }
                            rows.append(OverlayRow(id: s.name, kind: .done, title: s.name, detail: d, file: "", percent: nil, canSkip: false))
                        }
                    } else {
                        shownRuns.remove(runId); finishSeen.removeValue(forKey: runId)
                    }
                }
            }
        }
        rows = Array(rows.prefix(3))
        if let p = previewRow { rows.append(p) }
        if rows != model.rows { model.rows = rows }
        if rows.isEmpty || (!Settings.overlayEnabled && previewRow == nil) {
            temporaryOrigin = nil
            dragStartOrigin = nil
            dragStartMouse = nil
            if panel.isVisible { panel.orderOut(nil) }
        } else {
            layout()
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// 设置里切换"位置"时，立刻在目标角落显示 2 秒状态条预览
    func preview(corner: String) {
        previewTimer?.invalidate()
        cornerOverride = corner == "bottomLeft" ? "bottomLeft" : "bottomRight"
        temporaryOrigin = nil
        dragStartOrigin = nil
        dragStartMouse = nil
        previewRow = OverlayRow(id: "preview", kind: .running, title: "FolderSync",
                                detail: "状态条会显示在这里 · 同步 58%", file: "",
                                percent: 0.58, canSkip: false)
        update(StateStore.shared)
        previewTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.previewRow = nil
            self.cornerOverride = nil
            self.previewTimer = nil
            self.update(StateStore.shared)
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }

    private func movePanel(ended: Bool) {
        guard cornerOverride == nil else { return }   // 预览期间不改位置
        if ended {
            dragStartOrigin = nil
            dragStartMouse = nil
            temporaryOrigin = panel.frame.origin
            return
        }
        // 使用屏幕坐标计算位移，避免浮层移动后改变 SwiftUI 的局部坐标参照
        let mouse = NSEvent.mouseLocation
        let startMouse = dragStartMouse ?? mouse
        let startOrigin = dragStartOrigin ?? panel.frame.origin
        dragStartMouse = startMouse
        dragStartOrigin = startOrigin
        let origin = NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                             y: startOrigin.y + mouse.y - startMouse.y)
        temporaryOrigin = origin
        panel.setFrameOrigin(origin)
    }

    private func layout() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        let right = (cornerOverride ?? Settings.overlayCorner) != "bottomLeft"
        var x: CGFloat, y: CGFloat
        if let origin = temporaryOrigin, cornerOverride == nil {
            x = origin.x; y = origin.y
        } else {
            x = right ? vf.maxX - size.width - 12 : vf.minX + 12; y = vf.minY + 12
        }
        programmaticMove = true
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        programmaticMove = false
    }

    func snapshot(to path: String) {
        guard let v = panel.contentView, panel.isVisible else { return }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        temporaryOrigin = panel.frame.origin
    }
}
