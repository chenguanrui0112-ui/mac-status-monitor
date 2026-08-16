import SwiftUI

enum MetricChartStyle {
    case cpu
    case gpu
}

struct MetricChart: View {
    let points: [MetricPoint]
    let style: MetricChartStyle

    private let cpuColor = Color(red: 0.27, green: 0.54, blue: 0.91)
    private let gpuColor = Color(red: 0.73, green: 0.36, blue: 0.80)

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.primary.opacity(0.045)))
            guard !points.isEmpty else { return }

            switch style {
            case .cpu:
                drawCPU(in: &context, size: size)
            case .gpu:
                drawGPU(in: &context, size: size)
            }
        }
        .frame(height: 105)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private func drawCPU(in context: inout GraphicsContext, size: CGSize) {
        drawSoftTrend(
            values: points.map { $0.primary + $0.secondary },
            color: cpuColor,
            in: &context,
            size: size
        )
    }

    private func drawGPU(in context: inout GraphicsContext, size: CGSize) {
        drawSoftTrend(
            values: points.map(\.primary),
            color: gpuColor,
            in: &context,
            size: size
        )
    }

    private func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width }
        return width * CGFloat(index) / CGFloat(count - 1)
    }

    private func yPosition(value: Double, height: CGFloat) -> CGFloat {
        height * (1 - CGFloat(min(100, max(0, value))) / 100)
    }

    private func drawSoftTrend(
        values: [Double],
        color: Color,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !values.isEmpty else { return }
        let line = smoothLinePath(values: values, size: size)
        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(color.opacity(0.18)))
        context.stroke(
            line,
            with: .color(color.opacity(0.98)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )
    }

    private func smoothLinePath(values: [Double], size: CGSize) -> Path {
        let positions = values.enumerated().map { index, value in
            CGPoint(
                x: xPosition(index: index, count: values.count, width: size.width),
                y: yPosition(value: value, height: size.height)
            )
        }
        var path = Path()
        guard let first = positions.first else { return path }
        path.move(to: first)
        guard positions.count > 1 else { return path }

        for index in 1..<positions.count {
            let previous = positions[index - 1]
            let current = positions[index]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = positions.last {
            path.addLine(to: last)
        }
        return path
    }
}
