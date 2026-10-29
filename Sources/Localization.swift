import Foundation

/// Langue de l'app, choisie dans le menu (par défaut : celle du Mac).
enum Language: String, CaseIterable, Identifiable {
    case french = "fr"
    case english = "en"

    var id: String { rawValue }
    var label: String { self == .french ? "Français" : "English" }

    static var current: Language {
        get {
            if let saved = UserDefaults.standard.string(forKey: "language"), let language = Language(rawValue: saved) {
                return language
            }
            return Locale.preferredLanguages.first?.hasPrefix("fr") == true ? .french : .english
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
}

/// Texte affiché dans la langue choisie : `L("Quitter", "Quit")`.
func L(_ french: String, _ english: String) -> String {
    Language.current == .english ? english : french
}
