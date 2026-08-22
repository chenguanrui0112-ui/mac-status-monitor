import Foundation

final class YouTuQuotaProvider: @unchecked Sendable {
    func snapshot() async -> YouTuQuotaSnapshot {
        await Task.detached(priority: .utility) {
            YouTuQuotaQuery().run()
        }.value
    }
}

private struct YouTuQuotaQuery {
    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.youtu.app/database.sqlite")

    func run() -> YouTuQuotaSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return YouTuQuotaSnapshot(message: "未找到 YouTu 本地数据")
        }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-json",
            databaseURL.path,
            Self.query
        ]
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return YouTuQuotaSnapshot(
                    message: detail?.isEmpty == false ? "YouTu 数据暂时忙碌" : "无法读取 YouTu 数据"
                )
            }

            let rows = try JSONDecoder().decode([QuotaRow].self, from: data)
            guard let row = rows.first,
                  row.upload >= 0,
                  row.download >= 0,
                  row.total > 0 else {
                return YouTuQuotaSnapshot(message: "YouTu 暂无额度数据")
            }

            return YouTuQuotaSnapshot(
                usedBytes: row.upload + row.download,
                totalBytes: row.total,
                expiresAt: row.expire.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                cacheUpdatedAt: row.lastUpdate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                readAt: Date(),
                message: nil
            )
        } catch {
            return YouTuQuotaSnapshot(message: "无法读取 YouTu 数据")
        }
    }

    private static let query = """
        SELECT
            CAST(json_extract(subscription_info, '$.upload') AS INTEGER) AS upload,
            CAST(json_extract(subscription_info, '$.download') AS INTEGER) AS download,
            CAST(json_extract(subscription_info, '$.total') AS INTEGER) AS total,
            CAST(json_extract(subscription_info, '$.expire') AS INTEGER) AS expire,
            CAST(last_update_date AS INTEGER) AS last_update
        FROM profiles
        WHERE subscription_info IS NOT NULL
        ORDER BY last_update_date DESC
        LIMIT 1;
        """
}

private struct QuotaRow: Decodable {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64?
    let lastUpdate: Int64?

    enum CodingKeys: String, CodingKey {
        case upload
        case download
        case total
        case expire
        case lastUpdate = "last_update"
    }
}
