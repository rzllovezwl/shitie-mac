import AppKit

enum CopySoundPreference {
    static let enabledKey = "copySoundEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

@MainActor
final class CopySoundPlayer {
    static let shared = CopySoundPlayer()

    private let sound: NSSound?

    private init() {
        guard let url = Bundle.main.url(forResource: "CopyChime", withExtension: "wav") else {
            sound = nil
            return
        }
        sound = NSSound(contentsOf: url, byReference: false)
        sound?.volume = 0.5
    }

    func playIfEnabled() {
        guard CopySoundPreference.isEnabled else { return }
        play()
    }

    func playPreview() {
        play()
    }

    private func play() {
        guard let sound else { return }
        _ = sound.stop()
        _ = sound.play()
    }
}
