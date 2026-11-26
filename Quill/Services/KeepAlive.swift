import AVFoundation

/// Hält Quill im Hintergrund wach, solange der Nutzer in Safari oder den Einstellungen etwas
/// bestätigen muss (Kopplungscode, UDID-Profil). iOS friert Apps sonst nach rund 30 Sekunden ein,
/// und der lokale Server könnte nicht mehr antworten. Technisch: stumme Audiowiedergabe, die
/// andere Wiedergabe nicht unterbricht. Läuft nur während dieser kurzen Abläufe.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var users = 0

    var isPlaying: Bool { player?.isPlaying ?? false }

    func begin() {
        users += 1
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            AppLog.write("Audio session not active: \(error)")
        }
        let player = try? AVAudioPlayer(data: Self.silence)
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
        self.player = player
    }

    func end() {
        users = max(0, users - 1)
        guard users == 0, let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Eine Sekunde Stille als WAV (8 kHz, mono, 16 Bit).
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }()
}
