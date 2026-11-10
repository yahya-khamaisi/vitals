import AppKit
import SwiftUI

/// "Menu bar ›" row at the end of every module page.
struct MenuBarRow: View {
    let module: Module
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        Card {
            NavRow(symbol: "menubar.rectangle", tint: Color(white: 0.24), title: "Menu bar", value: value) {
                nav.focus = module
                nav.push(.widgets)
            }
        }
    }

    private var value: String {
        let w = monitor.config.widget(module)
        return w.enabled ? w.style.title : "Hidden"
    }
}

/// A list of processes with one or two value columns.
struct ProcessList: View {
    let items: [ProcessUsage]
    let value: (ProcessUsage) -> String

    var body: some View {
        Card {
            if items.isEmpty {
                Text("Measuring…").foregroundStyle(.secondary).padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
            }
            ForEach(items) { p in
                HStack(spacing: 8) {
                    ProcessIcon(pid: p.pid, name: p.name)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value(p)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, Metrics.inset)
                .frame(height: Metrics.row)
                .contextMenu {
                    Button("Quit \(p.name)") { kill(p.pid, SIGTERM) }
                    Button("Force Quit \(p.name)", role: .destructive) { kill(p.pid, SIGKILL) }
                }
            }
        }
    }
}

// MARK: - CPU

struct CPUPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        let c = monitor.cpu
        PageScroll {
            PageHeader(title: "CPU", subtitle: subtitle(c), back: nav.pop) { BigValue(text: Format.percent(c.total)) }
            Card(padded: true) {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Last minute").fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        LegendDot(title: "System", tint: .pink)
                        LegendDot(title: "User", tint: .blue)
                    }
                    .font(.system(size: 11)).frame(height: 14)
                    AreaChart(layers: [.init(values: monitor.series(.cpuTotal), tint: .blue),
                                       .init(values: monitor.series(.cpuSystem), tint: .pink)])
                        .frame(height: 72)
                    HStack {
                        Stat(title: "System", value: Format.percent(c.system))
                        Stat(title: "User", value: Format.percent(c.user))
                        Stat(title: "Idle", value: Format.percent(c.idle))
                    }
                }
            }
            if !c.cores.isEmpty {
                Captioned(title: "Cores", trailing: nil) {
                    Card(padded: true) {
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(Array(c.cores.enumerated()), id: \.offset) { i, load in
                                let isP = i < c.isPerformance.count ? c.isPerformance[i] : true
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isP ? Color.blue : Color.teal)
                                        .frame(height: max(3, 44 * load))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .accessibilityLabel("\(isP ? "Performance" : "Efficiency") core \(i + 1), \(Format.percent(load))")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 10) {
                        LegendDot(title: "Performance", tint: .blue)
                        LegendDot(title: "Efficiency", tint: .teal)
                    }
                    .padding(.trailing, Metrics.inset)
                    .frame(height: 14)
                }
            }
            Card {
                if c.pFrequency != nil || c.eFrequency != nil {
                    ValueRow(title: "Frequency", value: [c.pFrequency.map { "P " + Format.frequency($0) }, c.eFrequency.map { "E " + Format.frequency($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                ValueRow(title: "Temperature", value: Format.temperature(c.temperature, unit: true))
                ValueRow(title: "Load average", value: String(format: "%.2f · %.2f · %.2f", c.load.0, c.load.1, c.load.2))
                if let w = c.watts { ValueRow(title: "Power", value: String(format: "%.1f W", w)) }
                ValueRow(title: "Uptime", value: Format.duration(c.uptime))
            }
            Captioned(title: "Top processes", trailing: "% CPU") {
                ProcessList(items: monitor.topByCPU) { String(format: "%.1f", $0.cpu) }
            }
            MenuBarRow(module: .cpu)
        }
    }

    private func subtitle(_ c: CPUStats) -> String {
        let chip = c.name.isEmpty ? "CPU" : c.name
        return c.isPerformance.isEmpty ? chip : "\(chip) · \(c.pCount) performance, \(c.eCount) efficiency"
    }
}

// MARK: - GPU

struct GPUPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        let g = monitor.gpu
        PageScroll {
            PageHeader(title: "GPU", subtitle: g.cores.map { "\(g.name) · \($0) cores" } ?? g.name, back: nav.pop) {
                BigValue(text: Format.percent(g.utilization))
            }
            Card(padded: true) {
                VStack(spacing: 8) {
                    HStack {
                        Text("Last minute").fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        LegendDot(title: "Utilization", tint: .purple)
                    }
                    .font(.system(size: 11)).frame(height: 14)
                    AreaChart(layers: [.init(values: monitor.series(.gpu), tint: .purple)]).frame(height: 72)
                    HStack {
                        Stat(title: "Device", value: Format.percent(g.utilization))
                        Stat(title: "Renderer", value: Format.percent(g.renderer))
                        Stat(title: "Tiler", value: Format.percent(g.tiler))
                    }
                }
            }
            Card {
                ValueRow(title: "Memory in use", value: Format.memory(g.memoryUsed))
                if let f = g.frequency { ValueRow(title: "Frequency", value: Format.frequency(f)) }
                ValueRow(title: "Temperature", value: Format.temperature(g.temperature, unit: true))
                if let w = g.watts { ValueRow(title: "Power", value: String(format: "%.2f W", w)) }
            }
            MenuBarRow(module: .gpu)
        }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        let m = monitor.memory
        let pressureTint: Color = m.pressureLevel >= 4 ? .red : m.pressureLevel >= 2 ? .orange : .green
        PageScroll {
            PageHeader(title: "Memory", subtitle: "\(Format.memory(m.total)) unified memory", back: nav.pop) {
                BigValue(text: Format.percent(m.usedFraction))
            }
            Card(padded: true) {
                VStack(spacing: 8) {
                    HStack {
                        Text("Memory pressure").fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        Text(m.pressureTitle).fontWeight(.semibold).foregroundStyle(pressureTint)
                    }
                    .font(.system(size: 11)).frame(height: 14)
                    AreaChart(layers: [.init(values: monitor.series(.pressure), tint: pressureTint)]).frame(height: 56)
                }
            }
            Card(padded: true) {
                let parts: [(String, UInt64, Color)] = [("App", m.app, .green), ("Wired", m.wired, .orange), ("Compressed", m.compressed, .purple)]
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(parts, id: \.0) { p in
                                Rectangle().fill(p.2).frame(width: geo.size.width * CGFloat(Double(p.1) / Double(max(1, m.total))))
                            }
                            Spacer(minLength: 0)
                        }
                        .background(.quaternary)
                        .clipShape(Capsule())
                    }
                    .frame(height: 10)
                    .accessibilityLabel("\(Format.memory(m.used)) of \(Format.memory(m.total)) used")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 8) {
                        ForEach(parts + [("Free", m.free, Color.secondary.opacity(0.4))], id: \.0) { p in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                                Text(p.0).font(.system(size: 12)).lineLimit(1).layoutPriority(1)
                                Spacer(minLength: 2)
                                Text(Format.memory(p.1)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(height: 16)
                        }
                    }
                }
            }
            Card {
                ValueRow(title: "Swap used", value: Format.memory(m.swapUsed))
                ValueRow(title: "Cached files", value: Format.memory(m.cached))
                ValueRow(title: "Page ins · outs", value: "\(compact(m.pageIns)) · \(compact(m.pageOuts))")
                ValueRow(title: "Purgeable", value: Format.memory(m.purgeable))
            }
            Captioned(title: "Top processes", trailing: "Memory") {
                ProcessList(items: monitor.topByMemory) { Format.memory($0.memory) }
            }
            MenuBarRow(module: .memory)
        }
    }

    private func compact(_ n: UInt64) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0f K", Double(n) / 1e3) : "\(n)"
    }
}

