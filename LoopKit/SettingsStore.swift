//
//  SettingsStore.swift
//  LoopKit
//
//  Created by Darin Krauss on 10/14/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import Foundation
import CoreData
import HealthKit

public protocol SettingsStoreDelegate: AnyObject {
    /**
     Informs the delegate that the settings store has updated settings data.
     
     - Parameter settingsStore: The settings store that has updated settings data.
     */
    func settingsStoreHasUpdatedSettingsData(_ settingsStore: SettingsStore)

}

public class SettingsStore {
    public weak var delegate: SettingsStoreDelegate?
    
    private let store: PersistenceController
    private let expireAfter: TimeInterval
    private let dataAccessQueue = DispatchQueue(label: "com.loopkit.SettingsStore.dataAccessQueue", qos: .utility)
    private let log = OSLog(category: "SettingsStore")

    public init(store: PersistenceController, expireAfter: TimeInterval) {
        self.store = store
        self.expireAfter = expireAfter
    }
    
    public func storeSettings(_ settings: StoredSettings, completion: @escaping () -> Void) {
        dataAccessQueue.async {
            if let data = self.encodeSettings(settings) {
                self.store.managedObjectContext.performAndWait {
                    let object = SettingsObject(context: self.store.managedObjectContext)
                    object.data = data
                    object.date = settings.date
                    self.store.save()
                }
            }

            self.purgeExpiredSettingsObjects()

            self.delegate?.settingsStoreHasUpdatedSettingsData(self)
            completion()
        }
    }

    private var expireDate: Date {
        return Date(timeIntervalSinceNow: -expireAfter)
    }

    private func purgeExpiredSettingsObjects() {
        dispatchPrecondition(condition: .onQueue(dataAccessQueue))

        store.managedObjectContext.performAndWait {
            do {
                let fetchRequest: NSFetchRequest<SettingsObject> = SettingsObject.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "date < %@", expireDate as NSDate)
                let count = try self.store.managedObjectContext.deleteObjects(matching: fetchRequest)
                self.log.info("Deleted %d SettingsObjects", count)
            } catch let error {
                self.log.error("Unable to purge SettingsObjects: %@", String(describing: error))
            }
        }
    }

    private func encodeSettings(_ settings: StoredSettings) -> Data? {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(settings)
        } catch let error {
            self.log.error("Error encoding StoredSettings: %@", String(describing: error))
            return nil
        }
    }

    private func decodeSettings(fromData data: Data) -> StoredSettings? {
        do {
            let decoder = PropertyListDecoder()
            return try decoder.decode(StoredSettings.self, from: data)
        } catch let error {
            self.log.error("Error decoding StoredSettings: %@", String(describing: error))
            return nil
        }
    }
}

extension SettingsStore {
    public struct QueryAnchor: RawRepresentable {
        public typealias RawValue = [String: Any]
        
        internal var modificationCounter: Int64
        
        public init() {
            self.modificationCounter = 0
        }
        
        public init?(rawValue: RawValue) {
            guard let modificationCounter = rawValue["modificationCounter"] as? Int64 else {
                return nil
            }
            self.modificationCounter = modificationCounter
        }
        
        public var rawValue: RawValue {
            var rawValue: RawValue = [:]
            rawValue["modificationCounter"] = modificationCounter
            return rawValue
        }
    }
    
    public enum SettingsQueryResult {
        case success(QueryAnchor, [StoredSettings])
        case failure(Error)
    }

    public func executeSettingsQuery(fromQueryAnchor queryAnchor: QueryAnchor?, limit: Int, completion: @escaping (SettingsQueryResult) -> Void) {
        dataAccessQueue.async {
            var queryAnchor = queryAnchor ?? QueryAnchor()
            var queryResult = [StoredSettings]()
            var queryError: Error?

            guard limit > 0 else {
                completion(.success(queryAnchor, queryResult))
                return
            }

            self.store.managedObjectContext.performAndWait {
                let storedRequest: NSFetchRequest<SettingsObject> = SettingsObject.fetchRequest()

                storedRequest.predicate = NSPredicate(format: "modificationCounter > %d", queryAnchor.modificationCounter)
                storedRequest.sortDescriptors = [NSSortDescriptor(key: "modificationCounter", ascending: true)]
                storedRequest.fetchLimit = limit

                do {
                    let stored = try self.store.managedObjectContext.fetch(storedRequest)
                    if let modificationCounter = stored.max(by: { $0.modificationCounter < $1.modificationCounter })?.modificationCounter {
                        queryAnchor.modificationCounter = modificationCounter
                    }
                    queryResult.append(contentsOf: stored.compactMap { self.decodeSettings(fromData: $0.data) })
                } catch let error {
                    queryError = error
                    return
                }
            }

            if let queryError = queryError {
                completion(.failure(queryError))
                return
            }

            completion(.success(queryAnchor, queryResult))
        }
    }
}

