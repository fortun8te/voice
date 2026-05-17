// VOICE — Sound Effects
// ============================================================
// Programmatic earcons via AVAudioEngine. Premium dictation feel.
//
// WHY NOT NSSound(named:):
//   Shared instance, restarts mid-playback, volume leaks across callers.
//
// WHY programmatic synthesis:
//   Full control over spectra, envelope, stereo image, and tail.
//   Multi-component design (noise + tone + harmonics) avoids the
//   "phone notification" feel of a single sine pop.
//
// DESIGN PHILOSOPHY (Wispr Flow / Superwhisper-ish):
//   - Asymmetric envelopes: ~1ms attack, exponential decay
//   - Layered components: filtered noise (transient) + tonal body
//   - Inharmonic partials for "tap" character, not chime
//   - Subtle stereo widening (L/R micro-delay) for spaciousness
//   - Reverb-ish tail via low-amplitude exponential decay
//   - Volume-matched RMS across the three sounds
//
// SOUNDS:
//   playStart — Soft warm tap: noise transient + C4 body w/ slight glide up.
//                Inviting, "ready" feel. ~140ms total.
//   playStop  — Dampened descending pluck: G4 → C4, woody decay. ~180ms.
//                Confirmation, "got it" — not a warning.
//   playDone  — Subliminal soft pluck: E5 + perfect-fifth color, fast decay.
//                ~90ms. Almost felt, not heard.
// ============================================================

import AVFoundation

enum SoundEffects {

