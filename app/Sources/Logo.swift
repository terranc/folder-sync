import AppKit

/// 统一的上下箭头图形（与网页里的 logo 同一套路径，24×24 坐标系）
enum Logo {
    /// 在给定矩形里描出箭头路径
    static func strokeArrows(in rect: NSRect, lineWidth: CGFloat, color: NSColor) {
        let s = min(rect.width, rect.height) / 24.0
        let ox = rect.minX + (rect.width - 24 * s) / 2, oy = rect.minY + (rect.height - 24 * s) / 2
        // SVG 的 y 轴向下，这里翻转
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + (24 - y) * s) }
        let path = NSBezierPath()
        path.move(to: p(7, 20)); path.line(to: p(7, 4))
        path.move(to: p(3, 8)); path.line(to: p(7, 4)); path.line(to: p(11, 8))
        path.move(to: p(17, 4)); path.line(to: p(17, 20))
        path.move(to: p(13, 16)); path.line(to: p(17, 20)); path.line(to: p(21, 16))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 菜单栏用图标（模板图，跟随深浅色）；color 非空时为彩色（失败红 / 同步中蓝）
    static func menuBarImage(color: NSColor? = nil, alpha: CGFloat = 1) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            strokeArrows(in: r.insetBy(dx: 0.5, dy: 0.5), lineWidth: 1.9, color: (color ?? .black).withAlphaComponent(alpha))
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    /// 程序坞 / 应用图标：紫色圆角方块 + 白色箭头
    static func appIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let inset = r.width * 0.1
            let box = r.insetBy(dx: inset, dy: inset)
            let rr = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
            let g = NSGradient(starting: NSColor(red: 0.47, green: 0.47, blue: 0.93, alpha: 1),
                               ending: NSColor(red: 0.33, green: 0.33, blue: 0.80, alpha: 1))
            g?.draw(in: rr, angle: -90)
            strokeArrows(in: box.insetBy(dx: box.width * 0.2, dy: box.width * 0.2), lineWidth: box.width * 0.075, color: .white)
            return true
        }
    }
}
