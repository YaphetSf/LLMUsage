import Foundation

public enum WarmUpClient: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case claude, codex, glm
    public var id: Self { self }
    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .glm: "GLM 5.3"
        }
    }
    public var providerID: String { self == .glm ? "zai" : rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum GLMEndpoint: String, Codable, CaseIterable, Sendable {
    case codingPlan, standard
    public var title: String { self == .codingPlan ? "Coding Plan" : "Standard API" }
    public var url: URL {
        URL(string: self == .codingPlan
            ? "https://api.z.ai/api/coding/paas/v4/chat/completions"
            : "https://api.z.ai/api/paas/v4/chat/completions")!
    }
}

/// How a client is reached. It never says when: the timetable alone decides that.
public struct WarmUpClientConfiguration: Codable, Equatable, Sendable {
    public var executablePath = ""
    public var model = ""
    public var endpoint = GLMEndpoint.codingPlan

    public init(client: WarmUpClient) {
        if client == .glm { model = "glm-5.3" }
    }
}

/// A wall-clock time of day, repeated on chosen weekdays, for chosen clients.
public struct WarmUpSchedule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// `Calendar` weekday numbers: 1 is Sunday.
    public var weekdays: Set<Int>
    public var clients: Set<WarmUpClient>

    public init(id: UUID = UUID(), enabled: Bool = true, hour: Int = 8, minute: Int = 0,
                weekdays: Set<Int> = Set(1...7), clients: Set<WarmUpClient> = []) {
        self.id = id
        self.enabled = enabled
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.clients = clients
    }

    public var isActive: Bool { enabled && !weekdays.isEmpty && !clients.isEmpty }
    public var time: DateComponents { DateComponents(hour: hour, minute: minute) }

    public var timeTitle: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public var weekdaysTitle: String {
        let days = weekdays.sorted()
        if days == Array(1...7) { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        return days.map { Self.shortName(weekday: $0) }.joined(separator: " ")
    }

    public var clientsTitle: String {
        clients.sorted().map(\.title).joined(separator: ", ")
    }

    public static func shortName(weekday: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }
}

/// One configuration document, owned by the control center. Credentials never enter defaults.
public struct WarmUpConfiguration: Codable, Equatable, Sendable {
    public var schedules: [WarmUpSchedule] = []
    private var clients: [String: WarmUpClientConfiguration] = [:]

    public init() {}

    public subscript(client: WarmUpClient) -> WarmUpClientConfiguration {
        get { clients[client.rawValue] ?? WarmUpClientConfiguration(client: client) }
        set { clients[client.rawValue] = newValue }
    }

    /// The schedules that can actually fire this client. An enabled schedule is the whole
    /// switch: there is no second one above it.
    public func schedules(for client: WarmUpClient) -> [WarmUpSchedule] {
        schedules.filter { $0.isActive && $0.clients.contains(client) }
    }
}

public enum WarmUpOutcome: Codable, Equatable, Sendable {
    case succeeded
    case failed(String)
    case skipped(String)
    case cancelled

    public var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .failed(let reason), .skipped(let reason): reason
        case .cancelled: "Cancelled"
        }
    }
    public var isSuccess: Bool { self == .succeeded }
}

/// One execution, with the evidence needed to tell a real completion from an exit code.
public struct WarmUpRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var client: WarmUpClient
    public var scheduledAt: Date?
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: WarmUpOutcome?
    public var model: String?
    public var detail: String?
    public var tokens: Int?

    public init(id: UUID = UUID(), client: WarmUpClient, scheduledAt: Date? = nil, startedAt: Date) {
        self.id = id
        self.client = client
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
    }

    public var isRunning: Bool { outcome == nil }
    public var isAutomatic: Bool { scheduledAt != nil }
    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Runtime state, written only by the tracker.
public struct WarmUpState: Codable, Equatable, Sendable {
    public static let historyLimit = 60
    public var runs: [WarmUpRun] = []
    /// Latest scheduled occurrence already handled, per client. Prevents a restart from repeating it.
    public var handled: [String: Date] = [:]

    public init() {}

    public mutating func record(_ run: WarmUpRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
            runs = Array(runs.prefix(Self.historyLimit))
        }
    }

    public func latestRun(for client: WarmUpClient) -> WarmUpRun? {
        runs.first { $0.client == client }
    }
}

/// Runtime state has a single writer: the tracker. Manual requests carry IDs so UI replies
/// cannot be confused with a previous run or a delayed distributed notification.
@MainActor
public enum WarmUpStore {
    public static let configurationChanged = Notification.Name("com.llmusage.warmUp.configuration")
    public static let stateChanged = Notification.Name("com.llmusage.warmUp.state")
    public static let runRequested = Notification.Name("com.llmusage.warmUp.run")
    private static let configurationKey = "warmUp.configuration"
    private static let stateKey = "warmUp.runtime"

    public static func loadConfiguration() -> WarmUpConfiguration {
        decode(WarmUpConfiguration.self, key: configurationKey) ?? WarmUpConfiguration()
    }
    public static func saveConfiguration(_ configuration: WarmUpConfiguration) {
        save(configuration, key: configurationKey, notification: configurationChanged)
    }
    public static func loadState() -> WarmUpState {
        decode(WarmUpState.self, key: stateKey) ?? WarmUpState()
    }
    public static func saveState(_ state: WarmUpState) {
        save(state, key: stateKey, notification: stateChanged)
    }
    public static func requestRun(_ client: WarmUpClient, id: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            runRequested, object: client.rawValue, userInfo: ["requestID": id.uuidString], deliverImmediately: true
        )
    }
    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = AppPreferences.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func save<T: Encodable>(_ value: T, key: String, notification: Notification.Name) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AppPreferences.defaults.set(data, forKey: key)
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
