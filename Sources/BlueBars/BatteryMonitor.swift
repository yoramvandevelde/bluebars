import CoreBluetooth
import Foundation

final class BatteryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let shared = BatteryMonitor()

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    // How often to poke a BLE peripheral's Battery Service to refresh macOS's
    // cached value: quickly for a device that just reconnected and has no
    // reading yet, much less often for one that already has a recent value.
    private let missingNudgeInterval: TimeInterval = 20
    private let freshenNudgeInterval: TimeInterval = 300

    private let queryQueue = DispatchQueue(label: "BlueBars.deviceQuery")
    private var central: CBCentralManager!
    private var nudgedPeripherals: [CBPeripheral] = []
    private var lastNudge: [String: Date] = [:]

    private(set) var availableDeviceNames: [String] = []
    private(set) var batteryByName: [String: Int] = [:]

    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func refresh() {
        queryQueue.async { [weak self] in
            guard let self else { return }
            let (names, battery) = self.queryConnectedDevices()
            DispatchQueue.main.async {
                self.availableDeviceNames = names
                // Merge rather than replace: a value we picked up ourselves via a
                // direct BLE GATT read (see didUpdateValueFor) never shows up in
                // system_profiler's output, so don't let this overwrite it. Still
                // drop entries for devices that are no longer connected.
                var merged = self.batteryByName.filter { names.contains($0.key) }
                for (name, percent) in battery { merged[name] = percent }
                self.batteryByName = merged
                self.onUpdate?()
                self.nudgeStaleBLEDevices(names: names, battery: merged)
            }
        }
    }

    // `system_profiler SPBluetoothDataType` reads macOS's own live Bluetooth
    // state (same data System Settings shows) for both BLE and classic devices
    // in one call, at negligible cost (~80ms locally).
    private func queryConnectedDevices() -> ([String], [String: Int]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            log("system_profiler launch failed: \(error.localizedDescription)")
            return ([], [:])
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else {
            return ([], [:])
        }

        var names: [String] = []
        var battery: [String: Int] = [:]
        for entry in connected {
            guard let (name, propsAny) = entry.first, let props = propsAny as? [String: Any] else { continue }
            names.append(name)
            if let level = props["device_batteryLevelMain"] as? String,
               let percent = Int(level.filter(\.isNumber)) {
                battery[name] = percent
            }
        }
        return (names.sorted(), battery)
    }

    // BLE devices' battery level doesn't reliably show up in system_profiler's
    // output (macOS's own cache for it isn't consistently refreshed), so read
    // the standard Battery Service ourselves and use that value directly (see
    // didUpdateValueFor below). Throttled per device so this stays occasional
    // radio traffic rather than continuous polling. Classic-only devices (no
    // BLE, e.g. HFP headsets) never match here and rely on system_profiler.
    private func nudgeStaleBLEDevices(names: [String], battery: [String: Int]) {
        guard central.state == .poweredOn, !names.isEmpty else { return }

        let now = Date()
        let due = names.filter { name in
            let interval = battery[name] == nil ? missingNudgeInterval : freshenNudgeInterval
            return (lastNudge[name].map { now.timeIntervalSince($0) > interval }) ?? true
        }
        guard !due.isEmpty else { return }

        let peripherals = central.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        for peripheral in peripherals {
            guard let name = peripheral.name, due.contains(name) else { continue }
            lastNudge[name] = now
            nudgedPeripherals.append(peripheral)
            peripheral.delegate = self
            if peripheral.state != .connected {
                central.connect(peripheral, options: nil)
            } else {
                peripheral.discoverServices([batteryServiceUUID])
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("centralManagerDidUpdateState: \(central.state.rawValue)")
        // Catches the case where refresh() ran before Bluetooth was ready, so
        // the very first launch doesn't wait out a full poll interval for a
        // BLE nudge to happen at all.
        if central.state == .poweredOn {
            refresh()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        nudgedPeripherals.removeAll { $0 === peripheral }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            nudgedPeripherals.removeAll { $0 === peripheral }
            return
        }
        for service in peripheral.services ?? [] where service.uuid == batteryServiceUUID {
            peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            nudgedPeripherals.removeAll { $0 === peripheral }
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == batteryLevelUUID {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevelUUID else { return }
        nudgedPeripherals.removeAll { $0 === peripheral }
        // Our own GATT read never reaches whatever cache system_profiler mirrors
        // (verified: reading here doesn't make system_profiler's output change),
        // so use this value directly instead of hoping system_profiler picks it up.
        guard error == nil, let byte = characteristic.value?.first, let name = peripheral.name else { return }
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