public struct StoredSettings {
    public let date: Date
    public let dosingEnabled: Bool
    public let glucoseTargetRangeSchedule: GlucoseRangeSchedule?
    public let preMealTargetRange: DoubleRange?
    public let workoutTargetRange: DoubleRange?
    public let overridePresets: [TemporaryScheduleOverridePreset]?
    public let scheduleOverride: TemporaryScheduleOverride?
    public let preMealOverride: TemporaryScheduleOverride?
    public let maximumBasalRatePerHour: Double?
    public let maximumBolus: Double?
    public let suspendThreshold: GlucoseThreshold?
    public let deviceToken: String?
    public let insulinModel: InsulinModel?
    public let basalRateSchedule: BasalRateSchedule?
    public let insulinSensitivitySchedule: InsulinSensitivitySchedule?
    public let carbRatioSchedule: CarbRatioSchedule?
    public let bloodGlucoseUnit: HKUnit?
    public let syncIdentifier: String

    public init(date: Date = Date(),
                dosingEnabled: Bool = false,
                glucoseTargetRangeSchedule: GlucoseRangeSchedule? = nil,
                preMealTargetRange: DoubleRange? = nil,
                workoutTargetRange: DoubleRange? = nil,
                overridePresets: [TemporaryScheduleOverridePreset]? = nil,
                scheduleOverride: TemporaryScheduleOverride? = nil,
                preMealOverride: TemporaryScheduleOverride? = nil,
                maximumBasalRatePerHour: Double? = nil,
                maximumBolus: Double? = nil,
                suspendThreshold: GlucoseThreshold? = nil,
                deviceToken: String? = nil,
                insulinModel: InsulinModel? = nil,
                basalRateSchedule: BasalRateSchedule? = nil,
                insulinSensitivitySchedule: InsulinSensitivitySchedule? = nil,
                carbRatioSchedule: CarbRatioSchedule? = nil,
                bloodGlucoseUnit: HKUnit? = nil,
                syncIdentifier: String = UUID().uuidString) {
        self.date = date
        self.dosingEnabled = dosingEnabled
        self.glucoseTargetRangeSchedule = glucoseTargetRangeSchedule
        self.preMealTargetRange = preMealTargetRange
        self.workoutTargetRange = workoutTargetRange
        self.overridePresets = overridePresets
        self.scheduleOverride = scheduleOverride
        self.preMealOverride = preMealOverride
        self.maximumBasalRatePerHour = maximumBasalRatePerHour
        self.maximumBolus = maximumBolus
        self.suspendThreshold = suspendThreshold
        self.deviceToken = deviceToken
        self.insulinModel = insulinModel
        self.basalRateSchedule = basalRateSchedule
        self.insulinSensitivitySchedule = insulinSensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
        self.bloodGlucoseUnit = bloodGlucoseUnit
        self.syncIdentifier = syncIdentifier
    }

    public struct InsulinModel: Codable, Equatable {
        public enum ModelType: String, Codable {
            case fiasp
            case rapidAdult
            case rapidChild
            case walsh
        }
        
        public let modelType: ModelType
        public let actionDuration: TimeInterval
        public let peakActivity: TimeInterval?

        public init(modelType: ModelType, actionDuration: TimeInterval, peakActivity: TimeInterval? = nil) {
            self.modelType = modelType
            self.actionDuration = actionDuration
            self.peakActivity = peakActivity
        }
    }
}

