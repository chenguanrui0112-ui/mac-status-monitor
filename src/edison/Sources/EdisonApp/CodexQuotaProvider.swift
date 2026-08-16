import Darwin
import Foundation

final class CodexQuotaProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var activeQuery: CodexQuotaQuery?

    func snapshot() async -> CodexQuotaSnapshot {
        let query = CodexQuotaQuery()
        withLock {
            activeQuery?.cancel()
            activeQuery = query
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let result = query.run()
                    self?.clear(query)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            query.cancel()
        }
    }

    private func clear(_ query: CodexQuotaQuery) {
        withLock {
            if activeQuery === query {
                activeQuery = nil
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CodexQuotaQuery: @unchecked Sendable {
    private let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    private let stateLock = NSLock()
    private var isCancelled = false
    private weak var runningProcess: Process?
    private weak var runningInput: FileHandle?
    private var runningCollector: JSONLineCollector?

    func cancel() {
        stateLock.lock()
        isCancelled = true
        let process = runningProcess
        let input = runningInput
        let collector = runningCollector
        stateLock.unlock()

        collector?.abort()
        try? input?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func run() -> CodexQuotaSnapshot {
        guard !cancelled else {
            return CodexQuotaSnapshot(message: "刷新已取消")
        }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return CodexQuotaSnapshot(message: "未找到 Codex")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = JSONLineCollector()
        let terminated = DispatchSemaphore(value: 0)
        let deadline = DispatchTime.now() + 12

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = minimalEnvironment()
        process.terminationHandler = { _ in terminated.signal() }

        stateLock.lock()
        runningProcess = process
        runningInput = input.fileHandleForWriting
        runningCollector = collector
        let shouldStart = !isCancelled
        stateLock.unlock()

        guard shouldStart else {
            collector.abort()
            return CodexQuotaSnapshot(message: "刷新已取消")
        }

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                collector.finish()
            } else {
                collector.append(data)
            }
        }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            shutdown(
                process: process,
                input: input.fileHandleForWriting,
                output: output.fileHandleForReading,
                terminated: terminated
            )
            stateLock.lock()
            runningProcess = nil
            runningInput = nil
            runningCollector = nil
            stateLock.unlock()
        }

        do {
            try process.run()
            try send(
                [
                    "method": "initialize",
                    "id": 0,
                    "params": [
                        "clientInfo": [
                            "name": "edison_mac_status",
                            "title": "edison",
                            "version": "0.1.0"
                        ]
                    ]
                ],
                to: input.fileHandleForWriting
            )

            guard let initialization = collector.response(id: 0, deadline: deadline),
                  initialization["error"] == nil else {
                if cancelled { return CodexQuotaSnapshot(message: "刷新已取消") }
                return CodexQuotaSnapshot(message: "Codex 服务初始化失败")
            }

            try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
            try send(
                [
                    "method": "account/read",
                    "id": 1,
                    "params": ["refreshToken": false]
                ],
                to: input.fileHandleForWriting
            )

            guard let accountResponse = collector.response(id: 1, deadline: deadline),
                  accountResponse["error"] == nil else {
                if cancelled { return CodexQuotaSnapshot(message: "刷新已取消") }
                return CodexQuotaSnapshot(message: "无法读取 Codex 登录状态")
            }
            guard hasChatGPTAccount(accountResponse) else {
                return CodexQuotaSnapshot(message: "请先登录 Codex")
            }

            try send(
                ["method": "account/rateLimits/read", "id": 2],
                to: input.fileHandleForWriting
            )

            guard let limitsResponse = collector.response(id: 2, deadline: deadline),
                  limitsResponse["error"] == nil else {
                if cancelled { return CodexQuotaSnapshot(message: "刷新已取消") }
                return CodexQuotaSnapshot(message: "Codex 用量暂不可用")
            }

            let windows = parseWindows(limitsResponse)
            guard !windows.isEmpty else {
                return CodexQuotaSnapshot(message: "账号未返回额度窗口")
            }
            return CodexQuotaSnapshot(
                windows: windows,
                updatedAt: Date(),
                message: nil
            )
        } catch {
            return CodexQuotaSnapshot(message: "无法连接 Codex")
        }
    }

    private var cancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    private func shutdown(
        process: Process,
        input: FileHandle,
        output: FileHandle,
        terminated: DispatchSemaphore
    ) {
        try? input.close()
        if process.isRunning,
           terminated.wait(timeout: .now() + 0.35) == .timedOut {
            process.terminate()
        }
        if process.isRunning,
           terminated.wait(timeout: .now() + 0.65) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 1)
        }
        try? output.close()
    }

    private func minimalEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in [
            "HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL",
            "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "SSL_CERT_FILE", "SSL_CERT_DIR"
        ] {
            if let value = source[key] {
                environment[key] = value
            }
        }
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        }
        return environment
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func hasChatGPTAccount(_ response: [String: Any]) -> Bool {
        guard let result = response["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return false
        }
        return type == "chatgpt" || type == "chatgptAuthTokens" || type == "agentIdentity" || type == "personalAccessToken"
    }

    private func parseWindows(_ response: [String: Any]) -> [CodexQuotaWindow] {
        guard let result = response["result"] as? [String: Any] else { return [] }

        var buckets: [(String, [String: Any])] = []
        if let byIdentifier = result["rateLimitsByLimitId"] as? [String: Any] {
            for key in byIdentifier.keys.sorted() where key.lowercased().contains("codex") {
                if let bucket = byIdentifier[key] as? [String: Any] {
                    buckets.append((key, bucket))
                }
            }
        }

        var parsedWindows = windows(from: buckets)
        if parsedWindows.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            parsedWindows = windows(from: [("codex", legacy)])
        }

        return parsedWindows.sorted {
            if $0.durationMinutes == $1.durationMinutes {
                return $0.title < $1.title
            }
            if $0.durationMinutes == 0 { return false }
            if $1.durationMinutes == 0 { return true }
            return $0.durationMinutes < $1.durationMinutes
        }
    }

    private func windows(
        from buckets: [(String, [String: Any])]
    ) -> [CodexQuotaWindow] {
        var result: [CodexQuotaWindow] = []
        for (bucketIdentifier, bucket) in buckets {
            let fallbackTitle = (bucket["limitName"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            for key in ["primary", "secondary"] {
                guard let value = bucket[key] as? [String: Any],
                      let used = number(value["usedPercent"]) else {
                    continue
                }
                let duration = safeInteger(value["windowDurationMins"]) ?? 0
                let resetSeconds = number(value["resetsAt"]).flatMap {
                    ($0 > 0 && $0 < 32_503_680_000) ? $0 : nil
                }
                let resetDate = resetSeconds.map(Date.init(timeIntervalSince1970:))
                let identity = "\(bucketIdentifier)-\(key)-\(duration)-\(Int(resetSeconds ?? 0))"

                result.append(
                    CodexQuotaWindow(
                        id: identity,
                        title: title(for: duration, fallback: fallbackTitle),
                        durationMinutes: duration,
                        remainingPercent: min(100, max(0, 100 - used)),
                        resetsAt: resetDate
                    )
                )
            }
        }
        return result
    }

    private func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string)
        } else {
            result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private func safeInteger(_ value: Any?) -> Int? {
        guard let value = number(value),
              value >= 0,
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value.rounded())
    }

    private func title(for durationMinutes: Int, fallback: String?) -> String {
        switch durationMinutes {
        case 300:
            return "5 小时"
        case 10_080:
            return "1 周"
        default:
            if durationMinutes > 0, durationMinutes % 1_440 == 0 {
                return "\(durationMinutes / 1_440) 天"
            }
            if durationMinutes > 0, durationMinutes % 60 == 0 {
                return "\(durationMinutes / 60) 小时"
            }
            if durationMinutes > 0 {
                return "\(durationMinutes) 分钟"
            }
            if let fallback, !fallback.isEmpty {
                return fallback
            }
            return "Codex 额度"
        }
    }
}

