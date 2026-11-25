import SwiftUI

/// Kopplung ohne Rechner (iOS 27): Quill erscheint in den Entwicklermodus-Einstellungen als Rechner.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(PairingService.self) private var pairing
    @Environment(DeviceLink.self) private var device

    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if device.isPaired && !pairing.isRunning && pairing.phase != .paired {
                    Section {
                        Label("Quill ist bereits gekoppelt.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Kopplung entfernen", role: .destructive) { confirmUnpair = true }
                    } footer: {
                        Text("Eine neue Kopplung ersetzt die alte erst, wenn sie erfolgreich war.")
                    }
                }

                Section {
                    phaseView
                }

                Section("So geht’s") {
                    StepRow(number: 1, text: "„Kopplung starten“ tippen.")
                    StepRow(number: 2, text: "Einstellungen → Datenschutz & Sicherheit → Entwicklermodus öffnen und „Quill auf …“ auswählen.")
                    StepRow(number: 3, text: "Den Code eingeben, den Quill hier und als Mitteilung zeigt.")
                    StepRow(number: 4, text: "LocalDevVPN öffnen und verbinden. Quill prüft danach die Verbindung.")
                }

                Section {
                    if pairing.isRunning {
                        Button("Kopplung abbrechen", role: .destructive) { pairing.cancel() }
                    } else {
                        Button {
                            pairing.start()
                        } label: {
                            Label("Kopplung starten", systemImage: "link")
                        }
                    }
                    Button("Einstellungen öffnen", systemImage: "gear") {
                        SystemSettings.open()
                    }
                    NavigationLink {
                        PairingDiagnosticsView()
                    } label: {
                        Label("Kopplung prüfen", systemImage: "stethoscope")
                    }
                    if pairing.phase != .idle {
                        NavigationLink("Protokoll") { LogFileView(url: PairingLog.url, title: "Kopplung") }
                    }
                } footer: {
                    Text("Braucht iOS 27, eingeschalteten Entwicklermodus, WLAN und Zugriff auf das lokale Netzwerk. Die Pairing-Datei bleibt geschützt in Quill und gibt denselben Zugriff wie ein vertrauter Rechner.")
                }
            }
            .navigationTitle("Koppeln")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear {
                pairing.onPaired = { peer in
                    device.didPair(udid: peer.udid, name: peer.name)
                    Task { await device.refresh() }
                }
            }
            .confirmationDialog("Kopplung entfernen?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Entfernen", role: .destructive) { device.unpair() }
            } message: {
                Text("Danach kann Quill nicht mehr installieren, bis neu gekoppelt ist. In den Entwicklermodus-Einstellungen bleibt Quill als Rechner stehen und lässt sich dort entfernen.")
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch pairing.phase {
        case .idle, .stopped:
            Label(pairing.phase == .stopped ? "Abgebrochen." : "Bereit.", systemImage: "antenna.radiowaves.left.and.right")
        case .listening:
            HStack(spacing: 12) {
                ProgressView()
                Text(pairing.message)
            }
        case .connected:
            HStack(spacing: 12) {
                ProgressView()
                Text("iPhone verbunden, warte auf den Code …")
            }
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("Code in den Einstellungen eingeben").font(.footnote).foregroundStyle(.secondary)
                Text(spaced(pin))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityLabel("Kopplungscode \(pin.map(String.init).joined(separator: " "))")
                Button("Code kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = pin }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .paired:
            VStack(alignment: .leading, spacing: 6) {
                Label("Gekoppelt.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                switch device.state {
                case .ready: Label("Verbindung geprüft.", systemImage: "checkmark").foregroundStyle(.green)
                case .checking: Label("Prüfe Verbindung …", systemImage: "hourglass")
                case .unreachable(let reason): Text(reason).font(.footnote).foregroundStyle(.orange)
                case .unpaired: EmptyView()
                }
                if device.state != .ready {
                    Button("Verbindung erneut prüfen") { Task { await device.refresh() } }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func spaced(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }
}
