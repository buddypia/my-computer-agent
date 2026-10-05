import AudioToolbox
import CoreAudio
import Foundation
import MCACore
import OSLog

/// Captures everything the machine is playing — meeting participants, video,
/// anything — without a virtual audio driver.
///
/// The mechanism is a CoreAudio *process tap* (macOS 14.2+): CoreAudio inserts
/// a tap on the audio other processes render, attaches it to a private
/// aggregate device, and hands us a copy of the stream. The user keeps hearing
/// their audio normally.
///
/// Three undocumented constraints shape this implementation:
///
/// 1. `AVAudioEngine` **cannot** be retargeted at a tap-backed aggregate
///    device. Setting `kAudioOutputUnitProperty_CurrentDevice` returns `noErr`
///    and the engine then silently keeps reading the default input. We attach
///    an IOProc to the aggregate device directly instead.
/// 2. The aggregate needs a real output device as its main sub-device, with the
///    tap listed as a sub-tap and `TapAutoStart` enabled.
/// 3. The TCC prompt (`NSAudioCaptureUsageDescription`) is only raised on the
///    first `AudioHardwareCreateProcessTap` call *from a signed binary*. An
///    unsigned build fails without ever prompting.
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapError: Error, CustomStringConvertible {
        case noDefaultOutputDevice
        case osStatus(String, OSStatus)
        case unsupportedFormat

        public var description: String {
            switch self {
            case .noDefaultOutputDevice:
                return "No default system output device"
            case .osStatus(let op, let code):
                return "\(op) failed with OSStatus \(code)\(Self.hint(for: code))"
            case .unsupportedFormat:
                return "Tap produced an unsupported stream format"
            }
        }

        private static func hint(for code: OSStatus) -> String {
            switch code {
            case 1852797029: // 'nope' — kAudioHardwareIllegalOperationError
                return " (illegal operation — usually missing audio-capture permission or an unsigned binary)"
            case -10851:
                return " (invalid property value)"
            default:
                return ""
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "SystemAudioTap")

    /// 4 seconds at 48 kHz mono. Consumer drains every ~100 ms, so this is a
    /// generous margin against scheduler jitter.
    public let ringBuffer = AudioRingBuffer(capacity: 48_000 * 4)

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    /// Sample rate of the captured stream, known only after `start()`.
    public private(set) var sampleRate: Double = 48_000
    /// The scope of audio capture: either global (all system audio) or targeted to specific processes.
    public enum TargetScope: Sendable, Equatable {
        case global(excludedPIDs: [pid_t] = [])
        case processes([pid_t])
    }

    /// Capture scope configured for this tap.
    public let scope: TargetScope
    /// Processes whose audio must never be tapped (privacy exclusion).
    private let excludedPIDs: [pid_t]
    /// Target processes if scoped.
    private let targetPIDs: [pid_t]

    public init(scope: TargetScope = .global()) {
        self.scope = scope
        switch scope {
        case .global(let excluded):
            self.excludedPIDs = excluded
            self.targetPIDs = []
        case .processes(let targets):
            self.targetPIDs = targets
            self.excludedPIDs = []
        }
    }

    public convenience init(excludedPIDs: [pid_t]) {
        self.init(scope: .global(excludedPIDs: excludedPIDs))
    }

    public convenience init(targetPIDs: [pid_t]) {
        self.init(scope: .processes(targetPIDs))
    }

    /// CoreAudio identifies processes by `AudioObjectID`, not by `pid_t`, so
    /// exclusions have to be translated before they can go in the tap
    /// description. A PID with no audio object simply has nothing to exclude.
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var inputPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &objectID)

        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    deinit { try? stop() }

    public func start() throws {
        guard !isRunning else { return }

        // 1. Describe the tap.
        let description: CATapDescription
        switch scope {
        case .processes(let targets):
            let targetObjects = targets.compactMap(Self.processObject(for:))
            if !targetObjects.isEmpty {
                description = CATapDescription(stereoMixdownOfProcesses: targetObjects)
            } else {
                log.info("No audio objects found for target PIDs \(targets); falling back to global tap")
                let excludedObjects = excludedPIDs.compactMap(Self.processObject(for:))
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjects)
            }
        case .global(let excluded):
            let excludedObjects = excluded.compactMap(Self.processObject(for:))
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedObjects)
        }
        description.uuid = UUID()
        description.name = "MyComputerAgent System Tap"
        description.isPrivate = true  // not visible to other apps
        // The user must keep hearing their own audio; we only take a copy.
        description.muteBehavior = CATapMuteBehavior.unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard createStatus == noErr else {
            throw TapError.osStatus("AudioHardwareCreateProcessTap", createStatus)
        }
        tapID = tap

        // 2. Build a private aggregate device around a real output device.
        let outputUID = try defaultOutputDeviceUID()
        let aggregateUID = UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyComputerAgent Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &aggregate)
        guard aggStatus == noErr else {
            throw TapError.osStatus("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = aggregate

        // 3. Learn the tap's actual stream format before wiring the IOProc.
        let format = try tapStreamFormat()
        sampleRate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              channels > 0
        else { throw TapError.unsupportedFormat }

        // 4. Attach the IOProc directly to the aggregate device.
        //
        //    Everything inside this block runs on a CoreAudio realtime thread:
        //    no allocation, no locks, no `await`. It downmixes to mono and
        //    hands the frames to a lock-free ring buffer, and that is all.
        let ring = ringBuffer
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregate, nil
        ) { _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first,
                  let raw = first.mData
            else { return }

            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { return }
            let samples = raw.assumingMemoryBound(to: Float.self)

            if channels == 1 {
                ring.write(UnsafeBufferPointer(start: samples, count: frameCount))
            } else {
                // Interleaved multi-channel: average into mono in place on the
                // stack. `withUnsafeTemporaryAllocation` does not heap-allocate.
                let frames = frameCount / channels
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { mono in
                    for f in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += samples[f * channels + c] }
                        mono[f] = sum / Float(channels)
                    }
                    ring.write(UnsafeBufferPointer(start: mono.baseAddress!, count: frames))
                }
            }
        }
        guard procStatus == noErr, let procID else {
            throw TapError.osStatus("AudioDeviceCreateIOProcIDWithBlock", procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            throw TapError.osStatus("AudioDeviceStart", startStatus)
        }

        isRunning = true
        log.info("System audio tap started at \(self.sampleRate, privacy: .public) Hz, \(channels) ch")
    }

    public func stop() throws {
        guard isRunning else { return }
        isRunning = false

        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        log.info("System audio tap stopped")
    }

    // MARK: - CoreAudio property helpers

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw TapError.noDefaultOutputDevice
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else {
            throw TapError.osStatus("kAudioDevicePropertyDeviceUID", uidStatus)
        }
        return uid as String
    }

    private func tapStreamFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw TapError.osStatus("kAudioTapPropertyFormat", status)
        }
        return format
    }
}
