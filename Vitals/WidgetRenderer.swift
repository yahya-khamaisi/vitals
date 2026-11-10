import AppKit

/// Draws the 13 menu-bar widget styles into images for the status items.
/// Text uses the menu bar's label color; charts follow the widget's color setting.
@MainActor
enum WidgetRenderer {
    static let height: CGFloat = 22

    /// The whole image for one status item: one or more module widgets side by side.
    static func image(for modules: [Module], monitor: Monitor, overrides: [Module: WidgetConfig] = [:]) -> NSImage {
        let parts = modules.map { piece(for: $0, monitor: monitor, config: overrides[$0]) }.filter { $0.width > 0 }
        guard !parts.isEmpty else { return fallback }
        let spacing: CGFloat = 8
        let width = parts.map(\.width).reduce(0, +) + spacing * CGFloat(parts.count - 1)
        let monochrome = modules.allSatisfy { (overrides[$0] ?? monitor.config.widget($0)).color == .monochrome }
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(NSRect(x: x, y: 0, width: part.width, height: height))
                x += part.width + spacing
            }
            return true
        }
        image.isTemplate = monochrome
        image.accessibilityDescription = modules.map { describe($0, monitor: monitor) }.joined(separator: ", ")
        return image
    }

    static var fallback: NSImage {
        let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Vitals") ?? NSImage()
        image.isTemplate = true
        return image
    }

    struct Piece {
        let width: CGFloat
        let draw: (NSRect) -> Void
    }

    // MARK: Pieces

    private static func piece(for module: Module, monitor: Monitor, config: WidgetConfig?) -> Piece {
        let w = config ?? monitor.config.widget(module)
        let value = monitor.fraction(module)
        // Memory follows the system's pressure level, like Activity Monitor; a full RAM isn't a problem on its own.
        let tint = module == .memory && w.color == .byValue ? pressureColor(monitor.memory.pressureLevel) : color(w.color, value)
        let tag = w.showLabel ? module.tag : nil

        switch (module, w.style) {
        case (.network, .speed), (.disk, .speed):
            let (top, bottom) = module == .network
                ? (monitor.network.up, monitor.network.down)
                : (monitor.disk.writeRate, monitor.disk.readRate)
            let arrows = module == .network ? ("↑", "↓") : ("W", "R")
            return twoLines("\(Format.rate(top)) \(arrows.0)", "\(Format.rate(bottom)) \(arrows.1)", align: .right,
                            colors: w.color == .monochrome ? (nil, nil) : (.systemOrange, .systemBlue))
        case (.network, .networkChart):
            return chart(width: 34, tag: tag) { r in
                mirrored(monitor.series(.netDown), monitor.series(.netUp), in: r,
                         colors: w.color == .monochrome ? (.labelColor, .secondaryLabelColor) : (.systemBlue, .systemOrange))
            }
        case (.network, _):
            return text(w.style == .label ? "↓\(Format.shortRate(monitor.network.down)) ↑\(Format.shortRate(monitor.network.up))"
                                          : "↓\(Format.shortRate(monitor.network.down))", tag: w.style == .label ? nil : tag, tint: nil)
        case (.clock, _):
            return text(clockText(monitor), tag: nil, tint: nil)
        case (.bluetooth, .text) where w.template.isEmpty:
            return text(monitor.bluetooth.map { "\($0.name.prefix(1)) \($0.percent)%" }.joined(separator: " ").nilIfEmpty ?? "—", tag: nil, tint: nil)
        case (_, .text):
            return text(Template.expand(w.template.isEmpty ? defaultTemplate(module) : w.template, monitor: monitor), tag: nil, tint: nil)
        case (.sensors, .stack), (.bluetooth, .stack):
            return stack(module == .sensors ? sensorLines(monitor) : bluetoothLines(monitor))
        case (.bluetooth, _):
            let low = monitor.bluetooth.map(\.percent).min()
            return text(low.map { "\($0)%" } ?? "—", tag: tag, tint: nil)
        case (.sensors, _):
            return valueStyle(w.style, value: value, text: Format.temperature(monitor.hottest), tag: tag, tint: tint, module: module, monitor: monitor, color: w.color)
        case (.battery, .battery):
            return batteryPiece(monitor.battery, showPercent: w.showLabel, tint: w.color == .monochrome ? .labelColor : batteryColor(monitor.battery))
        case (.memory, .memory):
            let m = monitor.memory
            return twoLines(Format.memory(m.used), Format.memory(m.total), align: .right, colors: (nil, nil), tag: tag)
        default:
            return valueStyle(w.style, value: value, text: Format.percent(value), tag: tag, tint: tint, module: module, monitor: monitor, color: w.color)
        }
    }

    private static func valueStyle(_ style: WidgetStyle, value: Double, text valueText: String, tag: String?, tint: NSColor,
                                   module: Module, monitor: Monitor, color mode: WidgetColor) -> Piece {
        switch style {
        case .mini, .memory, .battery, .stack, .speed, .networkChart, .text:
            return mini(tag: tag ?? module.tag, value: valueText)
        case .label:
            return text(valueText, tag: tag, tint: nil)
        case .dot:
            return Piece(width: 10) { r in
                tint.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - 4, y: r.midY - 4, width: 8, height: 8)).fill()
            }
        case .pieChart:
            return chart(width: 16, tag: tag, framed: false) { r in pie(value, in: r, tint: tint) }
        case .tachometer:
            return chart(width: 22, tag: tag, framed: false) { r in tachometer(value, in: r, tint: tint) }
        case .lineChart:
            let series: Series = module == .gpu ? .gpu : module == .memory ? .pressure : .cpuTotal
            return chart(width: 34, tag: tag) { r in line(monitor.series(series), in: r, tint: tint) }
        case .barChart:
            let bars: [Double]
            switch module {
            case .cpu: bars = monitor.cpu.cores.isEmpty ? [value] : monitor.cpu.cores
            case .disk: bars = monitor.disk.volumes.map(\.usedFraction)
            default: bars = [value]
            }
            let barWidth: CGFloat = bars.count > 6 ? 3 : 5
            return chart(width: CGFloat(bars.count) * (barWidth + 1) + 3, tag: tag) { r in
                for (i, b) in bars.enumerated() {
                    let h = max(1, (r.height - 4) * CGFloat(min(1, b)))
                    (module == .memory ? tint : color(mode, b)).setFill()
                    NSBezierPath(rect: NSRect(x: r.minX + 2 + CGFloat(i) * (barWidth + 1), y: r.minY + 2, width: barWidth, height: h)).fill()
                }
            }
        }
    }

    // MARK: Primitives

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func size(_ s: String, _ f: NSFont) -> CGSize { (s as NSString).size(withAttributes: [.font: f]) }

    private static func draw(_ s: String, _ f: NSFont, color: NSColor = .labelColor, at p: CGPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }

    private static func text(_ value: String, tag: String?, tint: NSColor?) -> Piece {
        let valueFont = font(12.5)
        let tagFont = font(9, .semibold)
        let tagWidth = tag.map { size($0, tagFont).width + 3 } ?? 0
        let width = ceil(tagWidth + size(value, valueFont).width)
        return Piece(width: width) { r in
            if let tag {
                draw(tag, tagFont, color: .secondaryLabelColor, at: CGPoint(x: r.minX, y: r.midY - size(tag, tagFont).height / 2))
            }
            draw(value, valueFont, color: tint ?? .labelColor, at: CGPoint(x: r.minX + tagWidth, y: r.midY - size(value, valueFont).height / 2))
        }
    }

    private static func mini(tag: String, value: String) -> Piece {
        let tagFont = font(7.5, .bold)
        let valueFont = font(11, .semibold)
        let width = ceil(max(size(tag, tagFont).width, size(value, valueFont).width))
        return Piece(width: width) { r in
            draw(tag, tagFont, color: .secondaryLabelColor, at: CGPoint(x: r.minX, y: r.minY + 12))
            draw(value, valueFont, at: CGPoint(x: r.minX, y: r.minY - 1))
        }
    }

    private static func twoLines(_ top: String, _ bottom: String, align: NSTextAlignment, colors: (NSColor?, NSColor?), tag: String? = nil) -> Piece {
        let f = font(9, .semibold)
        let tagFont = font(9, .semibold)
        let tagWidth = tag.map { size($0, tagFont).width + 4 } ?? 0
        let w = max(size(top, f).width, size(bottom, f).width)
        return Piece(width: ceil(tagWidth + w)) { r in
            if let tag { draw(tag, tagFont, color: .secondaryLabelColor, at: CGPoint(x: r.minX, y: r.midY - 6)) }
            let x0 = r.minX + tagWidth
            let tx = align == .right ? x0 + w - size(top, f).width : x0
            let bx = align == .right ? x0 + w - size(bottom, f).width : x0
            draw(top, f, color: colors.0 ?? .labelColor, at: CGPoint(x: tx, y: r.minY + 10))
            draw(bottom, f, color: colors.1 ?? .labelColor, at: CGPoint(x: bx, y: r.minY))
        }
    }

    private static func stack(_ lines: [String]) -> Piece {
        guard !lines.isEmpty else { return text("—", tag: nil, tint: nil) }
        let f = font(9, .semibold)
        let columns = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
        let widths = columns.map { col in col.map { size($0, f).width }.max() ?? 0 }
        let total = widths.reduce(0, +) + CGFloat(columns.count - 1) * 6
        return Piece(width: ceil(total)) { r in
            var x = r.minX
            for (i, col) in columns.enumerated() {
                draw(col[0], f, at: CGPoint(x: x, y: col.count > 1 ? r.minY + 10 : r.midY - 6))
                if col.count > 1 { draw(col[1], f, at: CGPoint(x: x, y: r.minY)) }
                x += widths[i] + 6
            }
        }
    }

    /// A small chart, optionally framed, with the tag drawn to its left.
    private static func chart(width: CGFloat, tag: String?, framed: Bool = true, body: @escaping (NSRect) -> Void) -> Piece {
        let tagFont = font(7.5, .bold)
        let tagWidth = tag.map { size($0, tagFont).width + 3 } ?? 0
        return Piece(width: ceil(tagWidth + width)) { r in
            if let tag {
                draw(tag, tagFont, color: .secondaryLabelColor, at: CGPoint(x: r.minX, y: r.midY - size(tag, tagFont).height / 2))
            }
            let box = NSRect(x: r.minX + tagWidth, y: r.midY - 8, width: width, height: 16)
            if framed {
                let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                NSColor.labelColor.withAlphaComponent(0.35).setStroke()
                frame.lineWidth = 1
                frame.stroke()
                NSGraphicsContext.saveGraphicsState()
                frame.addClip()
                body(box)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                body(box)
            }
        }
    }

    private static func line(_ values: [Double], in r: NSRect, tint: NSColor) {
        let points = Array(values.suffix(Int(r.width / 1.5)))
        guard points.count > 1 else { return }
        let step = r.width / CGFloat(points.count - 1)
        let path = NSBezierPath()
        for (i, v) in points.enumerated() {
            let p = NSPoint(x: r.minX + CGFloat(i) * step, y: r.minY + 1.5 + (r.height - 3) * CGFloat(min(1, max(0, v))))
            i == 0 ? path.move(to: p) : path.line(to: p)
        }
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: r.maxX, y: r.minY))
        fill.line(to: NSPoint(x: r.minX, y: r.minY))
        fill.close()
        tint.withAlphaComponent(0.3).setFill()
        fill.fill()
        tint.setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }

    private static func mirrored(_ down: [Double], _ up: [Double], in r: NSRect, colors: (NSColor, NSColor)) {
        let n = Int(r.width / 1.5)
        let d = Array(down.suffix(n)), u = Array(up.suffix(n))
        let peak = max(1, (d + u).max() ?? 1)
        let mid = r.midY
        for (values, color, sign) in [(d, colors.0, 1.0), (u, colors.1, -1.0)] {
            guard values.count > 1 else { continue }
            let step = r.width / CGFloat(values.count - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX, y: mid))
            for (i, v) in values.enumerated() {
                path.line(to: NSPoint(x: r.minX + CGFloat(i) * step, y: mid + CGFloat(sign) * (r.height / 2 - 1) * CGFloat(v / peak)))
            }
            path.line(to: NSPoint(x: r.maxX, y: mid))
            path.close()
            color.setFill()
            path.fill()
        }
    }

    private static func pie(_ v: Double, in r: NSRect, tint: NSColor) {
        let c = NSPoint(x: r.midX, y: r.midY), radius: CGFloat = 7
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
        let wedge = NSBezierPath()
        wedge.move(to: c)
        wedge.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, max(0, v))), clockwise: true)
        wedge.close()
        tint.setFill()
        wedge.fill()
    }

    private static func tachometer(_ v: Double, in r: NSRect, tint: NSColor) {
        let c = NSPoint(x: r.midX, y: r.minY + 3), radius: CGFloat = 9
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
        track.lineWidth = 2.5
        track.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let filled = NSBezierPath()
        let end = 180 - 180 * CGFloat(min(1, max(0, v)))
        filled.appendArc(withCenter: c, radius: radius, startAngle: 180, endAngle: end, clockwise: true)
        filled.lineWidth = 2.5
        filled.lineCapStyle = .round
        tint.setStroke()
        filled.stroke()
        let angle = end * .pi / 180
        let needle = NSBezierPath()
        needle.move(to: c)
        needle.line(to: NSPoint(x: c.x + cos(angle) * (radius - 3), y: c.y + sin(angle) * (radius - 3)))
        needle.lineWidth = 1.5
        needle.lineCapStyle = .round
        NSColor.labelColor.setStroke()
        needle.stroke()
    }

    private static func batteryPiece(_ b: BatteryStats, showPercent: Bool, tint: NSColor) -> Piece {
        let label = Format.percent(b.percent)
        let f = font(11)
        let textWidth = showPercent ? size(label, f).width + 4 : 0
        return Piece(width: ceil(textWidth + 26)) { r in
            if showPercent { draw(label, f, at: CGPoint(x: r.minX, y: r.midY - size(label, f).height / 2)) }
            let body = NSRect(x: r.minX + textWidth, y: r.midY - 6, width: 22, height: 12)
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let cap = NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75)
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            cap.fill()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.minX + 2, y: body.minY + 2, width: max(1.5, (body.width - 4) * CGFloat(b.percent)), height: body.height - 4),
                         xRadius: 1.5, yRadius: 1.5).fill()
            if b.charging || b.pluggedIn, let bolt = NSImage(systemSymbolName: b.charging ? "bolt.fill" : "powerplug.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                let symbol = bolt.withSymbolConfiguration(config) ?? bolt
                let s = symbol.size
                symbol.draw(in: NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }

    // MARK: Values

    private static func pressureColor(_ level: Int) -> NSColor {
        level >= 4 ? .systemRed : level >= 2 ? .systemOrange : .systemGreen
    }

    private static func color(_ mode: WidgetColor, _ v: Double) -> NSColor {
        switch mode {
        case .byValue: v >= 0.85 ? .systemRed : v >= 0.6 ? .systemOrange : .systemGreen
        case .accent: .controlAccentColor
        case .monochrome: .labelColor
        }
    }

    private static func batteryColor(_ b: BatteryStats) -> NSColor {
        b.charging || b.pluggedIn ? .systemGreen : b.percent <= 0.2 ? .systemRed : .labelColor
    }

    private static func sensorLines(_ monitor: Monitor) -> [String] {
        var lines = monitor.config.starredSensors.compactMap { name in
            monitor.sensors.first { $0.name == name && $0.kind == .temperature }.map { Format.temperature($0.value) }
        }
        lines += monitor.fans.map { "\(Int($0.rpm)) rpm" }
        return lines
    }

    private static func bluetoothLines(_ monitor: Monitor) -> [String] {
        monitor.bluetooth.map { "\($0.name.prefix(1)) \($0.percent)%" }
    }

    private static func defaultTemplate(_ m: Module) -> String {
        switch m {
        case .cpu: "$cpu"
        case .gpu: "$gpu"
        case .memory: "$mem"
        case .disk: "$disk"
        case .battery: "$bat"
        case .sensors: "$temp"
        case .network: "↓$down ↑$up"
        case .clock: "$time"
        case .bluetooth: ""
        }
    }

    static func clockText(_ monitor: Monitor) -> String {
        let f = DateFormatter()
        f.dateFormat = monitor.config.clockFormat
        return f.string(from: Date())
    }

    private static func describe(_ m: Module, monitor: Monitor) -> String {
        switch m {
        case .network: "Network down \(Format.rate(monitor.network.down)), up \(Format.rate(monitor.network.up))"
        case .sensors: "Temperature \(Format.temperature(monitor.hottest, unit: true))"
        case .clock: clockText(monitor)
        case .bluetooth: "Bluetooth devices"
        default: "\(m.title) \(Format.percent(monitor.fraction(m)))"
        }
    }
}

