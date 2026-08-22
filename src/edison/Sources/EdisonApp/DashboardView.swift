import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 14) {
            header

            if model.showsSettings {
                SettingsView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                dashboard
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .padding(18)
        .frame(width: 700)
        .background {
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.12),
                    Color.pink.opacity(0.08),
                    Color.cyan.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .onAppear { model.panelDidAppear() }
        .onDisappear { model.panelDidDisappear() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                EdisonMarkView(useWhite: colorScheme == .dark)
            }
            .frame(width: 30, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("edison")
                    .font(.title3.weight(.semibold))
                Text("已运行 \(uptimeText(model.uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    model.showsSettings.toggle()
                }
            } label: {
                Image(systemName: model.showsSettings ? "chevron.backward" : "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(model.showsSettings ? "返回状态" : "设置")
        }
        .padding(.horizontal, 4)
    }

    private var dashboard: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 14) {
                    CPUCard(metrics: model.cpu, history: model.cpuHistory)
                    GPUCard(metrics: model.gpu, history: model.gpuHistory)
                    TemperatureCard(metrics: model.temperature)
                    AirPodsCard(snapshot: model.airPods)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    CodexCard(
                        snapshot: model.codexQuota,
                        isRefreshing: model.isRefreshingCodex,
                        refresh: model.refreshCodex
                    )
                    TodoCard(
                        snapshot: model.todos,
                        isWorking: model.isWorkingOnTodos,
                        requestAccess: model.requestTodoAccess,
                        add: model.addTodo,
                        complete: model.completeTodo
                    )
                }
            }
        }
    }
}

private struct GlassCard<Content: View>: View {
    let height: CGFloat
    let content: Content

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct CardHeader: View {
    let icon: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.medium))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct CPUCard: View {
    let metrics: CPUMetrics
    let history: [MetricPoint]

    var body: some View {
        GlassCard(height: 246) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "cpu", title: "CPU", trailing: "\(percent(metrics.total))%")
                Text("Apple M5 · 10 核")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MetricChart(points: history, style: .cpu)
                VStack(spacing: 5) {
                    LegendValue(color: .metricBlue, title: "用户", value: metrics.user)
                    LegendValue(color: .metricRed, title: "系统", value: metrics.system)
                    LegendValue(color: .primary.opacity(0.10), title: "闲置", value: metrics.idle)
                }
            }
        }
    }
}

private struct GPUCard: View {
    let metrics: GPUMetrics
    let history: [MetricPoint]

    var body: some View {
        GlassCard(height: 246) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    icon: "square.stack.3d.up",
                    title: "GPU",
                    trailing: metrics.isAvailable ? "\(percent(metrics.device))%" : "暂不可用"
                )
                Text("Apple M5 · 8 核")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MetricChart(points: history, style: .gpu)
                VStack(spacing: 5) {
                    LegendValue(color: .metricBlue, title: "利用率", value: metrics.device)
                    LegendValue(color: .metricRed, title: "渲染", value: metrics.renderer)
                    LegendValue(color: .metricTeal, title: "Tiler", value: metrics.tiler)
                }
                .opacity(metrics.isAvailable ? 1 : 0.45)
            }
        }
    }
}

private struct TemperatureCard: View {
    let metrics: TemperatureMetrics

