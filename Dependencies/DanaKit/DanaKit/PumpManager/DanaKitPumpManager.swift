//
//  DanaKitPumpManager.swift
//  DanaKit
//
//  Based on OmniKit/PumpManager/OmnipodPumpManager.swift
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import UserNotifications
import os.log
import CoreBluetooth
import UIKit

private enum ConnectionResult {
    case success
    case failure
}

public protocol StateObserver: AnyObject {
    func stateDidUpdate(_ state: DanaKitPumpManagerState, _ oldState: DanaKitPumpManagerState)
    func deviceScanDidUpdate(_ device: DanaPumpScan)
}

public class DanaKitPumpManager: DeviceManager {
    private static var bluetoothManager = BluetoothManager()
    
    private var oldState: DanaKitPumpManagerState
    public var state: DanaKitPumpManagerState
    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }
    
    public static let pluginIdentifier: String = "Dana" // use a single token to make parsing log files easier
    public let managerIdentifier: String = "Dana"
    
    public let localizedTitle = LocalizedString("Dana-i/RS", comment: "Generic title of the DanaKit pump manager")
    
    public init(state: DanaKitPumpManagerState, dateGenerator: @escaping () -> Date = Date.init) {
        self.state = state
        self.oldState = DanaKitPumpManagerState(rawValue: state.rawValue)
        
        DanaKitPumpManager.bluetoothManager.pumpManagerDelegate = self
        
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    public required convenience init?(rawState: PumpManager.RawStateValue) {
        self.init(state: DanaKitPumpManagerState(rawValue: rawState))
    }
    
    private let log = Logger(category: "DanaKitPumpManager")
    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    private let stateObservers = WeakSynchronizedSet<StateObserver>()
    private let scanDeviceObservers = WeakSynchronizedSet<StateObserver>()
    
    private var doseReporter: DanaKitDoseProgressReporter?
    private var doseEntry: UnfinalizedDose?
    
    public var isOnboarded: Bool {
        self.state.isOnBoarded
    }
    
    private let basalIntervals: [TimeInterval] = Array(0..<24).map({ TimeInterval(60 * 60 * $0) })
    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)
        
        let index = (basalIntervals.firstIndex(where: { $0 > nowTimeInterval}) ?? 24) - 1
        return self.state.basalSchedule[index]
    }
    public var status: PumpManagerStatus {
        return self.status(state)
    }
    
    public var debugDescription: String {
        let lines = [
            "## DanaKitPumpManager",
            state.debugDescription
        ]
        return lines.joined(separator: "\n")
    }
    
    public func connect(_ peripheral: CBPeripheral, _ completion: @escaping (Error?) -> Void) {
        DanaKitPumpManager.bluetoothManager.connect(peripheral, completion)
    }
    
    public func disconnect(_ peripheral: CBPeripheral) {
        DanaKitPumpManager.bluetoothManager.disconnect(peripheral)
        self.state.resetState()
    }
    
    public func startScan() throws {
        try DanaKitPumpManager.bluetoothManager.startScan()
    }
    
    public func stopScan() {
        DanaKitPumpManager.bluetoothManager.stopScan()
    }
    
    // Not persisted
    var provideHeartbeat: Bool = false

    private var lastHeartbeat: Date = .distantPast
    
    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        provideHeartbeat = mustProvideBLEHeartbeat
    }

    private func issueHeartbeatIfNeeded() {
        if self.provideHeartbeat, Date().timeIntervalSince(lastHeartbeat) > 2 * 60 {
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManagerBLEHeartbeatDidFire(self)
            }
            self.lastHeartbeat = Date()
        }
    }
    
    private let backgroundTask = BackgroundTask()
    @objc func appMovedToBackground() {
        if self.state.useSilentTones {
            self.log.info("\(#function, privacy: .public): Starting silent tones")
            backgroundTask.startBackgroundTask()
        }
    }

    @objc func appMovedToForeground() {
        backgroundTask.stopBackgroundTask()
    }
}

