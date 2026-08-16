import Darwin
import Foundation
import IOKit

struct SystemMetricsSnapshot: Equatable, Sendable {
    let cpu: CPUMetrics
    let gpu: GPUMetrics
    let uptime: TimeInterval
    let temperature: TemperatureMetrics
}

/// Synchronous system sampling intended to be owned and called by `AppModel`.
///
/// The provider keeps the previous Mach CPU counters and the IOKit/HID handles
/// alive between samples, so a one-hertz UI refresh does not recreate them.
@MainActor
final class SystemMetricsProvider {
    private var previousCPUTicks: CPUTicks?
    private var lastCPU = CPUMetrics()

    private var gpuServices: [io_service_t] = []
    private var lastGPUDiscoveryUptime = -Double.greatestFiniteMagnitude
    private let gpuRediscoveryInterval: TimeInterval = 30

    private let temperatureReader = HIDTemperatureReader()

    init() {
        // Establish a baseline without sleeping or blocking the main actor. The
        // first panel refresh will normally be one second after this sample.
        previousCPUTicks = Self.currentCPUTicks()
    }

    deinit {
        for service in gpuServices {
            IOObjectRelease(service)
        }
    }

    func resume() {
        previousCPUTicks = Self.currentCPUTicks()
    }

    func pause() {
        // Do not let ticks accumulated while the panel was closed dilute the
        // first visible CPU sample. IOKit/HID handles intentionally stay warm.
        previousCPUTicks = nil
    }

    func readSnapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: readCPU(),
            gpu: readGPU(),
            uptime: readUptime(),
            temperature: readTemperature()
        )
    }

    func readCPU() -> CPUMetrics {
        guard let current = Self.currentCPUTicks() else {
            return lastCPU
        }

        guard let previous = previousCPUTicks else {
            previousCPUTicks = current
            return lastCPU
        }
        previousCPUTicks = current

        // cpu_ticks are 32-bit counters. Wrapping subtraction also handles the
        // natural rollover that can occur on a long-running machine.
        let userDelta = UInt64(current.user &- previous.user)
        let niceDelta = UInt64(current.nice &- previous.nice)
        let systemDelta = UInt64(current.system &- previous.system)
        let idleDelta = UInt64(current.idle &- previous.idle)
        let totalDelta = userDelta + niceDelta + systemDelta + idleDelta

        guard totalDelta > 0 else {
            return lastCPU
        }

        let scale = 100.0 / Double(totalDelta)
        let user = min(max(Double(userDelta + niceDelta) * scale, 0), 100)
        let system = min(max(Double(systemDelta) * scale, 0), 100)
        let idle = min(max(Double(idleDelta) * scale, 0), 100)

        lastCPU = CPUMetrics(user: user, system: system, idle: idle)
        return lastCPU
    }

    func readGPU() -> GPUMetrics {
        let now = ProcessInfo.processInfo.systemUptime
        ensureGPUServices(now: now)

        var metrics = readGPUFromCachedServices()
        if !metrics.isAvailable,
           now - lastGPUDiscoveryUptime >= gpuRediscoveryInterval {
            discoverGPUServices(now: now)
            metrics = readGPUFromCachedServices()
        }
        return metrics
    }

    func readUptime() -> TimeInterval {
        max(ProcessInfo.processInfo.systemUptime, 0)
    }

    func readTemperature() -> TemperatureMetrics {
        TemperatureMetrics(
            celsius: temperatureReader?.readMaximumDieTemperature(),
            status: Self.currentThermalStatus()
        )
    }

    private static func currentCPUTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        let expectedCount = MemoryLayout<host_cpu_load_info_data_t>.stride
            / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(expectedCount)

        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: expectedCount
            ) { reboundPointer in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS,
              count >= mach_msg_type_number_t(expectedCount) else {
            return nil
        }

        return CPUTicks(
            user: load.cpu_ticks.0,
            system: load.cpu_ticks.1,
            idle: load.cpu_ticks.2,
            nice: load.cpu_ticks.3
        )
    }

    private static func currentThermalStatus() -> ThermalStatus {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }

    private func ensureGPUServices(now: TimeInterval) {
        guard gpuServices.isEmpty else { return }
        guard now - lastGPUDiscoveryUptime >= gpuRediscoveryInterval else { return }
        discoverGPUServices(now: now)
    }

    private func discoverGPUServices(now: TimeInterval) {
        releaseGPUServices()
        lastGPUDiscoveryUptime = now

        guard let matching = IOServiceMatching("IOAccelerator") else { return }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            // IOIteratorNext returns a retained object. Keep that ownership
            // while cached and balance it in releaseGPUServices().
            gpuServices.append(service)
        }
    }

    private func releaseGPUServices() {
        for service in gpuServices {
            IOObjectRelease(service)
        }
        gpuServices.removeAll(keepingCapacity: true)
    }

    private func readGPUFromCachedServices() -> GPUMetrics {
        var device: Double?
        var renderer: Double?
        var tiler: Double?

        for service in gpuServices {
            guard let unmanagedValue = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ) else {
                continue
            }

            let value = unmanagedValue.takeRetainedValue()
            guard let statistics = value as? NSDictionary else { continue }

            device = Self.maximum(
                device,
                Self.utilization(component: "device", in: statistics)
            )
            renderer = Self.maximum(
                renderer,
                Self.utilization(component: "renderer", in: statistics)
            )
            tiler = Self.maximum(
                tiler,
                Self.utilization(component: "tiler", in: statistics)
            )
        }

        guard device != nil || renderer != nil || tiler != nil else {
            return GPUMetrics()
        }

        return GPUMetrics(
            device: device ?? 0,
            renderer: renderer ?? 0,
            tiler: tiler ?? 0,
            isAvailable: true
        )
    }

    private static func utilization(
        component: String,
        in statistics: NSDictionary
    ) -> Double? {
        var result: Double?

        for (rawKey, rawValue) in statistics {
            guard let key = rawKey as? String else { continue }
            let normalizedKey = key.lowercased().filter { $0.isLetter }
            guard normalizedKey.contains(component),
                  normalizedKey.contains("utilization"),
                  let number = rawValue as? NSNumber else {
                continue
            }

            let value = number.doubleValue
            guard value.isFinite else { continue }
            result = maximum(result, min(max(value, 0), 100))
        }

        return result
    }

    private static func maximum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}

private struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

// MARK: - Private IOHID temperature SPI

private typealias HIDEventSystemClientCreateFunction = @convention(c) (
    CFAllocator?
) -> UnsafeRawPointer?

private typealias HIDEventSystemClientSetMatchingFunction = @convention(c) (
    UnsafeRawPointer?,
    CFDictionary?
) -> Void

private typealias HIDEventSystemClientCopyServicesFunction = @convention(c) (
    UnsafeRawPointer?
) -> UnsafeRawPointer?

private typealias HIDServiceClientCopyPropertyFunction = @convention(c) (
    UnsafeRawPointer?,
    CFString?
) -> UnsafeRawPointer?

private typealias HIDServiceClientCopyEventFunction = @convention(c) (
    UnsafeRawPointer?,
    Int64,
    Int32,
    Int64
) -> UnsafeRawPointer?

private typealias HIDEventGetFloatValueFunction = @convention(c) (
    UnsafeRawPointer?,
    UInt32
) -> Double

private struct HIDTemperatureSymbols {
    let createClient: HIDEventSystemClientCreateFunction
    let setMatching: HIDEventSystemClientSetMatchingFunction
    let copyServices: HIDEventSystemClientCopyServicesFunction
    let copyProperty: HIDServiceClientCopyPropertyFunction
    let copyEvent: HIDServiceClientCopyEventFunction
    let getFloatValue: HIDEventGetFloatValueFunction

