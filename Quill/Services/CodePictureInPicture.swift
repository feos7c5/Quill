import AVKit
import SwiftUI
import UIKit

/// Zeigt den Kopplungsstand als schwebendes Bild-im-Bild-Fenster, wie ein Video, das im
/// Hintergrund weiterläuft. Das Fenster liegt über allen Apps, also auch über den Einstellungen,
/// in denen der Code eingegeben wird. Es braucht weder Mitteilungen noch eine passende Bundle-ID.
///
/// Technik: `AVSampleBufferDisplayLayer` mit selbst gezeichneten Einzelbildern als Quelle für
/// `AVPictureInPictureController` (ab iOS 15). Startet automatisch, sobald Quill in den
/// Hintergrund geht, solange die Vorschau in der Kopplungsansicht zu sehen ist.
@MainActor
final class CodePictureInPicture: NSObject {
    static let shared = CodePictureInPicture()

    enum Content: Equatable {
        case waiting
        case connected
        case code(String)
        case paired
        case failed
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private var content: Content = .waiting
    /// Quill selbst beendet das Fenster (Kopplung fertig), nicht der Nutzer.
    private var stoppingByQuill = false
    /// Der Nutzer ist über das Fenster zu Quill zurückgekehrt (kein Abbruch).
    private var restoring = false
    /// Der Nutzer hat das Fenster geschlossen, ohne dass die Kopplung fertig war.
    private var onClosedByUser: (() -> Void)?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private static let pixelSize = CGSize(width: 720, height: 400)

    /// Vorbereiten, solange Quill im Vordergrund ist.
    func prepare(onClosedByUser: @escaping () -> Void) {
        self.onClosedByUser = onClosedByUser
        guard Self.isSupported else {
            PairingLog.write("Picture in Picture: not supported on this device")
            return
        }
        content = .waiting
        stoppingByQuill = false
        restoring = false
        displayLayer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
        render()
        // Regelmäßig ein frisches Bild liefern, damit das Fenster nicht als „angehalten“ gilt.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { CodePictureInPicture.shared.render() }
        }
    }

    func show(_ content: Content) {
        guard self.content != content else { return }
        self.content = content
        render()
    }

    /// Von Hand starten (Taste in der Kopplungsansicht).
    func start() {
        controller?.startPictureInPicture()
    }

    /// Beenden. Bei Erfolg kurz „Gekoppelt“ zeigen, bei Fehlern sofort schließen (die Meldung steht
    /// in Quill). `completion` läuft, wenn das Fenster zu ist.
    func finish(_ content: Content, completion: @escaping @MainActor () -> Void) {
        guard content == .paired else {
            stop()
            completion()
            return
        }
        show(content)
        Task {
            try? await Task.sleep(for: .seconds(3))
            self.stop()
            completion()
        }
    }

