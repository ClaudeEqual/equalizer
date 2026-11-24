import Foundation

/// macOS has no public API to check or request the "System Audio Recording" permission.
/// Like the open-source AudioCap sample, we use the system's TCC framework when it is available.
/// Without the permission a tap delivers silence (and mutes the original sound), so we check first.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown, unavailable }

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let lib = handle, let sym = dlsym(lib, "TCCAccessPreflight") else { return .unavailable }
        let preflight = unsafeBitCast(sym, to: PreflightFunc.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt. The completion runs on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let lib = handle, let sym = dlsym(lib, "TCCAccessRequest") else {
            completion(true)
            return
        }
        let request = unsafeBitCast(sym, to: RequestFunc.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
