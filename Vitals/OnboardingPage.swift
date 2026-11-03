import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum Onboarding {
    private static let key = "onboarding.completed"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @MainActor private static var panel: GlassPanel?

    /// On first launch, shows the welcome page in a glass panel under the menu bar.
    /// (MenuBarExtra can't open its own panel from code, so we present the same page.)
    @MainActor static func presentIfNeeded() {
        guard !isComplete else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let page = OnboardingPage(done: finish).environmentObject(Monitor.shared)
            let panel = GlassPanel(rootView: page.frame(width: Metrics.width).focusEffectDisabled())
            panel.showUnderMenuBar()
            self.panel = panel
        }
    }

    @MainActor static func finish() {
        isComplete = true
        panel?.close()
        panel = nil
    }
}

struct OnboardingPage: View {
    let done: () -> Void
    @EnvironmentObject var monitor: Monitor
    @ObservedObject private var fans = FanHelper.shared
    @State private var openAtLogin = true
    @State private var notifications: Bool?

    var body: some View {
        VStack(spacing: Metrics.gap) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                Text("Welcome to Vitals").font(.system(size: 17, weight: .bold)).padding(.top, 4)
                Text("CPU, memory, disks, network, battery and sensors in your menu bar. Free, with no account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Captioned(title: "Menu bar", trailing: nil) {
                HStack(spacing: Metrics.gap) {
                    LayoutCard(title: "Combined", subtitle: "One item, one panel", combined: true, selected: monitor.config.combined) {
                        monitor.config.combined = true
                    }
                    LayoutCard(title: "Separate", subtitle: "One item per module", combined: false, selected: !monitor.config.combined) {
                        monitor.config.combined = false
                    }
                }
            }

            Captioned(title: "Options", trailing: nil) {
                Card {
                    PermissionRow(symbol: "bell.badge.fill", tint: .red, title: "Notifications", subtitle: "Alerts when a limit is crossed",
                                  action: notifications == true ? nil : ("Allow", requestNotifications))
                    PermissionRow(symbol: "fan.fill", tint: .gray, title: "Fan control helper", subtitle: "Asks for your password once",
                                  action: fans.installed ? nil : ("Install", { fans.install() }))
                    ToggleRow(title: "Open at login", isOn: $openAtLogin)
                }
            }

            Button {
                if openAtLogin { try? SMAppService.mainApp.register() }
                done()
            } label: {
                Text("Start Monitoring").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.pad)
        .onAppear {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let ok = s.authorizationStatus == .authorized
                DispatchQueue.main.async { notifications = ok }
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { notifications = granted }
        }
    }
}

private struct LayoutCard: View {
    let title: String
    let subtitle: String
    let combined: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: combined ? 5 : 4) {
                    ForEach(["23%", "61%", "52°"], id: \.self) { v in
                        Text(v).padding(.horizontal, combined ? 0 : 5).padding(.vertical, 1)
                            .background(combined ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 5))
                    }
                }
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, combined ? 6 : 0)
                .frame(height: 18)
                .background(combined ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.quinary), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(.rect(cornerRadius: Metrics.radius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.0, action: action.1).controlSize(.small).buttonBorderShape(.capsule)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.tallRow)
    }
}