    var body: some View {
        GlassCard(height: 172) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "thermometer.medium", title: "温度")
                Spacer(minLength: 0)
                if let celsius = metrics.celsius {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(celsius.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("°C")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("芯片最高温度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("热状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(metrics.status.rawValue)
                            .font(.system(size: 31, weight: .semibold, design: .rounded))
                    }
                }
                Text("系统热状态：\(metrics.status.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AirPodsCard: View {
    let snapshot: AirPodsSnapshot

    var body: some View {
        GlassCard(height: 172) {
            VStack(alignment: .leading, spacing: 11) {
                CardHeader(
                    icon: "airpodspro",
                    title: "AirPods",
                    trailing: snapshot.isConnected ? "已连接" : "未连接"
                )
                Text(snapshot.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if snapshot.isConnected {
                    HStack(spacing: 12) {
                        AirPodsPartView(kind: .left, part: snapshot.left)
                        AirPodsPartView(kind: .right, part: snapshot.right)
                        AirPodsPartView(kind: .case, part: snapshot.caseBattery)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "airpodspro")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("未连接")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AirPodsPartView: View {
    enum Kind: Equatable {
        case left, right, `case`
    }

    let kind: Kind
    let part: AirPodsPart

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                AirPodsOfficialIcon(kind: kind)
                    .frame(width: 24, height: 24)
                if part.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 2)
                Text(part.level.map { "\($0)%" } ?? "—")
                    .font(.caption.monospacedDigit())
            }
            AirPodsBatteryBar(level: part.level)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AirPodsBatteryBar: View {
    let level: Int?

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(min(max(level ?? 0, 0), 100)) / 100
            Capsule()
                .fill(.primary.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.green)
                        .frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: 10)
        .opacity(level == nil ? 0.28 : 1)
    }
}

private struct AirPodsOfficialIcon: View {
    let kind: AirPodsPartView.Kind

    var body: some View {
        switch kind {
        case .left, .right:
            AirPodsAssetIcon(resourceName: kind == .left ? "airpodspro-left" : "airpodspro-right")
        case .case:
            AirPodsAssetIcon(resourceName: "airpodspro-case")
        }
    }
}

/// AirBattery's separate AirPods Pro SVG assets preserve the device silhouettes
/// for the left bud, right bud, and charging case at every display size.
private struct AirPodsAssetIcon: View {
    let resourceName: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let url = bundledResourceURL, let image = templateImage(at: url) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(iconColor)
        } else {
            Image(systemName: "questionmark.app")
                .resizable()
                .scaledToFit()
            .foregroundStyle(.secondary)
        }
    }

    private var iconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.58)
    }

    private var bundledResourceURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("edison_EdisonApp.bundle", isDirectory: true)
            .appendingPathComponent("\(resourceName).svg")
    }

    private func templateImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
}

