import CoreBluetooth
import Foundation

/// Left half's Mac-facing service (src/dashboard_relay.c); it relays every message to the right.
let dashboardServiceUUID = CBUUID(string: "8F2A1C40-6D3B-4B8E-9C71-5E0A3B9D1F60")
let dashboardCharacteristicUUID = CBUUID(string: "8F2A1C41-6D3B-4B8E-9C71-5E0A3B9D1F60")

/// Streams frames to the keyboard over the BLE connection macOS already holds for it as a
/// keyboard. Every callback and call happens on the main queue.
final class Transport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let retryInterval: TimeInterval = 5
    /// Pause between writes. Each one also crosses the split link, and back-to-back writes take
    /// the radio time the keyboard needs for keystrokes, which made typing lag during a refresh.
    private static let writeGap: TimeInterval = 0.05
    /// An attach that has not linked by then is cancelled and retried.
    private static let attachTimeout: TimeInterval = 15

    private var central: CBCentralManager!
    private var keyboard: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var attachStarted: TimeInterval = 0
    private var sync = FrameSync()
    private var queue: [[UInt8]] = []
    private var writing = false
    /// Repeated problems (keyboard missing, write rejected) are logged once until something works.
    private var lastProblem: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] _ in self?.attach() }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Linked, and every message of the previous frame has been written.
    var isIdle: Bool { characteristic != nil && !writing && queue.isEmpty }

    /// The next frame goes out whole: after a (re)connect or a failed write.
    var needsFrame: Bool { sync.needsFull }

    /// Sends what changed since the last frame; ignored unless `isIdle`, so a slow link drops
    /// frames instead of queueing them.
    func send(_ frame: [UInt8]) {
        guard isIdle, let keyboard else { return }
        let payload = dataPayload(maximumWriteLength: keyboard.maximumWriteValueLength(for: .withoutResponse))
        queue = sync.messages(for: frame, now: ProcessInfo.processInfo.systemUptime, payload: payload)
        writeNext()
    }

    // Writes go one at a time with response so the left half's full queue pushes back.
    private func writeNext() {
        guard !writing, !queue.isEmpty, let keyboard, let characteristic else { return }
        writing = true
        keyboard.writeValue(Data(queue.removeFirst()), for: characteristic, type: .withResponse)
    }

    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        log(problem)
    }

    private func attach() {
        guard central.state == .poweredOn, characteristic == nil else { return }
        if let keyboard {
            guard ProcessInfo.processInfo.systemUptime - attachStarted >= Self.attachTimeout else { return }
            // The next tick starts over, after the cancellation's disconnect callback.
            drop("Attaching to \(keyboard.name ?? "the keyboard") timed out; retrying")
            return
        }
        guard let peripheral = central.retrieveConnectedPeripherals(withServices: [dashboardServiceUUID]).first else {
            report("No connected keyboard offers the dashboard service; retrying every \(Int(Self.retryInterval)) s")
            return
        }
        log("Found \(peripheral.name ?? "keyboard"); attaching")
        keyboard = peripheral
        attachStarted = ProcessInfo.processInfo.systemUptime
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func reset() {
        keyboard = nil
        characteristic = nil
        queue.removeAll()
        writing = false
        sync.invalidate()
    }

    /// Gives up on the current keyboard; the retry timer attaches again.
    private func drop(_ reason: String) {
        report(reason)
        if let keyboard { central.cancelPeripheralConnection(keyboard) }
        reset()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            reset()
            report("Bluetooth unavailable (state \(central.state.rawValue))")
            return
        }
        attach()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == keyboard else { return }
        peripheral.discoverServices([dashboardServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == keyboard else { return }
        drop("Could not attach: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == keyboard else { return }
        log("Keyboard link closed: \(error?.localizedDescription ?? "no error")")
        reset()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == dashboardServiceUUID }) else {
            drop("Dashboard service not found: \(error?.localizedDescription ?? "missing")")
            return
        }
        peripheral.discoverCharacteristics([dashboardCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let found = service.characteristics?.first(where: { $0.uuid == dashboardCharacteristicUUID }),
              found.properties.contains(.write)
        else {
            drop("Dashboard characteristic not found: \(error?.localizedDescription ?? "missing")")
            return
        }
        characteristic = found
        sync.invalidate()
        lastProblem = nil
        let payload = dataPayload(maximumWriteLength: peripheral.maximumWriteValueLength(for: .withoutResponse))
        log("Linked to \(peripheral.name ?? "keyboard"); \(payload) bytes per DATA message")
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral == keyboard, invalidatedServices.contains(where: { $0.uuid == dashboardServiceUUID }) else { return }
        drop("Keyboard's dashboard service changed; attaching again")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == keyboard else { return }
        writing = false
        if let error {
            report("Write failed: \(error.localizedDescription); sending the full frame next")
            queue.removeAll()
            sync.invalidate()
            return
        }
        lastProblem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeGap) { [weak self] in self?.writeNext() }
    }
}