extension WidgetRenderer {
    /// Writes every module × style to PNGs in light and dark, for checking the drawing.
    static func renderAll(to directory: String, monitor: Monitor) -> String {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var count = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for m in Module.allCases {
                for style in m.styles {
                    var w = monitor.config.widget(m)
                    w.style = style
                    let image = WidgetRenderer.image(for: [m], monitor: monitor, overrides: [m: w])
                    let scale: CGFloat = 2
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale) + 16,
                                                     pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    rep.size = NSSize(width: image.size.width + 8, height: image.size.height)
                    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        (appearance == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
                        NSRect(origin: .zero, size: rep.size).fill()
                        image.draw(in: NSRect(x: 4, y: 0, width: image.size.width, height: image.size.height))
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let name = "\(appearance == .aqua ? "light" : "dark")-\(m.rawValue)-\(style.rawValue).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name))
                    count += 1
                }
            }
        }
        let windows = NSApp.windows.filter { $0.className.contains("StatusBar") }.map { "\($0.windowNumber) \($0.className) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) onscreen=\($0.occlusionState.contains(.visible)) subviews=\($0.contentView?.subviews.count ?? 0)" }
        let inserted = MenuBarState.shared.inserted.filter(\.value).keys.sorted().joined(separator: ",")
        return "rendered \(count)\ninserted: \(inserted)\n" + windows.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `$cpu · $temp` style templates for the Text widget.
@MainActor
enum Template {
    static let tokens = ["$cpu", "$gpu", "$mem", "$disk", "$down", "$up", "$bat", "$temp", "$fan", "$time"]

    static func expand(_ template: String, monitor: Monitor) -> String {
        var s = template
        let values: [String: String] = [
            "$cpu": Format.percent(monitor.cpu.total),
            "$gpu": Format.percent(monitor.gpu.utilization),
            "$mem": Format.percent(monitor.memory.usedFraction),
            "$disk": Format.percent(monitor.disk.mainUsedFraction),
            "$down": Format.shortRate(monitor.network.down),
            "$up": Format.shortRate(monitor.network.up),
            "$bat": Format.percent(monitor.battery.percent),
            "$temp": Format.temperature(monitor.hottest),
            "$fan": monitor.fans.first.map { "\(Int($0.rpm))" } ?? "—",
            "$time": WidgetRenderer.clockText(monitor)
        ]
        for token in tokens { s = s.replacingOccurrences(of: token, with: values[token] ?? "") }
        return s
    }
}
