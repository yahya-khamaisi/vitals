import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var fans = FanHelper.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        PageScroll {
            PageHeader(title: "Settings", back: nav.pop)
            Card {
                ToggleRow(title: "Open at login", isOn: Binding(get: { openAtLogin }, set: { on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {}
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }))
                ToggleRow(title: "Combine menu bar items", isOn: $monitor.config.combined)
                PickerRow(title: "Update every", selection: $monitor.config.interval,
                          options: [(1.0, "1 second"), (2.0, "2 seconds"), (3.0, "3 seconds"), (5.0, "5 seconds")])
                PickerRow(title: "Temperature", selection: $monitor.config.temperatureUnit,
                          options: TemperatureUnit.allCases.map { ($0, $0.title) })
                PickerRow(title: "Top processes shown", selection: $monitor.config.topProcesses, options: [(3, "3"), (5, "5"), (8, "8")])
            }
            Captioned(title: "Modules", trailing: "Shown in the panel and menu bar") {
                Card {
                    ForEach(Module.allCases) { m in
                        HStack(spacing: 8) {
                            IconTile(symbol: m.symbol, tint: m.tint)
                            Text(m.title)
                            Spacer(minLength: 8)
                            Toggle(m.title, isOn: Binding(get: { monitor.config.isOn(m) }, set: { monitor.config.enabled[m] = $0 }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                        .padding(.horizontal, Metrics.inset)
                        .frame(height: Metrics.row)
                    }
                }
            }
            Card {
                NavRow(symbol: "menubar.rectangle", tint: Color(white: 0.24), title: "Menu Bar",
                       value: monitor.config.combined ? "Combined" : "Separate") { nav.focus = nil; nav.push(.widgets) }
                NavRow(symbol: "bell.badge.fill", tint: .red, title: "Alerts",
                       value: "\(monitor.config.alerts.filter(\.enabled).count) rules") { nav.push(.alerts) }
                NavRow(symbol: "fan.fill", tint: .gray, title: "Fan Control Helper",
                       value: fans.running ? "Running" : fans.installed ? "Installed" : "Not installed") { nav.push(.fanHelper) }
                NavRow(symbol: "terminal.fill", tint: .indigo, title: "Shortcuts & Command Line") { nav.push(.automation) }
                NavRow(symbol: "info.circle.fill", tint: Color(white: 0.2), title: "About Vitals",
                       value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") { nav.push(.about) }
            }
        }
    }
}

// MARK: - Menu bar editor

struct WidgetsPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var bar = MenuBarState.shared
    @State private var selected: Module = .cpu

    var body: some View {
        let modules = monitor.config.order.filter { monitor.config.isOn($0) }
        PageScroll {
            PageHeader(title: "Menu Bar", subtitle: "Drag to reorder · click to edit", back: nav.pop) {
                Button("Reset") {
                    let d = Config()
                    monitor.config.widgets = d.widgets
                    monitor.config.order = d.order
                }
                .controlSize(.small).buttonBorderShape(.capsule)
            }
            preview
            Card {
                ForEach(modules) { m in
                    let w = monitor.config.widget(m)
                    Button { selected = m } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                            IconTile(symbol: m.symbol, tint: m.tint)
                            Text(m.title)
                            Spacer(minLength: 8)
                            Text(w.enabled ? w.style.title : "Hidden").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: Metrics.row)
                        .background(selected == m ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .draggable(m.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let moved = Module(rawValue: raw), moved != m,
                              let from = monitor.config.order.firstIndex(of: moved), let to = monitor.config.order.firstIndex(of: m) else { return false }
                        monitor.config.order.remove(at: from)
                        monitor.config.order.insert(moved, at: to)
                        return true
                    }
                    .accessibilityAddTraits(selected == m ? .isSelected : [])
                }
            }
            Captioned(title: "\(selected.title) style", trailing: nil) {
                Card(padded: true) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(selected.styles) { style in
                            let on = monitor.config.widget(selected).style == style
                            Button { monitor.config.widgets[selected]?.style = style } label: {
                                Text(style.title).font(.system(size: 12, weight: on ? .medium : .regular))
                                    .frame(maxWidth: .infinity).frame(height: 30)
                                    .background(on ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary), in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            Card {
                ToggleRow(title: "Show in menu bar", isOn: binding(\.enabled))
                PickerRow(title: "Color", selection: binding(\.color), options: WidgetColor.allCases.map { ($0, $0.title) })
                ToggleRow(title: "Show label", isOn: binding(\.showLabel))
                if monitor.config.combined { ToggleRow(title: "Own menu bar item", isOn: binding(\.ownItem)) }
                if monitor.config.widget(selected).style == .text {
                    Row(title: "Template", subtitle: "$cpu $gpu $mem $disk $down $up $bat $temp $fan $time") {
                        TextField("Template", text: binding(\.template), prompt: Text("$cpu · $temp"))
                            .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 110)
                    }
                }
            }
        }
        .onAppear {
            if let focus = nav.focus { selected = focus }
            else if let first = modules.first { selected = first }
        }
    }

    private var preview: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Array(bar.images.keys.sorted { order($0) < order($1) }), id: \.self) { key in
                if let image = bar.images[key], bar.inserted[key] == true {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: 22)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(highlighted(key) ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(.background.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityLabel("Menu bar preview")
    }

    private func order(_ key: String) -> Int {
        key == "combined" ? 99 : monitor.config.order.firstIndex { $0.rawValue == key } ?? 0
    }

    private func highlighted(_ key: String) -> Bool {
        key == selected.rawValue || (key == "combined" && !monitor.config.widget(selected).ownItem && monitor.config.combined)
    }

    private func binding<T>(_ path: WritableKeyPath<WidgetConfig, T>) -> Binding<T> {
        Binding(get: { monitor.config.widget(selected)[keyPath: path] },
                set: { var w = monitor.config.widget(selected); w[keyPath: path] = $0; monitor.config.widgets[selected] = w })
    }
}

// MARK: - Alerts

struct AlertsPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @State private var authorized: Bool?

    var body: some View {
        PageScroll {
            PageHeader(title: "Alerts", subtitle: "Notify when a value crosses a limit", back: nav.pop) {
                Menu {
                    ForEach(AlertMetric.allCases) { m in
                        Button(m.title) {
                            monitor.config.alerts.append(AlertRule(metric: m, threshold: m == .batteryLow ? 20 : m == .temperature ? 90 : m.range.upperBound * 0.8))
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.circle).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add alert")
            }
            if authorized == false {
                Card {
                    Row(title: "Notifications are off", subtitle: "Allow them so alerts can appear") {
                        Button("Allow") { request() }.controlSize(.small).buttonBorderShape(.capsule)
                    }
                }
            }
            ForEach($monitor.config.alerts) { $rule in
                Card {
                    HStack(spacing: 8) {
                        Text(rule.metric.title).fontWeight(.medium)
                        Spacer()
                        Toggle(rule.metric.title, isOn: $rule.enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        Button { monitor.config.alerts.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(rule.metric.title) alert")
                    }
                    .padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
                    HStack(spacing: 8) {
                        Text(rule.metric.fallingEdge ? "Below" : "Above").frame(width: 44, alignment: .leading)
                        Slider(value: $rule.threshold, in: rule.metric.range, step: 1) { Text("Limit") }.labelsHidden().controlSize(.small)
                        Text("\(Int(rule.threshold)) \(rule.metric.unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.inset).frame(height: Metrics.row)
                    PickerRow(title: "For at least", selection: $rule.seconds,
                              options: [(1, "Immediately"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes")])
                }
            }
        }
        .onAppear {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                DispatchQueue.main.async { authorized = ok }
            }
        }
    }

    private func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                authorized = granted
                if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Fan helper

struct FanHelperPage: View {
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var helper = FanHelper.shared

    var body: some View {
        PageScroll {
            PageHeader(title: "Fan Control Helper", subtitle: helper.running ? "Running" : helper.installed ? "Installed, not running" : "Not installed",
                       back: nav.pop)
            Card(padded: true) {
                Text("Setting a fan speed needs administrator rights. The helper is a small background process, installed once with your password, that only changes fan speeds and hands control back to macOS when you choose Auto or quit Vitals.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card {
                ValueRow(title: "Helper", value: FanHelper.binary.replacingOccurrences(of: "/Library/PrivilegedHelperTools/", with: ""))
                ValueRow(title: "Status", value: helper.running ? "Running" : helper.installed ? "Stopped" : "Not installed",
                         tint: helper.running ? .green : nil)
            }
            if let error = helper.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, Metrics.inset)
            }
            ButtonBar(buttons: helper.installed
                      ? [("Reinstall", false, { helper.install() }), ("Uninstall", true, { helper.uninstall() })]
                      : [("Install Helper…", false, { helper.install() })])
        }
        .onAppear { helper.refresh() }
    }
}

// MARK: - Automation

struct AutomationPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator
    @ObservedObject private var automation = Automation.shared

    var body: some View {
        PageScroll {
            PageHeader(title: "Shortcuts & Command Line", back: nav.pop)
            Card {
                ToggleRow(title: "Open panel with ⌃⌥V", isOn: $monitor.config.hotKeyEnabled)
                ToggleRow(title: "Look up public IP address", subtitle: "Asks api.ipify.org every 10 minutes", isOn: $monitor.config.lookUpPublicIP)
                Row(title: "Command-line tool", subtitle: automation.cliInstalled ? "/usr/local/bin/vitals" : "Not installed") {
                    Button(automation.cliInstalled ? "Reinstall" : "Install…") { automation.installCLI() }
                        .controlSize(.small).buttonBorderShape(.capsule)
                }
            }
            Captioned(title: "Examples", trailing: nil) {
                CodeBlock(text: """
                vitals get cpu
                vitals get all --json
                vitals open sensors
                open "vitals://open?page=network"
                """)
            }
            Card(padded: true) {
                Text("Shortcuts: “Get System Value” returns any reading, and “Open Vitals Page” opens a page. Find them under Vitals in the Shortcuts app.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            PageHeader(title: "About Vitals", back: nav.pop)
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                Text("Vitals").font(.system(size: 17, weight: .bold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("A free system monitor for the menu bar. No account, no tracking, no subscription.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Card {
                ValueRow(title: "Mac", value: Host.modelName)
                ValueRow(title: "Chip", value: Sys.string("machdep.cpu.brand_string") ?? "—")
                ValueRow(title: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
    }
}
