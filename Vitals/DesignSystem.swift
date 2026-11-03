import AppKit
import SwiftUI

/// One spacing system for every page. Values match the approved mock:
/// a 26pt panel with a 10pt edge, so 16pt sections sit concentric inside it.
enum Metrics {
    static let width: CGFloat = 340
    static let pad: CGFloat = 10          // panel edge
    static let gap: CGFloat = 8           // between sections
    static let radius: CGFloat = 16       // section corners
    static let row: CGFloat = 30          // single-line row
    static let tallRow: CGFloat = 44      // two-line row
    static let inset: CGFloat = 12        // row content inset inside a section
    static let chartWidth: CGFloat = width - 2 * pad - 2 * inset
    /// Tallest the panel gets before its content scrolls.
    static var maxHeight: CGFloat { min(780, (NSScreen.main?.visibleFrame.height ?? 800) - 40) }
}

/// A rounded group of rows, like a Control Center module.
struct Card<Content: View>: View {
    var padded = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, padded ? 10 : 4)
            .padding(.horizontal, padded ? Metrics.inset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// A caption above a section, with optional trailing text.
struct Captioned<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 8)
                if let trailing { Text(trailing) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(height: 14)
            .padding(.horizontal, Metrics.inset)
            content
        }
    }
}

/// White SF Symbol on a tinted rounded square, like System Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An app's own icon, or a neutral square for processes without one.
struct ProcessIcon: View {
    let pid: Int32
    let name: String

    var body: some View {
        Group {
            if let icon = AppIcons.icon(pid: pid, name: name) {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(.quaternary)
                    .overlay(Image(systemName: "gearshape.fill").font(.system(size: 9)).foregroundStyle(.secondary))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]
    static func icon(pid: Int32, name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var app = NSRunningApplication(processIdentifier: pid)
        if app?.bundleURL == nil {
            // Helpers ("Claude Helper (Renderer)") borrow their app's icon.
            app = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && name.hasPrefix(($0.localizedName ?? "\u{0}") + " ") }
                .max { ($0.localizedName?.count ?? 0) < ($1.localizedName?.count ?? 0) }
        }
        let icon = app?.bundleURL != nil ? app?.icon : nil
        cache[name] = icon
        return icon
    }
}

/// Row that opens another page.
struct NavRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var value: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, tint: tint)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, Metrics.inset)
            .padding(.trailing, 10)
            .frame(height: Metrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(value.isEmpty ? title : "\(title), \(value)")
    }
}

/// Subtle press highlight for full-width rows.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
    }
}

/// Label on the left, any control on the right.
struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.inset)
        .frame(minHeight: subtitle == nil ? Metrics.row : Metrics.tallRow)
    }
}

/// A label and a value, both on one 30pt line.
struct ValueRow: View {
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        Row(title: title) {
            Text(value).font(.system(size: 12)).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct PickerRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Row(title: title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// Page title row with a back button and an optional trailing view.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .help("Back")
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, back: back) { EmptyView() }
    }
}

/// The large number at the right of a module page's header.
struct BigValue: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 20, weight: .semibold)).monospacedDigit().padding(.trailing, 2)
    }
}

/// Scrolls only when the page is taller than the screen allows; otherwise sizes to fit.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 400

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Metrics.gap) { content }
                .padding(Metrics.pad)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, Metrics.maxHeight))
        .onPreferenceChange(HeightKey.self) { h in height = h }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A row of equal-width capsule buttons.
struct ButtonBar: View {
    let buttons: [(String, Bool, () -> Void)]   // title, destructive, action

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(buttons.indices, id: \.self) { i in
                Button(role: buttons[i].1 ? .destructive : nil, action: buttons[i].2) {
                    Text(buttons[i].0).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

/// Monospaced dark block for commands.
struct CodeBlock: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Color(white: 0.9))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 10)
            .background(Color(white: 0.11), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

// MARK: - Charts and meters

/// Ring gauge with the value in the middle, for the main page.
struct RingGauge: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle().trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.percent(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 52, height: 52)
            Text(label).font(.system(size: 11)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Format.percent(value))")
    }
}

/// A filled area chart. `max` scales the values; nil uses the series' own peak.
struct AreaChart: View {
    struct Layer {
        let values: [Double]
        let tint: Color
        var fill = true
    }

    let layers: [Layer]
    var max: Double? = 1
    var mirrored = false        // first layer above the midline, second below
    var gridLines = 3

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let peak = Swift.max(0.0001, max ?? layers.flatMap(\.values).max() ?? 1)
            ZStack {
                Path { p in
                    if mirrored {
                        p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                    } else if gridLines > 0 {
                        for i in 1...gridLines {
                            let y = h * CGFloat(i) / CGFloat(gridLines + 1)
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                }
                .stroke(.quaternary, lineWidth: 0.5)
                ForEach(layers.indices, id: \.self) { i in
                    let layer = layers[i]
                    let down = mirrored && i == 1
                    let base = mirrored ? h / 2 : h
                    let span = mirrored ? h / 2 - 1 : h - 1
                    let line = path(layer.values, w: w, base: base, span: span, peak: peak, down: down, closed: false)
                    if layer.fill {
                        path(layer.values, w: w, base: base, span: span, peak: peak, down: down, closed: true)
                            .fill(layer.tint.opacity(0.24))
                    }
                    line.stroke(layer.tint, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func path(_ values: [Double], w: CGFloat, base: CGFloat, span: CGFloat, peak: Double, down: Bool, closed: Bool) -> Path {
        Path { p in
            guard values.count > 1 else { return }
            let step = w / CGFloat(values.count - 1)
            for (i, v) in values.enumerated() {
                let offset = CGFloat(Swift.min(1, Swift.max(0, v / peak))) * span
                let pt = CGPoint(x: CGFloat(i) * step, y: down ? base + offset : base - offset)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            if closed {
                p.addLine(to: CGPoint(x: w, y: base))
                p.addLine(to: CGPoint(x: 0, y: base))
                p.closeSubpath()
            }
        }
    }
}

struct LegendDot: View {
    let title: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 8, height: 8)
            Text(title)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// Caption and big number, for the three-up stat rows under charts.
struct Stat: View {
    let title: String
    let value: String
    var tint: Color? = nil
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: tint == nil ? .regular : .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text(value).font(.system(size: size, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Thin horizontal meter.
struct Meter: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: Swift.max(height, g.size.width * Swift.min(1, Swift.max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Green under 60%, orange to 85%, red above: the colors the menu bar uses too.
func loadColor(_ v: Double) -> Color {
    v >= 0.85 ? .red : v >= 0.6 ? .orange : .green
}

func temperatureColor(_ c: Double) -> Color {
    c >= 80 ? .red : c >= 60 ? .orange : .green
}
