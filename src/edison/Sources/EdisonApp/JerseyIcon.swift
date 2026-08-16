import AppKit
import SwiftUI

struct JerseyMenuBarIcon: View {
    var body: some View {
        Image(nsImage: JerseyMenuBarIconImage.image)
            .frame(width: 22, height: 18)
            .fixedSize()
    }
}

struct EdisonMarkView: View {
    var useWhite: Bool = false

    var body: some View {
        let resource = useWhite ? "menubar-mark" : "edison-mark-black"
        if let url = EdisonResources.url(forResource: resource, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: JerseyMenuBarIconImage.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

private enum JerseyMenuBarIconImage {
    static let image: NSImage = {
        guard let url = EdisonResources.url(forResource: "menubar-mark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 22, height: 18))
        }
        image.size = NSSize(width: 22, height: 18)
        image.isTemplate = true
        return image
    }()
}

/// The executable is assembled into a standalone `.app` by `build-app.sh`.
/// SwiftPM's generated `Bundle.module` accessor assumes SwiftPM's own bundle
/// layout and traps if that bundle cannot be created during a cold launch.
/// Resolve the resource bundle from the app package instead, matching the
/// layout copied by the packaging script.
private enum EdisonResources {
    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("edison_EdisonApp.bundle", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
    }
}

struct JerseyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        var path = Path()
        // A deliberately spare jersey silhouette: a straight top closure,
        // broad sleeves, and a straight body with no collar curve.
        path.move(to: CGPoint(x: x + w * 0.34, y: y + h * 0.10))
        path.addLine(to: CGPoint(x: x + w * 0.66, y: y + h * 0.10))
        path.addLine(to: CGPoint(x: x + w * 0.78, y: y + h * 0.20))
        path.addLine(to: CGPoint(x: x + w * 0.96, y: y + h * 0.31))
        path.addLine(to: CGPoint(x: x + w * 0.88, y: y + h * 0.53))
        path.addLine(to: CGPoint(x: x + w * 0.73, y: y + h * 0.46))
        path.addLine(to: CGPoint(x: x + w * 0.73, y: y + h * 0.91))
        path.addLine(to: CGPoint(x: x + w * 0.27, y: y + h * 0.91))
        path.addLine(to: CGPoint(x: x + w * 0.27, y: y + h * 0.46))
        path.addLine(to: CGPoint(x: x + w * 0.12, y: y + h * 0.53))
        path.addLine(to: CGPoint(x: x + w * 0.04, y: y + h * 0.31))
        path.addLine(to: CGPoint(x: x + w * 0.22, y: y + h * 0.20))
        path.closeSubpath()
        return path
    }
}
