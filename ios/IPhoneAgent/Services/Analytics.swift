import Foundation
import UIKit

/// Anonymous usage stats, sent only after the user turns them on (first-launch sheet or Settings › Privacy;
/// off by default). A fixed list of events goes to PostHog: setup steps, board, mirroring and calibration,
/// run start and end with step count and duration, and the model provider. Never the task, screenshots,
/// model replies, keys or addresses; no location, no person profiles. No SDK: events are batched and
/// POSTed to PostHog's capture API. Builds without IA_POSTHOG_KEY (e.g. built from source) send nothing.
@MainActor
enum Analytics {
    static let consentKey = "usageStatsConsent"
    private static let idKey = "usageStatsID"
    private static let key = Bundle.main.object(forInfoDictionaryKey: "IAPostHogKey") as? String ?? ""
    private static let host = (Bundle.main.object(forInfoDictionaryKey: "IAPostHogHost") as? String)
        .flatMap(URL.init(string:))
    private static var queue: [[String: Any]] = []
    private static var sent: Set<String> = []  // captureOnce events this launch
    private static var timer: Timer?
    private static var sending = false
    private static let stamp = ISO8601DateFormatter()

    /// This build can send stats (the switch is shown only then).
    static var available: Bool { !key.isEmpty && host != nil && !MockMode.on }
    static var enabled: Bool { available && UserDefaults.standard.bool(forKey: consentKey) }

    /// Call once at launch: flush every 30 s and when the app leaves the screen.
    static func start() {
        guard available else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in flush() } }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in Task { @MainActor in flush() } }
        capture("app_opened")
    }

    /// The switch changed. Off forgets the queue and the install id (the next opt-in starts a new one).
    static func consentChanged(_ on: Bool) {
        if on {
            capture("usage_stats_enabled")
        } else {
            queue = []
            UserDefaults.standard.removeObject(forKey: idKey)
        }
    }

    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard enabled else { return }
        var p = common
        p.merge(props) { _, new in new }
        p["distinct_id"] = distinctID
        queue.append(["event": event, "properties": p, "timestamp": stamp.string(from: Date())])
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }  // offline for a long time
        if queue.count >= 20 { flush() }
    }

    /// At most once per launch, e.g. "board_connected" on every reconnect would be noise.
    static func captureOnce(_ event: String, _ props: [String: Any] = [:]) {
        guard enabled, sent.insert(event).inserted else { return }
        capture(event, props)
    }

    static func flush() {
        guard enabled, !sending, !queue.isEmpty, let host else { return }
        let batch = queue
        queue = []
        sending = true
        var request = URLRequest(url: host.appendingPathComponent("batch/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": key, "batch": batch])
        Task {
            let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode == 200
            sending = false
            if !ok && enabled { queue = batch + queue }  // retried with the next flush
        }
    }

    /// Random per-install id, not tied to the device or a person.
    private static var distinctID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static let common: [String: Any] = {
        let info = Bundle.main.infoDictionary
        return [
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$lib": "esp32-agent-ios",
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info?["CFBundleVersion"] as? String ?? "",
            "os_version": UIDevice.current.systemVersion,
            "device_model": DeviceInfo.model,
            "language": Locale.current.language.languageCode?.identifier ?? "",
        ]
    }()
}

enum DeviceInfo {
    /// The hardware model, e.g. "iPhone17,2".
    static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}
