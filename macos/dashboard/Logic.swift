// Pure logic for corne-dashboard: the wire protocol, the diff sent each second, and the state
// the collectors feed to render.js. No I/O, so tests/test_dashboard_mac.py compiles this file on
// its own with tests/dashboard_mac_test.swift.

import Foundation

// MARK: - Framebuffer and wire protocol (must match src/dashboard_protocol.h)

let frameStride = 9
let frameWidth = 68
let frameHeight = 160
let frameSize = frameStride * frameHeight
/// ATT MTU 65 minus the 3-byte ATT header: the longest message the keyboard accepts.
let maxMessageLength = 62
/// DATA is [type][offset lo][offset hi][bytes...].
let dataHeaderLength = 3

enum MessageType: UInt8 {
    case data = 0x01
    case present = 0x02
}

/// Bit 1 = black panel pixel; MSB is the leftmost pixel of each byte.
func isBlack(_ frame: [UInt8], x: Int, y: Int) -> Bool {
    frame[y * frameStride + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0
}

/// CRC-16/CCITT-FALSE, the same as Zephyr's crc16_itu_t(0xFFFF, buf, len).
func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

/// Byte ranges where `new` differs from `old`. Runs separated by fewer than `minGap` unchanged
/// bytes are merged: resending those bytes costs no more than another DATA header.
func changedRanges(from old: [UInt8], to new: [UInt8], minGap: Int = 4) -> [Range<Int>] {
    precondition(old.count == new.count)
    var ranges: [Range<Int>] = []
    var start = 0
    while start < new.count {
        guard old[start] != new[start] else {
            start += 1
            continue
        }
        var end = start + 1
        while end < new.count, old[end] != new[end] {
            end += 1
        }
        if let last = ranges.last, start - last.upperBound < minGap {
            ranges[ranges.count - 1] = last.lowerBound..<end
        } else {
            ranges.append(start..<end)
        }
        start = end
    }
    return ranges
}

/// DATA payload bytes per message for a link whose write-without-response limit is
/// `maximumWriteLength` (ATT MTU - 3), capped at what the keyboard accepts.
func dataPayload(maximumWriteLength: Int) -> Int {
    max(1, min(maximumWriteLength, maxMessageLength) - dataHeaderLength)
}

func dataMessages(_ frame: [UInt8], ranges: [Range<Int>], payload: Int) -> [[UInt8]] {
    precondition(payload > 0)
    var messages: [[UInt8]] = []
    for range in ranges {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(offset + payload, range.upperBound)
            messages.append([MessageType.data.rawValue, UInt8(offset & 0xFF), UInt8(offset >> 8)] + frame[offset..<end])
            offset = end
        }
    }
    return messages
}

func presentMessage(_ frame: [UInt8]) -> [UInt8] {
    let crc = crc16(frame)
    return [MessageType.present.rawValue, UInt8(crc & 0xFF), UInt8(crc >> 8)]
}

/// Decides what to send for each rendered frame. Frames go out at most once a minute, so every
/// call ends with a PRESENT, which is also the heartbeat: the right half shows "no data" after
/// 120 s without one. The keyboard ignores a PRESENT whose CRC does not match its back buffer, so
/// DATA lost without the left half noticing only heals with the occasional full frame.
struct FrameSync {
    static let fullInterval: TimeInterval = 600

    /// The frame the keyboard shows once every message handed out so far has arrived.
    private var shown: [UInt8]?
    private var lastFull: TimeInterval = 0

    /// The next send is the whole frame, and should go out without waiting for the minute.
    var needsFull: Bool { shown == nil }

    /// Makes the next send the whole frame: after a (re)connect or a failed write.
    mutating func invalidate() {
        shown = nil
    }

