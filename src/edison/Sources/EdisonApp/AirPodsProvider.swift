import Darwin
import Foundation

/// Reads an AirPods battery snapshot on demand. The provider has no timers and
/// never retains identifiers returned by the power-source service.
struct AirPodsProvider: Sendable {
    private let commandTimeout: TimeInterval

    init(commandTimeout: TimeInterval = 2.0) {
        self.commandTimeout = min(max(commandTimeout, 0.25), 10.0)
    }

    func snapshot() async -> AirPodsSnapshot {
        let timeout = commandTimeout
        let execution = PMSetExecution()

        return await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) {
                Self.makeSnapshot(commandTimeout: timeout, execution: execution)
            }.value
        }, onCancel: {
            // The detached worker does not inherit cancellation from the
            // dashboard task. Forward it explicitly so a closing panel never
            // leaves pmset running until its normal timeout.
            execution.cancel()
        })
    }
}

private extension AirPodsProvider {
    static let pmsetPath = "/usr/bin/pmset"
    static let systemProfilerPath = "/usr/sbin/system_profiler"
    static let maximumOutputSize = 1_048_576

    enum ProviderError: Error {
        case commandFailed
        case commandTimedOut
        case invalidPropertyList
        case outputTooLarge
    }

    enum PartKind: Int, CaseIterable, Hashable {
        case left
        case right
        case caseBattery
    }

    struct BluetoothDeviceState: Sendable {
        let name: String
        let isConnected: Bool
    }

    struct BluetoothInventory: Sendable {
        let isAvailable: Bool
        let devices: [BluetoothDeviceState]
    }

    struct SourceContext {
        var groupIdentifier: String?
        var name: String?
        var category: String?
        var transport: String?
        var sourceType: String?
        var part: PartKind?
        var hasCombinedParts = false
    }

    struct PartReading {
        let part: AirPodsPart
        let confidence: Int
    }

    struct CandidateGroup {
        var name: String?
        var parts: [PartKind: PartReading] = [:]
        var evidence = 0

        mutating func merge(
            kind: PartKind,
            level: Int?,
            isCharging: Bool?,
            confidence: Int,
            name proposedName: String?
        ) {
            if name == nil, let proposedName, !proposedName.isEmpty {
                name = proposedName
            }

            let incoming = AirPodsPart(level: level, isCharging: isCharging)
            if let existing = parts[kind] {
                let shouldReplace = confidence > existing.confidence
                    || (confidence == existing.confidence
                        && informationCount(incoming) > informationCount(existing.part))
                if shouldReplace {
                    parts[kind] = PartReading(part: incoming, confidence: confidence)
                } else {
                    parts[kind] = PartReading(
                        part: AirPodsPart(
                            level: existing.part.level ?? incoming.level,
                            isCharging: existing.part.isCharging ?? incoming.isCharging
                        ),
                        confidence: existing.confidence
                    )
                }
            } else {
                parts[kind] = PartReading(part: incoming, confidence: confidence)
            }

            evidence += 1
        }

        private func informationCount(_ part: AirPodsPart) -> Int {
            (part.level == nil ? 0 : 1) + (part.isCharging == nil ? 0 : 1)
        }
    }

