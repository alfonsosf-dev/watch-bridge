import CoreBluetooth
import Combine
import UIKit
import os.log

/// Manages BLE for the WearBridge companion app.
///
/// Acts as both:
/// - CBPeripheralManager: advertises for initial watch pairing
/// - CBCentralManager: detects connected watches via system BLE connections
///
/// ANCS itself is system-managed — this class provides discoverability and
/// connection status tracking.
class PeripheralManager: NSObject, ObservableObject {

    private let logger = Logger(subsystem: "com.wearos.ancsbridge", category: "PeripheralManager")

    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!

    @Published var isAdvertising = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var discoveredWatches: [DiscoveredWatch] = []
    /// True while a watch holds a subscription to the health-control
    /// characteristic — the practical "bridge connected" signal for UI.
    @Published private(set) var isWatchSubscribed = false

    let settingsStore = SettingsStore()

    private var companionService: CBMutableService?
    private var statusCharacteristic: CBMutableCharacteristic?
    private var callStateCharacteristic: CBMutableCharacteristic?
    private var healthControlCharacteristic: CBMutableCharacteristic?
    private var healthDataCharacteristic: CBMutableCharacteristic?
    private var tunnelPsmCharacteristic: CBMutableCharacteristic?
    /// PSM of the published L2CAP tunnel channel (0 = not published yet)
    private var tunnelPsm: CBL2CAPPSM = 0
    private var serviceAdded = false
    private var scanTimer: Timer?
    /// Health control notification that didn't fit the BLE buffer — retried
    /// when the peripheral manager signals readiness.
    private var pendingHealthControl: Data?

    /// Health bridge: decodes B6 batches, writes to HealthKit, acks via B5.
    let healthSyncManager = HealthSyncManager()

    /// Monitors phone call state via CallKit for live call status sync
    let callStateObserver = CallStateObserver()

    /// Standard BLE service UUIDs to probe for connected devices.
    /// Wear OS watches expose these standard GATT services.
    private static let probeServiceUUIDs: [CBUUID] = [
        CBUUID(string: "180A"),  // Device Information
        CBUUID(string: "180F"),  // Battery Service
        CBUUID(string: "1800"),  // Generic Access
        CBUUID(string: "1805"),  // Current Time Service
    ]

