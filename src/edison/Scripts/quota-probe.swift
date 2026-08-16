import Foundation

@main
enum QuotaProbe {
    static func main() async {
        let snapshot = await CodexQuotaProvider().snapshot()
        if let message = snapshot.message {
            print("status=\(message)")
        }
        for window in snapshot.windows {
            let reset = window.resetsAt.map {
                String(Int($0.timeIntervalSince1970))
            } ?? "none"
            print(
                "window=\(window.durationMinutes) "
                    + "remaining=\(Int(window.remainingPercent.rounded())) "
                    + "reset=\(reset)"
            )
        }
    }
}

