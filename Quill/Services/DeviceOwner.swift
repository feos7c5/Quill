import LocalAuthentication

/// Bestätigung durch Face ID, Touch ID oder Gerätecode vor heiklen Aktionen (Export des privaten Schlüssels).
enum DeviceOwner {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Ohne Gerätecode gibt es nichts zu prüfen; iOS schützt dann ohnehin nichts.
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
