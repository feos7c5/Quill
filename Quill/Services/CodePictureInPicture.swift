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
    var onClosedByUser: (() -> Void)?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private static let pixelSize = CGSize(width: 720, height: 360)

    /// Vorbereiten, solange Quill im Vordergrund ist.
    func prepare() {
        guard Self.isSupported else {
            PairingLog.write("Picture in Picture: not supported on this device")
            return
        }
        content = .waiting
        stoppingByQuill = false
        restoring = false
        displayLayer.videoGravity = .resizeAspect
        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            controller.delegate = self
            self.controller = controller
        }
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

    func stop() {
        stoppingByQuill = true
        timer?.invalidate()
        timer = nil
        controller?.stopPictureInPicture()
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

    private static func lines(for content: Content) -> (title: String, main: String, footnote: String) {
        switch content {
        case .waiting:
            (String(localized: "Quill wartet auf die Kopplung"), "· · ·",
             String(localized: "Einstellungen › Datenschutz & Sicherheit › Entwicklermodus"))
        case .connected:
            (String(localized: "Quill wartet auf die Kopplung"), "· · ·",
             String(localized: "iPhone verbunden, warte auf den Code …"))
        case .code(let code):
            (String(localized: "Kopplungscode"),
             code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code,
             String(localized: "In den Einstellungen eingeben"))
        case .paired:
            (String(localized: "Gekoppelt."), "✓", String(localized: "Zurück zu Quill"))
        case .failed:
            (String(localized: "Kopplung fehlgeschlagen."), "!", String(localized: "In Quill erneut starten."))
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

        UIColor(white: 0.08, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: pixelSize))

        let text = lines(for: content)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        func draw(_ string: String, font: UIFont, color: UIColor, y: CGFloat, height: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: centered]
            (string as NSString).draw(with: CGRect(x: 24, y: y, width: pixelSize.width - 48, height: height),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: attributes, context: nil)
        }
        draw(text.title, font: .systemFont(ofSize: 34, weight: .semibold), color: UIColor(white: 0.75, alpha: 1), y: 28, height: 48)
        let mainFont = UIFont.monospacedDigitSystemFont(ofSize: 116, weight: .bold)
        draw(text.main, font: mainFont, color: .white, y: 78, height: 150)
        // Pfad vollständig, bei Bedarf auf zwei Zeilen.
        draw(text.footnote, font: .systemFont(ofSize: 27, weight: .regular), color: UIColor(white: 0.65, alpha: 1), y: 262, height: 90)
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
