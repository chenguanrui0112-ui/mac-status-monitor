import Foundation

@main
enum AirPodsProbe {
    static func main() async {
        let snapshot = await AirPodsProvider().snapshot()
        let leftLevel = snapshot.left.level.map { String($0) } ?? "—"
        let rightLevel = snapshot.right.level.map { String($0) } ?? "—"
        let caseLevel = snapshot.caseBattery.level.map { String($0) } ?? "—"
        let leftCharging = snapshot.left.isCharging.map { String($0) } ?? "—"
        let rightCharging = snapshot.right.isCharging.map { String($0) } ?? "—"
        let caseCharging = snapshot.caseBattery.isCharging.map { String($0) } ?? "—"
        print("name=\(snapshot.name)")
        print("connected=\(snapshot.isConnected)")
        print("left=\(leftLevel) charging=\(leftCharging)")
        print("right=\(rightLevel) charging=\(rightCharging)")
        print("case=\(caseLevel) charging=\(caseCharging)")
        if let message = snapshot.message { print("message=\(message)") }
    }
}