private final class JSONLineCollector: @unchecked Sendable {
    private static let maximumBufferSize = 1_048_576
    private let condition = NSCondition()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private var reachedEOF = false

    func append(_ data: Data) {
        condition.lock()
        guard !reachedEOF else {
            condition.unlock()
            return
        }
        guard buffer.count <= Self.maximumBufferSize - data.count else {
            reachedEOF = true
            buffer.removeAll(keepingCapacity: false)
            messages.removeAll(keepingCapacity: false)
            condition.broadcast()
            condition.unlock()
            return
        }
        buffer.append(data)
        drainLines()
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        reachedEOF = true
        if !buffer.isEmpty {
            decode(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
        condition.broadcast()
        condition.unlock()
    }

    func abort() {
        condition.lock()
        reachedEOF = true
        buffer.removeAll(keepingCapacity: false)
        messages.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
    }

    func response(id: Int, deadline: DispatchTime) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let index = messages.firstIndex(where: { messageID($0) == id }) {
                return messages.remove(at: index)
            }
            if reachedEOF { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            let deadlineNanos = deadline.uptimeNanoseconds
            guard deadlineNanos > now else { return nil }
            let seconds = Double(deadlineNanos - now) / 1_000_000_000
            condition.wait(until: Date().addingTimeInterval(seconds))
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                decode(Data(line))
            }
        }
    }

    private func decode(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["id"] != nil,
              dictionary["result"] != nil || dictionary["error"] != nil else {
            return
        }
        messages.append(dictionary)
    }

    private func messageID(_ message: [String: Any]) -> Int? {
        if let number = message["id"] as? NSNumber { return number.intValue }
        if let integer = message["id"] as? Int { return integer }
        return nil
    }
}
