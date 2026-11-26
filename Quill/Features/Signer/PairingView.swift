import SwiftUI

/// Kopplung ohne Rechner (iOS 27): Quill erscheint in den Entwicklermodus-Einstellungen als Rechner.
struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(PairingService.self) private var pairing
    @Environment(DeviceLink.self) private var device
    private var network = NetworkState.shared

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
                    if network.vpnActive && !pairing.isRunning {
                        // Mit verbundenem VPN erreichen die Einstellungen Quill nicht.
                        Label("LocalDevVPN ist verbunden. Für die Kopplung in LocalDevVPN trennen und danach wieder verbinden.",
                              systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if pairing.isRunning && CodePictureInPicture.isSupported {
                    Section {
                        CodePictureInPicturePreview()
                            .aspectRatio(1.8, contentMode: .fit)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        Button("Als schwebendes Fenster zeigen", systemImage: "pip.enter") {
                            CodePictureInPicture.shared.start()
                        }
                    } footer: {
                        Text("Beim Wechsel in die Einstellungen schwebt dieses Fenster mit dem Code über allen Apps, wie ein Video im Bild-im-Bild.")
                    }
                }

                Section("So geht’s") {
                    StepRow(number: 1, text: "LocalDevVPN trennen, dann „Kopplung starten“ tippen.")
                    StepRow(number: 2, text: "Einstellungen → Datenschutz & Sicherheit → Entwicklermodus → „Pair with Quill“ tippen.")
                    StepRow(number: 3, text: "Zuerst den Gerätecode des iPhones eingeben (Entsperrcode), danach den 6-stelligen Quill-Code aus dem schwebenden Fenster.")
                    StepRow(number: 4, text: "Erst danach LocalDevVPN wieder verbinden. Quill prüft dann die Verbindung.")
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
                        .disabled(network.vpnActive)
                    }
                    Button("Einstellungen öffnen", systemImage: "gear") {
                        SystemSettings.open()
                    }
                    if pairing.phase != .idle {
                        NavigationLink("Protokoll") { LogFileView(url: PairingLog.url, title: "Kopplung") }
                    }
                    ShareLink(item: LogBundle(), preview: SharePreview("Quill-logs.txt")) {
                        Label("Protokolle teilen", systemImage: "square.and.arrow.up")
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
                Text("iPhone verbunden, der Quill-Code erscheint gleich")
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
            if pairing.needsLocalNetwork {
                // Die eigene Einstellungsseite darf Quill direkt öffnen; dort liegt der Schalter.
                Button("Lokales Netzwerk erlauben", systemImage: "network") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    private func spaced(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }
}
