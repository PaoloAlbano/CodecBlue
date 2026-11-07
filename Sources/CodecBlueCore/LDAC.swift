import CLDAC

/// Thin facts about the bundled LDAC encoder. The full encoder wrapper comes with the
/// streaming phase.
public enum LDAC {
    /// libldac version, e.g. "2.0.2".
    public static var libraryVersion: String {
        let v = ldacBT_get_version()
        return "\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    public static let vendorID: UInt32 = 0x0000_012D
    public static let codecID: UInt16 = 0x00AA
}
