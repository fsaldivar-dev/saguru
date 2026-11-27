import Foundation

// Saguru's words in other languages. The interface is written in Spanish; each other language has a
// table from the Spanish text to its own (Localization/<language>.lproj/Localizable.strings, copied into
// the app). SwiftUI looks its literal texts up there by itself; everything that is a String by the time
// it is shown goes through tr(). A text with no entry stays in Spanish.

/// The text in the language Saguru is running in. With values, the text is a format: "%@ se cerró".
func tr(_ key: String, _ values: CVarArg...) -> String {
    let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return values.isEmpty ? text : String(format: text, arguments: values)
}

enum Language: String, CaseIterable {
    case system, es, en, zh = "zh-Hans", ja

    /// Each language is named in itself, so it can be found by someone who reads no other.
    var name: String {
        switch self {
        case .system: return tr("Idioma del sistema")
        case .es: return "Español"
        case .en: return "English"
        case .zh: return "简体中文"
        case .ja: return "日本語"
        }
    }

    /// The one chosen in Saguru, as opposed to whatever the system would pick.
    static var chosen: Language {
        guard let forced = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
              UserDefaults.standard.bool(forKey: "language.chosen") else { return .system }
        return Language(rawValue: forced) ?? .system
    }

    /// macOS decides an app's language when it starts, so choosing another one restarts Saguru.
    static func choose(_ language: Language) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.set(false, forKey: "language.chosen")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
            UserDefaults.standard.set(true, forKey: "language.chosen")
        }
        UserDefaults.standard.synchronize()
        let again = Process()
        again.executableURL = Bundle.main.executableURL
        again.arguments = Array(CommandLine.arguments.dropFirst())
        try? again.run()
        exit(0)
    }
}
