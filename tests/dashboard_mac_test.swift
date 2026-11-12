// Compiled by tests/test_dashboard_mac.py together with macos/dashboard/Logic.swift.
// Prints "STATE <json>" lines for the Python test to render with render.js.

import Foundation

@main
enum DashboardMacTest {
    static func main() {
        var failures = 0
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
            guard actual != expected else { return }
            failures += 1
            print("FAIL line \(line): \(what)\n  got:      \(actual)\n  expected: \(expected)")
        }

        // MARK: Wire protocol

        expect(crc16(Array("123456789".utf8)), 0x29B1, "CRC-16/CCITT-FALSE check value")
        expect(dataPayload(maximumWriteLength: 182), 59, "payload capped at the keyboard's 62-byte messages")
        expect(dataPayload(maximumWriteLength: 20), 17, "payload on a default 23-byte MTU")

        let white = [UInt8](repeating: 0xFF, count: frameSize)
        var ends = white
        ends[0] = 0
        ends[1439] = 0
        expect(changedRanges(from: white, to: white), [], "identical frames")
        expect(changedRanges(from: white, to: ends), [0..<1, 1439..<1440], "first and last byte")
        var gap3 = white
        gap3[10] = 0
        gap3[14] = 0
        expect(changedRanges(from: white, to: gap3), [10..<15], "3 unchanged bytes are merged")
        var gap4 = white
        gap4[10] = 0
        gap4[15] = 0
        expect(changedRanges(from: white, to: gap4), [10..<11, 15..<16], "4 unchanged bytes split")
        var runs = white
        for i in 100..<110 { runs[i] = 0 }
        runs[113] = 0
        runs[200] = 0
        expect(changedRanges(from: white, to: runs), [100..<114, 200..<201], "runs merge across short gaps")

        let full = dataMessages(ends, ranges: [0..<frameSize], payload: 59)
        expect(full.count, 25, "full frame in 59-byte payloads")
        expect(full.map { Int($0[1]) | Int($0[2]) << 8 }, Array(stride(from: 0, to: frameSize, by: 59)), "DATA offsets")
        expect(full.allSatisfy { $0[0] == 0x01 && $0.count <= maxMessageLength }, true, "DATA type and length")
        expect(Array(full[5].prefix(3)), [0x01, 0x27, 0x01], "little-endian offset 295")
        expect(full.last?.count, 3 + frameSize - 24 * 59, "last DATA carries the remainder")
        expect(full.flatMap { $0.dropFirst(3) }, ends, "DATA payloads reassemble the frame")
        let endsCRC = crc16(ends)
        expect(presentMessage(ends), [0x02, UInt8(endsCRC & 0xFF), UInt8(endsCRC >> 8)], "PRESENT carries the CRC")

        var sync = FrameSync()
        let first = sync.messages(for: white, now: 1000, payload: 59)
        expect(first.count, 26, "first frame is sent whole")
        expect(first.last, presentMessage(white), "frame ends with PRESENT")
        expect(sync.messages(for: white, now: 1001, payload: 59), [], "nothing sent for an unchanged frame")
        expect(sync.messages(for: white, now: 1029.9, payload: 59), [], "no heartbeat before 30 s")
        expect(sync.messages(for: white, now: 1030, payload: 59), [presentMessage(white)], "heartbeat PRESENT at 30 s")
        expect(sync.messages(for: ends, now: 1031, payload: 59),
               [[0x01, 0x00, 0x00, 0x00], [0x01, 0x9F, 0x05, 0x00], presentMessage(ends)], "only changed bytes")
        expect(sync.messages(for: ends, now: 1059, payload: 59), [], "unchanged after a diff")
        expect(sync.messages(for: ends, now: 1060, payload: 59).count, 26, "full frame every 60 s")
        sync.invalidate()
        expect(sync.messages(for: ends, now: 1061, payload: 59).count, 26, "full frame after a failed write")

        // MARK: Waiting windows

        expect(classifyWaiting("0 \n1 \n1 ask\n0 error\n1 error\n0 ask\n0 running\n1 done\n"),
               Waiting(ask: 2, err: 2, bell: 2), "ask > error > bell, one per window")
        expect(classifyWaiting(""), Waiting(), "no windows")

        // MARK: Pull requests

