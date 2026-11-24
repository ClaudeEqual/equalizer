import Foundation
import CoreAudio
import AudioToolbox

enum EngineError: LocalizedError {
    case noOutputDevice
    case noOwnProcess
    case os(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "Не найдено устройство вывода звука"
        case .noOwnProcess: return "Не удалось подготовить звук. Выключите и включите эквалайзер"
        case .os(let what, let code): return "Ошибка звука: \(what) (код \(code))"
        }
    }
}

/// Captures all system audio with a Core Audio process tap (macOS 14.2+),
/// runs it through the EQ and plays it to the current output device.
/// The original sound is muted while the tap is active, so the user hears only the processed version.
final class SystemAudioEQ {
    let processor = EQProcessor()

    /// Called on the main queue when the output device changes its sample rate.
    var onNeedsRestart: (() -> Void)?

    private(set) var isRunning = false
    private(set) var outputName = ""
    private(set) var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?

    func start() throws {
        stop()

        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.stringProperty(outputID, kAudioDevicePropertyDeviceUID)
        outputDeviceID = outputID
        outputName = (try? Self.stringProperty(outputID, kAudioObjectPropertyName)) ?? "устройство вывода"
        sampleRate = Self.nominalSampleRate(outputID) ?? 48_000

        // Exclude ourselves from the tap, otherwise our own output would be captured again (feedback).
        guard let own = Self.ownProcessObject() else { throw EngineError.noOwnProcess }

        do {
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
            tapDescription.uuid = UUID()
            tapDescription.muteBehavior = .mutedWhenTapped

            var newTap = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(tapDescription, &newTap)
            guard status == noErr else { throw EngineError.os("перехват звука", status) }
            tapID = newTap

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Equalizer",
                kAudioAggregateDeviceUIDKey: "equalizer-" + UUID().uuidString,
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
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                    ]
                ]
            ]

            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
            guard status == noErr else { throw EngineError.os("аудиоустройство", status) }
            aggregateID = newAggregate

            processor.prepare(sampleRate: sampleRate)

            let processor = self.processor
            var newProc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) { _, inInputData, _, outOutputData, _ in
                processor.process(input: inInputData, output: outOutputData)
            }
            guard status == noErr, let proc = newProc else { throw EngineError.os("обработчик звука", status) }
            procID = proc

            status = AudioDeviceStart(aggregateID, proc)
            guard status == noErr else { throw EngineError.os("запуск звука", status) }

            addRateListener(outputID)
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        removeRateListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let proc = procID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    deinit { stop() }

    // MARK: - Sample rate changes

    private func addRateListener(_ device: AudioObjectID) {
        var address = Self.propAddr(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            if let rate = Self.nominalSampleRate(device), abs(rate - self.sampleRate) > 0.5 {
                self.onNeedsRestart?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
            rateListener = block
        }
    }

    private func removeRateListener() {
        guard let block = rateListener else { return }
        var address = Self.propAddr(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, DispatchQueue.main, block)
        rateListener = nil
    }

    // MARK: - Core Audio helpers

    static func propAddr(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        var address = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw EngineError.noOutputDevice }
        return device
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = propAddr(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw EngineError.os("свойство устройства", status) }
        return value as String
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = propAddr(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? rate : nil
    }

    static func ownProcessObject() -> AudioObjectID? {
        var address = propAddr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }
}
