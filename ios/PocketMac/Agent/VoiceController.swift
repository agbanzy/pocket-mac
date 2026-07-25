import AVFoundation
import Observation
import Speech
import SwiftUI

/// Voice for the Ask surface: dictate a task, and hear the outcome spoken back.
///
/// ## Why this is written defensively
///
/// `AVAudioEngine.installTap` throws an **Objective-C** exception on an invalid format, which Swift
/// cannot catch — it terminates the app. The engine also caches its input node's format when it is
/// created, so an engine built before the audio session is configured reports 0 Hz / 0 channels and
/// takes the app down the first time you tap the microphone. Hence two rules here:
///
/// 1. the engine is built **per session, after** the audio session is active, never held as a
///    long-lived property, and
/// 2. the format is **validated** before installing a tap, because validation is the only defence
///    available against an uncatchable exception.
///
/// Playback and recording also cannot share one session configuration: speaking while listening
/// reconfigures the route underneath a running engine. Speech is therefore deferred while dictating.
@MainActor
@Observable
final class VoiceController {

    /// What the assistant is doing, so the UI can show one honest state rather than guessing.
    enum Phase: Equatable {
        case idle, listening, speaking
    }

    private(set) var phase: Phase = .idle
    /// Live transcript while dictating, so you can see it forming and correct it.
    private(set) var transcript = ""
    /// Set when a permission is refused or audio fails, so the UI can explain itself.
    private(set) var problem: String?
    /// Whether the mic can be offered at all (permissions granted or still undetermined).
    private(set) var micDenied = false

    var isListening: Bool { phase == .listening }

    /// Speak task outcomes aloud. Off by default: audio is intrusive, so it is opt-in.
    var speaksResults: Bool {
        get { UserDefaults.standard.bool(forKey: Self.speakKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.speakKey) }
    }
    private static let speakKey = "com.innoedge.pocketmac.speakResults"

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let synthesizer = AVSpeechSynthesizer()

    // Built per dictation session — never held across one. See the note above.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onTranscript: ((String) -> Void)?
    /// An outcome that arrived while dictating; spoken once the mic is free.
    private var pendingSpeech: String?

    // MARK: Permissions

    /// Ask for both permissions up front, so the first tap on the mic doesn't stall behind two
    /// system dialogs. Safe to call repeatedly.
    func primePermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVAudioApplication.requestRecordPermission { _ in }
        }
    }

    private var speechAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private var micAuthorized: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: Dictation

    /// Toggle dictation. `onText` receives the running transcript, partials included.
    func toggleDictation(onText: @escaping (String) -> Void) {
        if phase == .listening {
            stopDictation()
        } else {
            onTranscript = onText
            requestThenStart()
        }
    }

    private func requestThenStart() {
        problem = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.micDenied = true
                    self.problem = "Speech recognition is off. Settings ▸ Pocket Mac ▸ Speech Recognition."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.micDenied = true
                            self.problem = "Microphone access is off. Settings ▸ Pocket Mac ▸ Microphone."
                            return
                        }
                        self.micDenied = false
                        self.startDictation()
                    }
                }
            }
        }
    }

    private func startDictation() {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn’t available right now."
            return
        }
        // Never let the synthesiser and the engine own the session at the same time.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Built AFTER the session is active, so the input node reports the real hardware format.
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)

            // The one check that prevents an uncatchable crash: a 0 Hz or 0-channel format means the
            // route isn't ready, and installTap would raise an ObjC exception and kill the app.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                problem = "The microphone isn’t available — another app may be using it."
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            transcript = ""
            phase = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.onTranscript?(self.transcript)
                        if result.isFinal { self.stopDictation() }
                    }
                    if error != nil { self.stopDictation() }
                }
            }
        } catch {
            problem = "Couldn’t start the microphone: \(error.localizedDescription)"
            teardown()
        }
    }

    func stopDictation() {
        teardown()
        phase = .idle
        // An outcome that landed mid-dictation gets its turn now that the route is free.
        if let pending = pendingSpeech {
            pendingSpeech = nil
            speak(pending)
        }
    }

    private func teardown() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        onTranscript = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Speech

    /// Speak an outcome. Ignored unless speech is on; deferred while dictating, because
    /// reconfiguring the session for playback would pull the route out from under a live engine.
    func speak(_ text: String) {
        guard speaksResults, !text.isEmpty else { return }
        guard phase != .listening else {
            pendingSpeech = text
            return
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        } catch {
            return // speaking is a nicety; never let it take the app down
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        phase = .speaking
        synthesizer.speak(utterance)
        // The synthesiser has no simple completion here; return to idle when it finishes.
        Task { @MainActor in
            while synthesizer.isSpeaking { try? await Task.sleep(nanoseconds: 200_000_000) }
            if phase == .speaking { phase = .idle }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if phase == .speaking { phase = .idle }
    }
}
