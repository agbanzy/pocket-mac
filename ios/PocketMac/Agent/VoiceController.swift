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
///
/// ## The isolation rule (this has crashed three shipped builds)
///
/// Every closure handed to AVFoundation, Speech, or TCC **must** be created from a `nonisolated`
/// context. Written inline in a method of this `@MainActor` type, a closure silently inherits main
/// actor isolation; Swift 6 then asserts the executor when the framework runs it, and since these
/// frameworks call back on background queues — or, for the audio tap, on the realtime render thread
/// — the assertion trips and takes the process down with `dispatch_assert_queue_fail`.
///
/// `SWIFT_STRICT_CONCURRENCY: complete` does **not** catch this. `AVAudioNodeTapBlock` and friends
/// are unannotated Objective-C typealiases, so the compiler sees a synchronous call in the same
/// isolation domain and stays silent. The `nonisolated static` helpers below are the whole defence.
/// If you add another framework callback, add another helper — do not write the closure inline.
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
    ///
    /// **`nonisolated` is load-bearing.** In a `@MainActor` type, a completion closure inherits main
    /// actor isolation, and Swift 6 then asserts the executor when it runs. TCC delivers these
    /// callbacks on a background queue, so that assertion traps and kills the process. Marking the
    /// method `nonisolated` keeps the closure off the main actor; anything touching state hops back
    /// explicitly.
    nonisolated func primePermissions() {
        Self.requestAuthorizations { _, _ in }
    }

    /// Request speech + microphone access, reporting `(granted, problem)` on an arbitrary queue.
    /// Static and `@Sendable` so no isolated `self` is captured.
    private nonisolated static func requestAuthorizations(
        _ done: @escaping @Sendable (Bool, String?) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                done(false, "Speech recognition is off. Settings ▸ Pocket Mac ▸ Speech Recognition.")
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                done(granted,
                     granted ? nil : "Microphone access is off. Settings ▸ Pocket Mac ▸ Microphone.")
            }
        }
    }

    /// Build the recognition task off the main actor. `onUpdate` receives the transcript so far and
    /// whether the task has ended (final result or error).
    private nonisolated static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onUpdate(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil { onUpdate(nil, true) }
        }
    }

    /// Install the microphone tap that feeds the recogniser.
    ///
    /// **`nonisolated` is load-bearing.** AVFAudio invokes this block on its realtime audio render
    /// thread, once per buffer. Written inline in a `@MainActor` method it inherits main actor
    /// isolation and traps on the very first buffer — which is precisely what killed build 12 the
    /// moment the mic button was tapped. Nothing here touches isolated state; it only forwards the
    /// buffer to the request, which is safe to feed from the audio thread.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        feeding request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
        // The callback arrives on a background queue (see `primePermissions`), so hop to the main
        // actor before touching any state.
        Self.requestAuthorizations { granted, problem in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.micDenied = !granted
                self.problem = problem
                if granted { self.startDictation() }
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

            // Everything past this point initialises the remote IO audio unit, and when no input
            // hardware answers the RPC, AudioToolbox calls `abort()` inside `AURemoteIO::Initialize`
            // — a process kill Swift cannot catch. So the checks have to happen *before* the engine
            // is touched, and they have to be checks that are actually true.
            //
            // The Simulator is excluded outright. It reports `isInputAvailable == true` and then
            // aborts anyway on `engine.inputNode`, so no session-level property can be trusted to
            // predict it; only the build environment can. Dictation is device-only by nature.
            #if targetEnvironment(simulator)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            problem = "Dictation needs a real device — the Simulator has no microphone."
            return
            #else
            // On device, an empty input route means nothing is there to record from.
            guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                problem = "No microphone is available right now."
                return
            }

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

            Self.installTap(on: input, format: format, feeding: request)
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            transcript = ""
            phase = .listening

            // Same isolation rule as the permission callbacks: the result handler must not inherit
            // main-actor isolation, or Swift 6 asserts the executor on whichever queue Speech uses.
            task = Self.makeTask(recognizer: recognizer, request: request) { text, finished in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text {
                        self.transcript = text
                        self.onTranscript?(text)
                    }
                    if finished { self.stopDictation() }
                }
            }
            #endif
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
