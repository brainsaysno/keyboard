// Switches every connected supported headphone between noise cancellation and transparency.
//
// AirPods (and Beats): the Bluetooth audio device exposes the listening mode as the
// undocumented Core Audio property 'lstm', with the supported modes in the 'lsms' bit mask,
// as documented by pods-control (github.com/raulgg/pods-control).
//
// Sony WH-1000XM5: Sony's MDR protocol over the RFCOMM control channel the headphones
// publish, as reverse-engineered by SonyHeadphonesClient (github.com/Plutoberth/SonyHeadphonesClient,
// mos9527 fork). Transparency maps to Ambient Sound, keeping the headphones' current ambient
// level and voice focus.
//
// Usage: headphones-mode noise-cancellation | transparency

import CoreAudio
import Foundation
import IOBluetooth

enum Mode: String {
    case noiseCancellation = "noise-cancellation"
    case transparency

    var name: String { self == .noiseCancellation ? "Noise Cancellation" : "Transparency" }
}

guard CommandLine.arguments.count == 2, let mode = Mode(rawValue: CommandLine.arguments[1]) else {
    print("usage: headphones-mode noise-cancellation | transparency")
    exit(1)
}

func waitFor(_ seconds: Double, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return done()
}

// MARK: - AirPods via Core Audio

let listeningModeProperty: AudioObjectPropertySelector = 0x6C73_746D // 'lstm'
let supportedModesProperty: AudioObjectPropertySelector = 0x6C73_6D73 // 'lsms'

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
}

func deviceName(_ device: AudioObjectID) -> String {
    var property = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr, let name else { return "Headphones" }
    return name.takeRetainedValue() as String
}

func audioDevices() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

/// Returns the names of the devices switched; failures are reported on stdout.
func setAppleListeningMode(_ mode: Mode) -> [String] {
    // 'lstm' values: 1 off, 2 noise cancellation, 3 transparency, 4 adaptive.
    // 'lsms' bits: 0 noise cancellation, 1 transparency, 2 adaptive.
    let (value, supportBit): (UInt32, UInt32) = mode == .noiseCancellation ? (2, 0b01) : (3, 0b10)
    let targets = audioDevices().filter { device in
        var property = address(listeningModeProperty)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &property),
              AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue,
              let mask = readUInt32(device, supportedModesProperty)
        else { return false }
        return mask & supportBit != 0
    }
    var switched: [String] = []
    for device in targets {
        var property = address(listeningModeProperty)
        var newValue = value
        guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &newValue) == noErr,
              waitFor(1, { readUInt32(device, listeningModeProperty) == value })
        else {
            print("\(deviceName(device)): \(mode.name) did not take effect")
            continue
        }
        switched.append(deviceName(device))
    }
    return switched
}

// MARK: - Sony via the MDR protocol

let sonyControlService: IOBluetoothSDPUUID = {
    let bytes: [UInt8] = [0x95, 0x6C, 0x7B, 0x26, 0xD4, 0x9A, 0x4B, 0xA8,
                          0xB0, 0x3F, 0xB1, 0x7D, 0x39, 0x3C, 0xB6, 0xE2]
    return IOBluetoothSDPUUID(bytes: bytes, length: bytes.count)
}()

