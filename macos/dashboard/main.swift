// corne-dashboard: renders the Corne right half's work dashboard with render.js and streams it
// to the keyboard over Bluetooth (wire protocol in Logic.swift and src/dashboard_protocol.h).
//
// Usage: corne-dashboard                        run as the LaunchAgent (install.sh)
//        corne-dashboard --print-state          collect once, print the state JSON
//        corne-dashboard --snapshot PATH.png    collect once, write a 4x PNG, print the state JSON

import Foundation
import MachO

/// render.js as embedded by install.sh (`-sectcreate __TEXT __render_js`), so the LaunchAgent
/// never depends on whatever the checkout has at the time.
func embeddedRenderScript() -> String? {
    var size: UInt = 0
    let header = UnsafeRawPointer(#dsohandle).assumingMemoryBound(to: mach_header_64.self)
    guard let bytes = getsectiondata(header, "__TEXT", "__render_js", &size) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
}

/// Every source once, synchronously; the microphone counts as live without debouncing.
func collectOnce() -> DashboardState {
    let now = Date()
    let review: Review
    do {
        review = try fetchReview(now: now)
    } catch {
        log("GitHub: \(error)")
        review = Review()
    }
    let meetings = CalendarCollector().meetings(now: now)
    return DashboardState(wait: collectWaiting(),
                          meet: meetState(meetings, micLiveSince: microphoneInUse() ? now : nil, now: now,
                                          calendar: .autoupdatingCurrent),
                          review: review)
}

/// The LaunchAgent: each collector on its own queue and schedule, results kept on the main
/// queue, one render per second sent to the keyboard.
final class Dashboard {
    private let renderer: Renderer
    private let transport = Transport()
    private let tmuxQueue = DispatchQueue(label: "dev.brainsaysno.corne-dashboard.tmux")
    private let calendarQueue = DispatchQueue(label: "dev.brainsaysno.corne-dashboard.calendar")
    private let gitHubQueue = DispatchQueue(label: "dev.brainsaysno.corne-dashboard.github")
    private var calendar: CalendarCollector!
    private var timers: [DispatchSourceTimer] = []

    private var waiting = Waiting()
    private var meetings: [Meeting] = []
    private var review = Review()
    private var mic = MicDebounce()
    private var meetMode = ""
    private var renderProblem: String?
    private var gitHubProblem: String?

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    func start() {
        calendar = CalendarCollector { [weak self] in
            self?.calendarQueue.async { self?.refreshCalendar() }
        }
        repeatEvery(2, on: tmuxQueue) { [weak self] in
            let waiting = collectWaiting()
            DispatchQueue.main.async { self?.waiting = waiting }
        }
        repeatEvery(60, on: calendarQueue) { [weak self] in self?.refreshCalendar() }
        repeatEvery(60, on: gitHubQueue) { [weak self] in self?.refreshReview() }
        // Just after each second boundary, so countdowns change with the system clock.
        let first = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 1.02)
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func repeatEvery(_ interval: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        timers.append(timer)
    }

    // On calendarQueue.
    private func refreshCalendar() {
        let meetings = calendar.meetings(now: Date())
        DispatchQueue.main.async { self.meetings = meetings }
    }

    // On gitHubQueue. A failure keeps the last good counts.
    private func refreshReview() {
        do {
            let review = try fetchReview(now: Date())
            DispatchQueue.main.async {
                if review.count != self.review.count || review.mine != self.review.mine || self.gitHubProblem != nil {
                    log("GitHub: \(review.count) to review; mine \(review.mine.ready) ready, "
                        + "\(review.mine.inReview) in review, \(review.mine.notAsked) not asked")
                }
                self.review = review
                self.gitHubProblem = nil
            }
        } catch {
            let problem = "\(error)"
            DispatchQueue.main.async {
                if problem != self.gitHubProblem { log("GitHub: \(problem); keeping the last counts") }
                self.gitHubProblem = problem
            }
        }
    }

    private func tick() {
        let now = Date()
        let wasLive = mic.liveSince != nil
        mic.update(running: microphoneInUse(), now: now)
        if (mic.liveSince != nil) != wasLive {
            log(wasLive ? "Microphone off" : "Microphone live")
        }
        let state = DashboardState(wait: waiting,
                                   meet: meetState(meetings, micLiveSince: mic.liveSince, now: now,
                                                   calendar: .autoupdatingCurrent),
                                   review: review)
        if state.meet.mode != meetMode {
            meetMode = state.meet.mode
            log("Meeting band: \(meetMode)")
        }
        guard transport.isIdle else { return }
        do {
            transport.send(try renderer.frame(state, time: now.timeIntervalSince1970))
            renderProblem = nil
        } catch {
            let problem = "\(error)"
            if problem != renderProblem { log("Render failed: \(problem)") }
            renderProblem = problem
        }
    }
}

func loadRenderer() -> Renderer {
    guard let source = embeddedRenderScript() else {
        log("render.js is not embedded; build with install.sh")
        exit(1)
    }
    do {
        return try Renderer(source: source)
    } catch {
        log("Cannot load render.js: \(error)")
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case (nil, _):
    log("Starting")
    let dashboard = Dashboard(renderer: loadRenderer())
    dashboard.start()
    RunLoop.main.run()
case ("--print-state", 1):
    print(collectOnce().json)
case ("--snapshot", 2):
    let renderer = loadRenderer()
    let state = collectOnce()
    do {
        try writeSnapshot(renderer.frame(state, time: Date().timeIntervalSince1970), to: URL(fileURLWithPath: arguments[1]))
    } catch {
        log("Snapshot failed: \(error)")
        exit(1)
    }
    print(state.json)
default:
    FileHandle.standardError.write(Data("usage: corne-dashboard [--print-state | --snapshot PATH.png]\n".utf8))
    exit(2)
}
