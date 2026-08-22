import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cpu = CPUMetrics()
    @Published private(set) var gpu = GPUMetrics()
    @Published private(set) var temperature = TemperatureMetrics(celsius: nil)
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var cpuHistory: [MetricPoint] = []
    @Published private(set) var gpuHistory: [MetricPoint] = []
    @Published private(set) var airPods = AirPodsSnapshot(message: "等待连接 AirPods")
    @Published private(set) var codexQuota = CodexQuotaSnapshot(message: "尚未刷新")
    @Published private(set) var youTuQuota = YouTuQuotaSnapshot(message: "尚未刷新")
    @Published private(set) var todos = TodoSnapshot(message: "等待连接提醒事项")
    @Published private(set) var isRefreshingCodex = false
    @Published private(set) var isRefreshingYouTu = false
    @Published private(set) var isWorkingOnTodos = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published var showsSettings = false

    private let metricsProvider = SystemMetricsProvider()
    private let airPodsProvider = AirPodsProvider()
    private let codexProvider = CodexQuotaProvider()
    private let youTuProvider = YouTuQuotaProvider()
    private let todoProvider = TodoProvider()
    private var metricsTask: Task<Void, Never>?
    private var airPodsTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?
    private var youTuTask: Task<Void, Never>?
    private var todoTask: Task<Void, Never>?
    private var panelIsVisible = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        updateLaunchAtLoginStatus()
        installWorkspaceObservers()
        // Keep a real rolling history while the menu-bar app is running, so
        // opening the panel never begins with an empty chart.
        startMetricsSampling()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    func panelDidAppear() {
        guard !panelIsVisible else { return }
        panelIsVisible = true
        configureDefaultLaunchAtLoginIfNeeded()
        // Interrupt a possible five-second background wait so the first open
        // always receives a fresh sample immediately.
        startMetricsSampling()
        startAirPodsSampling()
        refreshCodexIfNeeded()
        refreshYouTuIfNeeded()
        refreshTodos()
    }

    func panelDidDisappear() {
        panelIsVisible = false
        stopPanelWork()
        // Resume the lower-frequency rolling history while hidden.
        startMetricsSampling()
    }

    private func stopPanelWork() {
        airPodsTask?.cancel()
        airPodsTask = nil
        codexTask?.cancel()
        codexTask = nil
        youTuTask?.cancel()
        youTuTask = nil
        isRefreshingCodex = false
        isRefreshingYouTu = false
    }

    func refreshCodex() {
        codexTask?.cancel()
        isRefreshingCodex = true
        codexTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.codexProvider.snapshot()
            guard !Task.isCancelled else { return }
            self.applyCodexSnapshot(snapshot)
            self.isRefreshingCodex = false
            self.codexTask = nil
        }
    }

    func refreshYouTu() {
        youTuTask?.cancel()
        isRefreshingYouTu = true
        youTuTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.youTuProvider.snapshot()
            guard !Task.isCancelled else { return }
            self.applyYouTuSnapshot(snapshot)
            self.isRefreshingYouTu = false
            self.youTuTask = nil
        }
    }

    func requestTodoAccess() {
        performTodoOperation { [todoProvider] in
            await todoProvider.requestAccess()
        }
    }

    func addTodo(title: String) {
        performTodoOperation { [todoProvider] in
            await todoProvider.add(title: title)
        }
    }

    func completeTodo(id: String) {
        performTodoOperation { [todoProvider] in
            await todoProvider.complete(id: id)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = friendlyLoginItemError(error)
        }
        UserDefaults.standard.set(true, forKey: "hasConfiguredLaunchAtLogin")
        updateLaunchAtLoginStatus()
    }

    func terminateApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func startMetricsSampling() {
        metricsTask?.cancel()
        metricsProvider.resume()
        metricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = self.metricsProvider.readSnapshot()
                self.cpu = snapshot.cpu
                self.gpu = snapshot.gpu
                self.temperature = snapshot.temperature
                self.uptime = snapshot.uptime
                self.appendMetricHistory(at: Date())

                do {
                    try await Task.sleep(nanoseconds: metricsSamplingInterval)
                } catch {
                    break
                }
            }
        }
    }

    private func startAirPodsSampling() {
        airPodsTask?.cancel()
        airPodsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = await self.airPodsProvider.snapshot()
                guard !Task.isCancelled else { return }
                self.airPods = snapshot

                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private var metricsSamplingInterval: UInt64 {
        panelIsVisible ? 1_000_000_000 : 5_000_000_000
    }


    private func refreshCodexIfNeeded() {
        if let updatedAt = codexQuota.updatedAt,
           Date().timeIntervalSince(updatedAt) < 60 {
            return
        }
        refreshCodex()
    }

    private func refreshYouTuIfNeeded() {
        if let readAt = youTuQuota.readAt,
           Date().timeIntervalSince(readAt) < 60 {
            return
        }
        refreshYouTu()
    }

    private func refreshTodos() {
        performTodoOperation { [todoProvider] in
            await todoProvider.snapshot()
        }
    }

    private func performTodoOperation(
        _ operation: @escaping @Sendable () async -> TodoSnapshot
    ) {
        todoTask?.cancel()
        isWorkingOnTodos = true
        todoTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await operation()
            guard !Task.isCancelled else { return }
            self.todos = snapshot
            self.isWorkingOnTodos = false
            self.todoTask = nil
        }
    }

    private func applyCodexSnapshot(_ snapshot: CodexQuotaSnapshot) {
        guard snapshot.windows.isEmpty, !codexQuota.windows.isEmpty else {
            codexQuota = snapshot
            return
        }

        // 查询暂时失败时，保留最后一次成功的窗口和时间，避免面板突然变成空白。
        codexQuota.message = snapshot.message ?? "Codex 用量暂不可用"
    }

    private func applyYouTuSnapshot(_ snapshot: YouTuQuotaSnapshot) {
        guard snapshot.totalBytes == nil, youTuQuota.totalBytes != nil else {
            youTuQuota = snapshot
            return
        }

        // 本地缓存短暂被 YouTu 占用时，保留最近一次成功额度。
        youTuQuota.message = snapshot.message ?? "YouTu 用量暂不可用"
    }

    private func appendMetricHistory(at date: Date) {
        cpuHistory.append(
            MetricPoint(
                date: date,
                primary: cpu.user,
                secondary: cpu.system,
                tertiary: 0
            )
        )
        gpuHistory.append(
            MetricPoint(
                date: date,
                primary: gpu.device,
                secondary: gpu.renderer,
                tertiary: gpu.tiler
            )
        )
        if cpuHistory.count > 60 {
            cpuHistory.removeFirst(cpuHistory.count - 60)
        }
        if gpuHistory.count > 60 {
            gpuHistory.removeFirst(gpuHistory.count - 60)
        }
    }

    private func configureDefaultLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasConfiguredLaunchAtLogin") else {
            updateLaunchAtLoginStatus()
            return
        }
        defaults.set(true, forKey: "hasConfiguredLaunchAtLogin")

        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try SMAppService.mainApp.register()
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = friendlyLoginItemError(error)
        }
        updateLaunchAtLoginStatus()
    }

    private func updateLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "需要在系统设置的登录项中允许"
        default:
            launchAtLoginEnabled = false
        }
    }

    private func friendlyLoginItemError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.localizedDescription.isEmpty {
            return "无法更新登录启动设置"
        }
        return nsError.localizedDescription
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleSystemWillSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleSystemDidWake()
                }
            }
        ]
    }

    private func handleSystemWillSleep() {
        metricsTask?.cancel()
        metricsTask = nil
        metricsProvider.pause()
        if panelIsVisible {
            stopPanelWork()
        }
    }

    private func handleSystemDidWake() {
        // Re-establish the CPU differential baseline and fetch fresh AirPods
        // state instead of treating all sleep time as a sample interval.
        startMetricsSampling()
        guard panelIsVisible else { return }
        startAirPodsSampling()
        refreshCodexIfNeeded()
        refreshYouTuIfNeeded()
        refreshTodos()
    }
}
