import CoreAudio
import EventKit
import Foundation

/// Logs go to stderr: launchd appends them to ~/Library/Logs/corne-dashboard.log, and stdout
/// stays clean for --print-state.
func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(message)\n".utf8))
}

struct CommandFailure: Error, CustomStringConvertible {
    let description: String
}

/// Runs a command found on PATH (launchd's PATH comes from the LaunchAgent plist) and returns
/// its stdout, or throws with its stderr.
func runCommand(_ arguments: [String], timeout: TimeInterval) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let output = Pipe(), errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    // stderr is read after stdout: the commands used here never fill its pipe buffer.
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationReason == .exit ? "exit \(process.terminationStatus)" : "killed after \(Int(timeout)) s"
        throw CommandFailure(description: "\(arguments[0]) failed (\(status))\(message.isEmpty ? "" : ": \(message)")")
    }
    return stdout
}

// MARK: - tmux

/// Windows in tmux session "work" waiting on me. No session or no server counts as none.
func collectWaiting() -> Waiting {
    guard let output = try? runCommand(["tmux", "list-windows", "-t", "=work", "-F", "#{window_bell_flag} #{@agent_state}"],
                                       timeout: 5)
    else { return Waiting() }
    return classifyWaiting(String(decoding: output, as: UTF8.self))
}

// MARK: - Microphone

private func propertyAddress(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var property = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &objects) == noErr else { return [] }
    return objects
}

/// True while any input device is running for any process (Bluetooth headsets list their
/// microphone as a device of its own, so playback does not count).
func microphoneInUse() -> Bool {
    audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).contains { device in
        guard !audioObjects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty else { return false }
        var property = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &running) == noErr && running != 0
    }
}

// MARK: - Calendar

/// Meetings from EventKit, all calendars. Not thread-safe: call from one queue.
final class CalendarCollector {
    private let store = EKEventStore()
    private var requested = false
    private var lastStatus: EKAuthorizationStatus?
    private var observer: NSObjectProtocol?
    private let changed: () -> Void

    /// `changed` runs on an arbitrary queue when events change or access is granted.
    init(changed: @escaping () -> Void = {}) {
        self.changed = changed
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: nil) { _ in changed() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Empty until full access is granted; asks for it once per process.
    func meetings(now: Date) -> [Meeting] {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != lastStatus {
            log("Calendar access: \(describe(status))")
            // Reload calendars in a store created before access was granted in Settings.
            if lastStatus != nil, status == .fullAccess { store.reset() }
            lastStatus = status
        }
        switch status {
        case .fullAccess:
            break
        case .notDetermined:
            if !requested {
                requested = true
                store.requestFullAccessToEvents { [changed] granted, error in
                    if let error { log("Calendar access request failed: \(error.localizedDescription)") }
                    if granted { changed() }
                }
            }
            return []
        default:
            return []
        }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400),
                                                 end: now.addingTimeInterval(meetingLookahead), calendars: nil)
        return store.events(matching: predicate).map(entry).filter(isMeeting).map { entry in
            Meeting(title: entry.title, start: entry.start, end: entry.end)
        }
    }

    private func entry(_ event: EKEvent) -> CalendarEntry {
        let attendees = event.attendees ?? []
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEntry(
            title: title?.isEmpty == false ? title : nil,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            declinedByMe: attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined },
            hasOtherAttendee: attendees.contains {
                !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource
            },
            text: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
    }
}

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .fullAccess: "full access"
    case .writeOnly: "write only"
    @unknown default: "unknown (\(status.rawValue))"
    }
}

// MARK: - GitHub

func fetchReview(now: Date) throws -> Review {
    let output = try runCommand(["gh", "api", "graphql", "-f", "query=\(reviewQuery)",
                                 "-f", "requested=\(requestedSearch)", "-f", "mine=\(mineSearch)"],
                                timeout: 30)
    return try parseReview(output, now: now)
}