        func pullRequest(_ decision: String?, _ merge: String, requests: [String] = [],
                         reviews: [(type: String, login: String, state: String)] = [], draft: Bool = false) -> String {
            let decisionJSON = decision.map { "\"\($0)\"" } ?? "null"
            let requestJSON = requests.map { #"{"requestedReviewer":{"__typename":"\#($0)"}}"# }
            let reviewJSON = reviews.map {
                #"{"state":"\#($0.state)","author":{"__typename":"\#($0.type)","login":"\#($0.login)"}}"#
            }
            return #"{"isDraft":\#(draft),"reviewDecision":\#(decisionJSON),"mergeStateStatus":"\#(merge)","#
                + #""reviewRequests":{"nodes":[\#(requestJSON.joined(separator: ","))]},"#
                + #""reviews":{"nodes":[\#(reviewJSON.joined(separator: ","))]}}"#
        }
        func bucketOf(_ json: String) -> PullRequestBucket? {
            guard let pr = try? JSONDecoder().decode(MyPullRequest.self, from: Data(json.utf8)) else { return nil }
            return bucket(pr, viewer: "me")
        }
        let claude = (type: "Bot", login: "claude", state: "APPROVED")
        let german = (type: "User", login: "germanfndez", state: "APPROVED")
        expect(bucketOf(pullRequest("APPROVED", "CLEAN", reviews: [claude, german])), .ready, "APPROVED + CLEAN")
        expect(bucketOf(pullRequest("APPROVED", "UNKNOWN", requests: ["Team"], reviews: [claude])), .ready, "APPROVED + UNKNOWN")
        expect(bucketOf(pullRequest("APPROVED", "UNSTABLE", reviews: [claude, german])), .ready, "APPROVED + UNSTABLE")
        expect(bucketOf(pullRequest("APPROVED", "BLOCKED", reviews: [claude, german])), .inReview, "APPROVED + BLOCKED, user review")
        expect(bucketOf(pullRequest("APPROVED", "BEHIND", reviews: [claude])), .notAsked, "APPROVED by a bot + BEHIND")
        expect(bucketOf(pullRequest(nil, "BLOCKED", requests: ["Team"], reviews: [claude])), .notAsked,
               "team-only request + bot review")
        expect(bucketOf(pullRequest(nil, "BLOCKED", requests: ["Team", "User"], reviews: [claude])), .inReview,
               "team + user request")
        expect(bucketOf(pullRequest(nil, "BLOCKED", requests: ["Bot"])), .notAsked, "bot request")
        expect(bucketOf(pullRequest("CHANGES_REQUESTED", "BLOCKED",
                                    reviews: [(type: "User", login: "germanfndez", state: "CHANGES_REQUESTED")])),
               .inReview, "changes requested by a user")
        expect(bucketOf(pullRequest(nil, "BLOCKED", reviews: [(type: "User", login: "me", state: "COMMENTED")])),
               .notAsked, "my own replies are not a review")
        expect(bucketOf(pullRequest(nil, "BLOCKED", reviews: [(type: "User", login: "germanfndez", state: "PENDING")])),
               .notAsked, "an unsubmitted review")

        let requestedJSON = #"""
            {"createdAt":"2026-11-10T00:00:00Z","timelineItems":{"nodes":[
              {"createdAt":"2026-11-10T01:00:00Z","requestedReviewer":{"__typename":"Team"}},
              {"createdAt":"2026-11-10T02:00:00Z","requestedReviewer":{"__typename":"User","login":"me"}},
              {"createdAt":"2026-11-11T00:00:00Z","requestedReviewer":{"__typename":"User","login":"me"}},
              {"createdAt":"2026-11-11T06:00:00Z","requestedReviewer":{"__typename":"User","login":"someone"}}]}},
            {"createdAt":"2026-11-12T00:00:00Z","timelineItems":{"nodes":[
              {"createdAt":"2026-11-12T01:00:00Z","requestedReviewer":null}]}}
            """#
        let mineJSON = [pullRequest("APPROVED", "CLEAN"), pullRequest("APPROVED", "CLEAN", draft: true),
                        pullRequest(nil, "BLOCKED", requests: ["Team"], reviews: [claude]),
                        pullRequest(nil, "BLOCKED", requests: ["Team", "User"])].joined(separator: ",")
        let response = #"{"data":{"viewer":{"login":"me"},"requested":{"issueCount":2,"nodes":[\#(requestedJSON)]},"#
            + #""mine":{"nodes":[\#(mineJSON)]}}}"#
        let noon = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
        do {
            // PR 1: last asked 2026-11-11T00:00Z, 36 h before; PR 2 falls back to its creation, 12 h.
            expect(try parseReview(Data(response.utf8), now: noon),
                   Review(count: 2, oldestMin: 2160, mine: MyPullRequests(ready: 1, inReview: 1, notAsked: 1)),
                   "review counts, oldest request, drafts skipped")
        } catch {
            expect("\(error)", "", "parse a review response")
        }
        let failed = #"{"data":null,"errors":[{"message":"Something went wrong"}]}"#
        expect((try? parseReview(Data(failed.utf8), now: noon)) == nil, true, "GraphQL errors throw")

        // MARK: Meetings

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // November 2026: the 10th is a Tuesday.
        func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
                .addingTimeInterval(second)
        }
        func meeting(_ title: String?, _ start: Date, minutes: Double) -> Meeting {
            Meeting(title: title, start: start, end: start.addingTimeInterval(minutes * 60))
        }

        let start = at(10, 14, 0), end = at(10, 14, 30)
        expect(isMeeting(CalendarEntry(title: "Offsite", start: start, end: end, isAllDay: true, hasOtherAttendee: true)),
               false, "all-day events are not meetings")
        expect(isMeeting(CalendarEntry(title: "Sync", start: start, end: end, declinedByMe: true, hasOtherAttendee: true)),
               false, "declined events are not meetings")
        expect(isMeeting(CalendarEntry(title: "Focus", start: start, end: end)), false, "solo events are not meetings")
        expect(isMeeting(CalendarEntry(title: "Call", start: start, end: end, text: ["Join https://us02web.zoom.us/j/1"])),
               true, "zoom link")
        expect(isMeeting(CalendarEntry(title: "Call", start: start, end: end, text: ["https://meet.google.com/abc-defg-hij"])),
               true, "meet link")
        expect(isMeeting(CalendarEntry(title: "Call", start: start, end: end, text: ["HTTPS://TEAMS.MICROSOFT.COM/l/x"])),
               true, "teams link, any case")
        expect(isMeeting(CalendarEntry(title: "1:1", start: start, end: end, hasOtherAttendee: true)), true, "attendee")

        let oneOnOne = meeting("Gio / Nico - 1:1", at(10, 14, 0), minutes: 30)
        let sync2 = meeting("Eng Weekly Priority Sync", at(10, 15, 0), minutes: 30)
        let day = [oneOnOne, sync2]
        func mode(_ meetings: [Meeting], _ now: Date, live: Date? = nil) -> MeetState {
            meetState(meetings, micLiveSince: live, now: now, calendar: calendar)
        }
        expect(mode([], at(10, 13, 53)), .noMeeting, "no meetings")
        expect(mode(day, at(10, 13, 53)),
               .next(title: "Gio / Nico - 1:1", minsTo: 7, start: 840, dur: 30, day: 0, dow: "TUE", then: 900),
               "next meeting today, then the one after")
        expect(mode(day, at(10, 13, 52, 30)),
               .next(title: "Gio / Nico - 1:1", minsTo: 8, start: 840, dur: 30, day: 0, dow: "TUE", then: 900),
               "minutes round up")
        expect(mode(day, at(10, 13, 57, 59)),
               .next(title: "Gio / Nico - 1:1", minsTo: 3, start: 840, dur: 30, day: 0, dow: "TUE", then: 900),
               "121 s before: still next")
        expect(mode(day, at(10, 13, 58)), .alert(title: "Gio / Nico - 1:1", secsTo: 120, start: 840), "120 s before: alert")
        expect(mode(day, at(10, 13, 59, 59.5)), .alert(title: "Gio / Nico - 1:1", secsTo: 1, start: 840),
               "seconds round up")
        expect(mode(day, at(10, 14, 0)),
               .next(title: "Eng Weekly Priority Sync", minsTo: 60, start: 900, dur: 30, day: 0, dow: "TUE", then: nil),
               "a started meeting without the mic gives way to the next")
        expect(mode([meeting(nil, at(11, 10, 0), minutes: 45), meeting("Later", at(11, 11, 0), minutes: 25)], at(10, 13, 53)),
               .next(title: nil, minsTo: 1207, start: 600, dur: 45, day: 1, dow: "WED", then: 660), "tomorrow")
        expect(mode([meeting("Fri", at(13, 13, 52), minutes: 30)], at(10, 13, 53)),
               .next(title: "Fri", minsTo: 4319, start: 832, dur: 30, day: 3, dow: "FRI", then: nil), "within 3 days")
        expect(mode([meeting("Fri", at(13, 13, 54), minutes: 30)], at(10, 13, 53)), .noMeeting, "beyond 3 days")

        expect(mode(day, at(10, 14, 5, 30), live: at(10, 13, 58)),
               .onair(title: "Gio / Nico - 1:1", elapsed: 330, start: 840, dur: 30, next: 55), "on air in a meeting")
        expect(mode(day, at(10, 13, 59), live: at(10, 13, 58)),
               .onair(title: nil, elapsed: 60, start: 838, dur: 0, next: 1), "on air before the meeting starts")
        expect(mode(day, at(10, 14, 40), live: at(10, 13, 58)),
               .onair(title: "Gio / Nico - 1:1", elapsed: 2400, start: 840, dur: 30, next: 20), "meeting running over")
        expect(mode(day, at(10, 15, 2), live: at(10, 13, 58)),
               .onair(title: "Eng Weekly Priority Sync", elapsed: 120, start: 900, dur: 30, next: nil),
               "back-to-back: the latest meeting")
        expect(mode(day, at(10, 14, 32), live: at(10, 14, 31)),
               .onair(title: nil, elapsed: 60, start: 871, dur: 0, next: 28), "meeting ended before the mic went live")

        // MARK: Microphone

        var mic = MicDebounce()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for second in 0...2 { mic.update(running: true, now: t0 + Double(second)) }
        expect(mic.liveSince, nil, "on for 2 s: not live")
        mic.update(running: true, now: t0 + 3)
        expect(mic.liveSince, t0 + 3, "on for 3 s: live")
        for (second, running) in [(4, false), (5, false), (6, true), (7, false), (9, false)] {
            mic.update(running: running, now: t0 + Double(second))
        }
        expect(mic.liveSince, t0 + 3, "off blips shorter than 3 s keep it live")
        mic.update(running: false, now: t0 + 10)
        expect(mic.liveSince, nil, "off for 3 s: not live")
        for (second, running) in [(20, true), (21, false), (22, true), (24, true)] {
            mic.update(running: running, now: t0 + Double(second))
        }
        expect(mic.liveSince, nil, "on blips shorter than 3 s stay off")
        mic.update(running: true, now: t0 + 25)
        expect(mic.liveSince, t0 + 25, "live after 3 s continuously on")

        // MARK: State JSON

        let review = Review(count: 3, oldestMin: 95, mine: MyPullRequests(ready: 13, inReview: 2, notAsked: 5))
        let wait = Waiting(ask: 1, err: 0, bell: 2)
        let next = DashboardState(wait: wait, meet: mode(day, at(10, 14, 50)), review: review)
        expect(next.json, #"{"meet":{"day":0,"dow":"TUE","dur":30,"minsTo":10,"mode":"next","start":900,"then":null,"#
            + #""title":"Eng Weekly Priority Sync"},"review":{"count":3,"mine":{"inReview":2,"notAsked":5,"ready":13},"#
            + #""oldestMin":95},"wait":{"ask":1,"bell":2,"err":0}}"#, "state JSON with explicit nulls")
        expect(DashboardState().json,
               #"{"meet":{"mode":"none"},"review":{"count":0,"mine":{"inReview":0,"notAsked":0,"ready":0},"#
                   + #""oldestMin":0},"wait":{"ask":0,"bell":0,"err":0}}"#, "empty state JSON")

        let samples: [MeetState] = [
            .noMeeting,
            mode(day, at(10, 13, 53)),
            mode([meeting(nil, at(12, 9, 30), minutes: 60)], at(10, 13, 53)),
            mode(day, at(10, 13, 58, 10)),
            mode(day, at(10, 14, 5, 30), live: at(10, 13, 58)),
            mode(day, at(10, 14, 40), live: at(10, 13, 58)),
            mode(day, at(10, 14, 58), live: at(10, 14, 31)),
        ]
        for meet in samples {
            print("STATE " + DashboardState(wait: wait, meet: meet, review: review).json)
        }

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
    }
}
