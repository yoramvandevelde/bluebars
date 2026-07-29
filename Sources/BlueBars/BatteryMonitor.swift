import CoreBluetooth
import Foundation

final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let shared = BatteryMonitor()

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var peripheralsByName: [String: CBPeripheral] = [:]
    private(set) var batteryByName: [String: Int] = [:]

    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var availableDeviceNames: [String] {
        peripheralsByName.keys.sorted()
    }

    func refresh() {
        guard central.state == .poweredOn else {
            log("refresh(): central state = \(central.state.rawValue), not poweredOn")
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        log("refresh(): found \(connected.count) connected peripheral(s) with Battery Service")
        for peripheral in connected {
            guard let name = peripheral.name else { continue }
            peripheralsByName[name] = peripheral
            if peripheral.state != .connected {
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            } else {
                peripheral.delegate = self
                peripheral.discoverServices([batteryServiceUUID])
            }
        }
        onUpdate?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("centralManagerDidUpdateState: \(central.state.rawValue)")
        if central.state == .poweredOn {
            refresh()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("didConnect: \(peripheral.name ?? "?")")
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect: \(peripheral.name ?? "?") error=\(error?.localizedDescription ?? "nil")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("didDiscoverServices error for \(peripheral.name ?? "?"): \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("didDiscoverCharacteristics error for \(peripheral.name ?? "?"): \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevelUUID {
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevelUUID,
              let data = characteristic.value,
              let byte = data.first,
              let name = peripheral.name else { return }
        log("battery update: \(name) = \(byte)%")
        batteryByName[name] = Int(byte)
        onUpdate?()
    }

    private func log(_ text: String) {
        let line = "[\(Date())] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/bluebars_debug.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}