// MARK: - Disks

struct DiskPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @AppStorage("disk.totals.lifetime") private var showLifetime = false

    var body: some View {
        let d = monitor.disk
        let external = d.volumes.filter { !$0.isInternal }.count
        PageScroll {
            PageHeader(title: "Disks", subtitle: "\(d.volumes.count) volume\(d.volumes.count == 1 ? "" : "s")" + (external > 0 ? " · \(external) external" : ""),
                       back: nav.pop) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("R \(Format.rate(d.readRate))").foregroundStyle(.blue)
                    Text("W \(Format.rate(d.writeRate))").foregroundStyle(.orange)
                }
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().padding(.trailing, 2)
            }
            Card(padded: true) {
                VStack(spacing: 8) {
                    if d.lifetime != nil {
                        Picker("Totals", selection: $showLifetime) {
                            Text("Since boot").tag(false)
                            Text("Lifetime").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    let totals = showLifetime ? d.lifetime ?? (d.totalRead, d.totalWrite) : (d.totalRead, d.totalWrite)
                    HStack {
                        Stat(title: "Total read", value: Format.bytes(totals.0), tint: .blue, size: 17)
                        Stat(title: "Total written", value: Format.bytes(totals.1), tint: .orange, size: 17)
                    }
                    AreaChart(layers: [.init(values: monitor.series(.diskRead), tint: .blue),
                                       .init(values: monitor.series(.diskWrite), tint: .orange)], max: nil, mirrored: true)
                        .frame(height: 56)
                    if d.lifetime == nil {
                        HStack {
                            Text("Totals since boot")
                            Spacer()
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(height: 14)
                    }
                }
            }
            ForEach(d.volumes) { v in VolumeCard(volume: v) }
            MenuBarRow(module: .disk)
        }
    }
}