private struct CodexCard: View {
    let snapshot: CodexQuotaSnapshot
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        GlassCard(height: 166) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("Codex")
                        .font(.title3.weight(.medium))
                    Spacer()
                    Button(action: refresh) {
                        Group {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("刷新 Codex 剩余用量")
                }

                if snapshot.windows.isEmpty {
                    HStack {
                        Text(snapshot.message ?? "暂不可用")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
                        alignment: .leading,
                        spacing: 9
                    ) {
                        ForEach(snapshot.windows) { window in
                            QuotaWindowView(window: window)
                        }
                    }
                }

                if let updatedAt = snapshot.updatedAt {
                    Text(codexStatusText(updatedAt: updatedAt, message: snapshot.message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct QuotaWindowView: View {
    let window: CodexQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(percent(window.remainingPercent))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(.accentColor)
            if let resetsAt = window.resetsAt {
                Text("重置：\(resetText(resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TodoCard: View {
    let snapshot: TodoSnapshot
    let isWorking: Bool
    let requestAccess: () -> Void
    let add: (String) -> Void
    let complete: (String) -> Void

    @State private var isAdding = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        GlassCard(height: 166) {
            VStack(alignment: .leading, spacing: 10) {
                header

                switch snapshot.access {
                case .notDetermined:
                    permissionContent(
                        message: snapshot.message ?? "连接提醒事项后显示待办",
                        showsButton: true
                    )
                case .denied:
                    permissionContent(
                        message: snapshot.message ?? "请在系统设置中允许提醒事项访问",
                        showsButton: false
                    )
                case .restricted:
                    permissionContent(
                        message: snapshot.message ?? "系统限制了提醒事项访问",
                        showsButton: false
                    )
                case .unavailable:
                    permissionContent(
                        message: snapshot.message ?? "提醒事项暂不可用",
                        showsButton: false
                    )
                case .authorized:
                    authorizedContent
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("待办事项")
                .font(.title3.weight(.medium))
            Spacer()
            if snapshot.access == .authorized {
                Text("\(snapshot.totalIncomplete) 项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isAdding.toggle()
                    }
                    if isAdding {
                        isTitleFocused = true
                    } else {
                        draftTitle = ""
                    }
                } label: {
                    Image(systemName: isAdding ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(isAdding ? "取消新建" : "新建待办")
            } else if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func permissionContent(message: String, showsButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if showsButton {
                Button(action: requestAccess) {
                    Label("连接提醒事项", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if snapshot.items.isEmpty && !isAdding {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("暂时没有待办事项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            VStack(spacing: 8) {
                if isAdding {
                    HStack(spacing: 7) {
                        TextField("输入待办事项", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                            .focused($isTitleFocused)
                            .onSubmit(saveDraft)
                        Button(action: saveDraft) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(trimmedDraft.isEmpty || isWorking)
                        .help("添加")
                    }
                }

                ForEach(Array(snapshot.items.prefix(isAdding ? 2 : 3))) { item in
                    TodoRow(item: item, isWorking: isWorking) {
                        complete(item.id)
                    }
                }
            }
        }
    }

    private var trimmedDraft: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveDraft() {
        guard !trimmedDraft.isEmpty, !isWorking else { return }
        add(trimmedDraft)
        draftTitle = ""
        isAdding = false
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let isWorking: Bool
    let complete: () -> Void

    var body: some View {
        Button(action: complete) {
            HStack(spacing: 9) {
                Image(systemName: "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let label = todoDueText(item) {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(todoDueColor(item))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .frame(minHeight: 20)
        .help("完成“\(item.title)”")
    }
}

private struct LegendValue: View {
    let color: Color
    let title: String
    let value: Double

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 11, height: 11)
            Text(title)
                .font(.caption)
            Spacer()
            Text("\(percent(value))%")
                .font(.caption.monospacedDigit())
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                GlassCard(height: 124) {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(icon: "gearshape", title: "设置")
                        Toggle(
                            "登录后自动启动",
                            isOn: Binding(
                                get: { model.launchAtLoginEnabled },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        if let message = model.launchAtLoginMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GlassCard(height: 112) {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(icon: "sparkles", title: "Codex")
                        Button {
                            model.refreshCodex()
                        } label: {
                            Label("手动刷新剩余用量", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshingCodex)
                    }
                }

                GlassCard(height: 164) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(icon: "info.circle", title: "关于 edison")
                        Text("专为这台 Mac 打造的低功耗状态面板。数据默认只在本机处理。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("版本 0.1.0")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("退出 edison", role: .destructive) {
                            model.terminateApplication()
                        }
                    }
                }
            }
        }
        .frame(height: 428, alignment: .top)
    }
}

private extension Color {
    static let metricBlue = Color(red: 0.25, green: 0.64, blue: 0.92)
    static let metricRed = Color(red: 0.94, green: 0.29, blue: 0.36)
    static let metricTeal = Color(red: 0.20, green: 0.76, blue: 0.73)
}

private func percent(_ value: Double) -> Int {
    Int(min(100, max(0, value)).rounded())
}

private func uptimeText(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes / 60) % 24
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days) 天 \(hours) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
    return "\(minutes) 分钟"
}

private func resetText(_ date: Date) -> String {
    let remaining = max(0, date.timeIntervalSinceNow)
    let totalMinutes = Int(ceil(remaining / 60))
    let relative: String
    if totalMinutes >= 24 * 60 {
        relative = "约\(totalMinutes / (24 * 60))天后"
    } else if totalMinutes >= 60 {
        relative = "约\(totalMinutes / 60)小时后"
    } else {
        relative = "约\(max(1, totalMinutes))分钟后"
    }
    let absolute = date.formatted(
        Date.FormatStyle()
            .month(.abbreviated)
            .day()
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN"))
    )
    return "\(relative)重置 · \(absolute)"
}

private func todoDueText(_ item: TodoItem) -> String? {
    guard let dueDate = item.dueDate else { return nil }
    if item.isOverdue() { return "逾期" }

    let calendar = Calendar.current
    if calendar.isDateInToday(dueDate) {
        if item.dueIncludesTime {
            return dueDate.formatted(
                Date.FormatStyle()
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(Locale(identifier: "zh_CN"))
            )
        }
        return "今天"
    }
    if calendar.isDateInTomorrow(dueDate) { return "明天" }
    return dueDate.formatted(
        Date.FormatStyle()
            .month(.abbreviated)
            .day()
            .locale(Locale(identifier: "zh_CN"))
    )
}

private func todoDueColor(_ item: TodoItem) -> Color {
    if item.isOverdue() { return .red }
    if let dueDate = item.dueDate, Calendar.current.isDateInToday(dueDate) {
        return .orange
    }
    return .secondary
}

private func codexStatusText(updatedAt: Date, message: String?) -> String {
    let time = updatedAt.formatted(
        Date.FormatStyle()
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN"))
    )
    if let message, !message.isEmpty {
        return "更新于 \(time) · \(message)"
    }
    return "更新于 \(time)"
}
