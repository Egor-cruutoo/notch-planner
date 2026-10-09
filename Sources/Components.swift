import SwiftUI

struct Chip: View {
    let icon: String
    let text: String
    var color: Color = Color.white.opacity(0.75)

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
    }
}

struct Badge: View {
    let text: String
    var color: Color = Color.white.opacity(0.55)
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

struct CheckButton: View {
    let done: Bool
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(color.opacity(done ? 0 : (hover ? 1 : 0.65)), lineWidth: 1.6)
                if done {
                    Circle().fill(color)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.8))
                } else if hover {
                    Circle().fill(color.opacity(0.2))
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct IconButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 12
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(active || hover ? 1 : 0.6))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.18 : (hover ? 0.1 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = .white
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : tint)
            .background(Capsule().fill(prominent ? tint : tint.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct SegmentTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(selected ? Color.black.opacity(0.55) : color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.black.opacity(0.5) : Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
            .background(Capsule().fill(selected ? color : Color.white.opacity(0.07)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.28))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.45))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }
}
