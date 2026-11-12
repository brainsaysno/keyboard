// Sends the clock and a Stoic phrase to the Corne's right-half display.
//
// The left half exposes a custom GATT service (src/mac_link.c) that relays numbered text slots to
// the right half: 0 time, 1 day and seconds, 2 phrase, 3 author. The keyboard has no clock or
// text of its own; 90 seconds after this stops, the display shows "Waiting for Mac".
//
// Usage: keyboard-link   (the app that runs it needs Bluetooth permission)

import CoreBluetooth
import Foundation

let serviceUUID = CBUUID(string: "8F2A1C40-6D3B-4B8E-9C71-5E0A3B9D1F60")
let textUUID = CBUUID(string: "8F2A1C41-6D3B-4B8E-9C71-5E0A3B9D1F60")

enum Slot: UInt8 {
    case time = 0, detail, phrase, author
}

// Matches MAC_LINK_MAX_TEXT in src/mac_link_protocol.h.
let maxTextLength = 120
// Each write is [slot][offset][total][text...].
let headerLength = 3

// Kept short enough for five lines of the 68 px wide display.
let phrases: [(text: String, author: String)] = [
    ("What stands in the way becomes the way.", "Aurelius"),
    ("We suffer more in imagination than in reality.", "Seneca"),
    ("No man is free who is not master of himself.", "Epictetus"),
    ("Begin at once to live.", "Seneca"),
    ("Don't explain your philosophy. Embody it.", "Epictetus"),
    ("Very little is needed to make a happy life.", "Aurelius"),
    ("The best revenge is not to be like your enemy.", "Aurelius"),
    ("Loss is nothing else but change.", "Aurelius"),
    ("Confine yourself to the present.", "Aurelius"),
    ("Never let the future disturb you.", "Aurelius"),
    ("Make the best use of what is in your power.", "Epictetus"),
    ("Only the educated are free.", "Epictetus"),
    ("It's not things that upset us, but our judgments.", "Epictetus"),
    ("While we wait for life, life passes.", "Seneca"),
    ("Time discovers truth.", "Seneca"),
    ("He who is brave is free.", "Seneca"),
    ("Luck is where preparation meets opportunity.", "Seneca"),
    ("Difficulties strengthen the mind.", "Seneca"),
    ("Well-being is realized by small steps.", "Zeno"),
    ("If it is not right, do not do it.", "Aurelius"),
    ("Be tolerant with others and strict with yourself.", "Aurelius"),
    ("First say what you would be; then do it.", "Epictetus"),
    ("Hang on to your youthful enthusiasms.", "Seneca"),
    ("Associate with those who will improve you.", "Seneca"),
]

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

func formatter(_ pattern: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = pattern
    return formatter
}

let timeFormatter = formatter("HH:mm")
let detailFormatter = formatter("EEE :ss")

/// The display's fonts only cover printable ASCII.
func displayBytes(_ text: String) -> [UInt8] {
    let folded = text
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
        .replacingOccurrences(of: "\u{2013}", with: "-")
        .replacingOccurrences(of: "\u{2014}", with: "-")
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    let ascii = folded.unicodeScalars.filter { (0x20..<0x7F).contains($0.value) }.map { UInt8($0.value) }
    return Array(ascii.prefix(maxTextLength))
}

final class KeyboardLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var textCharacteristic: CBCharacteristic?
    private var timer: Timer?
    private var phraseMinute: Int?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            log("Bluetooth is not available (state \(central.state.rawValue))")
            return
        }
        findKeyboard()
    }

    /// The keyboard is already connected to macOS as a keyboard; this attaches to that connection.
    private func findKeyboard() {
        guard keyboard == nil, central.state == .poweredOn else { return }
        guard let peripheral = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first else {
            log("No connected keyboard offers the link service; retrying in 5 s")
            retry(after: 5)
            return
        }
        log("Found \(peripheral.name ?? "keyboard"); attaching")
        keyboard = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func retry(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.findKeyboard() }
    }

    private func detach(_ reason: String) {
        log(reason)
        timer?.invalidate()
        timer = nil
        textCharacteristic = nil
        keyboard = nil
        retry(after: 2)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        detach("Could not attach: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        detach("Keyboard disconnected: \(error?.localizedDescription ?? "no error")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            log("Link service not found: \(error?.localizedDescription ?? "missing")")
            return
        }
        peripheral.discoverCharacteristics([textUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == textUUID }) else {
            log("Text characteristic not found: \(error?.localizedDescription ?? "missing")")
            return
        }
        textCharacteristic = characteristic
        let chunk = peripheral.maximumWriteValueLength(for: .withoutResponse) - headerLength
        log("Linked; \(chunk) text bytes per write")
        phraseMinute = nil
        startClock()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Write failed: \(error.localizedDescription)")
        }
    }

    private func startClock() {
        timer?.invalidate()
        tick()
        // Fire just after each second boundary so the display changes with the system clock.
        let next = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 1.02)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        send(.time, timeFormatter.string(from: now))
        send(.detail, detailFormatter.string(from: now))

        // A new phrase each minute, resent every 15 s because the split link can drop a message.
        let minute = Int(now.timeIntervalSince1970 / 60)
        let second = Calendar.current.component(.second, from: now)
        if minute != phraseMinute || second % 15 == 0 {
            let phrase = phrases[minute % phrases.count]
            send(.phrase, phrase.text)
            send(.author, "- \(phrase.author)")
            if minute != phraseMinute {
                log("Phrase: \(phrase.text) - \(phrase.author)")
            }
            phraseMinute = minute
        }
    }

    private func send(_ slot: Slot, _ text: String) {
        guard let keyboard, let characteristic = textCharacteristic else { return }
        let bytes = displayBytes(text)
        let chunk = max(1, keyboard.maximumWriteValueLength(for: .withoutResponse) - headerLength)
        var offset = 0
        repeat {
            let piece = bytes[offset..<min(offset + chunk, bytes.count)]
            let value = Data([slot.rawValue, UInt8(offset), UInt8(bytes.count)] + piece)
            keyboard.writeValue(value, for: characteristic, type: .withResponse)
            offset += piece.count
        } while offset < bytes.count
    }
}

let link = KeyboardLink()
RunLoop.main.run()