    /// Known Wear OS watch name patterns
    private static let watchNamePatterns = [
        "pixel watch", "galaxy watch", "ticwatch", "fossil",
        "oppo watch", "oneplus watch", "mobvoi", "wear os", "xiaomi watch",
        "ancs"  // Our own app's advertised name during pairing
    ]

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey: BLEConstants.restoreIdentifier
            ]
        )
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ]
        )

        // Wire up call state observer to push BLE notifications
        callStateObserver.onCallStateChanged = { [weak self] state in
            self?.notifyCallState(state)
        }
        // Wire up health bridge acks/time-sync through this manager's B5 characteristic
        healthSyncManager.channel = self
        // Remote triggers live in SettingsStore; pushed after HELLO and on edits
        healthSyncManager.triggersProvider = { [weak self] in
            self?.settingsStore.remoteTriggers ?? []
        }
        // Fetched watch-app lists persist via SettingsStore (picker cache)
        healthSyncManager.appListPersister = { [weak self] apps in
            self?.settingsStore.watchApps = apps
            self?.settingsStore.watchAppsFetchedAt = Date()
        }
        // Start/stop based on setting
        updateCallStateObserving()
    }

    /// Start or stop call state observing based on the current setting.
    func updateCallStateObserving() {
        if settingsStore.liveCallStatus {
            callStateObserver.startObserving()
        } else {
            callStateObserver.stopObserving()
        }
    }

    /// Push call state to all subscribed watches via BLE notification.
    private func notifyCallState(_ state: UInt8) {
        guard let char = callStateCharacteristic else { return }
        let data = Data([state])
        let sent = peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        let stateStr: String
        switch state {
        case BLEConstants.callStateRinging: stateStr = "ringing"
        case BLEConstants.callStateActive: stateStr = "active"
        case BLEConstants.callStateEnded: stateStr = "ended"
        default: stateStr = "idle"
        }
        logger.info("Call state BLE notify: \(stateStr), sent=\(sent)")
    }

    // MARK: - Connected Watch Discovery

    /// Query the system for BLE peripherals currently connected that look like watches.
    /// Merges with persisted watches so offline ones still appear in the list.
    func refreshConnectedWatches() {
        guard centralManager.state == .poweredOn else { return }

        var found: [UUID: CBPeripheral] = [:]

        // Retrieve peripherals connected to the system with known services
        for serviceUUID in Self.probeServiceUUIDs {
            let peripherals = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
            for peripheral in peripherals {
                found[peripheral.identifier] = peripheral
            }
        }

        // Filter to likely watches by name
        var connectedWatchIds = Set<String>()
        var result: [DiscoveredWatch] = []

        for peripheral in found.values {
            guard let name = peripheral.name, !name.isEmpty else { continue }
            let lower = name.lowercased()
            let isWatch = Self.watchNamePatterns.contains { lower.contains($0) }
            let savedWatches = loadPersistedWatches()
            let wasPreviouslySeen = savedWatches.contains { $0.id == peripheral.identifier.uuidString }

            guard isWatch || wasPreviouslySeen else { continue }

            // Persist this watch
            savePersistedWatch(PersistedWatch(id: peripheral.identifier.uuidString, name: name))
            connectedWatchIds.insert(peripheral.identifier.uuidString)

            result.append(DiscoveredWatch(
                id: peripheral.identifier,
                name: name,
                isConnected: true,
                peripheral: peripheral
            ))
        }

        // Add offline (persisted but not currently connected) watches
        for saved in loadPersistedWatches() {
            if !connectedWatchIds.contains(saved.id), let uuid = UUID(uuidString: saved.id) {
                result.append(DiscoveredWatch(
                    id: uuid,
                    name: saved.name,
                    isConnected: false,
                    peripheral: nil
                ))
            }
        }

        DispatchQueue.main.async {
            // Connected watches first, then offline
            self.discoveredWatches = result.sorted { $0.isConnected && !$1.isConnected }
            let connected = result.filter { $0.isConnected }.count
            self.logger.info("Watches: \(connected) connected, \(result.count - connected) offline")
        }
    }

    // MARK: - Watch Persistence

    private static let persistedWatchesKey = "persistedWatches"

    private func loadPersistedWatches() -> [PersistedWatch] {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedWatchesKey),
              let watches = try? JSONDecoder().decode([PersistedWatch].self, from: data) else {
            return []
        }
        return watches
    }

    private func savePersistedWatch(_ watch: PersistedWatch) {
        var watches = loadPersistedWatches()
        if let index = watches.firstIndex(where: { $0.id == watch.id }) {
            watches[index] = watch
        } else {
            watches.append(watch)
        }
        if let data = try? JSONEncoder().encode(watches) {
            UserDefaults.standard.set(data, forKey: Self.persistedWatchesKey)
        }
    }

    /// Start periodic scanning for connected watches
    func startWatchRefresh() {
        refreshConnectedWatches()
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshConnectedWatches()
        }
    }

    func stopWatchRefresh() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Advertising

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            logger.warning("Cannot advertise: Bluetooth not powered on")
            return
        }

        if peripheralManager.isAdvertising {
            isAdvertising = true
            return
        }

        peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: BLEConstants.advertisingLocalName,
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.companionServiceUUID]
        ])

        logger.info("Started advertising as '\(BLEConstants.advertisingLocalName)'")
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        isAdvertising = false
        logger.info("Stopped advertising")
    }

    private func setupServices() {
        guard !serviceAdded else { return }

        statusCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.connectionStatusUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        let quickReplyCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.quickReplyCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        callStateCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.callStateCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        healthControlCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.healthControlCharacteristicUUID,
            // B5: watch writes HELLO/PING; iOS notifies ACK/TIME_SYNC/PONG; readable as time-sync snapshot
            properties: [.read, .notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )

        healthDataCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.healthDataCharacteristicUUID,
            // B6: watch writes TLV record batches (one complete batch per write)
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        tunnelPsmCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.tunnelPsmCharacteristicUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        companionService = CBMutableService(
            type: BLEConstants.companionServiceUUID,
            primary: true
        )
        companionService?.characteristics = [
            statusCharacteristic!,
            quickReplyCharacteristic,
            callStateCharacteristic!,
            healthControlCharacteristic!,
            healthDataCharacteristic!,
            tunnelPsmCharacteristic!
        ]

        peripheralManager.add(companionService!)
        serviceAdded = true
        logger.info("Companion service added")
    }
}

