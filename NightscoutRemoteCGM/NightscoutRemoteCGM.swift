import Foundation
import HealthKit
import LoopKit
import UserNotifications
import Combine
import NightscoutKit

public class NightscoutRemoteCGM: CGMManager {
    public static let pluginIdentifier = "NightscoutRemoteCGM"
    public static let localizedTitle = LocalizedString("Nightscout Remote CGM", comment: "Title")
    public var localizedTitle: String { return NightscoutRemoteCGM.localizedTitle }
    public var glucoseDisplay: GlucoseDisplayable? { latestBackfill }
    public var cgmManagerStatus: CGMManagerStatus { .init(hasValidSensorSession: isOnboarded, device: device) }
    public var isOnboarded: Bool { keychain.getNightscoutCgmURL() != nil }
    public enum CGMError: String, Error { case tooFlatData = "BG data is too flat." }
    private enum Config { static let useFilterKey = "NightscoutRemoteCGM.useFilter"; static let filterNoise = 2.5 }

    public init() {
        nightscoutService = NightscoutAPIService(keychainManager: keychain)
        updateTimer = DispatchTimer(timeInterval: 10, queue: processQueue)
        scheduleUpdateTimer()
    }

    public convenience required init?(rawState: CGMManager.RawStateValue) {
        self.init()
        useFilter = rawState[Config.useFilterKey] as? Bool ?? false
    }

    public var rawState: CGMManager.RawStateValue { [Config.useFilterKey: useFilter] }
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
        guard let nightscoutClient = nightscoutService.client, !isFetching else {
            delegateQueue.async { completion(.noData) }; return
        }
        
        // --- LIBRE OVERRIDE ---
        let useLibreDirect = true 

        processQueue.async {
            if useLibreDirect {
                self.isFetching = true
                self.fetchLibreData { result in
                    self.isFetching = false
                    DispatchQueue.main.async { completion(result) }
                }
                return 
            }

            self.isFetching = true
            nightscoutClient.fetchRecent { fetchResult in
                self.isFetching = false
                switch fetchResult {
                case .success(let glucoseEntries):
                    let startDate = self.delegate.call { $0?.startDateToFilterNewData(for: self) }
                    let newSamples = glucoseEntries.filterDateRange(startDate, nil).map { g in
                        return NewGlucoseSample(date: g.startDate, quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: g.glucose), condition: nil, trend: nil, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: g.id ?? "\(g.startDate.timeIntervalSince1970)", device: self.device)
                    }
                    if let max = glucoseEntries.max(by: {$0.startDate < $1.startDate}) { self.latestBackfill = max }
                    self.delegateQueue.async { completion(newSamples.isEmpty ? .noData : .newData(newSamples)) }
                case .failure(let error):
                    self.delegateQueue.async { completion(.error(error)) }
                }
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

    private let libreEmail = "timothy.theis@gmail.com"
    private let librePassword = "mmg5737TIM%!"
    private var libreToken: String?

   private func fetchLibreData(_ completion: @escaping (CGMReadingResult) -> Void) {
        authenticateLibre { success in
            guard success, let token = self.libreToken else {
                completion(.noData)
                return
            }

            let url = URL(string: "https://api-us.libreview.io/llu/connections")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("4.16.0", forHTTPHeaderField: "version")
            request.setValue("llu.ios", forHTTPHeaderField: "product")

            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArray = json["data"] as? [[String: Any]],
                      let connection = dataArray.first,
                      let glucoseData = connection["glucoseMeasurement"] as? [String: Any],
                      let value = glucoseData["Value"] as? Double,
                      let timestampString = glucoseData["Timestamp"] as? String else {
                    completion(.noData)
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "MM/dd/yyyy h:mm:ss a"
                formatter.timeZone = TimeZone(identifier: "UTC")
                let date = formatter.date(from: timestampString) ?? Date()
                
                // This is the "Safe" way to create a sample that bypasses versioning errors
                let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
                let sample = NewGlucoseSample(
                    date: date,
                    quantity: quantity,
                    condition: nil,
                    trend: nil,
                    trendRate: nil,
                    isDisplayOnly: false,
                    wasUserEntered: false,
                    syncIdentifier: "libre-\(Int(date.timeIntervalSince1970))"
                )

                self.latestBackfill = GlucoseEntry(
                    glucose: value,
                    date: date,
                    device: "LibreLinkUp",
                    glucoseType: .cgm,
                    trend: nil,
                    changeRate: nil,
                    id: "libre-\(Int(date.timeIntervalSince1970))"
                )

                completion(.newData([sample]))
            }.resume()
        }
    }

    private func authenticateLibre(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "https://api-us.libreview.io/llu/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("4.16.0", forHTTPHeaderField: "version")
        request.setValue("llu.ios", forHTTPHeaderField: "product")
        let body = ["email": libreEmail, "password": librePassword]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any], let auth = d["authTicket"] as? [String: Any],
               let token = auth["token"] as? String {
                self.libreToken = token; completion(true)
            } else { completion(false) }
        }.resume()
    }
}

extension NightscoutRemoteCGM {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) { completion(nil) }
    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }
}