    /// Schließt das Fenster und gibt den Controller frei. Ohne Controller kann iOS beim Verlassen
    /// von Quill kein leeres (schwarzes) Fenster mehr öffnen.
    func stop() {
        stoppingByQuill = true
        timer?.invalidate()
        timer = nil
        onClosedByUser = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        controller = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: - Zeichnen

    private func render() {
        guard let buffer = Self.pixelBuffer(for: content),
              let sample = Self.sampleBuffer(from: buffer) else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    /// Ein Textblock im Fenster, von oben nach unten gestapelt und mittig ausgerichtet.
    private struct Block {
        let text: String
        let font: UIFont
        let color: UIColor
        var spacingAfter: CGFloat = 14
    }

    private static let secondary = UIColor(white: 0.62, alpha: 1)
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1)

    private static func blocks(for content: Content) -> [Block] {
        let title = UIFont.systemFont(ofSize: 31, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 24, weight: .regular)
        let emphasis = UIFont.systemFont(ofSize: 24, weight: .semibold)
        let small = UIFont.systemFont(ofSize: 19, weight: .regular)
        let code = UIFont.monospacedDigitSystemFont(ofSize: 112, weight: .bold)
        switch content {
        case .waiting:
            return [
                Block(text: String(localized: "Quill ist bereit zur Kopplung"), font: title, color: .white, spacingAfter: 20),
                Block(text: String(localized: "1. Einstellungen › Datenschutz & Sicherheit › Entwicklermodus"), font: body, color: .white, spacingAfter: 6),
                Block(text: String(localized: "2. „Pair with Quill“ tippen › Gerätecode des iPhones eingeben"), font: body, color: .white, spacingAfter: 16),
                Block(text: String(localized: "3. Danach erscheint hier der 6-stellige Quill-Code"), font: emphasis, color: accent, spacingAfter: 16),
                Block(text: String(localized: "Die erste Abfrage ist dein iPhone-Entsperrcode, erst danach kommt der Quill-Code."), font: small, color: secondary, spacingAfter: 0),
            ]
        case .connected:
            return [
                Block(text: String(localized: "iPhone verbunden"), font: title, color: .white, spacingAfter: 8),
                Block(text: "· · ·", font: code, color: .white, spacingAfter: 8),
                Block(text: String(localized: "Der 6-stellige Quill-Code erscheint gleich."), font: body, color: secondary, spacingAfter: 0),
            ]
        case .code(let pin):
            return [
                Block(text: String(localized: "Quill-Code"), font: title, color: .white, spacingAfter: 4),
                Block(text: pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin, font: code, color: accent, spacingAfter: 4),
                Block(text: String(localized: "In den Einstellungen eingeben"), font: body, color: secondary, spacingAfter: 0),
            ]
        case .paired:
            return [
                Block(text: "✓", font: code, color: .white, spacingAfter: 4),
                Block(text: String(localized: "Gekoppelt."), font: title, color: .white, spacingAfter: 8),
                Block(text: String(localized: "Zurück zu Quill"), font: body, color: secondary, spacingAfter: 0),
            ]
        case .failed:
            return [
                Block(text: String(localized: "Kopplung fehlgeschlagen."), font: title, color: .white, spacingAfter: 8),
                Block(text: String(localized: "In Quill erneut starten."), font: body, color: secondary, spacingAfter: 0),
            ]
        }
    }

    private static func pixelBuffer(for content: Content) -> CVPixelBuffer? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // UIKit-Koordinaten (Ursprung oben links).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: pixelSize))

        // Blöcke messen, dann als Ganzes senkrecht mittig setzen. Lange Zeilen brechen um.
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let textWidth = pixelSize.width - 56
        let laid = blocks(for: content).map { block -> (Block, [NSAttributedString.Key: Any], CGFloat) in
            let attributes: [NSAttributedString.Key: Any] = [.font: block.font, .foregroundColor: block.color, .paragraphStyle: centered]
            let height = (block.text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                                options: [.usesLineFragmentOrigin], attributes: attributes, context: nil).height
            return (block, attributes, ceil(height))
        }
        let total = laid.reduce(0) { $0 + $1.2 + $1.0.spacingAfter }
        var y = max(12, (pixelSize.height - total) / 2)
        for (block, attributes, height) in laid {
            (block.text as NSString).draw(with: CGRect(x: 28, y: y, width: textWidth, height: height),
                                          options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            y += height + block.spacingAfter
        }
        return buffer
    }

    private static func sampleBuffer(from buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

extension CodePictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Live-Inhalt ohne Ende: keine Zeitleiste, kein Vor- und Zurückspulen.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}

extension CodePictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in PairingLog.write("Picture in Picture started") }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in PairingLog.write("Picture in Picture failed to start: \(error)") }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            CodePictureInPicture.shared.restoring = true
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            let shared = CodePictureInPicture.shared
            if shared.stoppingByQuill || shared.restoring {
                PairingLog.write("Picture in Picture stopped")
            } else {
                PairingLog.write("Picture in Picture closed by the user, cancelling pairing")
                shared.onClosedByUser?()
            }
            shared.restoring = false
        }
    }
}

/// Inline-Vorschau in der Kopplungsansicht. Sie muss sichtbar sein, damit iOS das Fenster beim
/// Wechsel in die Einstellungen automatisch öffnen darf.
struct CodePictureInPicturePreview: UIViewRepresentable {
    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CodePictureInPicture.shared.displayLayer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.layer.cornerRadius = 12
        view.layer.masksToBounds = true
        view.backgroundColor = .black
        view.layer.addSublayer(CodePictureInPicture.shared.displayLayer)
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if CodePictureInPicture.shared.displayLayer.superlayer !== uiView.layer {
            uiView.layer.addSublayer(CodePictureInPicture.shared.displayLayer)
        }
    }
}