final class SonyLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private static let start: UInt8 = 0x3E, end: UInt8 = 0x3C, escape: UInt8 = 0x3D
    private static let ackType: UInt8 = 0x01, commandType: UInt8 = 0x0C

    private var channel: IOBluetoothRFCOMMChannel?
    private var openStatus: IOReturn?
    private var buffer: [UInt8] = []
    private var frames: [(type: UInt8, payload: [UInt8])] = []
    private var sequence: UInt8 = 0

    init?(_ device: IOBluetoothDevice) {
        super.init()
        var channelID: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: sonyControlService),
              record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
              device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self) == kIOReturnSuccess,
              waitFor(4, { self.openStatus != nil }), openStatus == kIOReturnSuccess
        else {
            channel?.close()
            return nil
        }
    }

    func close() { channel?.close() }

    /// Sends a command and returns the first payload the headphones answer with `reply`.
    func request(_ payload: [UInt8], reply: UInt8) -> [UInt8]? {
        let first = frames.count
        send(type: Self.commandType, sequence: sequence, payload: payload)
        if waitFor(2, { self.frames[first...].contains { $0.type == Self.ackType } }) { sequence = 1 &- sequence }
        _ = waitFor(2, { self.frames[first...].contains { $0.payload.first == reply } })
        return frames[first...].first { $0.payload.first == reply }?.payload
    }

    // Frame: 3E | type | sequence | length (UInt32 BE) | payload | checksum | 3C, where checksum
    // is the byte sum of everything between the markers, and 3C/3D/3E inside are escaped.
    private func send(type: UInt8, sequence: UInt8, payload: [UInt8]) {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type, sequence] + withUnsafeBytes(of: length.bigEndian, Array.init) + payload
        body.append(body.reduce(0, &+))
        var bytes = [Self.start]
        for byte in body {
            if [Self.start, Self.end, Self.escape].contains(byte) { bytes += [Self.escape, byte & 0xEF] } else { bytes.append(byte) }
        }
        bytes.append(Self.end)
        _ = channel?.writeSync(&bytes, length: UInt16(bytes.count))
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        openStatus = status
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer += UnsafeRawBufferPointer(start: data, count: length)
        while let start = buffer.firstIndex(of: Self.start), let end = buffer[start...].firstIndex(of: Self.end) {
            var body: [UInt8] = []
            var escaped = false
            for byte in buffer[(start + 1)..<end] {
                if escaped { body.append(byte | 0x10); escaped = false } else if byte == Self.escape { escaped = true } else { body.append(byte) }
            }
            buffer.removeFirst(end + 1)
            guard body.count >= 7 else { continue }
            frames.append((body[0], Array(body[6..<(body.count - 1)])))
            if body[0] != Self.ackType { send(type: Self.ackType, sequence: 1 &- body[1], payload: []) }
        }
    }
}

func setSonyMode(_ mode: Mode) -> [String] {
    // NCASM commands: 0x66 get, 0x67 reply, 0x68 set, 0x69 notify. Inquired type 0x17 is the
    // WH-1000XM5 layout: [command, type, changed, on/off, mode (0 NC, 1 ambient), voice focus, level].
    let get: UInt8 = 0x66, reply: UInt8 = 0x67, set: UInt8 = 0x68, notify: UInt8 = 0x69, type: UInt8 = 0x17
    let modeByte: UInt8 = mode == .noiseCancellation ? 0x00 : 0x01
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    let targets = devices.filter { $0.isConnected() && $0.getServiceRecord(for: sonyControlService) != nil }
    guard !targets.isEmpty else { return [] }

    // IOBluetooth rides on CoreBluetooth, which ignores RFCOMM opens until it has powered on.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    var switched: [String] = []
    for device in targets {
        let name = device.name ?? "Sony headphones"
        guard let link = SonyLink(device) ?? SonyLink(device) else {
            print("\(name): could not open the control channel")
            continue
        }
        defer { link.close() }
        guard let current = link.request([get, type], reply: reply), current.count >= 7 else {
            print("\(name): noise control is not supported")
            continue
        }
        let update = link.request([set, type, 0x01, 0x01, modeByte, current[5], current[6]], reply: notify)
        guard let update, update.count >= 5, update[4] == modeByte else {
            print("\(name): \(mode.name) did not take effect")
            continue
        }
        switched.append(name)
    }
    return switched
}

// MARK: - Main

let switched = setAppleListeningMode(mode) + setSonyMode(mode)
guard !switched.isEmpty else {
    print("No connected headphones support \(mode.name)")
    exit(1)
}
print("\(mode.name): \(switched.joined(separator: ", "))")
