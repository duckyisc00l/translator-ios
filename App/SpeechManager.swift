import AVFoundation
import Speech

/// Text-to-speech (offline voices) and on-device speech-to-text.
@MainActor
final class SpeechManager: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var speakingID: String?
    @Published var message: String?

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Speaking

    func speak(_ text: String, lang: Lang, id: String) {
        if speakingID == id {
            synth.stopSpeaking(at: .immediate)
            speakingID = nil
            return
        }
        stopListening()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        synth.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice(for: lang)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        speakingID = id
        currentUtterance = utterance
        synth.speak(utterance)
    }

    private func bestVoice(for lang: Lang) -> AVSpeechSynthesisVoice? {
        let prefix = lang.speechCode.prefix(2)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        // Prefer the exact region, then the nicest quality installed.
        let ranked = voices.sorted {
            let a = ($0.language == lang.speechCode ? 1 : 0, $0.quality.rawValue)
            let b = ($1.language == lang.speechCode ? 1 : 0, $1.quality.rawValue)
            return a > b
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: lang.speechCode)
    }

    // MARK: Listening

    func toggleListening(lang: Lang, onText: @escaping (String) -> Void) async {
        if isListening { stopListening(); return }
        await startListening(lang: lang, onText: onText)
    }

    private func startListening(lang: Lang, onText: @escaping (String) -> Void) async {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else {
            message = "Allow Speech Recognition in Settings to use the microphone."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Allow Microphone access in Settings to speak."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang.speechCode)),
              recognizer.isAvailable else {
            message = "Voice input isn't available for \(lang.name)."
            return
        }

        synth.stopSpeaking(at: .immediate)
        speakingID = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(req))
            engine.prepare()
            try engine.start()

            request = req
            isListening = true
            resetSilenceTimer()

            task = recognizer.recognitionTask(with: req, resultHandler: Self.resultHandler { [weak self] text, done in
                guard let self else { return }
                if let text, !text.isEmpty {
                    onText(text)
                    self.resetSilenceTimer()
                }
                if done { self.stopListening() }
            })
        } catch {
            message = "Couldn't start the microphone."
            stopListening()
        }
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard isListening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stop automatically after 2.5 seconds without new words.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening() }
        }
    }

    // Built outside the main actor because the audio/speech callbacks run on background threads.
    nonisolated private static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ handle: @escaping @MainActor (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in handle(text, done) }
        }
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    nonisolated private func finished(_ id: ObjectIdentifier) {
        Task { @MainActor in
            if let current = self.currentUtterance, ObjectIdentifier(current) == id {
                self.speakingID = nil
                self.currentUtterance = nil
            }
        }
    }
}
