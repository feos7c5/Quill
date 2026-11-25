import ActivityKit
import Foundation

/// Live-Aktivität während der Kopplung: zeigt den Code in der Dynamic Island und auf dem
/// Sperrbildschirm, damit er sichtbar ist, während die Einstellungen im Vordergrund sind.
struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Stage: String, Codable, Hashable {
            case waiting, connected, code, paired, failed
        }
        var stage: Stage
        var code: String?
    }
}
