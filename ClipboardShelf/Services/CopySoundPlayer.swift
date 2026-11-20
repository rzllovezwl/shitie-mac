import AppKit

enum CopySoundEffect: String, CaseIterable {
    case shutter = "CopyShutter"
    case softClick = "CopySoftClick"
    case wood = "CopyWood"
    case bubble = "CopyBubble"
    case metalTap = "CopyMetalTap"
    case metalDouble = "CopyMetalDouble"
    case metalSpring = "CopyMetalSpring"
    case paperFlip = "CopyPaperFlip"
    case paperCrumple = "CopyPaperCrumple"
    case chime = "CopyChime"

    var title: String {
        switch self {
        case .shutter: "双咔嗒"
        case .softClick: "轻扣"
        case .wood: "木叩"
        case .bubble: "气泡"
        case .metalTap: "金属轻敲"
        case .metalDouble: "金属双击"
        case .metalSpring: "金属弹片"
        case .paperFlip: "纸张翻页"
        case .paperCrumple: "纸张轻揉"
        case .chime: "原提示音"
        }
    }
}

enum CopySoundPreference {
    static let enabledKey = "copySoundEnabled"
    static let effectKey = "copySoundEffect"
    static let defaultEffect = CopySoundEffect.shutter

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func selectedEffect(in defaults: UserDefaults = .standard) -> CopySoundEffect {
        defaults.string(forKey: effectKey).flatMap(CopySoundEffect.init(rawValue:)) ?? defaultEffect
    }
}

@MainActor
final class CopySoundPlayer {
    static let shared = CopySoundPlayer()

    private let sounds: [CopySoundEffect: NSSound]
    private var playingSound: NSSound?

    private init() {
        sounds = Dictionary(uniqueKeysWithValues: CopySoundEffect.allCases.compactMap { effect in
            guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "wav"),
                  let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
            sound.volume = 0.85
            return (effect, sound)
        })
    }

    func playIfEnabled(_ effect: CopySoundEffect = CopySoundPreference.selectedEffect()) {
        guard CopySoundPreference.isEnabled else { return }
        play(effect)
    }

    func playPreview(_ effect: CopySoundEffect = CopySoundPreference.selectedEffect()) {
        play(effect)
    }

    private func play(_ effect: CopySoundEffect) {
        guard let sound = sounds[effect] ?? sounds[.chime] else { return }
        _ = playingSound?.stop()
        sound.currentTime = 0
        _ = sound.play()
        playingSound = sound
    }
}
