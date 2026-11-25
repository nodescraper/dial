import Accelerate
import AudioToolbox
import AVFoundation
import MediaToolbox
import Observation
import os

#if targetEnvironment(macCatalyst)
fileprivate struct UnsafeMutableAudioBufferListPointer: Sequence {
    private let buffers: UnsafeMutablePointer<AudioBuffer>
    private let count: Int

    init(_ list: UnsafeMutablePointer<AudioBufferList>) {
        count = Int(list.pointee.mNumberBuffers)
        // The buffers start after the count and its padding (8 bytes, since an AudioBuffer holds a pointer), not right after the 4-byte
        // count: reading from 4 gave garbage pointers and crashed the app in the equalizer.
        buffers = UnsafeMutableRawPointer(list)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8)
            .assumingMemoryBound(to: AudioBuffer.self)
    }

    func makeIterator() -> IndexingIterator<[AudioBuffer]> {
        (0..<count).map { buffers[$0] }.makeIterator()
    }
}
#endif

/// A 10-band graphic equalizer. Settings live here; the audio work happens in `EqualizerTap`.
@MainActor
@Observable
final class Equalizer {
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// How far each band can go, in decibels.
    static let range: ClosedRange<Float> = -12...12

    struct Preset: Identifiable, Hashable {
        let name: String
        let gains: [Float]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        Preset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        Preset(name: "Rock", gains: [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        Preset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        Preset(name: "Hip-Hop", gains: [5, 4, 2, 3, -1, -1, 1, 0, 2, 3]),
        Preset(name: "Acoustic", gains: [3, 3, 2, 1, 1, 1, 2, 2, 2, 1]),
        Preset(name: "Late Night", gains: [3, 2, 1, 0, -1, -1, -2, -2, -3, -4]),
    ]

    var isEnabled: Bool {
        didSet { save() }
    }

    var gains: [Float] {
        didSet { save() }
    }

    /// The preset matching the current bands, if any.
    var presetName: String? {
        Self.presets.first { $0.gains == gains }?.name
    }

    /// Shared with the audio thread.
    let tapSettings = EqualizerTap.Settings()
    /// Called when the equalizer is switched on or its bands change.
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "dial.eq.enabled")
        let saved = defaults.array(forKey: "dial.eq.gains") as? [Float]
        gains = saved?.count == Self.frequencies.count ? saved! : Self.presets[0].gains
        tapSettings.update(enabled: isEnabled, gains: gains)
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
    }

    func setGain(_ gain: Float, at band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(gain, Self.range.lowerBound), Self.range.upperBound)
    }

    private func save() {
        UserDefaults.standard.set(isEnabled, forKey: "dial.eq.enabled")
        UserDefaults.standard.set(gains, forKey: "dial.eq.gains")
        tapSettings.update(enabled: isEnabled, gains: gains)
        onChange?()
    }
}

/// Runs the equalizer on the player's audio. It hooks into each song with an audio
/// processing tap and filters the sound with a chain of peaking filters (Accelerate's biquad).
/// This works for files and plain streams; HLS streams can't be tapped, so Dial avoids them.
enum EqualizerTap {
    /// Equalizer settings read on the audio thread. Changes are picked up within one buffer.
    final class Settings: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (enabled: false, gains: [Float](), version: 0))

        func update(enabled: Bool, gains: [Float]) {
            state.withLock { $0 = (enabled, gains, $0.version + 1) }
        }

        var snapshot: (enabled: Bool, gains: [Float], version: Int) {
            state.withLock { $0 }
        }
    }

    /// Adds the equalizer to a song once its audio track is known.
    static func attach(to item: AVPlayerItem, settings: Settings) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        let context = Context(settings: settings)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(context).release()
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        await MainActor.run { item.audioMix = mix }
    }

    /// Per-song state on the audio thread: the filters and their memory for each channel.
    final class Context {
        let settings: Settings
        private var sampleRate: Double = 44_100
        private var setup: vDSP_biquad_Setup?
        private var delays: [[Float]] = []
        private var version = -1
        private var preamp: Float = 1
        private var enabled = false

        init(settings: Settings) {
            self.settings = settings
        }

        deinit {
            if let setup { vDSP_biquad_DestroySetup(setup) }
        }

        func prepare(sampleRate: Double, channels: Int) {
            self.sampleRate = sampleRate
            delays = Array(repeating: [Float](repeating: 0, count: 2 * Equalizer.frequencies.count + 2), count: channels)
            version = -1
        }

        fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let current = settings.snapshot
            if current.version != version { rebuild(enabled: current.enabled, gains: current.gains, version: current.version) }
            guard enabled, let setup, frames > 0 else { return }

            for (channel, buffer) in buffers.enumerated() where channel < delays.count {
                // Only plain one-channel float buffers (what the player hands over); anything else is left untouched rather than risked.
                guard buffer.mNumberChannels == 1, Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var scale = preamp
                vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(frames))
                delays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquad(setup, delay.baseAddress!, samples, 1, samples, 1, vDSP_Length(frames))
                }
            }
        }

        private func rebuild(enabled: Bool, gains: [Float], version: Int) {
            self.version = version
            self.enabled = enabled && gains.contains { $0 != 0 }
            if let setup { vDSP_biquad_DestroySetup(setup) }
            setup = nil
            guard self.enabled else { return }

            var coefficients: [Double] = []
            for (frequency, gain) in zip(Equalizer.frequencies, gains) {
                coefficients += Self.peaking(frequency: Double(frequency), gain: Double(gain), sampleRate: sampleRate)
            }
            setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(Equalizer.frequencies.count))
            // Turn the music down by the biggest boost, so boosted bands don't clip.
            let boost = gains.max() ?? 0
            preamp = boost > 0 ? pow(10, -boost / 20) : 1
        }

        /// A peaking filter (from Robert Bristow-Johnson's Audio EQ Cookbook), one octave wide.
        private static func peaking(frequency: Double, gain: Double, sampleRate: Double) -> [Double] {
            let nyquistSafe = min(frequency, sampleRate * 0.45)
            let a = pow(10, gain / 40)
            let w0 = 2 * Double.pi * nyquistSafe / sampleRate
            let alpha = sin(w0) / (2 * 1.41)
            let cosW0 = cos(w0)
            let a0 = 1 + alpha / a
            return [(1 + alpha * a) / a0, (-2 * cosW0) / a0, (1 - alpha * a) / a0,
                    (-2 * cosW0) / a0, (1 - alpha / a) / a0]
        }
    }
}

// MARK: - Audio tap callbacks (plain C functions, called on the audio thread)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<EqualizerTap.Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let context = Unmanaged<EqualizerTap.Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frameCount, _, bufferList, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut) == noErr else { return }
    let context = Unmanaged<EqualizerTap.Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}
