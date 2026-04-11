import Foundation
import LoopKit
import HealthKit

public final class NightscoutRemoteCGM: RemoteCGMManager {
    public static let managerIdentifier = "NightscoutRemoteCGM"
    public static let localizedTitle = NSLocalizedString("Nightscout Remote CGM", comment: "Title for Nightscout Remote CGM")

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            return delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    public let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public var sensorState: SensorDisplayable? {
        return latestBackfill
    }

    public var managedDataInterval: TimeInterval?

    public private(set) var latestBackfill: NightscoutGlucoseReading?

    public var nightscoutService: NightscoutService

    public init(nightscoutService: NightscoutService) {
        self.nightscoutService = nightscoutService
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        nightscoutService.fetchRecentGlucose { (result) in
            switch result {
            case .success(let samples):
                let readings = samples.map { NightscoutGlucoseReading(reading: $0) }
                self.latestBackfill = readings.first
                completion(.newData(readings))
            case .failure(let error):
                completion(.error(error))
            }
        }
    }
}

// MARK: - Required Extensions
extension NightscoutRemoteCGM {
    public var debugDescription: String {
        return [
            "## NightscoutRemoteCGM",
            "latestBackfill: \(String(describing: latestBackfill))",
            "nightscoutService: \(nightscoutService.description)",
        ].joined(separator: "\n")
    }
}