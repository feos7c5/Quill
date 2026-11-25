import Foundation
import Observation

/// Stellt den Dokumente-Ordner im lokalen Netz per Browser bereit (Hoch- und Herunterladen).
@Observable
final class WiFiTransferService {
    private(set) var isRunning = false
    private(set) var address: String?

    @ObservationIgnored private var server: HTTPServer?
    private let port: UInt16 = 8080
    private let root = Paths.documents.standardizedFileURL

    func start() throws {
        guard !isRunning else { return }
        let root = self.root
        let server = HTTPServer(port: port) { request in
            Self.handle(request, root: root)
        }
        try server.start()
        self.server = server
        isRunning = true
        address = LocalNetwork.wifiAddress.map { "http://\($0):\(port)" }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        address = nil
    }

    // MARK: - Routen

    private static func handle(_ request: HTTPRequest, root: URL) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            guard let directory = resolve(request.query["dir"] ?? "", root: root) else {
                return .text("Forbidden", status: 403)
            }
            return .html(listing(of: directory, root: root))

        case ("GET", "/file"), ("HEAD", "/file"):
            guard let file = resolve(request.query["path"] ?? "", root: root),
                  FileManager.default.fileExists(atPath: file.path) else {
                return .text("Not found", status: 404)
            }
            return .file(file, downloadName: file.lastPathComponent)

        case ("POST", "/upload"):
            let name = (request.query["name"] ?? "").replacingOccurrences(of: "/", with: "-")
            guard !name.isEmpty, name != ".", name != "..",
                  let body = request.bodyFile,
                  let directory = resolve(request.query["dir"] ?? "", root: root) else {
                return .text("Bad request", status: 400)
            }
            let destination = Paths.uniqueURL(for: directory.appendingPathComponent(name))
            do {
                try FileManager.default.moveItem(at: body, to: destination)
                return .text("OK", status: 201)
            } catch {
                return .text(error.localizedDescription, status: 400)
            }

        default:
            return .text("Not found", status: 404)
        }
    }

    /// Löst einen relativen Pfad auf und verhindert das Verlassen des Dokumente-Ordners.
    private static func resolve(_ relative: String, root: URL) -> URL? {
        let url = relative.isEmpty ? root : root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return (url.path == root.path || url.path.hasPrefix(rootPath)) ? url : nil
    }

    private static func listing(of directory: URL, root: URL) -> String {
        let fm = FileManager.default
        let relative = String(directory.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var rows = ""
        if !relative.isEmpty {
            let parent = (relative as NSString).deletingLastPathComponent
            rows += "<li><a href=\"/?dir=\(encode(parent))\">⬆︎ ..</a></li>"
        }
        for url in urls {
            let path = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
            let name = escape(url.lastPathComponent)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                rows += "<li>📁 <a href=\"/?dir=\(encode(path))\">\(name)</a></li>"
            } else {
                rows += "<li>📄 <a href=\"/file?path=\(encode(path))\">\(name)</a> <small>\(Paths.size(of: url).fileSizeText)</small></li>"
            }
        }

        return """
        <!doctype html>
        <html lang="de"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Quill – Dateien</title>
        <style>
          body { font: 16px -apple-system, system-ui, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; }
          ul { list-style: none; padding: 0; } li { padding: .5rem 0; border-bottom: 1px solid #8883; }
          small { color: #888; margin-left: .5rem; } a { text-decoration: none; }
          .upload { padding: 1rem; border: 2px dashed #8886; border-radius: 12px; margin: 1rem 0; }
        </style></head>
        <body>
          <h1>/\(escape(relative))</h1>
          <div class="upload">
            <input type="file" id="files" multiple>
            <button onclick="upload()">Hochladen</button>
            <span id="status"></span>
          </div>
          <ul>\(rows)</ul>
          <script>
            async function upload() {
              const status = document.getElementById('status');
              const files = document.getElementById('files').files;
              const dir = new URLSearchParams(location.search).get('dir') || '';
              for (const file of files) {
                status.textContent = 'Lade ' + file.name + ' …';
                const url = '/upload?dir=' + encodeURIComponent(dir) + '&name=' + encodeURIComponent(file.name);
                const response = await fetch(url, { method: 'POST', body: file });
                if (!response.ok) { status.textContent = 'Fehler bei ' + file.name; return; }
              }
              location.reload();
            }
          </script>
        </body></html>
        """
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