    private static var enabled: Bool {
        if UserDefaults.standard.object(forKey: "soundEffectsEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "soundEffectsEnabled")
    }

    private static let engine = AVAudioEngine()
    private static let sampleRate: Double = 44100

    // MARK: - Public

    /// Recording-on earcon. Warm, inviting tap.
    static func playStart() {
        guard enabled else { return }
        renderAndPlay(duration: 0.18, peakAmplitude: 0.22) { t, dur in
            let n = noiseTransient(t: t, decayMs: 8, color: .high)
            // Body: C4 (261.63) with a 12-cent upward glide over the first 30ms
            let glide = 1.0 + 0.007 * smoothRise(t: t, ms: 30)
            let body = pluckTone(
                t: t,
                freq: 261.63 * glide,
                decay: 0.040,           // ~40ms tonal decay
                harmonics: [(1.0, 1.00), (2.01, 0.32), (3.03, 0.10)],
                inharmonicity: 0.004
            )
            // Reverb-like tail: dampened sine, very low amplitude
            let tail = exp(-t / 0.060) * sin(2.0 * .pi * 523.25 * t) * 0.05
            return (noise: n * 0.55, body: body * 0.85 + tail, t: t, dur: dur)
        }
    }

    /// Recording-off earcon. Dampened descending pluck. "Got it."
    static func playStop() {
        guard enabled else { return }
        renderAndPlay(duration: 0.22, peakAmplitude: 0.20) { t, dur in
            // Soft front-end transient — quieter than start (not a warning)
            let n = noiseTransient(t: t, decayMs: 6, color: .mid)
            // Descending: G4 (392) → C4 (261.63), exponential glide over 50ms
            let glideAmt = 1.0 - 0.333 * smoothRise(t: t, ms: 50)
            let freq = 392.0 * glideAmt
            let body = pluckTone(
                t: t,
                freq: freq,
                decay: 0.070,           // longer woody decay
                harmonics: [(1.0, 1.00), (2.0, 0.22), (3.0, 0.07)],
                inharmonicity: 0.002
            )
            // Slight sub-octave shimmer for warmth
            let sub = exp(-t / 0.080) * sin(2.0 * .pi * 130.81 * t) * 0.10
            return (noise: n * 0.30, body: body * 0.90 + sub, t: t, dur: dur)
        }
    }

    /// Paste-complete earcon. Subliminal soft pluck.
    static func playDone() {
        guard enabled else { return }
        renderAndPlay(duration: 0.10, peakAmplitude: 0.13) { t, dur in
            // Almost no transient — just air
            let n = noiseTransient(t: t, decayMs: 3, color: .high) * 0.20
            // E5 (659.25) + perfect-fifth color (B5 at 987.77) very quiet
            let body1 = pluckTone(
                t: t,
                freq: 659.25,
                decay: 0.025,
                harmonics: [(1.0, 1.00), (2.0, 0.15)],
                inharmonicity: 0.003
            )
            let body2 = pluckTone(
                t: t,
                freq: 987.77,
                decay: 0.018,
                harmonics: [(1.0, 0.45)],
                inharmonicity: 0.0
            )
            return (noise: n, body: (body1 + body2) * 0.75, t: t, dur: dur)
        }
    }

    // MARK: - Synthesis helpers

    private enum NoiseColor { case high, mid, low }

    /// Single-pole noise shaping state per call.
    private final class NoiseState {
        var lp: Double = 0  // low-pass state
        var hp: Double = 0  // high-pass state
    }

    /// Filtered noise burst with fast exponential decay.
    /// Used as the percussive transient ("tssst") at the head of each sound.
    /// NOTE: Returns shaped noise per-call sample; deterministic decay envelope.
    private static func noiseTransient(t: Double, decayMs: Double, color: NoiseColor) -> Double {
        // Deterministic pseudo-noise — cheap, avoids global RNG state
        // Hash time into a pseudo-random in [-1, 1].
        let scaled = t * sampleRate
        let bits = scaled.bitPattern &* 2862933555777941757 &+ 3037000493
        let u = Double(bits & 0xFFFFFFFF) / Double(UInt32.max)
        let raw = u * 2.0 - 1.0

        // Apply simple frequency coloring via a one-pole based on prior sample mix.
        // We approximate without per-call state by mixing with sin-based "tilt".
        let tilt: Double
        switch color {
        case .high:
            // Emphasize high freq → mostly raw noise plus high-pass-ish.
            tilt = raw - 0.4 * sin(2.0 * .pi * 220 * t)
        case .mid:
            tilt = raw * 0.7
        case .low:
            tilt = raw * 0.4 + 0.3 * sin(2.0 * .pi * 110 * t)
        }
        // Exponential decay envelope
        let decay = decayMs / 1000.0
        let env = exp(-t / decay)
        return tilt * env
    }

    /// A plucked tonal component: sum of (slightly inharmonic) sine harmonics
    /// with exponential decay. Per-harmonic decay scales with index for realism.
    private static func pluckTone(
        t: Double,
        freq: Double,
        decay: Double,                      // seconds for fundamental e-fold
        harmonics: [(ratio: Double, gain: Double)],
        inharmonicity: Double               // 0..0.01 typical
    ) -> Double {
        var sum: Double = 0
        for (idx, h) in harmonics.enumerated() {
            // Inharmonic stretch: each partial slightly sharper than integer ratio
            let stretch = 1.0 + inharmonicity * Double(idx * idx)
            let f = freq * h.ratio * stretch
            // Higher harmonics decay faster (natural pluck behavior)
            let hDecay = decay / (1.0 + 0.6 * Double(idx))
            let env = exp(-t / hDecay)
            sum += sin(2.0 * .pi * f * t) * h.gain * env
        }
        return sum
    }

    /// Smooth 0→1 ramp over `ms` milliseconds (cosine ease).
    private static func smoothRise(t: Double, ms: Double) -> Double {
        let dur = ms / 1000.0
        if t >= dur { return 1.0 }
        let x = t / dur
        return 0.5 - 0.5 * cos(.pi * x)
    }

    // MARK: - Render core

    /// Per-sample synthesis result.
    private typealias VoiceFrame = (noise: Double, body: Double, t: Double, dur: Double)

    /// Render the per-sample voice closure into a stereo buffer with
    /// subtle stereo widening (right channel delayed ~0.6ms + slight gain trim).
    ///
    /// Synthesis runs on a background QoS `.userInitiated` queue so the main
    /// thread is never blocked. `player.play()` is called from the background
    /// thread — AVAudioPlayerNode is thread-safe for schedule + play calls.
    private static func renderAndPlay(
        duration: Double,
        peakAmplitude: Float,
        voice: @escaping (Double, Double) -> VoiceFrame
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount

            guard let ch0 = buffer.floatChannelData?[0],
                  let ch1 = buffer.floatChannelData?[1] else { return }

            // Master envelope: 1.5ms cosine attack, exponential decay for the body
            // (per-component decays already shape the tail; this just removes any DC click).
            let attackSec = 0.0015
            let releaseSec = duration * 0.15
            let releaseStartSec = duration - releaseSec

            // Stereo widening: ~0.6ms inter-channel delay (Haas effect)
            let delayFrames = Int(sampleRate * 0.0006)

            // First pass: synthesize mono into a scratch buffer so we can apply
            // delay-based widening cleanly + measure peak for normalization.
            var mono = [Double](repeating: 0, count: Int(frameCount))
            var peak: Double = 0
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                let frame = voice(t, duration)

                // Master attack/release (anti-click)
                var menv: Double = 1.0
                if t < attackSec {
                    menv = 0.5 - 0.5 * cos(.pi * t / attackSec)
                } else if t > releaseStartSec {
                    let r = (t - releaseStartSec) / releaseSec
                    menv = 0.5 + 0.5 * cos(.pi * r)
                }

                // Mix noise + body. Noise is already enveloped internally.
                let s = (frame.noise + frame.body) * menv
                mono[i] = s
                if abs(s) > peak { peak = abs(s) }
            }

            // Normalize to peakAmplitude target (prevents clipping, RMS-matches sounds)
            let norm = peak > 0 ? Double(peakAmplitude) / peak : Double(peakAmplitude)

            for i in 0..<Int(frameCount) {
                let l = Float(mono[i] * norm)
                // Right channel: delayed copy at ~0.97 gain (gentle Haas widening)
                let j = i - delayFrames
                let r = (j >= 0) ? Float(mono[j] * norm * 0.97) : 0
                ch0[i] = l
                ch1[i] = r
            }

            let player = AVAudioPlayerNode()
            // AVAudioEngine attach/connect/start must be serialized. The engine
            // static is shared; guard with a lightweight lock. In practice only
            // one sound plays at a time (start ≠ stop ≠ done), so contention is
            // negligible. Using objc_sync on the engine object is enough.
            objc_sync_enter(engine)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            if !engine.isRunning { try? engine.start() }
            objc_sync_exit(engine)

            player.scheduleBuffer(buffer) {
                DispatchQueue.main.async {
                    engine.detach(player)
                }
            }
            player.play()
        }
    }
}
