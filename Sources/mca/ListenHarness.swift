import Foundation
import MCACore
import MCAPerception
import MCASensing

/// Stage-1 acceptance harness: capture → AEC → VAD → transcription, printing
/// both channels live.
///
/// This exists because the riskiest assumptions in the whole system are in the
/// audio path, and the only way to test them is on real hardware with real
/// permissions. If `mca listen` shows your voice on the microphone channel and
/// the other participant's on the system channel — with no echoed duplicates —
/// then the foundation is sound. If it does not, nothing built on top will
/// work, no matter how many unit tests pass.
actor ListenHarness {
    private var micLine = ""
    private var tapLine = ""

    func run(seconds: Double) async {
        print("Starting capture for \(Int(seconds))s. Speak, and play some audio.\n")

        let microphone = MicrophoneCapture()
        let tap = SystemAudioTap()

        var micPipeline: AudioChannelPipeline?
        var tapPipeline: AudioChannelPipeline?

        do {
            try microphone.start()
            print("""
                  microphone: \(Int(microphone.sampleRate)) Hz, \
                  AEC \(microphone.echoCancellationActive ? "on" : "OFF — expect echo")
                  """)
            micPipeline = AudioChannelPipeline(
                channel: .microphone,
                ringBuffer: microphone.ringBuffer,
                sampleRate: microphone.sampleRate,
                transcriber: SpeechAnalyzerTranscriber())
        } catch {
            print("microphone: FAILED — \(error)")
        }

        do {
            try tap.start()
            print("system audio: \(Int(tap.sampleRate)) Hz, process tap active")
            tapPipeline = AudioChannelPipeline(
                channel: .systemAudio,
                ringBuffer: tap.ringBuffer,
                sampleRate: tap.sampleRate,
                transcriber: SpeechAnalyzerTranscriber())
        } catch {
            print("system audio: FAILED — \(error)")
            let signing = Permissions.signingStatus()
            if !signing.isSigned {
                print("  (binary is unsigned; macOS will not prompt for audio capture)")
            } else if signing.isAdHoc {
                print("  (ad-hoc signed; the grant may not match this build — try `mca reset-permissions`)")
            }
        }

        guard micPipeline != nil || tapPipeline != nil else {
            print("\nNothing to capture. Fix the errors above and retry.")
            return
        }
        print("")

        await withTaskGroup(of: Void.self) { group in
            if let pipeline = micPipeline {
                group.addTask { await self.consume(pipeline, label: "YOU ", isMic: true) }
            }
            if let pipeline = tapPipeline {
                group.addTask { await self.consume(pipeline, label: "THEM", isMic: false) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
            }
            // First finisher is the timer; cancel the consumers.
            await group.next()
            group.cancelAll()
        }

        await micPipeline?.stop()
        await tapPipeline?.stop()
        microphone.stop()
        try? tap.stop()

        print("\n\nDone.")
        print("""

            What to check:
              • Your speech appears only on YOU, not on THEM.
              • Meeting audio appears only on THEM, not duplicated onto YOU.
                A duplicate there means echo cancellation is not engaged.
              • Dropped-frame warnings mean the consumer cannot keep up.
            """)
    }

    private func consume(_ pipeline: AudioChannelPipeline, label: String, isMic: Bool) async {
        do {
            try await pipeline.start()
        } catch {
            print("[\(label)] transcription unavailable: \(error)")
            return
        }

        for await event in pipeline.events {
            if Task.isCancelled { return }

            if event.speechStarted {
                print("[\(label)] ▶ speech")
            }
            guard let observation = event.observation, !observation.text.isEmpty else { continue }

            // Volatile results are rewrites of the same span, so they replace
            // the current line rather than appending to it.
            let line = "[\(label)] \(observation.text)"
            if observation.isFinal {
                print("\r\(line)")
                if isMic { micLine = "" } else { tapLine = "" }
            } else {
                if isMic { micLine = line } else { tapLine = line }
                FileHandle.standardOutput.write(Data("\r\(line)".utf8))
            }
        }
    }
}
