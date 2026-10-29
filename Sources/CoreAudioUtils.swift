import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let what: String
    var errorDescription: String? { "\(what) (Core Audio \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, what: what) }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try check(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) },
              "Lecture de la propriété \(selector)")
    return value
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var ref: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref) == noErr else { return nil }
    return ref?.takeRetainedValue() as String?
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

/// Un processus qui utilise l'audio, tel que Core Audio le voit.
struct AudioProcess {
    let pid: pid_t
    let bundleID: String
    let name: String
    let usesInput: Bool
    let usesOutput: Bool

    static func all() -> [AudioProcess] {
        readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = try? readValue(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let bundleID = readString(id, kAudioProcessPropertyBundleID) ?? ""
            let input = (try? readValue(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0
            let output = (try? readValue(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(pid: pid, bundleID: bundleID, name: processName(pid),
                                usesInput: input != 0, usesOutput: output != 0)
        }
    }
}

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &buffer, UInt32(buffer.count))
    return String(cString: buffer)
}
