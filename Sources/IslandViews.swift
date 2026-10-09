import SwiftUI

/// Форма островка: верх «вливается» в край экрана вогнутыми ушками, низ скруглён.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4, rect.height / 2)
        let br = max(0, min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    private var expanded: Bool { model.state == .expanded }
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)

    var body: some View {
        let size = model.currentSize
        let shape = IslandShape(topRadius: expanded ? 16 : 9,
                                bottomRadius: expanded ? 30 : (model.dropZone ? 26 : (model.peek == nil ? 13 : 22)))
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(expanded ? 0.55 : (model.peek == nil ? 0 : 0.35)),
                        radius: expanded ? 22 : 12, x: 0, y: expanded ? 10 : 4)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Fmt.ru)
        .animation(spring, value: model.state)
        .animation(spring, value: model.peek)
        .animation(spring, value: model.wingWidth)
        .animation(spring, value: model.dropZone)
        .onDrop(of: [.fileURL, .image], isTargeted: $model.dropTargeted) { providers in
            loadDroppedImage(providers, model: model)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hoverCollapsed)
    }

    @ViewBuilder private var content: some View {
        if expanded {
            ExpandedView(model: model, store: store)
                .frame(width: model.expandedSize.width, height: model.expandedSize.height, alignment: .top)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
        } else if model.dropZone {
            DropZoneView(model: model)
                .frame(width: model.dropZoneSize.width, height: model.dropZoneSize.height, alignment: .top)
                .transition(.opacity)
        } else if let peek = model.peek {
            PeekView(model: model, store: store, peek: peek)
                .frame(width: model.peekSize.width, height: model.peekSize.height, alignment: .top)
                .transition(.opacity)
        } else {
            CollapsedView(model: model, store: store)
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
        }
    }
}

// MARK: - Свёрнутый вид

struct CollapsedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let wide = model.wingWidth > 200
        HStack(spacing: 0) {
            LeftWing(store: store, wide: wide)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notchWidth + 10)
            RightWing(store: store, wide: wide)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: model.notchHeight)
        .foregroundStyle(.white)
    }
}

struct LeftWing: View {
    @ObservedObject var store: Store
    let wide: Bool

    var body: some View {
        let now = store.now
        if let cur = store.currentItem(now: now) {
            let total = cur.end.timeIntervalSince(cur.start)
            let progress = total > 0 ? now.timeIntervalSince(cur.start) / total : 0
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(cur.color).frame(width: 6, height: 6)
                    Text(cur.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(Fmt.duration(seconds: cur.end.timeIntervalSince(now)))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                    if wide, let next = store.nextItem(now: now) {
                        Text("· \(Fmt.time(next.start)) \(next.title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                ThinProgress(value: progress, color: cur.color)
                    .frame(height: 2)
            }
        } else if let stone = store.stones(now: now).first {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Palette.red)
                Text(stone.task.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("не сделано")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.red.opacity(0.85))
                    .fixedSize()
            }
        } else if let next = store.nextItem(now: now) {
            let soon = next.start.timeIntervalSince(now) < 3600
            HStack(spacing: 5) {
                Text(soon ? "через \(Fmt.duration(seconds: next.start.timeIntervalSince(now)))" : Fmt.time(next.start))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(soon ? next.color : .white.opacity(0.55))
                    .fixedSize()
                Text(next.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 5) {
                Text(Fmt.shortDate(now))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                if wide {
                    Text("· на сегодня всё").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

struct RightWing: View {
    @ObservedObject var store: Store
    let wide: Bool

    var body: some View {
        let now = store.now
        let progress = store.todayProgress(now: now)
        let overdue = store.overdueCount(now: now)
        HStack(spacing: 6) {
            if wide, let t = store.nextDeadlineTask(now: now), let d = t.deadline {
                let info = Fmt.deadline(d, now: now)
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(info.text)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(info.color)
                    .fixedSize()
            }
            if overdue > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("\(overdue)")
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Palette.red)
                .fixedSize()
            }
            if progress.total > 0 {
                Text("\(progress.done)/\(progress.total)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
                ProgressRing(value: Double(progress.done) / Double(progress.total))
                    .frame(width: 13, height: 13)
            } else {
                let open = store.openCount(project: nil)
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                    Text("\(open)")
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(open > 0 ? 0.75 : 0.4))
                .fixedSize()
            }
        }
    }
}

// MARK: - «Живое» уведомление

struct PeekView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let peek: Peek

    var body: some View {
        VStack(spacing: 0) {
            CollapsedView(model: model, store: store)
            HStack(spacing: 10) {
                Image(systemName: peek.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(peek.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(peek.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .frame(height: 50)
        }
    }
}

// MARK: - Мелкие элементы

struct ThinProgress: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, value))))
            }
        }
    }
}

struct ProgressRing: View {
    let value: Double
    var color: Color = Palette.colors[3]

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: min(1, max(0.001, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
