import EventKit
import Foundation

actor TodoProvider {
    private let store = EKEventStore()

    func snapshot() async -> TodoSnapshot {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined:
            return TodoSnapshot(access: .notDetermined, message: "连接提醒事项后显示待办")
        case .restricted:
            return TodoSnapshot(access: .restricted, message: "系统限制了提醒事项访问")
        case .denied, .writeOnly:
            return TodoSnapshot(access: .denied, message: "请在系统设置中允许提醒事项访问")
        case .fullAccess:
            return await loadSnapshot()
        @unknown default:
            return TodoSnapshot(access: .unavailable, message: "提醒事项暂不可用")
        }
    }

    func requestAccess() async -> TodoSnapshot {
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else {
                return TodoSnapshot(access: .denied, message: "未允许访问提醒事项")
            }
            return await loadSnapshot()
        } catch {
            return TodoSnapshot(access: .unavailable, message: friendlyMessage(for: error))
        }
    }

    func add(title: String) async -> TodoSnapshot {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return await snapshot()
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return await loadSnapshot() }

        guard let calendar = store.defaultCalendarForNewReminders() else {
            return TodoSnapshot(access: .unavailable, message: "没有可用的默认提醒事项列表")
        }

        do {
            let reminder = EKReminder(eventStore: store)
            reminder.title = trimmedTitle
            reminder.calendar = calendar
            try store.save(reminder, commit: true)
            return await loadSnapshot()
        } catch {
            return TodoSnapshot(access: .unavailable, message: friendlyMessage(for: error))
        }
    }

    func complete(id: String) async -> TodoSnapshot {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return await snapshot()
        }

        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return await loadSnapshot(message: "这条待办已不存在")
        }

        do {
            reminder.isCompleted = true
            reminder.completionDate = Date()
            try store.save(reminder, commit: true)
            return await loadSnapshot()
        } catch {
            return TodoSnapshot(access: .unavailable, message: friendlyMessage(for: error))
        }
    }

    private func loadSnapshot(message: String? = nil) async -> TodoSnapshot {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        let items = reminders.map(todoItem).sorted(by: comesBefore)
        return TodoSnapshot(
            items: Array(items.prefix(3)),
            totalIncomplete: items.count,
            access: .authorized,
            updatedAt: Date(),
            message: message
        )
    }

    private func todoItem(from reminder: EKReminder) -> TodoItem {
        let components = reminder.dueDateComponents
        var normalizedComponents = components
        if normalizedComponents?.calendar == nil {
            normalizedComponents?.calendar = .current
        }
        let includesTime = components?.hour != nil || components?.minute != nil
        return TodoItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未命名待办",
            dueDate: normalizedComponents?.date,
            dueIncludesTime: includesTime
        )
    }

    private func comesBefore(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        let now = Date()
        let lhsRank = sortRank(for: lhs, at: now)
        let rhsRank = sortRank(for: rhs, at: now)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func sortRank(for item: TodoItem, at date: Date) -> Int {
        if item.isOverdue(at: date) { return 0 }
        if item.dueDate != nil { return 1 }
        return 2
    }

    private func friendlyMessage(for error: Error) -> String {
        let description = (error as NSError).localizedDescription
        return description.isEmpty ? "提醒事项操作失败" : description
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
