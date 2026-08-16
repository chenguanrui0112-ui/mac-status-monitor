import Foundation

struct CPUMetrics: Equatable, Sendable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 100

    var total: Double { user + system }
}

struct GPUMetrics: Equatable, Sendable {
    var device: Double = 0
    var renderer: Double = 0
    var tiler: Double = 0
    var isAvailable = false
}

enum ThermalStatus: String, Equatable, Sendable {
    case nominal = "正常"
    case fair = "轻微"
    case serious = "严重"
    case critical = "危急"
    case unknown = "未知"
}

struct TemperatureMetrics: Equatable, Sendable {
    var celsius: Double?
    var status: ThermalStatus = .unknown
}

struct MetricPoint: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let primary: Double
    let secondary: Double
    let tertiary: Double
}

struct AirPodsPart: Equatable, Sendable {
    var level: Int?
    var isCharging: Bool?
}

struct AirPodsSnapshot: Equatable, Sendable {
    var name: String = "AirPods Pro"
    var isConnected = false
    var left = AirPodsPart()
    var right = AirPodsPart()
    var caseBattery = AirPodsPart()
    var updatedAt: Date?
    var message: String?
}

struct CodexQuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let durationMinutes: Int
    let remainingPercent: Double
    let resetsAt: Date?
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    var windows: [CodexQuotaWindow] = []
    var updatedAt: Date?
    var message: String?
}

