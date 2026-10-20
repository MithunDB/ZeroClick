import Foundation

struct JobRecord: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable { case done, cancelled, failed }
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let outcome: Outcome
    let outputs: [URL]
    let error: String?
}

enum JobHistory {
    static let maximumEntries = 50

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeroClick/history.json")
    }

    static func load(from url: URL = defaultURL) -> [JobRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([JobRecord].self, from: data) else { return [] }
        let retained = Array(records.prefix(maximumEntries))
        if records.count > maximumEntries { try? save(retained, to: url) }
        return retained
    }

    static func append(_ record: JobRecord, to url: URL = defaultURL) throws -> [JobRecord] {
        let records = Array(([record] + load(from: url)).prefix(maximumEntries))
        try save(records, to: url)
        return records
    }

    static func remove(ids: Set<UUID>, from url: URL = defaultURL) throws -> [JobRecord] {
        let records = load(from: url).filter { !ids.contains($0.id) }
        try save(records, to: url)
        return records
    }

    static func clear(from url: URL = defaultURL) throws -> [JobRecord] {
        try save([], to: url)
        return []
    }

    private static func save(_ records: [JobRecord], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }
}