    /// `now` is monotonic seconds.
    mutating func messages(for frame: [UInt8], now: TimeInterval, payload: Int) -> [[UInt8]] {
        precondition(frame.count == frameSize)
        let ranges: [Range<Int>]
        if let shown, now - lastFull < Self.fullInterval {
            ranges = changedRanges(from: shown, to: frame)
        } else {
            ranges = [0..<frameSize]
            lastFull = now
        }
        shown = frame
        return dataMessages(frame, ranges: ranges, payload: payload) + [presentMessage(frame)]
    }
}

// MARK: - Waiting windows

struct Waiting: Encodable, Equatable {
    var ask = 0
    var err = 0
    var bell = 0
}

/// Parses `tmux list-windows -F '#{window_bell_flag} #{@agent_state}'`. Each window counts once,
/// in the priority ~/.tmux/window-switcher.sh uses: ask, then error, then bell.
func classifyWaiting(_ output: String) -> Waiting {
    var waiting = Waiting()
    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let state = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
        if state == "ask" {
            waiting.ask += 1
        } else if state == "error" {
            waiting.err += 1
        } else if fields.first == "1" {
            waiting.bell += 1
        }
    }
    return waiting
}

// MARK: - Pull requests (TeracAI/platform)

struct MyPullRequests: Encodable, Equatable {
    var ready = 0
    var inReview = 0
    var notAsked = 0
}

struct Review: Encodable, Equatable {
    var count = 0
    var oldestMin = 0
    var mine = MyPullRequests()
}

let requestedSearch = "repo:TeracAI/platform is:pr is:open user-review-requested:@me"
let mineSearch = "repo:TeracAI/platform is:pr is:open author:@me draft:false"

/// Run as `gh api graphql -f query=... -f requested=<requestedSearch> -f mine=<mineSearch>`.
let reviewQuery = """
    query($requested: String!, $mine: String!) {
      viewer { login }
      requested: search(query: $requested, type: ISSUE, first: 100) {
        issueCount
        nodes { ... on PullRequest {
          createdAt
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 100) {
            nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } } } }
          }
        } }
      }
      mine: search(query: $mine, type: ISSUE, first: 100) {
        nodes { ... on PullRequest {
          isDraft reviewDecision mergeStateStatus
          reviewRequests(first: 100) { nodes { requestedReviewer { __typename } } }
          reviews(first: 100) { nodes { state author { __typename login } } }
        } }
      }
    }
    """

struct GitHubActor: Decodable {
    let typename: String
    let login: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
    }
}

struct GitHubNodes<Node: Decodable>: Decodable {
    let nodes: [Node]
}

struct RequestedPullRequest: Decodable {
    struct Event: Decodable {
        let createdAt: Date
        let requestedReviewer: GitHubActor?
    }

    let createdAt: Date
    let timelineItems: GitHubNodes<Event>
}

struct MyPullRequest: Decodable {
    struct Request: Decodable {
        let requestedReviewer: GitHubActor?
    }

    struct Submitted: Decodable {
        let state: String
        let author: GitHubActor?
    }

    let isDraft: Bool
    let reviewDecision: String?
    let mergeStateStatus: String
    let reviewRequests: GitHubNodes<Request>
    let reviews: GitHubNodes<Submitted>
}

private struct ReviewResponse: Decodable {
    struct Payload: Decodable {
        struct Viewer: Decodable {
            let login: String
        }

        struct Requested: Decodable {
            let issueCount: Int
            let nodes: [RequestedPullRequest]
        }

        let viewer: Viewer
        let requested: Requested
        let mine: GitHubNodes<MyPullRequest>
    }

    struct Failure: Decodable {
        let message: String
    }

    let data: Payload?
    let errors: [Failure]?
}

enum PullRequestBucket {
    case ready, inReview, notAsked
}

