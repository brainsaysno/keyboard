import Carbon.HIToolbox
import Foundation

/// The Corne's F-key shortcuts (config/corne.keymap): Raise+X sends F19, Raise+C sends F20.
let headphoneHotkeys: [(keyCode: Int, mode: ListeningMode)] = [
    (kVK_F19, .noiseCancellation),
    (kVK_F20, .transparency),
]

/// Global hotkeys through Carbon's RegisterEventHotKey, which needs no Accessibility or Input
/// Monitoring permission (an event tap would). Events arrive through the app's event loop, so
/// the process must run NSApplication.
final class Hotkeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []

    func register(keyCode: Int, name: String, action: @escaping () -> Void) {
        if handler == nil { installHandler() }
        let id = EventHotKeyID(signature: 0x434F_524E, id: UInt32(actions.count)) // 'CORN'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), 0, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            // eventHotKeyExistsErr: another app (Raycast, say) already owns this key.
            log("Hotkey \(name): could not register (\(status)); is another app using it?")
            return
        }
        actions[id.id] = action
        registered.append(ref)
    }

    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr
            else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().actions[id.id]?()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { log("Hotkeys: could not install the event handler (\(status))") }
    }
}

/// Runs the headphone switches one at a time; presses made while one runs collapse into the
/// latest. Each switch runs this binary's `--headphones` mode in a child process: talking to Sony
/// headphones spins a run loop while it waits, which must not stall the dashboard's.
final class HeadphoneSwitcher {
    private static let timeout: TimeInterval = 20
    private let queue = DispatchQueue(label: "dev.brainsaysno.corne-companion.headphones")
    private var pending: ListeningMode?
    private var running = false

    /// Main queue only.
    func request(_ mode: ListeningMode) {
        pending = mode
        if !running { runNext() }
    }

    private func runNext() {
        guard let mode = pending else {
            running = false
            return
        }
        pending = nil
        running = true
        queue.async {
            let result = Self.run(mode)
            DispatchQueue.main.async {
                log("Headphones: \(result)")
                self.runNext()
            }
        }
    }

    private static func run(_ mode: ListeningMode) -> String {
        guard let executable = Bundle.main.executableURL else { return "cannot find this program's path" }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--headphones", mode.rawValue]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return "\(mode.name) failed: \(error)"
        }
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        deadline.cancel()
        let lines = text.split(separator: "\n").joined(separator: "; ")
        return process.terminationReason == .exit ? lines : "\(mode.name) killed after \(Int(timeout)) s"
    }
}
