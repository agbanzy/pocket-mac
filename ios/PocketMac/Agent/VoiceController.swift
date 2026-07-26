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

    /// Listen continuously for a wake phrase, so a task can be started without touching the phone.
    ///
    /// **Off by default, and deliberately so.** It holds the microphone open for as long as the app
    /// is in front, which costs battery and means the app is always hearing the room — neither is
    /// something to switch on for somebody. Recognition is pinned on-device (see
    /// ``startWakeListening()``) so nothing is streamed to Apple while it waits.
    var wakePhraseEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.wakeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.wakeKey)
            if newValue { startWakeListening() } else { stopWakeListening() }
        }
    }
    private static let wakeKey = "com.innoedge.pocketmac.wakePhrase"

    /// What has to be heard. Two words, both common enough to be recognised reliably but unlikely
    /// together in ordinary speech — a single common word would fire constantly.
    static let wakePhrase = "hey mac"

    /// True while the wake listener holds the microphone.
    private(set) var isAwaitingWake = false

    /// Consecutive failed restarts, so a recogniser that always errors cannot spin forever.
    private var wakeRestarts = 0
    private static let maxWakeRestarts = 5

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let synthesizer = AVSpeechSynthesizer()

    // Built per dictation session — never held across one. See the note above.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onTranscript: ((String) -> Void)?
    /// An outcome that arrived while dictating; spoken once the mic is free.
    private var pendingSpeech: String?

    /// Called when the wake phrase is heard, so the surface can start dictating a task.
    var onWake: (() -> Void)?

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

    /// Prime once per launch. `primePermissions` is cheap to call but not free — two XPC round-trips
    /// to TCC — and it was being called on every return to the Ask tab for an answer the system
    /// already had. Once both answers are known there is nothing left to ask.
    func primePermissionsIfNeeded() {
        guard !(speechAuthorized && micAuthorized) else { return }
        primePermissions()
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
        stopWakeListening()   // the microphone cannot be shared; dictation takes precedence
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
        // requestThenStart() stopped the listener, but an async permission round-trip happened since
        // and speak()'s completion can legitimately re-arm it in that gap. Two engines with taps on
        // one session is the state that used to take the app down, so stand it down again here.
        stopWakeListening()
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

    // MARK: Wake phrase

    /// Begin listening for the wake phrase.
    ///
    /// Shares the same engine plumbing as dictation, with two differences that matter:
    /// `requiresOnDeviceRecognition` keeps the audio on the phone — a listener that ships every
    /// sound in the room to a server is not something to run continuously — and the recogniser is
    /// restarted after each hit, because a recognition task ends once it reports a final result.
    ///
    /// Only ever runs while nothing else owns the microphone. The mic cannot be shared, so wake
    /// listening yields to dictation and to speech, and is resumed by whichever finishes last.
    func startWakeListening() {
        guard wakePhraseEnabled, phase == .idle, !isAwaitingWake else { return }
        // `requiresOnDeviceRecognition` below is a hard requirement, not a preference: a listener
        // that ships every sound in the room to a server is not something to run continuously. If
        // the model for this locale has not been downloaded, recognition fails immediately — and
        // since a failed task reports "finished", restarting on finish would spin a hot loop
        // building an audio engine thousands of times a second. Check support up front.
        guard let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition,
              speechAuthorized, micAuthorized else {
            problem = wakePhraseEnabled
                ? "Hands-free needs on-device dictation for \(Locale.current.identifier), which "
                + "isn't downloaded. Settings ▸ General ▸ Keyboard ▸ Dictation."
                : nil
            return
        }
        #if targetEnvironment(simulator)
        return   // no capture path here; see the note in startDictation()
        #else
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else { return }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true

            Self.installTap(on: input, format: format, feeding: request)
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.request = request
            isAwaitingWake = true

            let phrase = Self.wakePhrase
            task = Self.makeTask(recognizer: recognizer, request: request) { text, finished in
                let heard = text?.lowercased().contains(phrase) ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.isAwaitingWake else { return }
                    if heard {
                        self.wakeRestarts = 0
                        self.stopWakeListening()
                        self.onWake?()
                    } else if finished {
                        // A recognition task also reports "finished" when it ERRORS, so restarting
                        // unconditionally is how a hot loop starts. Back off, and give up after a
                        // few consecutive failures rather than burning the battery in silence.
                        self.stopWakeListening()
                        self.wakeRestarts += 1
                        guard self.wakeRestarts <= Self.maxWakeRestarts else {
                            self.problem = "Hands-free listening kept failing, so it stopped. "
                                         + "Turn it off and on again to retry."
                            return
                        }
                        let delay = UInt64(self.wakeRestarts) * 500_000_000
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: delay)
                            self?.startWakeListening()
                        }
                    }
                }
            }
        } catch {
            isAwaitingWake = false
            teardown()
        }
        #endif
    }

    func stopWakeListening() {
        guard isAwaitingWake else { return }
        isAwaitingWake = false
        teardown()
    }

    func stopDictation() {
        teardown()
        phase = .idle
        // Hand the microphone back to the wake listener, if that is what the user asked for.
        defer { startWakeListening() }
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
        // Playback and recording cannot hold the session at once, so the wake listener stands down
        // for the length of the sentence and is resumed below.
        stopWakeListening()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        } catch {
            // Speaking is a nicety; never let it take the app down — but the wake listener was torn
            // down a few lines above and only the success path restores it, so put it back here too.
            startWakeListening()
            return
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
            startWakeListening()
        }
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if phase == .speaking { phase = .idle }
    }
}
