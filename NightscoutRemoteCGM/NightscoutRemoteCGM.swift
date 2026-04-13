//
//  NightscoutAPIManager.swift
//  NightscoutRemoteCGM
//
//  Created by Ivan Valkou on 10.10.2019.
//  Copyright © 2019 Ivan Valkou. All rights reserved.
//

import LoopKit
import HealthKit
import Combine
import NightscoutKit
import CryptoKit

public class NightscoutRemoteCGM: CGMManager {
    
    public static let pluginIdentifier = "NightscoutRemoteCGM"
    
    public static let localizedTitle = LocalizedString("Nightscout Remote CGM", comment: "Title for the CGMManager option")
    
    public var localizedTitle: String {
        return NightscoutRemoteCGM.localizedTitle
    }
    
    public var glucoseDisplay: GlucoseDisplayable? { latestBackfill }
    
    public var cgmManagerStatus: CGMManagerStatus {
        return .init(hasValidSensorSession: isOnboarded, device: device)
    }
    
    public var isOnboarded: Bool {
        return keychain.getNightscoutCgmURL() != nil
    }
    
    public enum CGMError: String, Error {
        case tooFlatData = "BG data is too flat."
    }

    private enum Config {
        static let useFilterKey = "NightscoutRemoteCGM.useFilter"
        static let filterNoise = 2.5
    }

    public init() {
        nightscoutService = NightscoutAPIService(keychainManager: keychain)
        updateTimer = DispatchTimer(timeInterval: 10, queue: processQueue)
        scheduleUpdateTimer()
    }

    public convenience required init?(rawState: CGMManager.RawStateValue) {
        self.init()
        useFilter = rawState[Config.useFilterKey] as? Bool ?? false
    }

    public var rawState: CGMManager.RawStateValue {
        [
            Config.useFilterKey: useFilter
        ]
    }

    private let keychain = KeychainManager()

    public var nightscoutService: NightscoutAPIService {
        didSet {
            keychain.setNightscoutCgmCredentials(nightscoutService.url, apiSecret: nightscoutService.apiSecret)
        }
    }

    public let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    public let providesBLEHeartbeat = false

    public var managedDataInterval: TimeInterval?

    public var shouldSyncToRemoteService = false

    public var useFilter = false

    public private(set) var latestBackfill: GlucoseEntry?

    private var requestReceiver: Cancellable?

    private let processQueue = DispatchQueue(label: "NightscoutRemoteCGM.processQueue")

