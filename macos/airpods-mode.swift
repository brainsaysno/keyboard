// Sets the connected AirPods' listening mode by driving the Sound menu in the menu bar.
// macOS has no public API for listening modes, and the private CoreBluetooth one requires
// the com.apple.bluetooth.system entitlement, so this uses the Accessibility API instead.
//
// Usage: airpods-mode noise-cancellation | transparency
// Requires Accessibility permission for the app that runs it (Raycast, a terminal, ...).

import AppKit
import ApplicationServices

let modes = ["noise-cancellation": "Noise Cancellation", "transparency": "Transparency"]

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String { attr(element, kAXRoleAttribute) as? String ?? "" }
func identifier(_ element: AXUIElement) -> String { attr(element, kAXIdentifierAttribute) as? String ?? "" }
func label(_ element: AXUIElement) -> String { attr(element, kAXDescriptionAttribute) as? String ?? "" }
func isOn(_ element: AXUIElement) -> Bool { (attr(element, kAXValueAttribute) as? NSNumber)?.intValue == 1 }
func press(_ element: AXUIElement) { AXUIElementPerformAction(element, kAXPressAction as CFString) }

func descendants(_ element: AXUIElement) -> [AXUIElement] {
    children(element).flatMap { [$0] + descendants($0) }
}

func waitFor<T>(_ seconds: Double, _ probe: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let value = probe() { return value }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return nil
}

func postKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

let keyF2: CGKeyCode = 120
let keyEscape: CGKeyCode = 53

guard CommandLine.arguments.count == 2, let wanted = modes[CommandLine.arguments[1]] else {
    fail("usage: airpods-mode \(modes.keys.sorted().joined(separator: " | "))")
}
guard AXIsProcessTrusted() else {
    fail("Needs Accessibility: System Settings > Privacy & Security > Accessibility")
}
guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
    fail("Control Center is not running")
}
let app = AXUIElementCreateApplication(controlCenter.processIdentifier)
guard let extras = attr(app, "AXExtrasMenuBar"),
      let sound = children(extras as! AXUIElement).first(where: { identifier($0) == "com.apple.menuextra.sound" })
else {
    fail("Sound is not in the menu bar: System Settings > Control Center > Sound > Always Show in Menu Bar")
}

// While the menu bar is auto-hidden, presses on its items do nothing until it has keyboard
// focus; Ctrl+F2 ("Move focus to the menu bar") gives it focus whether or not it is hidden.
postKey(keyF2, .maskControl)

func finish(closing menuIsOpen: Bool) {
    if menuIsOpen { press(sound) }
    // Escape takes keyboard focus back from the menu bar for the frontmost app.
    postKey(keyEscape)
}

func openWindow() -> AXUIElement? {
    for _ in 0..<2 {
        Thread.sleep(forTimeInterval: 0.3)
        press(sound)
        if let window = waitFor(1, { (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first }) { return window }
    }
    return nil
}

guard let window = openWindow() else {
    finish(closing: false)
    fail("Sound menu did not open")
}

// The first heading under a device row starts its Listening Mode toggles.
func listeningToggles() -> [AXUIElement]? {
    var toggles: [AXUIElement] = []
    var inGroup = false
    for element in descendants(window) {
        let isDeviceElement = identifier(element).hasPrefix("sound-device-")
        if role(element) == "AXHeading" && isDeviceElement {
            if inGroup { break }
            inGroup = true
        } else if inGroup && role(element) == "AXCheckBox" {
            toggles.append(element)
        }
    }
    return toggles.isEmpty ? nil : toggles
}

var toggles = listeningToggles()
if toggles == nil,
   let disclosure = descendants(window).first(where: { role($0) == "AXDisclosureTriangle" && identifier($0).hasPrefix("sound-device-") }) {
    press(disclosure)
    toggles = waitFor(1, listeningToggles)
}
guard let toggles else {
    finish(closing: true)
    fail("No AirPods with listening modes are connected")
}
guard let target = toggles.first(where: { label($0) == wanted }) else {
    finish(closing: true)
    fail("\(wanted) is not offered; available: \(toggles.map(label).joined(separator: ", "))")
}
if !isOn(target) {
    press(target)
}
let switched = waitFor(1) { isOn(target) ? true : nil } != nil
finish(closing: true)
if !switched { fail("\(wanted) did not turn on") }
print(wanted)
