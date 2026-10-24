import Foundation

enum QuickSlot: String, CaseIterable, Hashable {
    case last, mostUsedOne, mostUsedTwo

    var title: String {
        switch self {
        case .last: "Last used"
        case .mostUsedOne: "Most used #1"
        case .mostUsedTwo: "Most used #2"
        }
    }

    var marker: String {
        switch self {
        case .last: "L"
        case .mostUsedOne: "1"
        case .mostUsedTwo: "2"
        }
    }

    var placeholderSymbol: String {
        switch self {
        case .last: "clock.arrow.circlepath"
        case .mostUsedOne: "1.circle"
        case .mostUsedTwo: "2.circle"
        }
    }
}

extension WheelMode {
    var historyKey: String {
        switch self {
        case .convert: "convert"
        case .tools: "tools"
        case .actions: "actions"
        case .ai: "ai"
        }
    }
}

extension RadialAction {
    var historyKey: String? {
        switch self {
        case .convert(let target): "convert:\(target.rawValue)"
        case .tool(let tool): "tool:\(tool.rawValue)"
        case .fileAction(let action): "file:\(action.rawValue)"
        case .ai, .quickPlaceholder: nil
        }
    }
}

enum QuickActionHistory {
    private static let lock = NSLock()

    private struct State: Codable {
        var last: String?
        var counts: [String: Int] = [:]
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeroClick/quick-actions.json")
    }

    static func recordSuccess(_ action: RadialAction, in mode: WheelMode, to url: URL = defaultURL) throws {
        guard mode != .ai, let key = action.historyKey else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = load(from: url)
        var state = all[mode.historyKey] ?? State()
        state.last = key
        let old = state.counts[key] ?? 0
        state.counts[key] = old == Int.max ? Int.max : old + 1
        all[mode.historyKey] = state
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    static func record(_ action: RadialAction, in mode: WheelMode,
                       outcome: JobRecord.Outcome, to url: URL = defaultURL) throws {
        guard outcome == .done else { return }
        try recordSuccess(action, in: mode, to: url)
    }

    static func shortcuts(for mode: WheelMode, among items: [RadialItem], from url: URL = defaultURL) -> [(QuickSlot, RadialItem?)] {
        guard mode != .ai else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let state = load(from: url)[mode.historyKey] ?? State()
        let byKey = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.action.historyKey.map { ($0, item) }
        })
        func item(for key: String) -> RadialItem? {
            if let current = byKey[key] { return current }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "convert":
                return FileFormat(rawValue: parts[1]).map { RadialItem(format: $0, disabledReason: "Not for selection") }
            case "tool":
                return ToolID(rawValue: parts[1]).map { RadialItem(tool: $0, disabledReason: "Not for selection") }
            case "file":
                return FileAction(rawValue: parts[1]).map { RadialItem(fileAction: $0, disabledReason: "Not for selection") }
            default: return nil
            }
        }
        let last = state.last.flatMap(item(for:))
        let mostUsed = state.counts.keys.filter { key in
            key != state.last && item(for: key) != nil && (state.counts[key] ?? 0) > 0
        }.sorted { a, b in
            let left = state.counts[a] ?? 0, right = state.counts[b] ?? 0
            return left == right ? a < b : left > right
        }.prefix(2).compactMap(item(for:))
        return [(.last, last),
                (.mostUsedOne, mostUsed.indices.contains(0) ? mostUsed[0] : nil),
                (.mostUsedTwo, mostUsed.indices.contains(1) ? mostUsed[1] : nil)]
    }

    private static func load(from url: URL) -> [String: State] {
        guard let data = try? Data(contentsOf: url),
              let states = try? JSONDecoder().decode([String: State].self, from: data) else { return [:] }
        return states
    }
}
