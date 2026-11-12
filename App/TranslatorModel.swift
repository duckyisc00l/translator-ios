import SwiftUI
import Translation
import NaturalLanguage

// MARK: - Languages

struct Lang: Identifiable, Hashable {
    let code: String        // used for Apple's Translation framework
    let speechCode: String  // used for speech recognition / text-to-speech
    var id: String { code }

    var name: String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized(with: Locale.current) ?? code
    }
    var language: Locale.Language { Locale.Language(identifier: code) }

    static let english = Lang(code: "en", speechCode: "en-US")
    static let spanish = Lang(code: "es", speechCode: "es-MX")

    /// Languages Apple can translate on-device. Spanish and English come first.
    static let all: [Lang] = [
        .english, .spanish,
        Lang(code: "fr", speechCode: "fr-FR"),
        Lang(code: "pt-BR", speechCode: "pt-BR"),
        Lang(code: "it", speechCode: "it-IT"),
        Lang(code: "de", speechCode: "de-DE"),
        Lang(code: "zh-Hans", speechCode: "zh-CN"),
        Lang(code: "zh-Hant", speechCode: "zh-TW"),
        Lang(code: "ja", speechCode: "ja-JP"),
        Lang(code: "ko", speechCode: "ko-KR"),
        Lang(code: "ru", speechCode: "ru-RU"),
        Lang(code: "ar", speechCode: "ar-SA"),
        Lang(code: "hi", speechCode: "hi-IN"),
        Lang(code: "nl", speechCode: "nl-NL"),
        Lang(code: "pl", speechCode: "pl-PL"),
        Lang(code: "tr", speechCode: "tr-TR"),
        Lang(code: "uk", speechCode: "uk-UA"),
        Lang(code: "vi", speechCode: "vi-VN"),
        Lang(code: "th", speechCode: "th-TH"),
        Lang(code: "id", speechCode: "id-ID"),
    ]

    static func find(_ code: String?) -> Lang? {
        guard let code else { return nil }
        return all.first { $0.code == code }
            ?? all.first { $0.code.split(separator: "-").first.map(String.init) == code.split(separator: "-").first.map(String.init) }
    }
}

// MARK: - History

struct HistoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var input: String
    var output: String
    var starred = false
    var date = Date()
}

// MARK: - Model

@MainActor
final class TranslatorModel: ObservableObject {
    @Published var source: Lang { didSet { UserDefaults.standard.set(source.code, forKey: "source") } }
    @Published var target: Lang { didSet { UserDefaults.standard.set(target.code, forKey: "target") } }
    @Published var input = "" { didSet { if input != oldValue { inputChanged() } } }
    @Published var output = ""
    @Published var isTranslating = false
    @Published var errorText: String?
    @Published var status: LanguageAvailability.Status?
    @Published var suggestion: Lang?
    @Published var history: [HistoryItem] = []

    // Smart mode (Apple Intelligence second pass)
    @Published var isRefining = false
    @Published var smart: SmartResult?
    @Published var smartEnabled: Bool { didSet { UserDefaults.standard.set(smartEnabled, forKey: "smart") } }
    @Published var formality: Formality { didSet { UserDefaults.standard.set(formality.rawValue, forKey: "formality") } }
    @Published var variety: SpanishVariety { didSet { UserDefaults.standard.set(variety.rawValue, forKey: "variety") } }
    private var draft = ""

    private let historyURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("history.json")

    init() {
        let d = UserDefaults.standard
        let s = Lang.find(d.string(forKey: "source")) ?? .spanish
        var t = Lang.find(d.string(forKey: "target")) ?? .english
        if s == t { t = s == .english ? .spanish : .english }
        source = s
        target = t
        smartEnabled = d.object(forKey: "smart") as? Bool ?? true
        formality = Formality(rawValue: d.string(forKey: "formality") ?? "") ?? .auto
        variety = SpanishVariety(rawValue: d.string(forKey: "variety") ?? "") ?? .latinAmerica
        loadHistory()
    }

    /// Changes whenever a new translation is needed.
    var requestKey: String { "\(source.code)|\(target.code)|\(input)" }

    /// Changes whenever only the smart second pass needs to run again.
    var smartKey: String { "\(smartEnabled)|\(formality.rawValue)|\(variety.rawValue)" }

    var smartAvailable: Bool { SmartTranslator.isAvailable }

    var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Translation