extension StoredSettings: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var bloodGlucoseUnit: HKUnit?
        if let bloodGlucoseUnitString = try container.decodeIfPresent(String.self, forKey: .bloodGlucoseUnit) {
            bloodGlucoseUnit = HKUnit(from: bloodGlucoseUnitString)
        }
        self.init(date: try container.decode(Date.self, forKey: .date),
                  dosingEnabled: try container.decode(Bool.self, forKey: .dosingEnabled),
                  glucoseTargetRangeSchedule: try container.decodeIfPresent(GlucoseRangeSchedule.self, forKey: .glucoseTargetRangeSchedule),
                  preMealTargetRange: try container.decodeIfPresent(DoubleRange.self, forKey: .preMealTargetRange),
                  workoutTargetRange: try container.decodeIfPresent(DoubleRange.self, forKey: .workoutTargetRange),
                  overridePresets: try container.decodeIfPresent([TemporaryScheduleOverridePreset].self, forKey: .overridePresets),
                  scheduleOverride: try container.decodeIfPresent(TemporaryScheduleOverride.self, forKey: .scheduleOverride),
                  preMealOverride: try container.decodeIfPresent(TemporaryScheduleOverride.self, forKey: .preMealOverride),
                  maximumBasalRatePerHour: try container.decodeIfPresent(Double.self, forKey: .maximumBasalRatePerHour),
                  maximumBolus: try container.decodeIfPresent(Double.self, forKey: .maximumBolus),
                  suspendThreshold: try container.decodeIfPresent(GlucoseThreshold.self, forKey: .suspendThreshold),
                  deviceToken: try container.decodeIfPresent(String.self, forKey: .deviceToken),
                  insulinModel: try container.decodeIfPresent(InsulinModel.self, forKey: .insulinModel),
                  basalRateSchedule: try container.decodeIfPresent(BasalRateSchedule.self, forKey: .basalRateSchedule),
                  insulinSensitivitySchedule: try container.decodeIfPresent(InsulinSensitivitySchedule.self, forKey: .insulinSensitivitySchedule),
                  carbRatioSchedule: try container.decodeIfPresent(CarbRatioSchedule.self, forKey: .carbRatioSchedule),
                  bloodGlucoseUnit: bloodGlucoseUnit,
                  syncIdentifier: try container.decode(String.self, forKey: .syncIdentifier))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(dosingEnabled, forKey: .dosingEnabled)
        try container.encodeIfPresent(glucoseTargetRangeSchedule, forKey: .glucoseTargetRangeSchedule)
        try container.encodeIfPresent(preMealTargetRange, forKey: .preMealTargetRange)
        try container.encodeIfPresent(workoutTargetRange, forKey: .workoutTargetRange)
        try container.encodeIfPresent(overridePresets, forKey: .overridePresets)
        try container.encodeIfPresent(scheduleOverride, forKey: .scheduleOverride)
        try container.encodeIfPresent(preMealOverride, forKey: .preMealOverride)
        try container.encodeIfPresent(maximumBasalRatePerHour, forKey: .maximumBasalRatePerHour)
        try container.encodeIfPresent(maximumBolus, forKey: .maximumBolus)
        try container.encodeIfPresent(suspendThreshold, forKey: .suspendThreshold)
        try container.encodeIfPresent(deviceToken, forKey: .deviceToken)
        try container.encodeIfPresent(insulinModel, forKey: .insulinModel)
        try container.encodeIfPresent(basalRateSchedule, forKey: .basalRateSchedule)
        try container.encodeIfPresent(insulinSensitivitySchedule, forKey: .insulinSensitivitySchedule)
        try container.encodeIfPresent(carbRatioSchedule, forKey: .carbRatioSchedule)
        try container.encodeIfPresent(bloodGlucoseUnit?.unitString, forKey: .bloodGlucoseUnit)
        try container.encode(syncIdentifier, forKey: .syncIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case dosingEnabled
        case glucoseTargetRangeSchedule
        case preMealTargetRange
        case workoutTargetRange
        case overridePresets
        case scheduleOverride
        case preMealOverride
        case maximumBasalRatePerHour
        case maximumBolus
        case suspendThreshold
        case deviceToken
        case insulinModel
        case basalRateSchedule
        case insulinSensitivitySchedule
        case carbRatioSchedule
        case bloodGlucoseUnit
        case syncIdentifier
    }
}

extension NSManagedObjectContext {
    fileprivate func deleteObjects<T>(matching fetchRequest: NSFetchRequest<T>) throws -> Int where T: NSManagedObject {
        let objects = try fetch(fetchRequest)
        objects.forEach { delete($0) }
        if hasChanges {
            try save()
        }
        return objects.count
    }
}