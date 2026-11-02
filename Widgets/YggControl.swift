import AppIntents
import SwiftUI
import WidgetKit

@main
struct YggWidgets: WidgetBundle {
    var body: some Widget {
        YggControl()
    }
}

/// Control Center / Lock Screen / Action button toggle for the tunnel.
struct YggControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AppIDs.controlKind, provider: Provider()) { isOn in
            ControlWidgetToggle("Yggdrasil", isOn: isOn, action: SetYggdrasilIntent()) { on in
                Label(on ? "Connected" : "Off", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .tint(.green)
        }
        .displayName("Yggdrasil")
        .description("Connect to or disconnect from the Yggdrasil network.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { await VPNControl.isOn() }
    }
}

struct SetYggdrasilIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Connect to Yggdrasil"
    static let description = IntentDescription("Turns the Yggdrasil tunnel on or off.")

    @Parameter(title: "Connected")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try await VPNControl.setEnabled(value)
        return .result()
    }
}
