import SwiftUI
import Translation
import UIKit

// MARK: - Colors (Google-Translate-like palette, light + dark)

extension Color {
    static let brandBlue = Color(red: 26/255, green: 115/255, blue: 232/255)
    static let outputCard = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.17, blue: 0.27, alpha: 1)
            : UIColor(red: 0.91, green: 0.94, blue: 0.996, alpha: 1)
    })
    static let outputText = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.66, green: 0.78, blue: 0.98, alpha: 1)
            : UIColor(red: 0.07, green: 0.28, blue: 0.62, alpha: 1)
    })
    static let pill = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.17, green: 0.18, blue: 0.20, alpha: 1)
            : UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    })
}

// MARK: - Main screen

struct ContentView: View {
    @EnvironmentObject var model: TranslatorModel
    @EnvironmentObject var speech: SpeechManager
    @FocusState private var inputFocused: Bool

    @State private var config: TranslationSession.Configuration?
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var picking: PickSide?
    @State private var showSaved = false
    @State private var showSettings = false
    @State private var copied = false

    enum PickSide: String, Identifiable { case source, target; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        inputSection
                        if let err = model.errorText {
                            errorCard(err)
                        } else if !model.output.isEmpty || model.isTranslating {
                            outputCard
                        }
                        if model.input.isEmpty {
                            offlineCard
                            historySection
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)

