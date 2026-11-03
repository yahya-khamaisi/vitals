import AppIntents

/// Shortcuts actions. Each one is a thin wrapper over the shared command language.

enum VitalsValue: String, AppEnum {
    case cpu, gpu, memory, disk, network, battery, sensors, fans, bluetooth, all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "System Value"
    static let caseDisplayRepresentations: [VitalsValue: DisplayRepresentation] = [
        .cpu: "CPU", .gpu: "GPU", .memory: "Memory", .disk: "Disks", .network: "Network",
        .battery: "Battery", .sensors: "Sensors", .fans: "Fans", .bluetooth: "Bluetooth", .all: "Everything"
    ]
}

struct GetSystemValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Value"
    static let description = IntentDescription("Returns current readings from Vitals as text, or JSON.")
    @Parameter(title: "Value", default: .cpu) var value: VitalsValue
    @Parameter(title: "As JSON", default: false) var json: Bool

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$value) readings") { \.$json } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["get", value.rawValue] + (json ? ["--json"] : [])))
    }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Vitals Page"
    @Parameter(title: "Page", default: .cpu) var page: VitalsValue

    @MainActor func perform() async throws -> some IntentResult {
        _ = Command.run(["open", page == .all ? "main" : page == .fans ? "sensors" : page.rawValue])
        return .result()
    }
}

struct VitalsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetSystemValueIntent(), phrases: ["Get readings from \(.applicationName)"],
                    shortTitle: "Get System Value", systemImageName: "waveform.path.ecg")
    }
}