    static func load(from handle: UnsafeMutableRawPointer) -> HIDTemperatureSymbols? {
        guard
            let createClient = dlsym(handle, "IOHIDEventSystemClientCreate"),
            let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
            let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
            let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
            let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
            let getFloatValue = dlsym(handle, "IOHIDEventGetFloatValue")
        else {
            return nil
        }

        return HIDTemperatureSymbols(
            createClient: unsafeBitCast(
                createClient,
                to: HIDEventSystemClientCreateFunction.self
            ),
            setMatching: unsafeBitCast(
                setMatching,
                to: HIDEventSystemClientSetMatchingFunction.self
            ),
            copyServices: unsafeBitCast(
                copyServices,
                to: HIDEventSystemClientCopyServicesFunction.self
            ),
            copyProperty: unsafeBitCast(
                copyProperty,
                to: HIDServiceClientCopyPropertyFunction.self
            ),
            copyEvent: unsafeBitCast(
                copyEvent,
                to: HIDServiceClientCopyEventFunction.self
            ),
            getFloatValue: unsafeBitCast(
                getFloatValue,
                to: HIDEventGetFloatValueFunction.self
            )
        )
    }
}

private final class HIDTemperatureReader {
    private static let temperatureEventType: Int64 = 15
    private static let temperatureLevelField: UInt32 = 0x000F_0000
    private static let serviceRediscoveryInterval: TimeInterval = 30

    private let libraryHandle: UnsafeMutableRawPointer
    private let symbols: HIDTemperatureSymbols
    private let client: UnsafeRawPointer
    private var dieServices: [UnsafeRawPointer] = []
    private var lastServiceDiscoveryUptime = -Double.greatestFiniteMagnitude

    init?() {
        guard let libraryHandle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            return nil
        }

        guard let symbols = HIDTemperatureSymbols.load(from: libraryHandle) else {
            dlclose(libraryHandle)
            return nil
        }

        guard let client = symbols.createClient(kCFAllocatorDefault) else {
            dlclose(libraryHandle)
            return nil
        }

        self.libraryHandle = libraryHandle
        self.symbols = symbols
        self.client = client

        let matching = [
            "PrimaryUsagePage": NSNumber(value: Int32(0xFF00)),
            "PrimaryUsage": NSNumber(value: Int32(5))
        ] as CFDictionary
        symbols.setMatching(client, matching)
        discoverDieServices(now: ProcessInfo.processInfo.systemUptime)
    }

    deinit {
        releaseDieServices()
        Unmanaged<AnyObject>.fromOpaque(client).release()
        dlclose(libraryHandle)
    }

    func readMaximumDieTemperature() -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        if dieServices.isEmpty,
           now - lastServiceDiscoveryUptime >= Self.serviceRediscoveryInterval {
            discoverDieServices(now: now)
        }

        var maximumTemperature: Double?
        for service in dieServices {
            guard let event = symbols.copyEvent(
                service,
                Self.temperatureEventType,
                0,
                0
            ) else {
                continue
            }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }

            let value = symbols.getFloatValue(
                event,
                Self.temperatureLevelField
            )
            // Avoid exposing sentinel, uninitialised, or corrupted SPI values.
            guard value.isFinite, value > 0, value < 150 else { continue }
            maximumTemperature = max(maximumTemperature ?? value, value)
        }

        return maximumTemperature
    }

    private func discoverDieServices(now: TimeInterval) {
        releaseDieServices()
        lastServiceDiscoveryUptime = now

        guard let servicesPointer = symbols.copyServices(client) else { return }
        let services = Unmanaged<CFArray>
            .fromOpaque(servicesPointer)
            .takeRetainedValue()

        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let product = copyProductName(for: service),
                  Self.isDieSensor(product) else {
                continue
            }

            // The copied array owns its elements. Retain selected services so
            // they remain valid after the array is released at function exit.
            _ = Unmanaged<AnyObject>.fromOpaque(service).retain()
            dieServices.append(service)
        }
    }

    private func releaseDieServices() {
        for service in dieServices {
            Unmanaged<AnyObject>.fromOpaque(service).release()
        }
        dieServices.removeAll(keepingCapacity: true)
    }

    private func copyProductName(for service: UnsafeRawPointer) -> String? {
        guard let property = symbols.copyProperty(service, "Product" as CFString) else {
            return nil
        }
        let value = Unmanaged<AnyObject>
            .fromOpaque(property)
            .takeRetainedValue()
        return value as? String
    }

    private static func isDieSensor(_ product: String) -> Bool {
        let normalized = product.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("pmu") && normalized.contains("tdie")
    }
}