/// `viewer` is the PR's author: replies in their own review threads do not count as a review.
func bucket(_ pr: MyPullRequest, viewer: String) -> PullRequestBucket {
    // GitHub computes mergeStateStatus lazily, so UNKNOWN still counts as ready.
    if pr.reviewDecision == "APPROVED", !["BLOCKED", "DIRTY", "BEHIND"].contains(pr.mergeStateStatus) {
        return .ready
    }
    let requested = pr.reviewRequests.nodes.contains { $0.requestedReviewer?.typename == "User" }
    let reviewed = pr.reviews.nodes.contains { review in
        guard let author = review.author, author.typename == "User", author.login != viewer else { return false }
        return review.state != "PENDING"
    }
    return requested || reviewed ? .inReview : .notAsked
}

struct GitHubQueryError: Error, CustomStringConvertible {
    let description: String
}

func parseReview(_ json: Data, now: Date) throws -> Review {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(ReviewResponse.self, from: json)
    if let failure = response.errors?.first {
        throw GitHubQueryError(description: failure.message)
    }
    guard let data = response.data else {
        throw GitHubQueryError(description: "response has no data")
    }
    let viewer = data.viewer.login
    var review = Review(count: data.requested.issueCount)
    // When the viewer was last asked on each PR, else when the PR was opened.
    let askedAt = data.requested.nodes.map { pr in
        pr.timelineItems.nodes
            .filter { $0.requestedReviewer?.typename == "User" && $0.requestedReviewer?.login == viewer }
            .map(\.createdAt)
            .max() ?? pr.createdAt
    }
    if let oldest = askedAt.min() {
        review.oldestMin = max(0, Int(now.timeIntervalSince(oldest) / 60))
    }
    for pr in data.mine.nodes where !pr.isDraft {
        switch bucket(pr, viewer: viewer) {
        case .ready: review.mine.ready += 1
        case .inReview: review.mine.inReview += 1
        case .notAsked: review.mine.notAsked += 1
        }
    }
    return review
}

// MARK: - Meetings

let videoCallHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com"]
let meetingLookahead: TimeInterval = 3 * 86_400
/// A meeting starting within this many seconds takes over the band with a countdown.
let alertLead: TimeInterval = 120

/// A calendar event reduced to what decides whether it is a meeting.
struct CalendarEntry {
    var title: String?
    var start: Date
    var end: Date
    var isAllDay = false
    var declinedByMe = false
    /// An attendee other than me who is a person, not a room or resource.
    var hasOtherAttendee = false
    /// Event URL, location and notes, searched for a video-call link.
    var text: [String] = []
}

func isMeeting(_ entry: CalendarEntry) -> Bool {
    guard !entry.isAllDay, !entry.declinedByMe else { return false }
    return entry.hasOtherAttendee || entry.text.contains { text in
        videoCallHosts.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}

struct Meeting: Equatable {
    var title: String?
    var start: Date
    var end: Date
}

/// The "meet" object render.js draws. `start`/`then` are minutes after local midnight of the
/// meeting's own day; `dur`/`minsTo`/`next`/`elapsed` are minutes, since the screen refreshes once
/// a minute.
enum MeetState: Equatable {
    case noMeeting
    case alert(title: String?, minsTo: Int, start: Int)
    case next(title: String?, minsTo: Int, start: Int, dur: Int, day: Int, dow: String, then: Int?)
    case onair(title: String?, elapsed: Int, start: Int, dur: Int, next: Int?)

    var mode: String {
        switch self {
        case .noMeeting: "none"
        case .alert: "alert"
        case .next: "next"
        case .onair: "onair"
        }
    }
}

extension MeetState: Encodable {
    private enum Key: String, CodingKey {
        case mode, title, minsTo, start, dur, day, dow, then, elapsed, next
    }

    // Optionals are encoded explicitly so render.js sees null rather than a missing key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(mode, forKey: .mode)
        switch self {
        case .noMeeting:
            break
        case let .alert(title, minsTo, start):
            try container.encode(title, forKey: .title)
            try container.encode(minsTo, forKey: .minsTo)
            try container.encode(start, forKey: .start)
        case let .next(title, minsTo, start, dur, day, dow, then):
            try container.encode(title, forKey: .title)
            try container.encode(minsTo, forKey: .minsTo)
            try container.encode(start, forKey: .start)
            try container.encode(dur, forKey: .dur)
            try container.encode(day, forKey: .day)
            try container.encode(dow, forKey: .dow)
            try container.encode(then, forKey: .then)
        case let .onair(title, elapsed, start, dur, next):
            try container.encode(title, forKey: .title)
            try container.encode(elapsed, forKey: .elapsed)
            try container.encode(start, forKey: .start)
            try container.encode(dur, forKey: .dur)
            try container.encode(next, forKey: .next)
        }
    }
}

