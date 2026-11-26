import ActivityKit
import SwiftUI
import WidgetKit

struct PairingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            LockScreenPairingView(state: context.state)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "link")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(context.state))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let code = context.state.code {
                        Text(spaced(code))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .accessibilityLabel(Text("Kopplungscode \(code)"))
                    } else {
                        Text(detail(context.state))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "link")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                if let code = context.state.code {
                    Text(code)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: context.state.stage == .paired ? "checkmark" : "ellipsis")
                }
            } minimal: {
                Image(systemName: context.state.code == nil ? "link" : "number")
                    .foregroundStyle(.tint)
            }
        }
    }
}

private struct LockScreenPairingView: View {
    let state: PairingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: state.stage == .paired ? "checkmark.circle.fill" : "link.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(state)).font(.headline)
                if let code = state.code {
                    Text(spaced(code))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text(detail(state)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private func title(_ state: PairingActivityAttributes.ContentState) -> LocalizedStringKey {
    switch state.stage {
    case .waiting, .connected: "Quill ist bereit zur Kopplung"
    case .code: "Quill-Code"
    case .paired: "Gekoppelt."
    case .failed: "Kopplung fehlgeschlagen."
    }
}

private func detail(_ state: PairingActivityAttributes.ContentState) -> LocalizedStringKey {
    switch state.stage {
    case .waiting: "„Pair with Quill“ tippen, zuerst den iPhone-Gerätecode eingeben"
    case .connected: "iPhone verbunden, der Quill-Code erscheint gleich"
    case .code: "In den Einstellungen eingeben"
    case .paired: "Zurück zu Quill"
    case .failed: "In Quill erneut starten."
    }
}

private func spaced(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return "\(code.prefix(3)) \(code.suffix(3))"
}