struct VolumeCard: View {
    let volume: Volume

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill", tint: volume.isInternal ? .orange : .gray)
                VStack(alignment: .leading, spacing: 0) {
                    Text(volume.name).fontWeight(.semibold).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if volume.ejectable {
                    HeaderButton(symbol: "eject.fill", label: "Eject \(volume.name)") {
                        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                    }
                }
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 30)
            VStack(spacing: 4) {
                Meter(value: volume.usedFraction, tint: volume.isInternal ? .orange : .gray, height: 8)
                HStack {
                    Text("\(Format.bytes(volume.used)) used")
                    Spacer()
                    Text("\(Format.bytes(volume.free)) free")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, Metrics.inset)
            VStack(spacing: 0) {
                Divider().padding(.leading, Metrics.inset)
                ValueRow(title: "Capacity", value: Format.bytes(volume.total))
                if let smart = volume.smart {
                    Divider().padding(.leading, Metrics.inset)
                    ValueRow(title: "SMART health", value: smart == "Not Supported" ? "Not reported" : smart,
                             tint: smart == "Verified" ? .green : smart == "Not Supported" ? nil : .red)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }

    private var subtitle: String {
        [volume.media, volume.format, volume.isInternal ? "internal" : "external"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Network

struct NetworkPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        let n = monitor.network
        PageScroll {
            PageHeader(title: "Network", subtitle: subtitle(n), back: nav.pop)
            Card(padded: true) {
                VStack(spacing: 8) {
                    HStack {
                        Stat(title: "↓ Download", value: Format.rate(n.down), tint: .blue, size: 17)
                        Stat(title: "↑ Upload", value: Format.rate(n.up), tint: .orange, size: 17)
                    }
                    AreaChart(layers: [.init(values: monitor.series(.netDown), tint: .blue),
                                       .init(values: monitor.series(.netUp), tint: .orange)], max: nil, mirrored: true)
                        .frame(height: 64)
                    HStack {
                        Text("Today ↓ \(Format.bytes(n.todayDown)) · ↑ \(Format.bytes(n.todayUp))")
                        Spacer()
                        Button("Reset") { monitor.resetNetworkToday() }.buttonStyle(.link)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(height: 14)
                }
            }
            Card {
                ValueRow(title: "Interface", value: n.interface.isEmpty ? "None" : "\(n.interface) · \(n.kind)")
                CopyRow(title: "Local IP", value: n.localIP)
                if monitor.config.lookUpPublicIP { CopyRow(title: "Public IP", value: n.publicIP ?? (n.online ? "Looking up…" : nil)) }
                if let r = n.router { ValueRow(title: "Router", value: r + (n.routerLatency.map { " · \(Int($0.rounded())) ms" } ?? "")) }
                ValueRow(title: "Internet latency", value: n.internetLatency.map { "\(Int($0.rounded())) ms" } ?? "—")
                if !n.dns.isEmpty { ValueRow(title: "DNS", value: n.dns.prefix(2).joined(separator: ", ")) }
                if let s = n.linkSpeed { ValueRow(title: "Link speed", value: "\(Int(s)) Mbps") }
            }
            Captioned(title: "Top processes", trailing: "↓ · ↑") {
                Card {
                    if monitor.netProcesses.isEmpty {
                        Text("Measuring…").foregroundStyle(.secondary).padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
                    }
                    ForEach(monitor.netProcesses.prefix(monitor.config.topProcesses)) { p in
                        HStack(spacing: 8) {
                            ProcessIcon(pid: 0, name: p.name)
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Format.rate(p.down)).frame(width: 70, alignment: .trailing)
                            Text(Format.rate(p.up)).frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit()
                        .padding(.horizontal, Metrics.inset)
                        .frame(height: Metrics.row)
                    }
                }
            }
            MenuBarRow(module: .network)
        }
        .onAppear { monitor.watchNetworkProcesses = true }
        .onDisappear { monitor.watchNetworkProcesses = false }
    }

    private func subtitle(_ n: NetworkStats) -> String {
        guard n.online else { return "Offline" }
        var parts = ["Online", n.kind]
        if let ssid = n.ssid { parts[1] = "\(n.kind) “\(ssid)”" }
        if let rssi = n.rssi { parts.append("\(rssi) dBm") }
        return parts.joined(separator: " · ")
    }
}

struct CopyRow: View {
    let title: String
    let value: String?

    var body: some View {
        Row(title: title) {
            Text(value ?? "—").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
            if let value, !value.hasSuffix("…") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy \(title)")
            }
        }
    }
}