// MARK: - CBPeripheralManagerDelegate
extension PeripheralManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        bluetoothState = peripheral.state
        logger.info("Peripheral Bluetooth state: \(peripheral.state.rawValue)")

        switch peripheral.state {
        case .poweredOn:
            setupServices()
            if tunnelPsm == 0 {
                // Encrypted channel: only the bonded watch can open it
                peripheral.publishL2CAPChannel(withEncryption: true)
            }
            if settingsStore.autoAdvertise {
                startAdvertising()
            }
        case .poweredOff:
            isAdvertising = false
            discoveredWatches = []
            tunnelPsm = 0
            TunnelServer.shared.close()
        default:
            break
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            logger.error("Failed to start advertising: \(error.localizedDescription)")
            isAdvertising = false
        } else {
            isAdvertising = true
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.info("Central subscribed: \(central.identifier)")
        if characteristic.uuid == BLEConstants.healthControlCharacteristicUUID {
            isWatchSubscribed = true
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        logger.info("Central unsubscribed: \(central.identifier)")
        if characteristic.uuid == BLEConstants.healthControlCharacteristicUUID {
            isWatchSubscribed = false
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BLEConstants.connectionStatusUUID {
            request.value = Data([0x01])
            peripheral.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == BLEConstants.callStateCharacteristicUUID {
            request.value = Data([callStateObserver.currentState])
            peripheral.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == BLEConstants.tunnelPsmCharacteristicUUID {
            let psm = UInt16(tunnelPsm)
            request.value = Data([UInt8(psm & 0xFF), UInt8(psm >> 8)])
            peripheral.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == BLEConstants.healthControlCharacteristicUUID {
            // Time-sync snapshot without subscribing
            let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
            request.value = HealthControlCodec.encode(.timeSync(epochMs: epochMs))
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.quickReplyCharacteristicUUID,
               let data = request.value,
               let payload = String(data: data, encoding: .utf8) {
                logger.info("Quick reply received: \(payload)")
                handleQuickReply(payload)
            } else if request.characteristic.uuid == BLEConstants.healthControlCharacteristicUUID,
                      let data = request.value {
                logger.debug("Health control write (\(data.count) bytes)")
                healthSyncManager.handleControlWrite(data)
            } else if request.characteristic.uuid == BLEConstants.healthDataCharacteristicUUID,
                      let data = request.value {
                logger.debug("Health data batch (\(data.count) bytes)")
                healthSyncManager.handleDataWrite(data)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    // MARK: - Health control channel

    /// Sends a control notification (ACK/TIME_SYNC/PONG) to subscribed watches.
    /// If the BLE buffer is full the message is queued and flushed on
    /// peripheralManagerIsReady(toUpdateSubscribers:).
    @discardableResult
    func sendHealthControl(_ data: Data) -> Bool {
        guard let char = healthControlCharacteristic else { return false }
        let sent = peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        if !sent {
            pendingHealthControl = data
            logger.info("Health control buffered — BLE buffer full")
        }
        return sent
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if let data = pendingHealthControl {
            pendingHealthControl = nil
            _ = sendHealthControl(data)
        }
    }

    private func handleQuickReply(_ payload: String) {
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? payload
        let urlString = "shortcuts://run-shortcut?name=WearBridge%20Reply&input=text&text=\(encoded)"
        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    if success {
                        self.logger.info("Opened WearBridge Reply shortcut")
                    } else {
                        self.logger.error("Failed to open Shortcuts — is 'WearBridge Reply' shortcut created?")
                    }
                }
            }
        }
    }

    // MARK: - L2CAP internet-tunnel probe

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error = error {
            logger.error("L2CAP publish failed: \(error.localizedDescription)")
            return
        }
        tunnelPsm = PSM
        logger.info("L2CAP tunnel published on PSM \(PSM)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            logger.error("L2CAP open failed: \(error.localizedDescription)")
            return
        }
        if let channel = channel {
            TunnelServer.shared.accept(channel)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        logger.info("Restoring peripheral manager state")
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            serviceAdded = !services.isEmpty
        }
        if peripheral.isAdvertising {
            isAdvertising = true
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension PeripheralManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central Bluetooth state: \(central.state.rawValue)")

        if central.state == .poweredOn {
            startWatchRefresh()
        } else {
            stopWatchRefresh()
            DispatchQueue.main.async {
                self.discoveredWatches = []
            }
        }
    }
}

extension PeripheralManager: HealthControlChannel {}

// MARK: - DiscoveredWatch Model
struct DiscoveredWatch: Identifiable {
    let id: UUID
    let name: String
    let isConnected: Bool
    let peripheral: CBPeripheral?
}

// MARK: - Persisted Watch (for offline display)
struct PersistedWatch: Codable {
    let id: String // UUID string
    let name: String
}
