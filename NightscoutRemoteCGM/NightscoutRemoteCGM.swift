import Foundation
import HealthKit
import LoopKit
import UserNotifications
import Combine
import NightscoutKit
import CryptoKit

public class NightscoutRemoteCGM: CGMManager {
    public static let pluginIdentifier = "NightscoutRemoteCGM"
    public static let localizedTitle = LocalizedString("Nightscout Remote CGM", comment: "Title")
    public var localizedTitle: String { return NightscoutRemoteCGM.localizedTitle }
    public var glucoseDisplay: GlucoseDisplayable? { latestBackfill }
    public var cgmManagerStatus: CGMManagerStatus { .init(hasValidSensorSession: isOnboarded, device: device) }
    public var isOnboarded: Bool { keychain.getNightscoutCgmURL() != nil }
    public enum CGMError: String, Error { case tooFlatData = "BG data is too flat." }

    public init() {
        nightscoutService = NightscoutAPIService(keychainManager: keychain)
        // 1. TIMING FIX: Set to 60 seconds to match the 1-minute data heartbeat
        updateTimer = DispatchTimer(timeInterval: 60, queue: processQueue)
        scheduleUpdateTimer()
    }

    public convenience required init?(rawState: CGMManager.RawStateValue) { self.init() }

    public var rawState: CGMManager.RawStateValue { [:] }
    private let keychain = KeychainManager()
    public var nightscoutService: NightscoutAPIService {
        didSet { keychain.setNightscoutCgmCredentials(nightscoutService.url, apiSecret: nightscoutService.apiSecret) }
    }
    public let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()
    public var delegateQueue: DispatchQueue! { get { delegate.queue } set { delegate.queue = newValue } }
    public var cgmManagerDelegate: CGMManagerDelegate? { get { delegate.delegate } set { delegate.delegate = newValue } }
    public let providesBLEHeartbeat = false
    public var managedDataInterval: TimeInterval?
    public var shouldSyncToRemoteService = false
    public var useFilter = true // Keep this enabled
    public private(set) var latestBackfill: GlucoseEntry?
    private let processQueue = DispatchQueue(label: "NightscoutRemoteCGM.processQueue")
    private var isFetching = false

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        guard !isFetching else {
            delegateQueue.async { completion(.noData) }; return
        }
        processQueue.async {
            self.isFetching = true
            self.fetchLibreData { result in
                self.isFetching = false
                self.delegateQueue.async { completion(result) }
            }
        }
    }

    public var device: HKDevice? = nil
    public var debugDescription: String { "## NightscoutRemoteCGM\n" }
    public var appURL: URL? { nightscoutService.url }
    private let updateTimer: DispatchTimer
    private func scheduleUpdateTimer() {
        updateTimer.suspend()
        updateTimer.eventHandler = { [weak self] in
            guard let self = self else { return }
            self.fetchNewDataIfNeeded { result in
                if case .newData = result { self.delegate.notify { $0?.cgmManager(self, hasNew: result) } }
            }
        }
        updateTimer.resume()
    }

    // --- LAYER 2: KALMAN FILTER ---
    private var kalmanEstimate: Double? = nil
    private var kalmanError: Double = 1.0
    private let kalmanQ: Double = 0.05 // Process Variance (How fast true BG changes)
    private let kalmanR: Double = 3.0  // Measurement Variance (How much we trust the sensor)

    private func resetKalman() {
        kalmanEstimate = nil
        kalmanError = 1.0
    }

    private func applyKalman(rawGlucose: Double) -> Double {
        guard let estimate = kalmanEstimate else {
            kalmanEstimate = rawGlucose
            return rawGlucose
        }
        let predictedEstimate = estimate
        let predictedError = kalmanError + kalmanQ
        
        let kalmanGain = predictedError / (predictedError + kalmanR)
        let newEstimate = predictedEstimate + kalmanGain * (rawGlucose - predictedEstimate)
        kalmanError = (1 - kalmanGain) * predictedError
        
        kalmanEstimate = newEstimate
        return newEstimate
    }

    // --- LIBRE INTEGRATION ---
    private let lEmail = "timothy.theis@gmail.com"
    private let lPass = "mmg5737TIM%!"
    
    private func fetchLibreData(_ completion: @escaping (CGMReadingResult) -> Void) {
        let authUrl = URL(string: "https://api-us.libreview.io/llu/auth/login")!
        var authReq = URLRequest(url: authUrl)
        authReq.httpMethod = "POST"
        authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authReq.setValue("4.16.0", forHTTPHeaderField: "version")
        authReq.setValue("llu.ios", forHTTPHeaderField: "product")
        let body = ["email": lEmail, "password": lPass]
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
            
            // 2. CACHE BUSTER: Force iOS to fetch the 1-minute data directly from Abbott
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
                if let t = currentTrendInt {
                    switch t {
                    case 1: currentLoopTrend = .downDown
                    case 2: currentLoopTrend = .down
                    case 3: currentLoopTrend = .flat
                    case 4: currentLoopTrend = .up
                    case 5: currentLoopTrend = .upUp
                    default: break
                    }
                }

                // SMART BACKFILL LOGIC
                if self.latestBackfill == nil {
                    let graphUrl = URL(string: "https://api-us.libreview.io/llu/connections/\(patientId)/graph")!
                    var graphReq = URLRequest(url: graphUrl)
                    graphReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    graphReq.setValue("4.16.0", forHTTPHeaderField: "version")
                    graphReq.setValue("llu.ios", forHTTPHeaderField: "product")
                    graphReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    graphReq.setValue(accountId, forHTTPHeaderField: "Account-Id")
                    graphReq.cachePolicy = .reloadIgnoringLocalCacheData // Cache buster for history

                    URLSession.shared.dataTask(with: graphReq) { gd, _, _ in
                        var rawPoints: [(date: Date, val: Double, trend: LoopKit.GlucoseTrend?, id: String)] = []
                        
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
                                    rawPoints.append((date: gDate, val: gValNum.doubleValue, trend: gLoopTrend, id: gID))
                                }
                            }
                        }
                        
                        rawPoints.append((date: currentDate, val: currentVal, trend: currentLoopTrend, id: currentSID))
                        rawPoints.sort { $0.date < $1.date }
                        
                        self.resetKalman()
                        var samples: [NewGlucoseSample] = []
                        var finalSmoothedVal: Double = currentVal
                        
                        for p in rawPoints {
                            let smoothedVal = self.applyKalman(rawGlucose: p.val)
                            finalSmoothedVal = smoothedVal
                            samples.append(NewGlucoseSample(
                                date: p.date, 
                                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: smoothedVal), 
                                condition: nil, trend: p.trend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: p.id
                            ))
                        }
                        
                        self.latestBackfill = GlucoseEntry(
                            glucose: finalSmoothedVal, date: currentDate, device: "Libre", glucoseType: .sensor, trend: nil, changeRate: nil, id: currentSID
                        )
                        completion(.newData(samples))
                    }.resume()
                    
                } else {
                    if currentDate > self.latestBackfill!.date {
                        let smoothedVal = self.applyKalman(rawGlucose: currentVal)
                        let sample = NewGlucoseSample(
                            date: currentDate, 
                            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: smoothedVal), 
                            condition: nil, trend: currentLoopTrend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: currentSID
                        )
                        self.latestBackfill = GlucoseEntry(
                            glucose: smoothedVal, date: currentDate, device: "Libre", glucoseType: .sensor, trend: nil, changeRate: nil, id: currentSID
                        )
                        completion(.newData([sample]))
                    } else {
                        completion(.noData)
                    }
                }
            }.resume()
        }.resume()
    }
}

extension NightscoutRemoteCGM {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) { completion(nil) }
    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }
}