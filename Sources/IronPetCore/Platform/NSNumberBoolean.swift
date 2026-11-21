import Foundation

extension NSNumber {
    /// True for a JSON `true` or `false`, which `JSONSerialization` hands back as an NSNumber. Core Foundation tells them apart from
    /// 0 and 1 on Apple platforms. On Linux the Bool-backed NSNumber reports the type encoding "c".
    package var isJSONBoolean: Bool {
        #if canImport(Darwin)
        return CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        return String(cString: objCType) == "c"
        #endif
    }
}
