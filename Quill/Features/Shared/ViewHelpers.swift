import SwiftUI

extension View {
    /// Fehlermeldung als Standard-Alert. Der Text bleibt beim Ausblenden sichtbar.
    func messageAlert(_ title: LocalizedStringKey = "Fehler", message: Binding<String?>) -> some View {
        alert(title,
              isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
              presenting: message.wrappedValue) { _ in
            Button("OK", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }
}

extension View {
    /// Die eine Hauptaktion eines Bildschirms: volle Breite, Glas-Stil, ohne Zeilenhintergrund.
    func primaryActionRow() -> some View {
        frame(maxWidth: .infinity)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
}

/// Nummerierter Schritt in einer Anleitung.
struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}

/// Fortschritt und Protokoll des laufenden oder letzten Signiervorgangs.
struct PipelineProgressView: View {
    @Environment(SigningPipeline.self) private var pipeline

    var body: some View {
        if pipeline.isRunning {
            ProgressView(value: pipeline.progress) {
                Text(pipeline.status)
                    .font(.subheadline)
            }
        } else if pipeline.failed {
            Label(pipeline.status, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else if !pipeline.status.isEmpty {
            Label(pipeline.status, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        if !pipeline.log.isEmpty {
            NavigationLink("Protokoll") {
                ScrollView {
                    Text(pipeline.log.joined(separator: "\n"))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Protokoll")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
