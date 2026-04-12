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
        updateTimer = DispatchTimer(timeInterval: 10, queue: processQueue)
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
    public var useFilter = false
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

    // --- LIBRE INTEGRATION ---
    private let lEmail = "timothy.theis@gmail.com"
    private let lPass = "mmg5737TIM%!"
    
    private func fetchLibreData(_ completion: @escaping (CGMReadingResult) -> Void) {
        // Step 1: Login
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

            // Step 2: Get Connections
            let connUrl = URL(string: "https://api-us.libreview.io/llu/connections")!
            var connReq = URLRequest(url: connUrl)
            connReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            connReq.setValue("4.16.0", forHTTPHeaderField: "version")
            connReq.setValue("llu.ios", forHTTPHeaderField: "product")
            connReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            connReq.setValue(accountId, forHTTPHeaderField: "Account-Id")

            URLSession.shared.dataTask(with: connReq) { d, _, _ in
                guard let d = d,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let dArray = j["data"] as? [[String: Any]],
                      let conn = dArray.first,
                      let gData = conn["glucoseMeasurement"] as? [String: Any],
                      let valNumber = gData["Value"] as? NSNumber, // Fix: Use NSNumber to handle integers
                      let ts = gData["FactoryTimestamp"] as? String else { // Fix: Pull the actual UTC timestamp
                    completion(.noData); return
                }

                let val = valNumber.doubleValue

                // Fix: Parse the date safely
                let fmt = DateFormatter()
                fmt.dateFormat = "M/d/yyyy h:mm:ss a" 
                fmt.timeZone = TimeZone(identifier: "UTC")
                let date = fmt.date(from: ts) ?? Date()
                let sID = "LLU" + String(Int(date.timeIntervalSince1970))
                
                // Layer 1: Trend Arrows mapped to LoopKit
                let trendInt = gData["TrendArrow"] as? Int
                var loopTrend: GlucoseTrend? = nil
                if let t = trendInt {
                    switch t {
                    case 1: loopTrend = .downDown
                    case 2: loopTrend = .down
                    case 3: loopTrend = .flat
                    case 4: loopTrend = .up
                    case 5: loopTrend = .upUp
                    default: break
                    }
                }

                let sample = NewGlucoseSample(
                    date: date, 
                    quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: val), 
                    condition: nil, trend: loopTrend, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: sID
                )

                self.latestBackfill = GlucoseEntry(
                    glucose: val, date: date, device: "Libre", glucoseType: .sensor, trend: loopTrend, changeRate: nil, id: sID
                )
                completion(.newData([sample]))
            }.resume()
        }.resume()
    }
}

extension NightscoutRemoteCGM {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) { completion(nil) }
    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }
}