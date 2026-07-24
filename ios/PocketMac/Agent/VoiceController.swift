import AVFoundation
import Observation
import Speech
import SwiftUI

/// Voice for the Ask surface: dictate a task instead of typing it, and hear the outcome spoken back.
///
/// Both halves are deliberately conservative. Dictation streams partial results straight into the
/// prompt so you can see it forming and correct it before running — a task that drives your Mac
/// should never be fired off from a transcript you haven't read. Speech is limited to the events
/// worth interrupting you for, not every step, so the agent narrates rather than chatters.
@MainActor
@Observable
final class VoiceController {
    /// Live dictation state, drives the mic button.
    private(set) var isListening = false
    /// Set when a permission is refused or the recognizer fails, so the UI can explain itself.
    private(set) var problem: String?
    /// Speak task outcomes aloud. Off by default: audio is intrusive, so it's opt-in.
    var speaksResults: Bool {
        get { UserDefaults.standard.bool(forKey: Self.speakKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.speakKey) }
    }

    private static let speakKey = "com.innoedge.pocketmac.speakResults"

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    /// Held as main-actor state rather than passed through the permission callbacks: the system
    /// hands those back on arbitrary queues, and Swift 6 rightly refuses to let a UI-mutating
    /// closure cross that boundary.
    private var onTranscript: ((String) -> Void)?

    // MARK: Dictation

    /// Toggle dictation. `onText` receives the running transcript, partials included.
    func toggleDictation(onText: @escaping (String) -> Void) {
        if isListening {
            stopDictation()
        } else {
            onTranscript = onText
            startDictation()
        }
    }

    private func startDictation() {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.problem = "Speech recognition is off. Enable it in Settings ▸ Pocket Mac."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.problem = "Microphone access is off. Enable it in Settings ▸ Pocket Mac."
                            return
                        }
                        self.beginCapture()
                    }
                }
            }
        }
    }

    private func beginCapture() {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available on this device right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audio.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            audio.prepare()
            try audio.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.onTranscript?(result.bestTranscription.formattedString)
                        if result.isFinal { self.stopDictation() }
                    }
                    if error != nil { self.stopDictation() }
                }
            }
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            stopDictation()
        }
    }

    func stopDictation() {
        audio.inputNode.removeTap(onBus: 0)
        if audio.isRunning { audio.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        onTranscript = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Speech

    /// Speak an outcome. Silently ignored unless the user turned speech on.
    func speak(_ text: String) {
        guard speaksResults, !text.isEmpty else { return }
        // Don't stack utterances if several events land together.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
}