extension DanaKitPumpManager: PumpManager {
    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        return 24
    }
    
    public static var onboardingSupportedBasalRates: [Double] {
        // 0.05 units for rates between 0.00-3U/hr
        // 0 U/hr is a supported scheduled basal rate
        return (0...60).map { Double($0) / 20 }
    }
    
    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.10 units for rates between 0.10-30U
        // 0 is not a supported bolus volume
        return (1...300).map { Double($0) / 10 }
    }
    
    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        return DanaKitPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }
    
    public var supportedBasalRates: [Double] {
        return DanaKitPumpManager.onboardingSupportedBasalRates
    }
    
    public var supportedBolusVolumes: [Double] {
        return DanaKitPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var supportedMaximumBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        return DanaKitPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var maximumBasalScheduleEntryCount: Int {
        return DanaKitPumpManager.onboardingMaximumBasalScheduleEntryCount
    }
    
    public var minimumBasalScheduleEntryDuration: TimeInterval {
        // One per hour
        return TimeInterval(60 * 60)
    }
    
    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding a 0 U volume to 0
        return supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }
    
    public var pumpManagerDelegate: LoopKit.PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }
    
    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }
    
    public var pumpReservoirCapacity: Double {
        return Double(self.state.reservoirLevel)
    }
    
    public var lastSync: Date? {
        return self.state.lastStatusDate
    }
    
    private func status(_ state: DanaKitPumpManagerState) -> LoopKit.PumpManagerStatus {
        // Check if temp basal is expired, before constructing basalDeliveryState
        if self.state.basalDeliveryOrdinal == .tempBasal && self.state.tempBasalEndsAt < Date.now {
            self.state.basalDeliveryOrdinal = .active
            self.state.basalDeliveryDate = Date.now
            self.state.tempBasalDuration = nil
            self.state.tempBasalUnits = nil
        }
        
        return PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(),
            pumpBatteryChargeRemaining: state.batteryRemaining / 100,
            basalDeliveryState: state.basalDeliveryState,
            bolusState: bolusState(state.bolusState),
            insulinType: state.insulinType
        )
    }
    
    private func bolusState(_ bolusState: BolusState) -> PumpManagerStatus.BolusState {
        switch bolusState {
        case .noBolus:
            return .noBolus
        case .initiating:
            return .initiating
        case .canceling:
            return .canceling
        case .inProgress:
            if let dose = self.doseEntry?.toDoseEntry() {
                return .inProgress(dose)
            }
            
            return .noBolus
        }
    }
    
    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard Date.now.timeIntervalSince(self.state.lastStatusDate) > .minutes(6) else {
            self.log.info("\(#function, privacy: .public): Skipping status update because pumpData is fresh: \(Date.now.timeIntervalSince(self.state.lastStatusDate)) sec")
            completion?(self.state.lastStatusDate)
            return
        }
        
        syncPump(completion)
    }
    
    /// Extention from ensureCurrentPumpData, but overrides the stale data check
    public func syncPump(_ completion: ((Date?) -> Void)?) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Syncing pump data")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection failure")
                    completion?(nil)
                    return
                case .success:
                    let events = await self.syncHistory()
                    self.state.lastStatusDate = Date.now
                    
                    self.disconnect()

                    self.issueHeartbeatIfNeeded()
                    self.notifyStateDidChange()
                    
                    self.pumpDelegate.notify { (delegate) in
                        delegate?.pumpManager(self, hasNewPumpEvents: events, lastReconciliation: Date.now, completion: { _ in })
                        delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoirLevel, at: Date.now, completion: { _ in })
                        delegate?.pumpManagerDidUpdateState(self)
                    }
                    
                    completion?(Date.now)
                }
            }
        }
    }
    
    private func syncHistory() async -> [NewPumpEvent] {
        var hasHistoryModeBeenActivate = false
        do {
            let activateHistoryModePacket = generatePacketGeneralSetHistoryUploadMode(options: PacketGeneralSetHistoryUploadMode(mode: 1))
            let activateHistoryModeResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(activateHistoryModePacket)
            guard activateHistoryModeResult.success else {
                return []
            }
            
            hasHistoryModeBeenActivate = true
            
            let fetchHistoryPacket = generatePacketHistoryAll(options: PacketHistoryBase(from: state.lastStatusDate))
            let fetchHistoryResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(fetchHistoryPacket)
            guard activateHistoryModeResult.success else {
                return []
            }
            
            let deactivateHistoryModePacket = generatePacketGeneralSetHistoryUploadMode(options: PacketGeneralSetHistoryUploadMode(mode: 0))
            let _ = try await DanaKitPumpManager.bluetoothManager.writeMessage(deactivateHistoryModePacket)

            return (fetchHistoryResult.data as! [HistoryItem]).map({ item in
                switch(item.code) {
                case HistoryCode.RECORD_TYPE_ALARM:
                    return NewPumpEvent(date: item.timestamp, dose: nil, raw: item.raw, title: "Alarm: \(getAlarmMessage(param8: item.alarm))", type: .alarm, alarmType: PumpAlarmType.fromParam8(item.alarm))
                
                case HistoryCode.RECORD_TYPE_BOLUS:
                    // If we find a bolus here, we assume that is hasnt been synced to Loop
                    return NewPumpEvent.bolus(
                        dose: DoseEntry.bolus(units: item.value!, deliveredUnits: item.value!, duration: item.durationInMin! * 60, activationType: .manualNoRecommendation, insulinType: self.state.insulinType!, startDate: item.timestamp),
                        units: item.value!,
                        date: item.timestamp)
                    
                case HistoryCode.RECORD_TYPE_SUSPEND:
                    if item.value! == 1 {
                        return NewPumpEvent.suspend(dose: DoseEntry.suspend(suspendDate: item.timestamp))
                    } else {
                        return NewPumpEvent.resume(dose: DoseEntry.resume(insulinType: self.state.insulinType!, resumeDate: item.timestamp), date: item.timestamp)
                    }
                    
                case HistoryCode.RECORD_TYPE_PRIME:
                    return NewPumpEvent(date: item.timestamp, dose: nil, raw: item.raw, title: "Prime \(item.value!)U", type: .prime, alarmType: nil)
                    
                case HistoryCode.RECORD_TYPE_REFILL:
                    return NewPumpEvent(date: item.timestamp, dose: nil, raw: item.raw, title: "Rewind \(item.value!)U", type: .rewind, alarmType: nil)
                    
                case HistoryCode.RECORD_TYPE_TEMP_BASAL:
                    // TODO: Find a way to convert % to U/hr
                    return nil
                    
                default:
                    return nil
                }
            })
            // Filter nil values
            .compactMap{$0}
        } catch {
            self.log.error("\(#function, privacy: .public): Failed to sync history. Error: \(error.localizedDescription, privacy: .public)")
            if hasHistoryModeBeenActivate {
                do {
                    let deactivateHistoryModePacket = generatePacketGeneralSetHistoryUploadMode(options: PacketGeneralSetHistoryUploadMode(mode: 0))
                    let _ = try await DanaKitPumpManager.bluetoothManager.writeMessage(deactivateHistoryModePacket)
                } catch {}
            }
            return []
        }
    }
    
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        return doseReporter
    }
    
    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        switch(self.state.bolusSpeed) {
        case .speed12:
            return units * 12 // 12sec/U
        case .speed30:
            return units * 30 // 30sec/U
        case .speed60:
            return units * 60 // 60sec/U
        }
    }
    
    public func enactBolus(units: Double, activationType: BolusActivationType, completion: @escaping (PumpManagerError?) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Enact bolus")
            
            let duration = self.estimatedDuration(toBolus: units)
            self.doseEntry = UnfinalizedDose(units: units, duration: duration, activationType: activationType, insulinType: self.state.insulinType!)
            self.state.bolusState = .initiating
            self.doseReporter = DanaKitDoseProgressReporter(total: units)
            self.notifyStateDidChange()
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    self.state.bolusState = .noBolus
                    self.doseReporter = nil
                    self.notifyStateDidChange()
                    
                    completion(PumpManagerError.connection(DanaKitPumpManagerError.noConnection))
                    return
                case .success:
                    guard !self.state.isPumpSuspended else {
                        self.state.bolusState = .noBolus
                        self.doseReporter = nil
                        self.doseEntry = nil
                        self.notifyStateDidChange()
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Pump is suspended")
                        completion(PumpManagerError.deviceState(DanaKitPumpManagerError.pumpSuspended))
                        return
                    }
                    
                    do {
                        let packet = generatePacketBolusStart(options: PacketBolusStart(amount: units, speed: self.state.bolusSpeed))
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        guard result.success else {
                            self.state.bolusState = .noBolus
                            self.doseReporter = nil
                            self.doseEntry = nil
                            self.notifyStateDidChange()
                            self.disconnect()
                            
                            completion(PumpManagerError.uncertainDelivery)
                            return
                        }
                        
                        self.state.lastStatusDate = Date()
                        self.state.bolusState = .inProgress
                        self.notifyStateDidChange()
                        
                        // It is not possible to enforce other commands while the bolus is going
                        // Therefore, we set a timer and after that, we allow a possible temp basal to continue
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1 + duration) {
                            self.state.lastStatusDate = Date()
                            self.state.bolusState = .noBolus
                            self.doseReporter = nil
                            self.doseEntry = nil
                            self.notifyStateDidChange()
                        }
                        
                        completion(nil)
                    } catch {
                        self.state.bolusState = .noBolus
                        self.doseReporter = nil
                        self.notifyStateDidChange()
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to do bolus. Error: \(error.localizedDescription, privacy: .public)")
                        completion(PumpManagerError.connection(DanaKitPumpManagerError.unknown(error.localizedDescription)))
                    }
                }
            }
        }
    }
    
    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Cancel bolus")
            
            let oldBolusState = self.state.bolusState
            self.state.bolusState = .canceling
            self.notifyStateDidChange()
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    self.state.bolusState = oldBolusState
                    self.notifyStateDidChange()
                    
                    completion(.failure(PumpManagerError.connection(DanaKitPumpManagerError.noConnection)))
                    return
                case .success:
                    do {
                        let packet = generatePacketBolusStop()
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        self.disconnect()
                        
                        if (!result.success) {
                            self.state.bolusState = oldBolusState
                            self.notifyStateDidChange()
                            
                            completion(.failure(PumpManagerError.communication(nil)))
                            return
                        }
                        
                        // Increase status update date, to prevent double bolus entries
                        self.state.lastStatusDate = Date()
                        self.state.bolusState = .noBolus
                        self.notifyStateDidChange()
                        
                        completion(.success(nil))
                        return
                    } catch {
                        self.state.bolusState = oldBolusState
                        self.notifyStateDidChange()
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to cancel bolus. Error: \(error.localizedDescription, privacy: .public)")
                        completion(.failure(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription))))
                    }
                }
            }
        }
    }
    
    /// NOTE: There are 2 ways to set a temp basal:
    /// - The normal way (which only accepts full hours and percentages)
    /// - A short APS-special temp basal command (which only accepts 15 min or 30 min
    /// Currently, this is implemented with a simpel U/hr -> % calculator
    /// NOTE: A temp basal >200% for 30 min (or full hour) is rescheduled to 15min
    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Enact temp basal. Value: \(unitsPerHour) U/hr, duration: \(duration) sec")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(PumpManagerError.connection(DanaKitPumpManagerError.noConnection))
                    return
                case .success:
                    guard !self.state.isPumpSuspended else {
                        self.log.error("\(#function, privacy: .public): Pump is suspended")
                        self.disconnect()
                        completion(PumpManagerError.deviceState(DanaKitPumpManagerError.pumpSuspended))
                        return
                    }
                    
                    do {
                        // Check if duration is supported
                        // If not, round it down to nearest supported duration
                        var duration = duration
                        if !self.isSupportedDuration(duration) {
                            let oldDuration = duration
                            if duration > .hours(1) {
                                // Round down to nearest full hour
                                duration = .hours(1) * floor(duration / .hours(1))
                                self.log.info("\(#function, privacy: .public): Temp basal rounded down from \(oldDuration / .hours(1))h to \(floor(duration / .hours(1)))h")
                                
                            } else if duration > .minutes(30) {
                                // Round down to 30 min
                                duration = .minutes(30)
                                self.log.info("\(#function, privacy: .public): Temp basal rounded down from \(oldDuration / .minutes(1))min to 30min")
                                
                            } else if duration > .minutes(15) {
                                // Round down to 15 min
                                duration = .minutes(15)
                                self.log.info("\(#function, privacy: .public): Temp basal rounded down from \(oldDuration / .minutes(1))min to 15min")
                                
                            } else {
                                self.disconnect()
                                self.log.error("\(#function, privacy: .public): Temp basal below 15 min is unsupported (floor duration)")
                                completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Temp basal below 15 min is unsupported... (floor duration)")))
                                return
                            }
                        }
                        
                        guard let percentage = self.absoluteBasalRateToPercentage(absoluteValue: unitsPerHour, basalSchedule: self.state.basalSchedule) else {
                            self.disconnect()
                            self.log.error("\(#function, privacy: .public): Basal schedule is not available...")
                            completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Basal schedule is not available...")))
                            return
                        }
                        
                        // Temp basal >15min && >200% is not supported
                        // Floor it down to 15min
                        if percentage > 200 && duration != .minutes(15) {
                            duration = .minutes(15)
                        }
                        
                        if self.state.isTempBasalInProgress {
                            let packet = generatePacketBasalCancelTemporary()
                            let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                            
                            guard result.success else {
                                self.disconnect()
                                self.log.error("\(#function, privacy: .public): Could not cancel old temp basal")
                                completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Could not cancel old temp basal")))
                                return
                            }
                            
                            self.log.info("\(#function, privacy: .public): Succesfully canceled old temp basal")
                        }
                        
                        if (duration < .ulpOfOne) {
                            // Temp basal is already canceled (if deem needed)
                            self.disconnect()
                            
                            self.state.basalDeliveryOrdinal = .active
                            self.state.basalDeliveryDate = Date.now
                            self.state.tempBasalUnits = nil
                            self.state.tempBasalDuration = nil
                            self.notifyStateDidChange()
                            
                            let dose = DoseEntry.basal(rate: self.currentBaseBasalRate, insulinType: self.state.insulinType!)
                            self.pumpDelegate.notify { (delegate) in
                                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.basal(dose: dose)], lastReconciliation: Date.now, completion: { _ in })
                            }
                            
                            self.log.info("\(#function, privacy: .public): Succesfully cancelled temp basal")
                            completion(nil)
                            
                        } else if duration == .minutes(15) {
                            let packet = generatePacketLoopSetTemporaryBasal(options: PacketLoopSetTemporaryBasal(percent: percentage, duration: .min15))
                            let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                            self.disconnect()
                            
                            guard result.success else {
                                self.log.error("\(#function, privacy: .public): Pump rejected command (15 min)")
                                completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Pump rejected command (15 min)")))
                                return
                            }
                            
                            let dose = DoseEntry.tempBasal(absoluteUnit: unitsPerHour, duration: duration, insulinType: self.state.insulinType!)
                            self.state.basalDeliveryOrdinal = .tempBasal
                            self.state.basalDeliveryDate = Date.now
                            self.state.tempBasalUnits = unitsPerHour
                            self.state.tempBasalDuration = duration
                            self.notifyStateDidChange()
                            
                            self.pumpDelegate.notify { (delegate) in
                                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.tempBasal(dose: dose, units: unitsPerHour, duration: duration)], lastReconciliation: Date.now, completion: { _ in })
                            }
                            
                            self.log.info("\(#function, privacy: .public): Succesfully started 15 min temp basal")
                            completion(nil)
                            
                        } else if duration == .minutes(30) {
                            let packet = generatePacketLoopSetTemporaryBasal(options: PacketLoopSetTemporaryBasal(percent: percentage, duration: .min30))
                            let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                            self.disconnect()
                            
                            guard result.success else {
                                self.log.error("\(#function, privacy: .public): Pump rejected command (30 min)")
                                completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Pump rejected command (30 min)")))
                                return
                            }
                            
                            let dose = DoseEntry.tempBasal(absoluteUnit: unitsPerHour, duration: duration, insulinType: self.state.insulinType!)
                            self.state.basalDeliveryOrdinal = .tempBasal
                            self.state.basalDeliveryDate = Date.now
                            self.state.tempBasalUnits = unitsPerHour
                            self.state.tempBasalDuration = duration
                            self.notifyStateDidChange()
                            
                            self.pumpDelegate.notify { (delegate) in
                                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.tempBasal(dose: dose, units: unitsPerHour, duration: duration)], lastReconciliation: Date.now, completion: { _ in })
                            }
                            
                            self.log.info("\(#function, privacy: .public): Succesfully started 30 min temp basal")
                            completion(nil)
                            
                            // Full hour
                        } else {
                            let packet = generatePacketBasalSetTemporary(options: PacketBasalSetTemporary(temporaryBasalRatio: UInt8(percentage), temporaryBasalDuration: UInt8(floor(duration / .hours(1)))))
                            let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                            self.disconnect()
                            
                            guard result.success else {
                                self.log.error("\(#function, privacy: .public): Pump rejected command (full hour)")
                                completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTempBasalAdjustment("Pump rejected command (full hour)")))
                                return
                            }
                            
                            let dose = DoseEntry.tempBasal(absoluteUnit: unitsPerHour, duration: duration, insulinType: self.state.insulinType!)
                            self.state.basalDeliveryOrdinal = .tempBasal
                            self.state.basalDeliveryDate = Date.now
                            self.state.tempBasalUnits = unitsPerHour
                            self.state.tempBasalDuration = duration
                            self.notifyStateDidChange()
                            
                            self.pumpDelegate.notify { (delegate) in
                                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.tempBasal(dose: dose, units: unitsPerHour, duration: duration)], lastReconciliation: Date.now, completion: { _ in })
                            }
                            
                            self.log.info("\(#function, privacy: .public): Succesfully started full hourly temp basal")
                            completion(nil)
                        }
                    } catch {
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to set temp basal. Error: \(error.localizedDescription, privacy: .public)")
                        completion(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription)))
                    }
                }
            }
        }
    }
    
    private func isSupportedDuration(_ duration: TimeInterval) -> Bool {
        return duration < .ulpOfOne || duration == .minutes(15) || duration == .minutes(30) || Int(duration) % Int(.hours(1)) == 0
    }
    
    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Suspend delivery")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(PumpManagerError.connection(DanaKitPumpManagerError.noConnection))
                    return
                case .success:
                    do {
                        let packet = generatePacketBasalSetSuspendOn()
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        self.disconnect()
                        
                        guard result.success else {
                            self.log.error("\(#function, privacy: .public): Pump rejected command")
                            completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedSuspensionAdjustment))
                            return
                        }
                        
                        self.state.isPumpSuspended = true
                        self.state.basalDeliveryOrdinal = .suspended
                        self.state.basalDeliveryDate = Date.now
                        self.notifyStateDidChange()
                        
                        let dose = DoseEntry.suspend()
                        self.pumpDelegate.notify { (delegate) in
                            guard let delegate = delegate else {
                                preconditionFailure("pumpManagerDelegate cannot be nil")
                            }
                            
                            delegate.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.suspend(dose: dose)], lastReconciliation: Date.now, completion: { (error) in
                                completion(nil)
                            })
                        }
                    } catch {
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to suspend delivery. Error: \(error.localizedDescription, privacy: .public)")
                        completion(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription)))
                    }
                }
            }
        }
    }
    
    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Resume delivery")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(PumpManagerError.connection(DanaKitPumpManagerError.noConnection))
                    return
                case .success:
                    do {
                        let packet = generatePacketBasalSetSuspendOff()
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        self.disconnect()
                        
                        guard result.success else {
                            self.log.error("\(#function, privacy: .public): Pump rejected command")
                            completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedSuspensionAdjustment))
                            return
                        }
                        
                        self.state.isPumpSuspended = false
                        self.state.basalDeliveryOrdinal = .active
                        self.state.basalDeliveryDate = Date.now
                        self.notifyStateDidChange()
                        
                        let dose = DoseEntry.resume(insulinType: self.state.insulinType!)
                        self.pumpDelegate.notify { (delegate) in
                            guard let delegate = delegate else {
                                preconditionFailure("pumpManagerDelegate cannot be nil")
                            }
                            
                            delegate.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.resume(dose: dose)], lastReconciliation: Date.now, completion: { (error) in
                                completion(nil)
                            })
                        }
                    } catch {
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to suspend delivery. Error: \(error.localizedDescription, privacy: .public)")
                        completion(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription)))
                    }
                }
            }
        }
    }
    
    public func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Sync basal")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(.failure(PumpManagerError.connection(DanaKitPumpManagerError.noConnection)))
                    return
                case .success:
                    do {
                        let basal = DanaKitPumpManagerState.convertBasal(scheduleItems)
                        let packet = try generatePacketBasalSetProfileRate(options: PacketBasalSetProfileRate(profileNumber: self.state.basalProfileNumber, profileBasalRate: basal))
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        guard result.success else {
                            self.disconnect()
                            self.log.error("\(#function, privacy: .public): Pump rejected command (setting rates)")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.failedBasalAdjustment)))
                            return
                        }
                        
                        let activatePacket = generatePacketBasalSetProfileNumber(options: PacketBasalSetProfileNumber(profileNumber: self.state.basalProfileNumber))
                        let activateResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(activatePacket)
                        
                        self.disconnect()
                        
                        guard activateResult.success else {
                            self.log.error("\(#function, privacy: .public): Pump rejected command (activate profile)")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.failedBasalAdjustment)))
                            return
                        }
                        
                        guard let schedule = DailyValueSchedule<Double>(dailyItems: scheduleItems) else {
                            self.log.error("\(#function, privacy: .public): Failed to convert schedule")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.failedBasalGeneration)))
                            return
                        }
                        
                        self.state.basalDeliveryOrdinal = .active
                        self.state.basalDeliveryDate = Date.now
                        self.state.basalSchedule = basal
                        self.notifyStateDidChange()
                        
                        let dose = DoseEntry.basal(rate: self.currentBaseBasalRate, insulinType: self.state.insulinType!)
                        self.pumpDelegate.notify { (delegate) in
                            guard let delegate = delegate else {
                                preconditionFailure("pumpManagerDelegate cannot be nil")
                            }
                            
                            delegate.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.basal(dose: dose)], lastReconciliation: Date.now, completion: { (error) in
                                completion(.success(schedule))
                            })
                        }
                    } catch {
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to suspend delivery. Error: \(error.localizedDescription, privacy: .public)")
                        completion(.failure(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription))))
                    }
                }
            }
        }
    }
    
    public func syncBasalSchedule(basal: [Double], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Sync basal")

            self.ensureConnected { result in
                switch result {
                case .failure:
                    completion(.failure(PumpManagerError.connection(DanaKitPumpManagerError.noConnection)))
                    return
                case .success:
                    do {
                        let packet = try generatePacketBasalSetProfileRate(options: PacketBasalSetProfileRate(profileNumber: self.state.basalProfileNumber, profileBasalRate: basal))
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        guard result.success else {
                            self.disconnect()
                            self.log.error("\(#function, privacy: .public): Pump rejected command (setting rates)")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.failedBasalAdjustment)))
                            return
                        }
                        
                        let activatePacket = generatePacketBasalSetProfileNumber(options: PacketBasalSetProfileNumber(profileNumber: self.state.basalProfileNumber))
                        let activateResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(activatePacket)
                        
                        self.disconnect()
                        
                        guard activateResult.success else {
                            self.log.error("\(#function, privacy: .public): Pump rejected command (activate profile)")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.failedBasalAdjustment)))
                            return
                        }
                    } catch {
                        self.disconnect()
                        
                        self.log.error("\(#function, privacy: .public): Failed to suspend delivery. Error: \(error.localizedDescription, privacy: .public)")
                        completion(.failure(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription))))
                    }
                }
            }
        }
    }
    
    public func setUserSettings(data: PacketGeneralSetUserOption, completion: @escaping (Bool) -> Void) {
        delegateQueue.async {
            self.log.info("\(#function, privacy: .public): Set user settings")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(false)
                    return
                case .success:
                    do {
                        let packet = generatePacketGeneralSetUserOption(options: data)
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        self.disconnect()
                        completion(result.success)
                    } catch {
                        self.log.error("\(#function, privacy: .public): error caught \(error.localizedDescription, privacy: .public)")
                        self.disconnect()
                        completion(false)
                    }
                }
            }
        }
    }
    
    public func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        delegateQueue.async {
            // Dana does not allow the max basal and max bolus to be set
            self.log.info("\(#function, privacy: .public): Skipping sync delivery limits (not supported by dana). Fetching current settings")
            
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(.failure(PumpManagerError.connection(DanaKitPumpManagerError.noConnection)))
                    return
                case .success:
                    do {
                        let basalPacket = generatePacketBasalGetRate()
                        let basalResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(basalPacket)
                        
                        guard basalResult.success else {
                            self.log.error("\(#function, privacy: .public): Pump refused to send basal rates back")
                            self.disconnect()
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.unknown("Pump refused to send basal rates back"))))
                            return
                        }
                        
                        let bolusPacket = generatePacketBolusGetStepInformation()
                        let bolusResult = try await DanaKitPumpManager.bluetoothManager.writeMessage(bolusPacket)
                        
                        self.disconnect()
                        guard bolusResult.success else {
                            self.log.error("\(#function, privacy: .public): Pump refused to send bolus step back")
                            completion(.failure(PumpManagerError.configuration(DanaKitPumpManagerError.unknown("Pump refused to send bolus step back"))))
                            return
                        }
                        
                        self.log.info("\(#function, privacy: .public): Fetching pump settings succesfully!")
                        completion(.success(DeliveryLimits(
                            maximumBasalRate: HKQuantity(unit: HKUnit.internationalUnit().unitDivided(by: .hour()), doubleValue: (basalResult.data as! PacketBasalGetRate).maxBasal),
                            maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: (bolusResult.data as! PacketBolusGetStepInformation).maxBolus)
                        )))
                    } catch {
                        self.log.error("\(#function, privacy: .public): error caught \(error.localizedDescription, privacy: .public)")
                        self.disconnect()
                        completion(.failure(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription))))
                    }
                }
            }
        }
    }
    
    public func syncPumpTime(completion: @escaping (Error?) -> Void) {
        delegateQueue.async {
            self.ensureConnected { result in
                switch result {
                case .failure:
                    self.log.error("\(#function, privacy: .public): Connection error")
                    completion(PumpManagerError.connection(DanaKitPumpManagerError.noConnection))
                    return
                case .success:
                    do {
                        let offset = Date.now.timeIntervalSince(self.state.pumpTime ?? Date.distantPast)
                        let packet = generatePacketGeneralSetPumpTimeUtcWithTimezone(options: PacketGeneralSetPumpTimeUtcWithTimezone(time: Date.now, zoneOffset: UInt8(round(Double(TimeZone.current.secondsFromGMT(for: Date.now) / 3600)))))
                        let result = try await DanaKitPumpManager.bluetoothManager.writeMessage(packet)
                        
                        self.disconnect()
                        
                        guard result.success else {
                            completion(PumpManagerError.configuration(DanaKitPumpManagerError.failedTimeAdjustment))
                            return
                        }
                        
                        self.pumpDelegate.notify { (delegate) in
                            delegate?.pumpManager(self, didAdjustPumpClockBy: offset)
                        }
                        completion(nil)
                    } catch {
                        self.disconnect()
                        self.log.error("\(#function, privacy: .public): Failed to sync time. Error: \(error.localizedDescription, privacy: .public)")
                        completion(PumpManagerError.communication(DanaKitPumpManagerError.unknown(error.localizedDescription)))
                    }
                }
            }
        }
    }
    
    private func device() -> HKDevice {
        return HKDevice(
            name: managerIdentifier,
            manufacturer: "Sooil",
            model: self.state.getFriendlyDeviceName(),
            hardwareVersion: String(self.state.hwModel),
            firmwareVersion: String(self.state.pumpProtocol),
            softwareVersion: "",
            localIdentifier: self.state.deviceName,
            udiDeviceIdentifier: nil
        )
    }
    
    private func ensureConnected(_ completion: @escaping (ConnectionResult) async -> Void) {
        let block: (ConnectionResult) -> Void = { result in
            Task {
                await completion(result)
            }
        }
        
        // Device still has an active connection with pump and is probably busy with something
        if DanaKitPumpManager.bluetoothManager.isConnected && DanaKitPumpManager.bluetoothManager.peripheral?.state == .connected {
            self.logDeviceCommunication("Failed to connect: Already connected", type: .connection)
            block(.failure)
            
        // We stored the peripheral. We can quickly reconnect
        } else if DanaKitPumpManager.bluetoothManager.peripheral != nil {
            self.connect(DanaKitPumpManager.bluetoothManager.peripheral!) { error in
                if error == nil {
                    self.logDeviceCommunication("Connected", type: .connection)
                    block(.success)
                } else {
                    self.logDeviceCommunication("Failed to connect: " + error!.localizedDescription, type: .connection)
                    block(.failure)
                }
            }
            // No active connection and no stored peripheral. We have to scan for device before being able to send command
        } else if !DanaKitPumpManager.bluetoothManager.isConnected && self.state.bleIdentifier != nil {
            do {
                try DanaKitPumpManager.bluetoothManager.connect(self.state.bleIdentifier!) { error in
                    if error == nil {
                        self.logDeviceCommunication("Connected", type: .connection)
                        block(.success)
                    } else {
                        self.logDeviceCommunication("Failed to connect: " + error!.localizedDescription, type: .connection)
                        block(.failure)
                    }
                }
            } catch {
                self.logDeviceCommunication("Failed to connect: " + error.localizedDescription, type: .connection)
                block(.failure)
            }
            
            // Should never reach, but is only possible if device is not onboard (we have no ble identifier to connect to)
        } else {
            self.log.error("\(#function, privacy: .public): Pump is not onboarded")
            self.logDeviceCommunication("Pump is not onboarded", type: .connection)
            block(.failure)
        }
    }
    
    private func disconnect() {
        if DanaKitPumpManager.bluetoothManager.isConnected {
            DanaKitPumpManager.bluetoothManager.disconnect(DanaKitPumpManager.bluetoothManager.peripheral!)
            logDeviceCommunication("Disconnected", type: .connection)
        }
    }
    
    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        let address = String(format: "%04X", self.state.bleIdentifier ?? "")
        // Not dispatching here; if delegate queue is blocked, timestamps will be delayed
        self.pumpDelegate.delegate?.deviceManager(self, logEventForDeviceIdentifier: address, type: type, message: message, completion: nil)
    }
    
    private func absoluteBasalRateToPercentage(absoluteValue: Double, basalSchedule: [Double]) -> UInt16? {
        if absoluteValue == 0 {
            return 0
        }
        
        guard basalSchedule.count == 24 else {
            return nil
        }
        
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)
        
        let basalIntervals: [TimeInterval] = Array(0..<24).map({ TimeInterval(60 * 60 * $0) })
        let basalIndex = (basalIntervals.firstIndex(where: { $0 > nowTimeInterval}) ?? 24) - 1
        let basalRate = basalSchedule[basalIndex]
        
        return UInt16(round(absoluteValue / basalRate * 100))
    }
}

