// Sets the connected AirPods' listening mode through Core Audio.
// The AirPods' Bluetooth audio device exposes the mode as the undocumented 'lstm' property
// and the supported modes as the 'lsms' bit mask, as documented by pods-control
// (github.com/raulgg/pods-control). No UI scripting or extra permissions are involved.
//
// Usage: airpods-mode noise-cancellation | transparency

import CoreAudio
import Foundation

let listeningMode: AudioObjectPropertySelector = 0x6C73_746D // 'lstm'
let supportedModes: AudioObjectPropertySelector = 0x6C73_6D73 // 'lsms'

// 'lstm' values; 'lsms' advertises Noise Cancellation as bit 0 and Transparency as bit 1.
let modes: [String: (name: String, value: UInt32, supportBit: UInt32)] = [
    "noise-cancellation": ("Noise Cancellation", 2, 0b01),
    "transparency": ("Transparency", 3, 0b10),
]

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func read(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value : nil
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

guard CommandLine.arguments.count == 2, let mode = modes[CommandLine.arguments[1]] else {
    fail("usage: airpods-mode \(modes.keys.sorted().joined(separator: " | "))")
}

let targets = audioDevices().filter { device in
    var property = address(listeningMode)
    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(device, &property),
          AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue,
          let mask = read(device, supportedModes)
    else { return false }
    return mask & mode.supportBit != 0
}
guard !targets.isEmpty else { fail("No connected AirPods support \(mode.name)") }

for device in targets {
    var property = address(listeningMode)
    var value = mode.value
    let status = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    guard status == noErr else { fail("Setting \(mode.name) failed (OSStatus \(status))") }
}

let deadline = Date().addingTimeInterval(1)
while !targets.allSatisfy({ read($0, listeningMode) == mode.value }) {
    guard Date() < deadline else { fail("\(mode.name) did not take effect") }
    Thread.sleep(forTimeInterval: 0.05)
}
print(mode.name)
