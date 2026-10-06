import Foundation
import AVFoundation
import Speech

/// Hold-free voice question: tap to start, stops on a second tap, 1.5 s of silence, or 15 s.
/// Replaces PocketTourGuide's always-on wake word (mic live from launch, no backoff).
@MainActor
final class QuestionRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var limitTimer: Timer?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func toggle() { if isRecording { stop() } else { Task { await start() } } }

    func start() async {
        error = nil
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else { error = "Allow the microphone and speech recognition in Settings to ask by voice."; return }
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now."; return }
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString; self.armSilence() }
                    if err != nil || result?.isFinal == true { self.stop() }
                }
            }
            limitTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    private func armSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        silenceTimer?.invalidate(); limitTimer?.invalidate()
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); task?.finish()
        request = nil; task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