                bottomBar
                    .translationTask(downloadConfig) { session in
                        do { try await session.prepareTranslation() } catch { }
                        await model.refreshStatus()
                    }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSaved = true } label: { Image(systemName: "star") }
                        .accessibilityLabel("Saved")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { inputFocused = false; model.commitHistory() }
                }
            }
            .sheet(item: $picking) { side in
                LanguagePicker(selected: side == .source ? model.source : model.target,
                               title: side == .source ? "Translate from" : "Translate to") { lang in
                    model.select(lang, forSource: side == .source)
                }
            }
            .sheet(isPresented: $showSaved) { SavedView() }
            .sheet(isPresented: $showSettings) { SettingsView(download: startDownload) }
            .alert("Microphone", isPresented: Binding(get: { speech.message != nil },
                                                     set: { if !$0 { speech.message = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(speech.message ?? "") }
        }
        .tint(.brandBlue)
        // Debounced translation whenever the text or languages change.
        .task(id: model.requestKey) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard !model.trimmedInput.isEmpty else { return }
            if let c = config, c.source == model.source.language, c.target == model.target.language {
                config?.invalidate()
            } else {
                config = TranslationSession.Configuration(source: model.source.language,
                                                          target: model.target.language)
            }
        }
        .translationTask(config) { session in
            await model.translate(with: session)
        }
        // Re-run only the smart pass when formality / region / smart toggle change.
        .task(id: model.smartKey) {
            guard !model.output.isEmpty else { return }
            await model.refine()
        }
        // Save to history once the user pauses.
        .task(id: model.output) {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            model.commitHistory()
        }
        .task(id: "\(model.source.code)|\(model.target.code)") {
            await model.refreshStatus()
        }
    }

    private func startDownload() {
        if let c = downloadConfig, c.source == model.source.language, c.target == model.target.language {
            downloadConfig?.invalidate()
        } else {
            downloadConfig = TranslationSession.Configuration(source: model.source.language,
                                                              target: model.target.language)
        }
    }

    // MARK: Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.source.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.input.isEmpty {
                    Button { model.clear(); inputFocused = true } label: {
                        Image(systemName: "xmark").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear")
                }
            }

            TextField("Enter text", text: $model.input, axis: .vertical)
                .font(.system(size: 28))
                .lineLimit(2...12)
                .focused($inputFocused)
                .autocorrectionDisabled(false)

            if let s = model.suggestion {
                Button { model.useSuggestion() } label: {
                    (Text("Translate from ").foregroundColor(.secondary) + Text(s.name).foregroundColor(.brandBlue).bold())
                        .font(.subheadline)
                }
            }

            if !model.trimmedInput.isEmpty {
                HStack(spacing: 20) {
                    speakButton(text: model.trimmedInput, lang: model.source, id: "input", tint: .secondary)
                    Spacer()
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: Output

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(model.target.name)
                    .font(.subheadline.weight(.medium))
                if model.smart != nil {
                    Label("Improved", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.brandBlue.opacity(0.15), in: Capsule())
                } else if model.isRefining {
                    ProgressView().controlSize(.mini)
                    Text("Improving…").font(.caption)
                }
                Spacer()
            }
            .foregroundStyle(Color.outputText)

            if model.output.isEmpty {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(model.output)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.outputText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: model.output)
            }

            if model.smartEnabled && model.smartAvailable {
                formalityPicker
            }

            HStack(spacing: 22) {
                speakButton(text: model.output, lang: model.target, id: "output", tint: .outputText)
                Spacer()
                Button {
                    UIPasteboard.general.string = model.output
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("Copy")
                ShareLink(item: model.output) { Image(systemName: "square.and.arrow.up") }
                Button { model.toggleStarCurrent() } label: {
                    Image(systemName: model.currentIsStarred ? "star.fill" : "star")
                }
                .accessibilityLabel("Save")
            }
            .font(.title3)
            .foregroundStyle(Color.outputText)

            if let smart = model.smart {
                smartExtras(smart)
            }
        }
        .padding(18)
        .background(Color.outputCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var formalityPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Formality.allCases) { f in
                    Button { model.formality = f } label: {
                        Text(f.label(for: model.target))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(model.formality == f ? Color.brandBlue : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(Color.outputText.opacity(0.35), lineWidth: model.formality == f ? 0 : 1))
                            .foregroundStyle(model.formality == f ? Color.white : Color.outputText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func smartExtras(_ smart: SmartResult) -> some View {
        if !smart.alternatives.isEmpty || smart.note != nil {
            Divider().overlay(Color.outputText.opacity(0.2))
        }
        if !smart.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other ways to say it")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.outputText.opacity(0.8))
                ForEach(smart.alternatives, id: \.self) { alt in
                    Button { model.useAlternative(alt) } label: {
                        HStack(alignment: .top) {
                            Text(alt).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left").font(.caption)
                        }
                        .font(.body)
                        .foregroundStyle(Color.outputText)
                        .padding(10)
                        .background(Color.outputText.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        if let note = smart.note {
            Label { Text(note) } icon: { Image(systemName: "lightbulb") }
                .font(.footnote)
                .foregroundStyle(Color.outputText.opacity(0.9))
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(text, systemImage: "arrow.down.circle")
                .font(.body)
            if model.status == .supported {
                Button("Download languages", action: startDownload)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: Offline status

    @ViewBuilder
    private var offlineCard: some View {
        switch model.status {
        case .some(.installed):
            Label("\(model.source.name) and \(model.target.name) work offline", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .some(.supported):
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down").font(.title2).foregroundStyle(Color.brandBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate offline").font(.subheadline.weight(.semibold))
                    Text("Download \(model.source.name) and \(model.target.name) once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download", action: startDownload).buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.pill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .some(.unsupported):
            Label("This language pair isn't available on iPhone.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if !model.history.isEmpty {
            Text("History")
                .font(.headline)
                .padding(.top, 6)
            ForEach(model.history.prefix(40)) { item in
                HistoryRow(item: item) { model.load(item) }
                    .contextMenu {
                        Button { model.toggleStar(item) } label: {
                            Label(item.starred ? "Remove from Saved" : "Save", systemImage: "star")
                        }
                        Button { UIPasteboard.general.string = item.output } label: {
                            Label("Copy translation", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) { model.delete(item) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: Bottom bar (language pills + mic)

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                langPill(model.source) { picking = .source }
                Button {
                    withAnimation(.spring(duration: 0.3)) { model.swap() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Swap languages")
                langPill(model.target) { picking = .target }
            }

            Button {
                inputFocused = false
                Task {
                    await speech.toggleListening(lang: model.source) { text in
                        model.input = text
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(speech.isListening ? Color.red : Color.brandBlue)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    if speech.isListening {
                        Circle()
                            .stroke(Color.red.opacity(0.35), lineWidth: 6)
                            .frame(width: 86, height: 86)
                            .phaseAnimator([0.9, 1.1]) { v, s in v.scaleEffect(s) } animation: { _ in .easeInOut(duration: 0.6) }
                    }
                    Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(height: 88)
            }
            .accessibilityLabel(speech.isListening ? "Stop listening" : "Speak")

            if speech.isListening {
                Text("Speak now in \(model.source.name)…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func langPill(_ lang: Lang, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(lang.name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.brandBlue)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.pill, in: Capsule())
        }
    }

    private func speakButton(text: String, lang: Lang, id: String, tint: Color) -> some View {
        Button { speech.speak(text, lang: lang, id: id) } label: {
            Image(systemName: speech.speakingID == id ? "stop.circle" : "speaker.wave.2")
                .font(.title3)
                .foregroundStyle(tint)
        }
        .accessibilityLabel("Listen")
    }
}

// MARK: - History row

struct HistoryRow: View {
    @EnvironmentObject var model: TranslatorModel
    let item: HistoryItem
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Lang.find(item.source)?.name ?? item.source) → \(Lang.find(item.target)?.name ?? item.target)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(item.input).font(.body).foregroundStyle(.primary).lineLimit(2)
                    Text(item.output).font(.body).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            }
            Button { model.toggleStar(item) } label: {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .foregroundStyle(item.starred ? Color.brandBlue : Color.secondary)
            }
        }
        .padding(14)
        .background(Color.pill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Language picker

struct LanguagePicker: View {
    let selected: Lang
    let title: String
    let onPick: (Lang) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Lang] {
        search.isEmpty ? Lang.all : Lang.all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { lang in
                Button {
                    onPick(lang)
                    dismiss()
                } label: {
                    HStack {
                        Text(lang.name).foregroundStyle(.primary)
                        Spacer()
                        if lang == selected {
                            Image(systemName: "checkmark").foregroundStyle(Color.brandBlue)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search languages")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Saved

struct SavedView: View {
    @EnvironmentObject var model: TranslatorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let saved = model.history.filter(\.starred)
                if saved.isEmpty {
                    ContentUnavailableView("No saved translations",
                                           systemImage: "star",
                                           description: Text("Tap the star on a translation to save it here."))
                } else {
                    List {
                        ForEach(saved) { item in
                            Button {
                                model.load(item)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.input).foregroundStyle(.primary)
                                    Text(item.output).foregroundStyle(Color.brandBlue)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { model.toggleStar(item) } label: {
                                    Label("Remove", systemImage: "star.slash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: TranslatorModel
    @Environment(\.dismiss) private var dismiss
    let download: () -> Void
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $model.smartEnabled) {
                        Label("Smart translation", systemImage: "sparkles")
                    }
                    .disabled(!model.smartAvailable)
                    if model.smartAvailable {
                        Picker("Formality", selection: $model.formality) {
                            ForEach(Formality.allCases) { Text($0.label(for: .spanish)).tag($0) }
                        }
                        Picker("Spanish from", selection: $model.variety) {
                            ForEach(SpanishVariety.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } footer: {
                    Text(model.smartAvailable
                         ? "Uses Apple Intelligence on your iPhone to make translations sound natural, and suggests other ways to say things. Works offline."
                         : "Smart translation: \(SmartTranslator.unavailableReason) Regular offline translation still works.")
                }

                Section {
                    HStack {
                        Text("\(model.source.name) ⇄ \(model.target.name)")
                        Spacer()
                        switch model.status {
                        case .some(.installed): Text("Downloaded").foregroundStyle(.green)
                        case .some(.supported): Button("Download") { dismiss(); download() }
                        case .some(.unsupported): Text("Not available").foregroundStyle(.secondary)
                        default: ProgressView()
                        }
                    }
                } header: {
                    Text("Offline languages")
                } footer: {
                    Text("Downloaded languages are also managed in iPhone Settings › Apps › Translate › Downloaded Languages.")
                }

                Section {
                    Button("Clear history", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Saved (starred) translations are kept.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Clear history?", isPresented: $confirmClear) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            }
            .task { await model.refreshStatus() }
        }
    }
}