    final class BoundedDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()
        private(set) var overflowed = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }

            guard !overflowed else { return }
            guard storage.count <= limit - data.count else {
                overflowed = true
                storage.removeAll(keepingCapacity: false)
                return
            }
            storage.append(data)
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func didOverflow() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return overflowed
        }
    }

    /// Owns at most one pmset process and safely bridges Swift task
    /// cancellation to that process. The lock also closes the launch race:
    /// cancellation occurring between `run()` and registration still causes
    /// the newly launched process to be terminated.
    final class PMSetExecution: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var process: Process?

        func register(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !isCancelled else { return false }
            self.process = process
            return true
        }

        func unregister(_ process: Process) {
            lock.lock()
            defer { lock.unlock() }

            guard self.process === process else { return }
            self.process = nil
        }

        func cancel() {
            let activeProcess: Process?

            lock.lock()
            isCancelled = true
            activeProcess = process
            lock.unlock()

            if let activeProcess {
                AirPodsProvider.cancelProcess(activeProcess)
            }
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    static func makeSnapshot(
        commandTimeout: TimeInterval,
        execution: PMSetExecution
    ) -> AirPodsSnapshot {
        guard !execution.cancelled else { return AirPodsSnapshot() }
        let bluetooth = readBluetoothInventory()
        guard !execution.cancelled else { return AirPodsSnapshot() }

        do {
            let data = try runPMSet(timeout: commandTimeout, execution: execution)
            guard !execution.cancelled else { return AirPodsSnapshot() }
            let dictionaries = try decodePropertyListDocuments(data)
            guard !execution.cancelled else { return AirPodsSnapshot() }
            let groups = collectCandidateGroups(from: dictionaries)
            return normalizedSnapshot(groups: groups, bluetooth: bluetooth, queriedAt: Date())
        } catch {
            var result = AirPodsSnapshot()
            if let device = preferredAirPodsDevice(in: bluetooth.devices) {
                result.name = device.name
                result.isConnected = device.isConnected
            }
            result.message = result.isConnected ? "状态暂不可用" : "未连接"
            return result
        }
    }

    static func runPMSet(
        timeout: TimeInterval,
        execution: PMSetExecution
    ) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = BoundedDataBuffer(limit: maximumOutputSize)
        let termination = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g", "accps", "-xml"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            throw ProviderError.commandFailed
        }

        guard execution.register(process) else {
            cancelProcess(process)
            throw CancellationError()
        }
        defer { execution.unregister(process) }

        // Process owns duplicated write descriptors after launch. Closing the
        // parent's copies lets the readers observe EOF when pmset exits.
        standardOutput.fileHandleForWriting.closeFile()
        standardError.fileHandleForWriting.closeFile()

        drain(standardOutput.fileHandleForReading, into: output, group: readers)
        drain(standardError.fileHandleForReading, into: nil, group: readers)

        if execution.cancelled {
            terminate(process, semaphore: termination)
            finishReaders(
                readers,
                handles: [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
            )
            throw CancellationError()
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            terminate(process, semaphore: termination)
            finishReaders(
                readers,
                handles: [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
            )
            throw ProviderError.commandTimedOut
        }

        finishReaders(
            readers,
            handles: [standardOutput.fileHandleForReading, standardError.fileHandleForReading]
        )

        guard !execution.cancelled else {
            throw CancellationError()
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProviderError.commandFailed
        }
        guard !output.didOverflow() else {
            throw ProviderError.outputTooLarge
        }
        return output.value()
    }

    static func drain(
        _ handle: FileHandle,
        into buffer: BoundedDataBuffer?,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }

            while true {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: 16_384) ?? Data()
                } catch {
                    return
                }
                guard !chunk.isEmpty else { return }
                buffer?.append(chunk)
            }
        }
    }

    static func terminate(_ process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        cancelProcess(process)

        if semaphore.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + 1.0)
        }
    }

    static func cancelProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        // `pmset` normally exits immediately on SIGTERM. Keep the fallback
        // asynchronous so cancellation handlers never block the main actor.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            guard process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    static func finishReaders(_ readers: DispatchGroup, handles: [FileHandle]) {
        if readers.wait(timeout: .now() + 1.0) == .timedOut {
            handles.forEach { $0.closeFile() }
            _ = readers.wait(timeout: .now() + 0.25)
        }
    }

    /// `pmset` writes one complete XML plist for every power source, so its
    /// stdout can contain several adjacent plist documents rather than an array.
    static func decodePropertyListDocuments(_ data: Data) throws -> [[String: Any]] {
        let opening = Data("<?xml".utf8)
        let closing = Data("</plist>".utf8)
        var cursor = data.startIndex
        var result: [[String: Any]] = []

        while cursor < data.endIndex,
              let openingRange = data.range(of: opening, in: cursor..<data.endIndex) {
            guard let closingRange = data.range(
                of: closing,
                in: openingRange.lowerBound..<data.endIndex
            ) else {
                throw ProviderError.invalidPropertyList
            }

            let document = Data(data[openingRange.lowerBound..<closingRange.upperBound])
            var format = PropertyListSerialization.PropertyListFormat.xml
            let propertyList: Any
            do {
                propertyList = try PropertyListSerialization.propertyList(
                    from: document,
                    options: [],
                    format: &format
                )
            } catch {
                throw ProviderError.invalidPropertyList
            }
            guard format == .xml else {
                throw ProviderError.invalidPropertyList
            }

            if let dictionary = propertyList as? [String: Any] {
                result.append(dictionary)
            } else if let dictionaries = propertyList as? [[String: Any]] {
                result.append(contentsOf: dictionaries)
            } else {
                throw ProviderError.invalidPropertyList
            }

            cursor = closingRange.upperBound
        }

        guard !result.isEmpty else {
            throw ProviderError.invalidPropertyList
        }
        return result
    }

    static func collectCandidateGroups(
        from dictionaries: [[String: Any]]
    ) -> [String: CandidateGroup] {
        var groups: [String: CandidateGroup] = [:]
        for (index, dictionary) in dictionaries.enumerated() {
            walk(
                dictionary,
                inherited: SourceContext(),
                containerHint: nil,
                documentIndex: index,
                groups: &groups
            )
        }
        return groups.filter { !$0.value.parts.isEmpty }
    }

    static func walk(
        _ dictionary: [String: Any],
        inherited: SourceContext,
        containerHint: String?,
        documentIndex: Int,
        groups: inout [String: CandidateGroup]
    ) {
        let fields = canonicalFields(dictionary)
        var context = inherited

        context.groupIdentifier = stringValue(
            firstValue(fields, keys: ["groupidentifier", "groupid", "accessoryidentifier"])
        ) ?? context.groupIdentifier
        context.name = cleanName(
            stringValue(firstValue(fields, keys: ["name", "devicename", "productname"]))
        ) ?? context.name
        context.category = stringValue(
            firstValue(fields, keys: ["accessorycategory", "category"])
        ) ?? context.category
        context.transport = stringValue(
            firstValue(fields, keys: ["transporttype", "transport"])
        ) ?? context.transport
        context.sourceType = stringValue(
            firstValue(fields, keys: ["type", "powersourcetype"])
        ) ?? context.sourceType
        context.hasCombinedParts = context.hasCombinedParts
            || fields["combinedparts"] != nil

        let explicitPart = stringValue(
            firstValue(
                fields,
                keys: ["partidentifier", "batterycomponent", "component", "role", "part"]
            )
        )
        let partName = stringValue(firstValue(fields, keys: ["partname"]))
        context.part = partKind(from: explicitPart)
            ?? partKind(from: partName)
            ?? partKind(from: containerHint)
            ?? context.part

        if !isInternal(context), isAccessory(context), let kind = context.part {
            let level = normalizedLevel(
                current: firstValue(
                    fields,
                    keys: [
                        "currentcapacity", "batterypercent", "batterypercentage",
                        "percentcharge", "batterylevel"
                    ]
                ),
                maximum: firstValue(fields, keys: ["maxcapacity", "maximumcapacity"])
            )
            let charging = boolValue(
                firstValue(fields, keys: ["ischarging", "charging"])
            )

            if level != nil || charging != nil {
                merge(
                    context: context,
                    kind: kind,
                    level: level,
                    charging: charging,
                    confidence: explicitPart == nil ? 2 : 3,
                    documentIndex: documentIndex,
                    groups: &groups
                )
            }
        }

        if !isInternal(context), isAccessory(context) {
            collectCompactReadings(
                dictionary,
                context: context,
                documentIndex: documentIndex,
                groups: &groups
            )
        }

        for (key, value) in dictionary {
            if let child = value as? [String: Any] {
                walk(
                    child,
                    inherited: context,
                    containerHint: key,
                    documentIndex: documentIndex,
                    groups: &groups
                )
            } else if let children = value as? [[String: Any]] {
                for child in children {
                    walk(
                        child,
                        inherited: context,
                        containerHint: key,
                        documentIndex: documentIndex,
                        groups: &groups
                    )
                }
            } else if let values = value as? [Any] {
                for child in values {
                    if let child = child as? [String: Any] {
                        walk(
                            child,
                            inherited: context,
                            containerHint: key,
                            documentIndex: documentIndex,
                            groups: &groups
                        )
                    }
                }
            }
        }
    }

    static func collectCompactReadings(
        _ dictionary: [String: Any],
        context: SourceContext,
        documentIndex: Int,
        groups: inout [String: CandidateGroup]
    ) {
        for kind in PartKind.allCases {
            var level: Int?
            var charging: Bool?

            for (key, value) in dictionary {
                let canonical = canonicalKey(key)
                guard keyRefersToPart(canonical, kind: kind) else { continue }

                if keyDescribesCharging(canonical) {
                    charging = boolValue(value) ?? charging
                } else if keyDescribesLevel(canonical) {
                    level = normalizedLevel(current: value, maximum: nil) ?? level
                } else if canonical == canonicalPartName(kind), !(value is [Any]) {
                    level = normalizedLevel(current: value, maximum: nil) ?? level
                }
            }

            if level != nil || charging != nil {
                merge(
                    context: context,
                    kind: kind,
                    level: level,
                    charging: charging,
                    confidence: 1,
                    documentIndex: documentIndex,
                    groups: &groups
                )
            }
        }
    }

    static func merge(
        context: SourceContext,
        kind: PartKind,
        level: Int?,
        charging: Bool?,
        confidence: Int,
        documentIndex: Int,
        groups: inout [String: CandidateGroup]
    ) {
        let key = groupKey(context: context, documentIndex: documentIndex)
        var group = groups[key] ?? CandidateGroup()
        group.merge(
            kind: kind,
            level: level,
            isCharging: charging,
            confidence: confidence,
            name: context.name
        )
        groups[key] = group
    }

    static func normalizedSnapshot(
        groups: [String: CandidateGroup],
        bluetooth: BluetoothInventory,
        queriedAt: Date
    ) -> AirPodsSnapshot {
        guard let group = bestGroup(in: groups, bluetooth: bluetooth) else {
            var result = AirPodsSnapshot()
            if let device = preferredAirPodsDevice(in: bluetooth.devices) {
                result.name = displayName(device.name)
                result.isConnected = device.isConnected
            }
            result.updatedAt = queriedAt
            result.message = result.isConnected ? "电量暂不可用" : "未连接"
            return result
        }

        let device = matchingBluetoothDevice(for: group.name, in: bluetooth.devices)
            ?? preferredAirPodsDevice(in: bluetooth.devices)
        var result = AirPodsSnapshot()
        result.name = displayName(group.name ?? device?.name)
        result.isConnected = device?.isConnected ?? true
        result.left = group.parts[.left]?.part ?? AirPodsPart()
        result.right = group.parts[.right]?.part ?? AirPodsPart()
        result.caseBattery = group.parts[.caseBattery]?.part ?? AirPodsPart()
        result.updatedAt = queriedAt

        if result.left.level == nil,
           result.right.level == nil,
           result.caseBattery.level == nil,
           result.left.isCharging == nil,
           result.right.isCharging == nil,
           result.caseBattery.isCharging == nil {
            result.message = "电量暂不可用"
        } else if !result.isConnected {
            result.message = "未连接"
        }
        return result
    }

    static func bestGroup(
        in groups: [String: CandidateGroup],
        bluetooth: BluetoothInventory
    ) -> CandidateGroup? {
        groups.values.max { lhs, rhs in
            score(lhs, bluetooth: bluetooth) < score(rhs, bluetooth: bluetooth)
        }
    }

    static func score(_ group: CandidateGroup, bluetooth: BluetoothInventory) -> Int {
        var value = group.parts.count * 25 + group.evidence
        value += group.parts.values.reduce(0) { partial, reading in
            partial + (reading.part.level == nil ? 0 : 8)
                + (reading.part.isCharging == nil ? 0 : 2)
        }

        if let name = group.name, canonicalName(name).contains("airpods") {
            value += 100
        }
        if let device = matchingBluetoothDevice(for: group.name, in: bluetooth.devices) {
            value += device.isConnected ? 500 : 150
        }
        return value
    }

    static func groupKey(context: SourceContext, documentIndex: Int) -> String {
        if let identifier = context.groupIdentifier, !identifier.isEmpty {
            return "identifier:\(identifier)"
        }
        if let name = context.name {
            let normalized = canonicalName(name)
            if !normalized.isEmpty {
                return "name:\(normalized)"
            }
        }
        // Group anonymous component documents together; pmset supplies stable
        // identifiers for normal accessory records, so this is a last resort.
        return context.hasCombinedParts ? "combined" : "anonymous:\(documentIndex / 3)"
    }

    static func readBluetoothInventory() -> BluetoothInventory {
        let process = Process()
        let standardOutput = Pipe()
        let output = BoundedDataBuffer(limit: maximumOutputSize)
        let termination = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: systemProfilerPath)
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            return BluetoothInventory(isAvailable: false, devices: [])
        }

        standardOutput.fileHandleForWriting.closeFile()
        drain(standardOutput.fileHandleForReading, into: output, group: readers)

        guard termination.wait(timeout: .now() + 1.0) == .success else {
            terminate(process, semaphore: termination)
            finishReaders(readers, handles: [standardOutput.fileHandleForReading])
            return BluetoothInventory(isAvailable: false, devices: [])
        }
        finishReaders(readers, handles: [standardOutput.fileHandleForReading])

        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              !output.didOverflow(),
              let object = try? JSONSerialization.jsonObject(with: output.value()),
              let root = object as? [String: Any],
              let records = root["SPBluetoothDataType"] as? [[String: Any]],
              let record = records.first else {
            return BluetoothInventory(isAvailable: false, devices: [])
        }

        var devices: [BluetoothDeviceState] = []
        for (section, connected) in [("device_connected", true), ("device_not_connected", false)] {
            guard let entries = record[section] as? [[String: Any]] else { continue }
            for entry in entries {
                for (rawName, _) in entry {
                    guard let name = cleanName(rawName),
                          canonicalName(name).contains("airpods") else { continue }
                    devices.append(BluetoothDeviceState(name: name, isConnected: connected))
                }
            }
        }
        return BluetoothInventory(isAvailable: true, devices: devices)
    }

    static func matchingBluetoothDevice(
        for candidateName: String?,
        in devices: [BluetoothDeviceState]
    ) -> BluetoothDeviceState? {
        guard let candidateName else { return nil }
        let candidate = canonicalName(candidateName)
        guard !candidate.isEmpty else { return nil }

        let matches = devices.filter {
            let deviceName = canonicalName($0.name)
            return deviceName == candidate
                || (min(deviceName.count, candidate.count) >= 5
                    && (deviceName.contains(candidate) || candidate.contains(deviceName)))
        }
        return matches.first(where: \.isConnected) ?? matches.first
    }

    static func preferredAirPodsDevice(
        in devices: [BluetoothDeviceState]
    ) -> BluetoothDeviceState? {
        let airPods = devices.filter { canonicalName($0.name).contains("airpods") }
        return airPods.first(where: \.isConnected) ?? airPods.first
    }

    static func isInternal(_ context: SourceContext) -> Bool {
        let values = [context.transport, context.sourceType, context.name]
            .compactMap { $0 }
            .map(canonicalKey)
        return values.contains { value in
            value == "internal" || value.contains("internalbattery")
        }
    }

    static func isAccessory(_ context: SourceContext) -> Bool {
        let category = canonicalKey(context.category ?? "")
        let transport = canonicalKey(context.transport ?? "")
        let sourceType = canonicalKey(context.sourceType ?? "")
        let name = canonicalName(context.name ?? "")

        let audioCategory = category.contains("headphone")
            || category.contains("earphone")
            || category.contains("earbud")
            || category.contains("headset")
        return name.contains("airpods")
            || audioCategory
            || (context.part != nil
                && (transport.contains("bluetooth")
                    || sourceType.contains("accessory")
                    || context.groupIdentifier != nil
                    || context.hasCombinedParts))
    }

    static func normalizedLevel(current: Any?, maximum: Any?) -> Int? {
        guard let current = numberValue(current), current.isFinite, current >= 0 else {
            return nil
        }

        let percentage: Double
        if let maximum = numberValue(maximum), maximum.isFinite, maximum > 0 {
            percentage = current * 100.0 / maximum
        } else {
            percentage = current
        }
        guard percentage >= 0, percentage <= 100.5 else { return nil }
        return min(max(Int(percentage.rounded()), 0), 100)
    }

    static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        guard let string = value as? String else { return nil }
        switch canonicalKey(string) {
        case "true", "yes", "1", "charging":
            return true
        case "false", "no", "0", "notcharging":
            return false
        default:
            return nil
        }
    }

    static func partKind(from value: String?) -> PartKind? {
        guard let value else { return nil }
        let normalized = canonicalKey(value)

        if normalized == "left"
            || normalized == "l"
            || normalized.contains("leftear")
            || normalized.contains("leftbud")
            || normalized.contains("leftpod") {
            return .left
        }
        if normalized == "right"
            || normalized == "r"
            || normalized.contains("rightear")
            || normalized.contains("rightbud")
            || normalized.contains("rightpod") {
            return .right
        }
        if normalized == "case"
            || normalized == "c"
            || normalized.contains("chargingcase")
            || normalized.contains("casebattery")
            || normalized.contains("batterycase")
            || normalized.contains("smartcase") {
            return .caseBattery
        }
        return nil
    }

    static func keyRefersToPart(_ key: String, kind: PartKind) -> Bool {
        switch kind {
        case .left:
            return key == "left" || key.contains("left")
        case .right:
            return key == "right" || key.contains("right")
        case .caseBattery:
            return key == "case"
                || key.hasPrefix("case")
                || key.contains("casebattery")
                || key.contains("batterycase")
                || key.contains("chargingcase")
        }
    }

    static func keyDescribesLevel(_ key: String) -> Bool {
        !key.contains("max")
            && (key.contains("level")
                || key.contains("percent")
                || key.contains("capacity")
                || key.contains("battery"))
    }

    static func keyDescribesCharging(_ key: String) -> Bool {
        key.contains("charging")
    }

    static func canonicalPartName(_ kind: PartKind) -> String {
        switch kind {
        case .left: return "left"
        case .right: return "right"
        case .caseBattery: return "case"
        }
    }

    static func canonicalFields(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            let canonical = canonicalKey(key)
            if result[canonical] == nil {
                result[canonical] = value
            }
        }
        return result
    }

    static func firstValue(_ fields: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = fields[key] {
                return value
            }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func cleanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !canonicalKey(trimmed).contains("internalbattery") else {
            return nil
        }
        return trimmed
    }

    static func displayName(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "AirPods Pro" }
        let normalized = canonicalName(value)
        if normalized.contains("airpodspro") { return "AirPods Pro" }
        if normalized.contains("airpods") { return "AirPods" }
        return value
    }

    static func canonicalKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func canonicalName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).filter { $0.isLetter || $0.isNumber }
    }
}
