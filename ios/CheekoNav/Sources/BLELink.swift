// Bluetooth link to the Cheeko: finds it, stays connected, reconnects on its own
// (also in the background), and writes protocol messages to it.

import CoreBluetooth
import Foundation

final class BLELink: NSObject, ObservableObject {
    enum Status { case bluetoothOff, searching, connecting, connected }

    @Published private(set) var status: Status = .bluetoothOff
    /// The Cheeko asked for everything again (it restarted, or we just subscribed).
    var onHello: (() -> Void)?

    private static let service = CBUUID(string: "6E3A0001-6C3F-4B6A-9C2E-8F1D2C3B4A50")
    private static let rxID = CBUUID(string: "6E3A0002-6C3F-4B6A-9C2E-8F1D2C3B4A50")
    private static let txID = CBUUID(string: "6E3A0003-6C3F-4B6A-9C2E-8F1D2C3B4A50")
    private static let savedKey = "cheekoPeripheral"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var bulk: [Data] = []
    private var pumpScheduled = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "cheeko-central"])
    }

    /// Writes one message. Live data goes without response (fast, may drop);
    /// anything that must arrive (resets, routes) goes with response.
    func send(_ data: Data, reliable: Bool = false) {
        guard status == .connected, let peripheral, let rx else { return }
        peripheral.writeValue(data, for: rx, type: reliable ? .withResponse : .withoutResponse)
    }

    /// Large uploads (street lines): queued and fed out at a pace the Cheeko can
    /// keep up with, without holding up live data. Dropped if the link drops;
    /// the Cheeko then says HELLO and everything is sent again.
    func sendBulk(_ messages: [Data]) {
        bulk += messages
        pump()
    }

    func cancelBulk() { bulk.removeAll() }

    private func pump() {
        guard status == .connected, let peripheral, let rx else { return }
        var sentNow = 0
        while !bulk.isEmpty && peripheral.canSendWriteWithoutResponse && sentNow < 12 {
            peripheral.writeValue(bulk.removeFirst(), for: rx, type: .withoutResponse)
            sentNow += 1
        }
        if !bulk.isEmpty && !pumpScheduled {  // about 240 messages a second at most
            pumpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pumpScheduled = false
                self?.pump()
            }
        }
    }

    private func connectOrScan() {
        guard central.state == .poweredOn else { return }
        if let id = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            status = .searching
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = .connecting
        // A pending connect never times out: iOS completes it whenever the Cheeko
        // comes back in range, even with the app in the background.
        central.connect(p)
    }
}

extension BLELink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if let peripheral, peripheral.state == .connected {
                peripheral.discoverServices([Self.service])
            } else {
                connectOrScan()
            }
        } else {
            status = .bluetoothOff
            rx = nil
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        rx = nil
        bulk.removeAll()
        connect(p)
    }
}

extension BLELink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == Self.service }) else {
            // Saved device isn't a Cheeko any more: forget it and look again.
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.rxID, Self.txID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.rxID { rx = c }
            if c.uuid == Self.txID { p.setNotifyValue(true, for: c) }  // the Cheeko answers with HELLO
        }
        if rx != nil { status = .connected }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { pump() }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if c.value?.first == 0x20 { onHello?() }
    }
}
