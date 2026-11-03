import AppKit
import SwiftUI

// MARK: - Battery & Bluetooth

struct BatteryPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        let b = monitor.battery
        PageScroll {
            PageHeader(title: b.present ? "Battery" : "Power", subtitle: subtitle(b), back: nav.pop) {
                if b.present { BigValue(text: Format.percent(b.percent)) }
            }
            if b.present {
                Card(padded: true) {
                    VStack(spacing: 10) {
                        HStack(spacing: 3) {
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(b.charging || b.pluggedIn ? Color.green : b.percent <= 0.2 ? .red : Color(red: 0.19, green: 0.63, blue: 0.31))
                                    .frame(width: max(8, (g.size.width - 6) * b.percent))
                                    .padding(3)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.tertiary, lineWidth: 1.5))
                            .overlay {
                                if b.charging { Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).shadow(radius: 1) }
                            }
                            UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2).fill(.tertiary).frame(width: 3, height: 10)
                        }
                        .frame(height: 28)
                        .accessibilityLabel("Battery \(Format.percent(b.percent))")
                        HStack {
                            Stat(title: "Health", value: b.health.map(Format.percent) ?? "—")
                            Stat(title: "Cycles", value: b.cycles.map(String.init) ?? "—")
                            Stat(title: b.charging ? "Charging" : "Drawing", value: b.drawingWatts.map { String(format: "%.1f W", $0) } ?? "—")
                        }
                    }
                }
                Card {
                    ValueRow(title: "Condition", value: b.condition, tint: b.condition == "Normal" ? nil : .orange)
                    if let max = b.maxCapacity, let design = b.designCapacity {
                        ValueRow(title: "Capacity", value: "\(max.formatted()) of \(design.formatted()) mAh")
                    }
                    ValueRow(title: "Temperature", value: Format.temperature(b.temperature, unit: true))
                    if let v = b.voltage, let a = b.amperage {
                        ValueRow(title: "Voltage · current", value: String(format: "%.1f V · %.2f A", v, a))
                    }
                    ValueRow(title: "Power adapter", value: b.adapterWatts.map { "\(Int($0)) W" } ?? (b.pluggedIn ? "Connected" : "Not connected"))
                    ValueRow(title: "Low Power Mode", value: b.lowPowerMode ? "On" : "Off")
                }
                let heavy = monitor.processes.filter { $0.cpu >= 20 && AppIcons.icon(pid: $0.pid, name: $0.name) != nil }
                    .sorted { $0.cpu > $1.cpu }.prefix(3)
                if !heavy.isEmpty {
                    Captioned(title: "Using significant energy", trailing: nil) {
                        ProcessList(items: Array(heavy)) { $0.cpu >= 60 ? "High" : "Medium" }
                    }
                }
            }
            Captioned(title: "Bluetooth devices", trailing: nil) {
                Card {
                    if !monitor.config.isOn(.bluetooth) {
                        Row(title: "Show battery levels") {
                            Button("Turn On") { monitor.config.enabled[.bluetooth] = true }.controlSize(.small).buttonBorderShape(.capsule)
                        }
                    } else if monitor.bluetooth.isEmpty {
                        Text("No connected devices report a battery level.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
                    }
                    ForEach(monitor.bluetooth) { d in
                        HStack(spacing: 8) {
                            IconTile(symbol: d.symbol, tint: .indigo)
                            Text(d.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(d.percent)%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            BatteryGlyph(percent: Double(d.percent) / 100)
                        }
                        .padding(.horizontal, Metrics.inset)
                        .frame(height: Metrics.row)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            MenuBarRow(module: .battery)
        }
    }

    private func subtitle(_ b: BatteryStats) -> String {
        guard b.present else { return "No battery" }
        if b.charging { return "Charging" + (b.minutesRemaining.map { " · full in \(Format.minutes($0))" } ?? "") }
        if b.pluggedIn { return "On power adapter" }
        return "On battery" + (b.minutesRemaining.map { " · \(Format.minutes($0)) left" } ?? "")
    }
}

struct BatteryGlyph: View {
    let percent: Double
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(.secondary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5).fill(percent <= 0.2 ? Color.red : .green)
                    .frame(width: max(1.5, 14 * percent)).padding(1.5)
            }
            .frame(width: 19, height: 10)
            Capsule().fill(.secondary).frame(width: 1.5, height: 3.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sensors & Fans

struct SensorsPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var fans = FanHelper.shared
    @State private var kind: SensorKind = .temperature

    var body: some View {
        let count = monitor.sensors.count
        let total = monitor.sensors.first { $0.kind == .power && $0.name == "System total" }?.value
        PageScroll {
            PageHeader(title: "Sensors & Fans",
                       subtitle: "\(count) sensors · \(monitor.fans.count) fan\(monitor.fans.count == 1 ? "" : "s")" + (total.map { String(format: " · %.1f W total", $0) } ?? ""),
                       back: nav.pop)
            Picker("Sensor type", selection: $kind) {
                ForEach(SensorKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            Card {
                let list = monitor.sensors(kind)
                if list.isEmpty {
                    Text("This Mac doesn't report \(kind.title.lowercased()) sensors.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
                }
                ForEach(list) { s in SensorRow(reading: s) }
            }
            if !monitor.fans.isEmpty {
                Captioned(title: "Fans", trailing: fans.installed ? nil : "Manual control uses the helper") {
                    VStack(spacing: Metrics.gap) {
                        ForEach(monitor.fans) { fan in FanCard(fan: fan) }
                    }
                }
            }
            MenuBarRow(module: .sensors)
        }
    }
}

struct SensorRow: View {
    let reading: SensorReading
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let starred = monitor.config.starredSensors.contains(reading.name)
        HStack(spacing: 8) {
            Text(reading.name).lineLimit(1)
            Spacer(minLength: 8)
            if reading.kind == .temperature {
                Meter(value: reading.value / 100, tint: temperatureColor(reading.value)).frame(width: 64)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
            if reading.kind == .temperature {
                Button {
                    if starred { monitor.config.starredSensors.removeAll { $0 == reading.name } }
                    else { monitor.config.starredSensors.append(reading.name) }
                } label: {
                    Image(systemName: starred ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundStyle(starred ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help(starred ? "Remove from menu bar" : "Show in menu bar")
                .accessibilityLabel(starred ? "Remove \(reading.name) from menu bar" : "Show \(reading.name) in menu bar")
            }
        }
        .padding(.leading, Metrics.inset)
        .padding(.trailing, reading.kind == .temperature ? 8 : Metrics.inset)
        .frame(height: Metrics.row)
    }

    private var text: String {
        switch reading.kind {
        case .temperature: Format.temperature(reading.value)
        case .power: String(format: "%.2f W", reading.value)
        case .voltage: String(format: "%.2f V", reading.value)
        case .current: String(format: "%.2f A", reading.value)
        }
    }
}

struct FanCard: View {
    let fan: Fan
    @ObservedObject private var helper = FanHelper.shared
    @State private var target: Double = 0

    var body: some View {
        let manual = helper.manual[fan.index] != nil
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: "fan.fill", tint: .gray)
                Text(fan.name)
                Spacer(minLength: 8)
                Text("\(Int(fan.rpm).formatted()) rpm").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Picker("\(fan.name) mode", selection: Binding(get: { manual }, set: { on in
                    if on { setManual(target > 0 ? target : max(fan.min, fan.rpm)) } else { helper.setAutomatic(fan.index) }
                })) {
                    Text("Auto").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .frame(height: 22)
            HStack(spacing: 8) {
                Text(Int(fan.min).formatted()).frame(width: 36, alignment: .leading)
                Slider(value: $target, in: fan.min...max(fan.min + 1, fan.max)) { Text("\(fan.name) speed") } onEditingChanged: { editing in
                    if !editing { setManual(target) }
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(!manual)
                Text(Int(fan.max).formatted()).frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            .frame(height: 16)
            if let error = helper.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 10)
        .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .onAppear { target = helper.manual[fan.index] ?? max(fan.min, fan.rpm) }
    }

    private func setManual(_ rpm: Double) {
        target = rpm
        helper.setManual(fan.index, rpm: rpm)
    }
}

// MARK: - Clock

struct ClockPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @State private var adding = ""

    var body: some View {
        PageScroll {
            PageHeader(title: "Clock", subtitle: TimeZone.current.localizedName(for: .standard, locale: .current), back: nav.pop)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Card {
                    ForEach(monitor.config.clocks) { zone in
                        let tz = TimeZone(identifier: zone.identifier) ?? .current
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(zone.label)
                                Text(offset(tz)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(time(context.date, tz)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                            if zone.identifier != TimeZone.current.identifier {
                                Button { monitor.config.clocks.removeAll { $0.id == zone.id } } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(zone.label)")
                            }
                        }
                        .padding(.horizontal, Metrics.inset)
                        .frame(height: Metrics.tallRow)
                    }
                }
            }
            Card {
                Row(title: "Add time zone") {
                    Picker("Add time zone", selection: $adding) {
                        Text("Choose…").tag("")
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 150)
                    .onChange(of: adding) { _, id in
                        guard !id.isEmpty else { return }
                        let label = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
                        monitor.config.clocks.append(ClockZone(identifier: id, label: label))
                        adding = ""
                    }
                }
                Row(title: "Menu bar format") {
                    TextField("Format", text: $monitor.config.clockFormat).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 140)
                }
            }
            MenuBarRow(module: .clock)
        }
    }

    private func time(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func offset(_ tz: TimeZone) -> String {
        let diff = (tz.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600
        let sameDay = Calendar.current.dateComponents(in: tz, from: .now).day == Calendar.current.component(.day, from: .now)
        let day = sameDay ? "Today" : diff > 0 ? "Tomorrow" : "Yesterday"
        return diff == 0 ? "Local time" : "\(day), \(diff > 0 ? "+" : "")\(diff) h"
    }
}
