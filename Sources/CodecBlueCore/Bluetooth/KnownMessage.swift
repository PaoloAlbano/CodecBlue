import Foundation

public enum KnownMessage {
    /// Device-level messages, from a working takeover.
    public static let device: [Int64: String] = [
        1: "kCBMsgIdDeviceGetInfo",
        2: "kCBMsgIdDeviceConnect",
        3: "kCBMsgIdDeviceDisconnect",
        4: "kCBMsgIdDeviceGetServices",
        5: "kCBMsgIdDeviceOpenConnection",
        6: "kCBMsgIdDeviceCloseConnection",
        7: "kCBMsgIdDeviceOpenL2CAPChannel",
        8: "kCBMsgIdDeviceCloseL2CAPChannel",
        9: "kCBMsgIdDeviceGetAttribute",
        10: "kCBMsgIdDeviceSetAttribute",
    ]

    /// Controller-level messages, from the general service's own log lines.
    public static let general: [Int64: String] = [
        1: "kCBMsgIdGeneralGetVersion",
        2: "kCBMsgIdGeneralGetPowerState",
        3: "kCBMsgIdGeneralSetPowerState",
        4: "kCBMsgIdGeneralGetLocalName",
        5: "kCBMsgIdGeneralSetLocalName",
        6: "kCBMsgIdGeneralGetDevices",
    ]

    public static func name(_ id: Int64, in table: [Int64: String]) -> String? { table[id] }
}
