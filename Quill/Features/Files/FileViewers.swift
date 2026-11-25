import SwiftUI

// MARK: - Property List

struct PlistNode: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    let type: String
    var children: [PlistNode]?

    static func make(key: String, value: Any) -> PlistNode {
        switch value {
        case let dictionary as [String: Any]:
            let children = dictionary.keys.sorted().map { make(key: $0, value: dictionary[$0]!) }
            return PlistNode(key: key, value: String(localized: "\(children.count) Einträge"), type: "Dictionary", children: children)
        case let array as [Any]:
            let children = array.enumerated().map { make(key: "[\($0.offset)]", value: $0.element) }
            return PlistNode(key: key, value: String(localized: "\(children.count) Einträge"), type: "Array", children: children)
        case let string as String:
            return PlistNode(key: key, value: string, type: "String")
        case let date as Date:
            return PlistNode(key: key, value: date.formatted(date: .abbreviated, time: .standard), type: "Date")
        case let data as Data:
            return PlistNode(key: key, value: Int64(data.count).fileSizeText, type: "Data")
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return PlistNode(key: key, value: number.boolValue ? "true" : "false", type: "Boolean")
            }
            return PlistNode(key: key, value: number.stringValue, type: "Number")
        default:
            return PlistNode(key: key, value: String(describing: value), type: "?")
        }
    }
}

/// Zeigt .plist, .entitlements und .mobileprovision als Baum; Plists lassen sich als XML bearbeiten.
struct PlistDocumentView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [PlistNode] = []
    @State private var errorText: String?
    @State private var isEditing = false
    @State private var xml = ""
    @State private var saveError: String?

    private var isProfile: Bool { url.pathExtension.lowercased() == "mobileprovision" }

    var body: some View {
        Group {
            if let errorText {
                ContentUnavailableView("Nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if isEditing {
                TextEditor(text: $xml)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
            } else {
                List(nodes, children: \.children) { node in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(node.key).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(node.type).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(node.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen") { dismiss() }
            }
            if !isProfile && errorText == nil {
                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        Button("Sichern") { save() }
                    } else {
                        Button("XML bearbeiten") { startEditing() }
                    }
                }
            }
        }
        .alert("Sichern fehlgeschlagen", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let root = try readRoot()
            let top = PlistNode.make(key: "Root", value: root)
            nodes = top.children ?? [top]
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func readRoot() throws -> Any {
        let data = try Data(contentsOf: url)
        if isProfile {
            return try ProvisioningProfile.embeddedPlist(in: data)
        }
        return try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private func startEditing() {
        do {
            let root = try readRoot()
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            xml = String(decoding: data, as: UTF8.self)
            isEditing = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() {
        do {
            // Erst prüfen, ob das XML eine gültige Property List ist, dann schreiben.
            let root = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            isEditing = false
            load()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Text

struct TextFileEditorView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var errorText: String?

    private static let maxSize: Int64 = 2 * 1024 * 1024

    var body: some View {
        Group {
            if let errorText {
                ContentUnavailableView("Nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Sichern") { save() }
                    .disabled(text == original || errorText != nil)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard Paths.size(of: url) <= Self.maxSize else {
            errorText = "Die Datei ist größer als 2 MB. Die Hex-Ansicht kann sie öffnen."
            return
        }
        guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
            errorText = "Die Datei ist kein UTF-8-Text. Die Hex-Ansicht kann sie öffnen."
            return
        }
        text = string
        original = string
    }

    private func save() {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            original = text
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Hex

struct HexView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var data = Data()
    @State private var isTruncated = false

    private static let limit = 1024 * 1024
    private var rowCount: Int { (data.count + 15) / 16 }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(0..<rowCount, id: \.self) { index in
                    Text(row(index))
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize()
                }
                if isTruncated {
                    Text("Anzeige auf das erste Megabyte begrenzt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(8)
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen") { dismiss() }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: Self.limit)) ?? Data()
        data = Data(chunk)
        isTruncated = Paths.size(of: url) > Int64(Self.limit)
    }

    private func row(_ index: Int) -> String {
        let start = index * 16
        let bytes = [UInt8](data[start..<min(start + 16, data.count)])
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return String(format: "%08X  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
    }
}