    private var isFetching = false

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // --- TRAFFIC CONTROLLER ---
        if UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.UseDirectLibre") == "true" {
            guard !isFetching else {
                delegateQueue.async { completion(.noData) }
                return
            }
            processQueue.async {
                self.isFetching = true
                self.fetchLibreData { result in
                    self.isFetching = false
                    self.delegateQueue.async { completion(result) }
                }
            }
        } else {
            // --- ORIGINAL NIGHTSCOUT LOGIC ---
            guard let nightscoutClient = nightscoutService.client, !isFetching else {
                delegateQueue.async {
                    completion(.noData)
                }
                return
            }

            if let latestGlucose = latestBackfill, latestGlucose.startDate.timeIntervalSinceNow > -TimeInterval(minutes: 4.5) {
                delegateQueue.async {
                    completion(.noData)
                }
                return
            }

            processQueue.async {
                self.isFetching = true

                nightscoutClient.fetchRecent { fetchResult in
                    
                    self.isFetching = false
                    
                    switch fetchResult {
                    case .success(let glucoseEntries):
                        guard !glucoseEntries.isEmpty else {
                            self.delegateQueue.async {
                                completion(.noData)
                            }
                            return
                        }

                        var filteredGlucose = glucoseEntries
                        if self.useFilter {
                            var filter = KalmanFilter(stateEstimatePrior: glucoseEntries.last!.glucose, errorCovariancePrior: Config.filterNoise)
                            filteredGlucose.removeAll()
                            for item in glucoseEntries.reversed() {
                                let prediction = filter.predict(stateTransitionModel: 1, controlInputModel: 0, controlVector: 0, covarianceOfProcessNoise: Config.filterNoise)
                                let update = prediction.update(measurement: item.glucose, observationModel: 1, covarienceOfObservationNoise: Config.filterNoise)
                                filter = update
                                filteredGlucose.append(
                                    GlucoseEntry(
                                        glucose: filter.stateEstimatePrior.rounded(),
                                        date: item.date,
                                        device: item.device,
                                        glucoseType: item.glucoseType,
                                        trend: item.trend,
                                        changeRate: item.changeRate,
                                        id: item.id
                                    )
                                )
                            }
                            filteredGlucose = filteredGlucose.reversed()
                        }

                        let startDate = self.delegate.call { (delegate) -> Date? in
                            return delegate?.startDateToFilterNewData(for: self)
                        }
                        let newGlucose = filteredGlucose.filterDateRange(startDate, nil)
                        let newSamples = newGlucose.filter({ $0.isStateValid }).map { glucose -> NewGlucoseSample in
                            let glucoseTrend: LoopKit.GlucoseTrend?
                            if let trend = glucose.trend {
                                glucoseTrend = LoopKit.GlucoseTrend(rawValue: trend.rawValue)
                            } else {
                                glucoseTrend = nil
                            }
                            return NewGlucoseSample(
                                date: glucose.startDate,
                                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose.glucose),
                                condition: nil,
                                trend: glucoseTrend,
                                trendRate: glucose.trendRate,
                                isDisplayOnly: glucose.isCalibration == true,
                                wasUserEntered: glucose.glucoseType == .meter,
                                syncIdentifier: glucose.id ?? "\(Int(glucose.startDate.timeIntervalSince1970))",
                                device: self.device)
                        }

                        if let latestBackfill = newGlucose.max(by: {$0.startDate > $1.startDate}) {
                            self.latestBackfill = latestBackfill
                        }

                        self.delegateQueue.async {
                            guard !newSamples.isEmpty else {
                                completion(.noData)
                                return
                            }
                            completion(.newData(newSamples))
                        }
                    case let .failure(error):
                        self.delegateQueue.async {
                            completion(.error(error))
                        }
                    }
                }
            }
        }
    }

    // --- DIRECT LIBRE LOGIC ---
    private func fetchLibreData(_ completion: @escaping (CGMReadingResult) -> Void) {
        let email = UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.LibreEmail") ?? ""
        let pass = UserDefaults.standard.string(forKey: "com.loopkit.NightscoutRemoteCGM.LibrePassword") ?? ""
        
        let authUrl = URL(string: "https://api-us.libreview.io/llu/auth/login")!
        var authReq = URLRequest(url: authUrl)
        authReq.httpMethod = "POST"
        authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authReq.setValue("4.16.0", forHTTPHeaderField: "version")
        authReq.setValue("llu.ios", forHTTPHeaderField: "product")
        let body = ["email": email, "password": pass]
        authReq.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: authReq) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dDict = json["data"] as? [String: Any],
                  let auth = dDict["authTicket"] as? [String: Any],
                  let token = auth["token"] as? String,
                  let user = dDict["user"] as? [String: Any],
                  let userId = user["id"] as? String else {
                completion(.noData); return
            }

            let userIdData = Data(userId.utf8)
            let hashedId = SHA256.hash(data: userIdData)
            let accountId = hashedId.compactMap { String(format: "%02x", $0) }.joined()

            let connUrl = URL(string: "https://api-us.libreview.io/llu/connections")!
            var connReq = URLRequest(url: connUrl)
            connReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            connReq.setValue("4.16.0", forHTTPHeaderField: "version")
            connReq.setValue("llu.ios", forHTTPHeaderField: "product")
            connReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            connReq.setValue(accountId, forHTTPHeaderField: "Account-Id")
            connReq.cachePolicy = .reloadIgnoringLocalCacheData

            URLSession.shared.dataTask(with: connReq) { d, _, _ in
                guard let d = d,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let dArray = j["data"] as? [[String: Any]],
                      let conn = dArray.first,
                      let patientId = conn["patientId"] as? String,
                      let gData = conn["glucoseMeasurement"] as? [String: Any],
                      let valNumber = gData["Value"] as? NSNumber,
                      let ts = gData["FactoryTimestamp"] as? String else {
                    completion(.noData); return
                }

                let currentVal = valNumber.doubleValue
                let fmt = DateFormatter()
                fmt.dateFormat = "M/d/yyyy h:mm:ss a" 
                fmt.timeZone = TimeZone(identifier: "UTC")
                let currentDate = fmt.date(from: ts) ?? Date()
                let currentSID = "LLU" + String(Int(currentDate.timeIntervalSince1970))
                
		let currentTrendInt = gData["TrendArrow"] as? Int
                var currentLoopTrend: LoopKit.GlucoseTrend? = nil
                var nsTrend: BloodGlucose.Trend? = nil
                if let t = currentTrendInt {
                    switch t {
                    case 1: 
                        currentLoopTrend = .downDown
                        nsTrend = .doubleDown
                    case 2: 
                        currentLoopTrend = .down
                        nsTrend = .singleDown
                    case 3: 
                        currentLoopTrend = .flat
                        nsTrend = .flat
                    case 4: 
                        currentLoopTrend = .up
                        nsTrend = .singleUp
                    case 5: 
                        currentLoopTrend = .upUp
                        nsTrend = .doubleUp
                    default: break
                    }
                }

                if self.latestBackfill == nil || currentDate.timeIntervalSince(self.latestBackfill!.date) > 120 {
                    let graphUrl = URL(string: "https://api-us.libreview.io/llu/connections/\(patientId)/graph")!
                    var graphReq = URLRequest(url: graphUrl)
                    graphReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    graphReq.setValue("4.16.0", forHTTPHeaderField: "version")
                    graphReq.setValue("llu.ios", forHTTPHeaderField: "product")
                    graphReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    graphReq.setValue(accountId, forHTTPHeaderField: "Account-Id")
                    graphReq.cachePolicy = .reloadIgnoringLocalCacheData

                    URLSession.shared.dataTask(with: graphReq) { gd, _, _ in
                        var samples: [NewGlucoseSample] = []
                        if let gd = gd,
                           let gj = try? JSONSerialization.jsonObject(with: gd) as? [String: Any],
                           let gdDict = gj["data"] as? [String: Any],
                           let graphData = gdDict["graphData"] as? [[String: Any]] {
                            for gItem in graphData {
                                if let gValNum = gItem["Value"] as? NSNumber,
                                   let gTs = gItem["FactoryTimestamp"] as? String {
                                    let gDate = fmt.date(from: gTs) ?? Date()
                                    let gID = "LLU" + String(Int(gDate.timeIntervalSince1970))
                                    let gTrendInt = gItem["TrendArrow"] as? Int
                                    var gLoopTrend: LoopKit.GlucoseTrend? = nil
                                    if let t = gTrendInt {
                                        switch t {
                                        case 1: gLoopTrend = .downDown
                                        case 2: gLoopTrend = .down
                                        case 3: gLoopTrend = .flat
                                        case 4: gLoopTrend = .up
                                        case 5: gLoopTrend = .upUp
                                        default: break
                                        }
                                    }
                                    samples.append(NewGlucoseSample(date: gDate, quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: gValNum.doubleValue), condition: nil, trend: gLoopTrend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: gID))
                                }
                            }
                        }
                        samples.append(NewGlucoseSample(date: currentDate, quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: currentVal), condition: nil, trend: currentLoopTrend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: currentSID))
                        samples.sort { $0.date < $1.date }
                        self.latestBackfill = GlucoseEntry(glucose: currentVal, date: currentDate, device: "Libre", glucoseType: .sensor, trend: nsTrend, changeRate: nil, id: currentSID)
                        completion(.newData(samples))
                    }.resume()
                } else {
                    if currentDate > self.latestBackfill!.date {
                        let sample = NewGlucoseSample(date: currentDate, quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: currentVal), condition: nil, trend: currentLoopTrend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: currentSID)
                        self.latestBackfill = GlucoseEntry(glucose: currentVal, date: currentDate, device: "Libre", glucoseType: .sensor, trend: nsTrend, changeRate: nil, id: currentSID)
                        completion(.newData([sample]))
                    } else { completion(.noData) }
                }
            }.resume()
        }.resume()
    }

    public var device: HKDevice? = nil

    public var debugDescription: String {
        "## NightscoutRemoteCGM\nlatestBackfill: \(String(describing: latestBackfill))\n"
    }

    public var appURL: URL? {
        guard let url = nightscoutService.url else { return nil }
        switch url.absoluteString {
        case "http://127.0.0.1:1979":
            return URL(string: "spikeapp://")
        case "http://127.0.0.1:17580":
            return URL(string: "diabox://")
        default:
            return url
        }
    }

    private let updateTimer: DispatchTimer

    private func scheduleUpdateTimer() {
        updateTimer.suspend()
        updateTimer.eventHandler = { [weak self] in
            guard let self = self else { return }
            self.fetchNewDataIfNeeded { result in
                guard case .newData = result else { return }
                self.delegate.notify { delegate in
                    delegate?.cgmManager(self, hasNew: result)
                }
            }
        }
        updateTimer.resume()
    }
}

// MARK: - AlertResponder implementation
extension NightscoutRemoteCGM {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }
}

// MARK: - AlertSoundVendor implementation
extension NightscoutRemoteCGM {
    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }
}