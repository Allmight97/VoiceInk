import SwiftUI

enum AppTheme {
    enum Status {
        static let error = Color.red
        static let warning = Color.orange
        static let info = Color.blue
        static let success = Color.green
    }

    enum Accent {
        static let fill = Color.accentColor.opacity(0.18)
        static let border = Color.accentColor.opacity(0.55)
        static let foreground = Color.accentColor
    }

    enum Surface {
        static let control = Color.secondary.opacity(0.12)
        static let window = Color.secondary.opacity(0.10)
    }

    enum Border {
        static let subtle = Color.secondary.opacity(0.22)
    }

    enum Radius {
        static let card: CGFloat = 8
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + spacing + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct InfoTip: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(text)
    }
}

struct AddIconButton: View {
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .help(helpText)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
