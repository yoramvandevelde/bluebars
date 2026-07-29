import CoreBluetooth
import Foundation
import IOBluetooth

final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let shared = BatteryMonitor()

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    // Not in the public IOBluetoothDevice header, but backs the same battery
    // percentage System Settings shows for classic (non-BLE) accessories.
    private let classicBatteryKeys = [
        "batteryPercentSingle",
        "batteryPercentCombined",
        "batteryPercentLeft",
        "headsetBatteryPercent"
    ]

    private var central: CBCentralManager!
    private var peripheralsByName: [String: CBPeripheral] = [:]
    private var classicDeviceNames: Set<String> = []
    private(set) var batteryByName: [String: Int] = [:]

    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var availableDeviceNames: [String] {
        Set(peripheralsByName.keys).union(classicDeviceNames).sorted()
    }

    func refresh() {
        refreshClassicDevices()

        if central.state == .poweredOn {
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
        } else {
            log("refresh(): central state = \(central.state.rawValue), not poweredOn")
        }

        onUpdate?()
    }

    private func refreshClassicDevices() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log("refreshClassicDevices(): pairedDevices() returned nil/not castable")
            return
        }
        classicDeviceNames.removeAll()
        for device in devices {
            guard device.isConnected(), let name = device.name else { continue }
            // Devices already tracked via BLE GATT report accurate battery levels;
            // classic HFP/HID battery indicators default to 0 (not -1) when unset,
            // which would otherwise clobber a correct BLE reading.
            guard peripheralsByName[name] == nil else { continue }
            classicDeviceNames.insert(name)
            if let percent = classicBatteryPercent(for: device) {
                batteryByName[name] = percent
            }
        }
    }

    private func classicBatteryPercent(for device: IOBluetoothDevice) -> Int? {
        for key in classicBatteryKeys {
            if let number = device.value(forKey: key) as? NSNumber, number.intValue >= 0 {
                return number.intValue
            }
        }
        return nil
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
