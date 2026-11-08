// The message numbers and argument keys of bluetoothd's classic Bluetooth XPC service.
//
// This is a private interface. The values were recorded by Blue Bloom
// (https://github.com/jonathanlu98/bluebloom, MIT, Copyright (c) 2026 Blue Bloom contributors)
// by tracing what IOBluetooth exchanges with bluetoothd on macOS 26/27. Keep them here, in
// one versioned table, so that a macOS release that changes them only needs a new table.

import Foundation

public struct XPCProtocol: Sendable {
    public var name: String
    public var serviceName = "com.apple.server.bluetooth.classic.xpc"
    /// bluetoothd's second XPC service, which carries the "general" messages: the ones that
    /// reach the controller directly (sniff mode, packet type, QoS, power). It is where
    /// `kCBGeneralMsgIdExitSniffMode` lives.
    public static let generalServiceName = "com.apple.server.bluetooth.general.xpc"

    // Requests
    public var checkIn: Int64 = 1
    public var afterCheckIn: Int64 = 10
    public var retrievePairedDevices: Int64 = 12
    public var openChannel: Int64 = 29
    public var closeChannel: Int64 = 30
    public var retrievePeerWithAddress: Int64 = 44
    public var connectPeer: Int64 = 45
    public var cancelPeerConnection: Int64 = 46
    public var openRFCOMM: Int64 = 59
    public var closeRFCOMM: Int64 = 60
    /// Asks bluetoothd for a high-priority ACL link to a device. bluetoothd then sends the
    /// controller's ACL-priority vendor command (`aclPriority: device %@, priority %s`), the
    /// same one Lucid sends itself (Broadcom 0xFC57). Found in bluetoothd's strings; the
    /// message number is not known yet, so it is disabled until it is captured.
    public var setACLHighPriority: Int64? = nil

    // Events
    public var stateChanged: Int64 = 6
    public var channelConnected: Int64 = 27
    public var channelDisconnected: Int64 = 28
    public var peerConnected: Int64 = 51
    public var rfcommOpened: Int64 = 62
    public var rfcommClosed: Int64 = 63

    // Check-in arguments as sent by IOBluetooth
    public var checkInVersion: Int64 = 20_161_219
    public var checkInType: Int64 = 3
    /// `kCBOptionServicesKey` value IOBluetooth passes when connecting a peer.
    public var connectServices: Int64 = 4096
    /// `kCBMsgArgState` once Bluetooth is powered on.
    public var statePoweredOn: Int64 = 5
    /// `kCBMsgArgState` once Bluetooth is powered off. Distinct from "not 5": a radio that is
    /// turning on reports states in between, and treating those as "off" ended streams on a
    /// machine whose Bluetooth was on (measured 2026-11-08).
    public var statePoweredOff: Int64 = 4

    public static let macOS26 = XPCProtocol(name: "macOS 26-27")

    /// The table to use on this system. Only one layout is known so far; a new macOS release
    /// that changes it gets its own entry, selected here by OS version.
    public static var current: XPCProtocol { .macOS26 }
}

/// Keys used in XPC dictionaries.
enum XPCKey {
    static let messageID = "kCBMsgId"
    static let arguments = "kCBMsgArgs"
    static let version = "kCBMsgArgVersion"
    static let options = "kCBMsgArgOptions"
    static let type = "kCBMsgArgType"
    static let name = "kCBMsgArgName"
    static let isPrivilegedDaemon = "kCBMsgArgIsPrivilegedDaemon"
    static let state = "kCBMsgArgState"
    static let addressString = "kCBMsgArgAddressString"
    static let devices = "kCBMsgArgDevices"
    static let deviceUUID = "kCBMsgArgDeviceUUID"
    static let internalState = "kCBMsgArgInternalState"
    static let services = "kCBMsgArgServices"
    static let serviceUUID = "kCBMsgArgServiceUUID"
    static let rfcommChannelID = "kCBMsgArgRFCOMMChannelID"
    static let psm = "kCBMsgArgPSM"
    static let result = "kCBMsgArgResult"
    static let socket = "kCBMsgArgSocket"
    static let cid = "kCBMsgArgCID"
    static let outMTU = "kCBMsgArgOutMTU"
    static let mtu = "kCBMsgArgMTU"
    static let servicesOption = "kCBOptionServicesKey"
    static let forceOption = "kCBCancelConnectOptionForce"
    static let channelPriority = "kCBL2CAPChannelPriority"
    /// Connection options that ask bluetoothd to keep the link out of sniff mode. Found in
    /// bluetoothd's strings together with `aclPriority` and `setLinkMode`: they are what
    /// macOS itself uses for latency-critical links (audio, game controllers).
    static let requiresLowLatency = "kCBConnectOptionRequiresLowLatency"
    static let latencyCritical = "kCBConnectOptionLatencyCritical"
    static let maxAllowedConnectionDelay = "kCBConnectOptionMaxAllowedConnectionDelay"
    /// Argument of the ACL-priority request: the priority itself (bluetoothd's `aclPriority`).
    static let aclPriority = "aclPriority"
    /// The general service addresses an ACL link by its connection handle, not by device.
    static let connHandle = "kCBMsgArgConnHandle"
}

/// Result codes bluetoothd reports when opening a channel (observed).
public enum ChannelResult {
    public static let noLink: Int = 1804  // no ACL link to the device: refused locally
    public static let alreadyConnected: Int = 1803  // this session already has a channel request
    public static let refusedNoResources: Int = 454  // the headphones refused (macOS holds it)
    public static let rfcommBusy: Int = 913  // macOS already holds this RFCOMM channel
}