extension DanaKitPumpManager: AlertSoundVendor {
    public func getSoundBaseURL() -> URL? {
        return nil
    }

    public func getSounds() -> [LoopKit.Alert.Sound] {
        return []
    }
}

extension DanaKitPumpManager {
    public func acknowledgeAlert(alertIdentifier: LoopKit.Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
    }
}

// MARK: State observers
extension DanaKitPumpManager {
    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }
    
    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }
    
    public func addStateObserver(_ observer: StateObserver, queue: DispatchQueue) {
        stateObservers.insert(observer, queue: queue)
    }

    public func removeStateObserver(_ observer: StateObserver) {
        stateObservers.removeElement(observer)
    }
    
    public func notifyStateDidChange() {
        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)
            
            self.stateObservers.forEach { (observer) in
                observer.stateDidUpdate(self.state, self.oldState)
            }
            
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }
            
            self.statusObservers.forEach { (observer) in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }
            
            self.oldState = DanaKitPumpManagerState(rawValue: self.state.rawValue)
        }
    }
    
    public func addScanDeviceObserver(_ observer: StateObserver, queue: DispatchQueue) {
        scanDeviceObservers.insert(observer, queue: queue)
    }

    public func removeScanDeviceObserver(_ observer: StateObserver) {
        scanDeviceObservers.removeElement(observer)
    }
    
    func notifyAlert(_ alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.identifier)
        let loopAlert = Alert(identifier: identifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .immediate)
        
        let event = NewPumpEvent(date: Date(), dose: nil, raw: alert.raw, title: "Alarm: \(alert.foregroundContent.title)", type: .alarm, alarmType: alert.type)
        
        self.pumpDelegate.notify { delegate in
            delegate?.issueAlert(loopAlert)
            delegate?.pumpManager(self, hasNewPumpEvents: [event], lastReconciliation: Date(), completion: { _ in })
        }
    }
    
    func notifyScanDeviceDidChange(_ device: DanaPumpScan) {
        DispatchQueue.main.async {
            self.scanDeviceObservers.forEach { (observer) in
                observer.deviceScanDidUpdate(device)
            }
        }
    }
    
    func notifyBolusError() {
        guard let doseEntry = self.doseEntry, self.state.bolusState != .noBolus else {
            // Ignore if no bolus is going
            return
        }
        
        self.state.lastStatusDate = Date()
        self.state.bolusState = .noBolus
        self.notifyStateDidChange()
        
        let dose = doseEntry.toDoseEntry()
        let deliveredUnits = doseEntry.deliveredUnits
        
        self.doseEntry = nil
        self.doseReporter = nil
        
        guard let dose = dose else {
            return
        }
        
        DispatchQueue.main.async {
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.bolus(dose: dose, units: deliveredUnits)], lastReconciliation: Date.now, completion: { _ in })
            }
        }
    }
    
    func notifyBolusDidUpdate(deliveredUnits: Double) {
        guard let doseEntry = self.doseEntry else {
            self.log.error("\(#function, privacy: .public): No bolus entry found...")
            return
        }
        
        doseEntry.deliveredUnits = deliveredUnits
        self.doseReporter?.notify(deliveredUnits: deliveredUnits)
        self.notifyStateDidChange()
    }
    
    func notifyBolusDone(deliveredUnits: Double) {
        self.state.lastStatusDate = Date()
        self.state.bolusState = .noBolus
        self.notifyStateDidChange()
        self.disconnect()
        
        guard let doseEntry = self.doseEntry else {
            return
        }
        
        doseEntry.deliveredUnits = deliveredUnits
        
        let dose = doseEntry.toDoseEntry()
        self.doseEntry = nil
        self.doseReporter = nil
        
        guard let dose = dose else {
            return
        }
        
        DispatchQueue.main.async {
            self.pumpDelegate.notify { (delegate) in
                delegate?.pumpManager(self, hasNewPumpEvents: [NewPumpEvent.bolus(dose: dose, units: deliveredUnits)], lastReconciliation: Date.now, completion: { _ in })
            }
            
            self.notifyStateDidChange()
        }
    }
}