    func translate(with session: TranslationSession) async {
        let text = trimmedInput
        guard !text.isEmpty else { output = ""; return }
        isTranslating = true
        defer { isTranslating = false }
        do {
            let response = try await session.translate(text)
            guard text == trimmedInput else { return }
            draft = response.targetText
            output = response.targetText
            smart = nil
            errorText = nil
            isTranslating = false
            await refine()
        } catch {
            await refreshStatus()
            if status == .installed {
                errorText = "Couldn't translate that. Try again."
            } else if status == .unsupported {
                errorText = "\(source.name) → \(target.name) can't be translated on this iPhone."
            } else {
                errorText = "Download \(source.name) and \(target.name) to translate offline."
            }
        }
    }

    /// Runs the Apple Intelligence pass on the current draft (if turned on and supported).
    func refine() async {
        let text = trimmedInput
        let base = draft
        guard smartEnabled, smartAvailable, !text.isEmpty, !base.isEmpty else {
            if !base.isEmpty { output = base }
            smart = nil
            return
        }
        isRefining = true
        let result = await SmartTranslator.refine(text: text, draft: base, from: source, to: target,
                                                  formality: formality, variety: variety)
        isRefining = false
        guard text == trimmedInput, base == draft else { return }
        if let result {
            smart = result
            output = result.translation
        }
    }

    func useAlternative(_ alt: String) {
        guard var s = smart else { return }
        s.alternatives.removeAll { $0 == alt }
        s.alternatives.insert(output, at: 0)
        s.translation = alt
        smart = s
        output = alt
    }

    func refreshStatus() async {
        status = await LanguageAvailability().status(from: source.language, to: target.language)
    }

    func swap() {
        let oldSource = source
        source = target
        target = oldSource
        if !output.isEmpty {
            let oldInput = input
            input = output
            output = oldInput
            draft = oldInput
        }
        smart = nil
        suggestion = nil
    }

    func select(_ lang: Lang, forSource: Bool) {
        if forSource {
            if lang == target { swap() } else { source = lang }
        } else {
            if lang == source { swap() } else { target = lang }
        }
    }

    func clear() {
        input = ""
        output = ""
        draft = ""
        smart = nil
        errorText = nil
    }

    // MARK: Language detection ("Translate from Spanish?")

    private func inputChanged() {
        if trimmedInput.isEmpty { output = ""; draft = ""; smart = nil; errorText = nil; suggestion = nil; return }
        guard trimmedInput.count >= 6 else { suggestion = nil; return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedInput)
        let guesses = recognizer.languageHypotheses(withMaximum: 2)
        guard let best = guesses.max(by: { $0.value < $1.value }), best.value > 0.75,
              let lang = Lang.find(best.key.rawValue), lang != source else {
            suggestion = nil
            return
        }
        suggestion = lang
    }

    func useSuggestion() {
        guard let s = suggestion else { return }
        if s == target { swapLanguagesOnly() } else { source = s }
        suggestion = nil
    }

    private func swapLanguagesOnly() {
        let oldSource = source
        source = target
        target = oldSource
    }

    // MARK: History

    func commitHistory() {
        let text = trimmedInput
        guard !text.isEmpty, !output.isEmpty else { return }
        var item = HistoryItem(source: source.code, target: target.code, input: text, output: output)
        if let first = history.first, first.source == item.source, first.target == item.target,
           text.hasPrefix(first.input) || first.input.hasPrefix(text) {
            item.id = first.id
            item.starred = first.starred
            history[0] = item
        } else if let i = history.firstIndex(where: { $0.input == text && $0.source == item.source && $0.target == item.target }) {
            item.starred = history[i].starred
            history.remove(at: i)
            history.insert(item, at: 0)
        } else {
            history.insert(item, at: 0)
        }
        if history.count > 300 {
            history = Array(history.prefix(300)) + history.dropFirst(300).filter(\.starred)
        }
        saveHistory()
    }

    func load(_ item: HistoryItem) {
        if let s = Lang.find(item.source) { source = s }
        if let t = Lang.find(item.target) { target = t }
        input = item.input
        output = item.output
        draft = item.output
        smart = nil
        suggestion = nil
    }

    func toggleStar(_ item: HistoryItem) {
        guard let i = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[i].starred.toggle()
        saveHistory()
    }

    /// Stars the current translation (adds it to history first if needed).
    func toggleStarCurrent() {
        commitHistory()
        if let first = history.first { toggleStar(first) }
    }

    var currentIsStarred: Bool {
        guard let first = history.first else { return false }
        return first.starred && first.input == trimmedInput && first.output == output
    }

    func delete(_ item: HistoryItem) {
        history.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll { !$0.starred }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        history = items
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch {
            print("History save failed: \(error)")
        }
    }
}