private let weekdayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

/// `micLiveSince` is when the debounced microphone went live, nil while it is off.
func meetState(_ meetings: [Meeting], micLiveSince: Date?, now: Date, calendar: Calendar) -> MeetState {
    let sorted = meetings.sorted { $0.start < $1.start }
    let upcoming = sorted.filter { $0.start > now && $0.start.timeIntervalSince(now) <= meetingLookahead }

    func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    func durationMinutes(_ meeting: Meeting) -> Int {
        Int((meeting.end.timeIntervalSince(meeting.start) / 60).rounded())
    }
    // Rounded up so the count changes when the wall clock's minute does.
    func minutesUntil(_ date: Date) -> Int {
        Int((date.timeIntervalSince(now) / 60).rounded(.up))
    }

    if let liveSince = micLiveSince {
        let next = upcoming.first.map { minutesUntil($0.start) }
        // The latest-started meeting still running when the mic went live. It stays the title
        // past its scheduled end while the mic is live, so render.js can show "+N OVER".
        if let current = sorted.last(where: { $0.start <= now && $0.end > liveSince }) {
            return .onair(title: current.title, elapsed: Int(now.timeIntervalSince(current.start) / 60),
                          start: minuteOfDay(current.start), dur: durationMinutes(current), next: next)
        }
        return .onair(title: nil, elapsed: max(0, Int(now.timeIntervalSince(liveSince) / 60)),
                      start: minuteOfDay(liveSince), dur: 0, next: next)
    }

    guard let first = upcoming.first else { return .noMeeting }
    if first.start.timeIntervalSince(now) <= alertLead {
        return .alert(title: first.title, minsTo: minutesUntil(first.start), start: minuteOfDay(first.start))
    }
    let day = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                      to: calendar.startOfDay(for: first.start)).day ?? 0
    let then = sorted.first { $0.start > first.start && calendar.isDate($0.start, inSameDayAs: first.start) }
    return .next(title: first.title, minsTo: minutesUntil(first.start), start: minuteOfDay(first.start),
                 dur: durationMinutes(first), day: day,
                 dow: weekdayNames[calendar.component(.weekday, from: first.start) - 1],
                 then: then.map { minuteOfDay($0.start) })
}

// MARK: - Microphone

/// Live after `hold` seconds continuously on, off after `hold` seconds continuously off.
struct MicDebounce {
    static let hold: TimeInterval = 3

    /// When it went live; ON AIR's elapsed time counts from here when no meeting is running.
    private(set) var liveSince: Date?
    /// Start of the current run of samples that disagree with the debounced state.
    private var changingSince: Date?

    mutating func update(running: Bool, now: Date) {
        guard running != (liveSince != nil) else {
            changingSince = nil
            return
        }
        let since = changingSince ?? now
        if now.timeIntervalSince(since) >= Self.hold {
            liveSince = running ? now : nil
            changingSince = nil
        } else {
            changingSince = since
        }
    }
}

// MARK: - State

struct DashboardState: Encodable, Equatable {
    var wait = Waiting()
    var meet = MeetState.noMeeting
    var review = Review()

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every member is a plain value, so encoding cannot fail.
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}
