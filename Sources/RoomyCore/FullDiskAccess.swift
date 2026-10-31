import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum FullDiskAccess {
    public static func isGranted() -> Bool {
        #if os(macOS)
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return !(errno == EPERM || errno == EACCES)
        #else
        return true
        #endif
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
