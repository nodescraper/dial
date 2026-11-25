import AVFoundation
import Observation
import Speech

/// Hold-to-talk for the DJ: records while the button is held and turns speech into text,
/// on the device when it supports that.
@MainActor
@Observable
final class VoiceRequest {
    private(set) var isListening = false
    /// What's been heard so far, shown while you talk.
    private(set) var transcript = ""
    var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?

    /// Starts listening. Returns false if permission was refused or speech isn't available.
    func start() async -> Bool {
        guard !isListening else { return true }
        guard await Self.permissions() else {
            errorMessage = "To talk to the DJ, allow the microphone and speech recognition in Settings."
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return false
        }
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            cleanUp()
            return false
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.finished?.resume(); self.finished = nil }
            }
        }
        isListening = true
        return true
    }

    /// Stops listening and returns what was said.
    func stop() async -> String {
        guard isListening else { return transcript }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Give the recognizer a moment to finish the last words.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in self.finished = continuation }
            }
            group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
            await group.next()
            group.cancelAll()
        }
        finished?.resume()
        finished = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanUp()
        return text
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        // Back to normal playback.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private static func permissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
