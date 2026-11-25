import SwiftUI
import AppKit

// MARK: - Look

enum Theme {
    static let bg = Color(red: 0.067, green: 0.071, blue: 0.082)
    static let panel = Color(red: 0.086, green: 0.090, blue: 0.106)
    static let border = Color(red: 0.137, green: 0.145, blue: 0.169)
    static let control = Color(red: 0.173, green: 0.184, blue: 0.216)
    static let text = Color(red: 0.953, green: 0.953, blue: 0.961)
    static let secondary = Color(red: 0.639, green: 0.655, blue: 0.694)
    static let muted = Color(red: 0.557, green: 0.573, blue: 0.612)
    static let accent = Color(red: 1.0, green: 0.71, blue: 0.278)
    static let onAccent = Color(red: 0.102, green: 0.071, blue: 0.024)
    static let green = Color(red: 0.239, green: 0.863, blue: 0.518)
    static let red = Color(red: 1.0, green: 0.353, blue: 0.353)
}

extension View {
    func panel(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}

func dbText(_ v: Double) -> String {
    if abs(v) < 0.05 { return "0 дБ" }
    return String(format: "%+g дБ", (v * 10).rounded() / 10)
}

// MARK: - Controls

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Theme.control : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct Segmented: View {
    let options: [String]
    let selected: Int
    var compact = false
    var fill = false
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    onSelect(i)
                } label: {
                    Text(options[i])
                        .font(.system(size: compact ? 12 : 13, weight: i == selected ? .semibold : .regular))
                        .foregroundStyle(i == selected ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, compact ? 10 : 14)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: compact ? 26 : 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(i == selected ? Theme.control : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border, lineWidth: 1))
    }
}

struct PowerSwitch: View {
    @Binding var isOn: Bool
    var big = true

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.control)
                Circle().fill(Color.white).padding(3)
            }
            .frame(width: big ? 60 : 48, height: big ? 34 : 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .help(isOn ? "Выключить эквалайзер" : "Включить эквалайзер")
        .accessibilityLabel("Эквалайзер включён")
        .accessibilityValue(isOn ? "да" : "нет")
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(selected ? Theme.accent : Theme.panel))
                .overlay(Capsule().stroke(selected ? Theme.accent : Theme.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal slider with a title, a value and an optional hint. Double-click the title to reset.
struct ValueSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    var resetValue: Double? = nil
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let r = resetValue { value = r } }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
                .controlSize(.small)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Vertical band slider: grab the knob and it follows smoothly; click the track to jump; double-click resets to 0.
struct BandSlider: View {
    @Binding var value: Double
    let label: String
    var showValue = true
    var range: ClosedRange<Double> = EQModel.gainRange

    @State private var dragStart: (value: Double, y: CGFloat)? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(showValue ? valueText : " ")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? Theme.muted : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 14)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let knob = min(20, max(9, w - 2))
                let y = yPosition(for: value, height: h, knob: knob)
                let y0 = yPosition(for: 0, height: h, knob: knob)
                ZStack {
                    Capsule()
                        .fill(Theme.control)
                        .frame(width: 4, height: max(h - knob, 0))
                        .position(x: w / 2, y: h / 2)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 4, height: max(abs(y - y0), 0))
                        .position(x: w / 2, y: (y + y0) / 2)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                        .frame(width: knob, height: knob)
                        .position(x: w / 2, y: y)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragStart == nil {
                                let startY = g.startLocation.y
                                if abs(startY - y) <= max(knob, 14) {
                                    dragStart = (value, startY)
                                } else {
                                    let v = valueFor(y: startY, height: h, knob: knob)
                                    value = v
                                    dragStart = (v, startY)
                                }
                            }
                            if let s = dragStart {
                                let perPoint = (range.upperBound - range.lowerBound) / Double(max(h - knob, 1))
                                value = clampStep(s.value + Double(s.y - g.location.y) * perPoint)
                            }
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 13)
        }
        .help(valueText)
    }

    private var valueText: String {
        if value == 0 { return "0" }
        return String(format: "%+g", value)
    }

    private func clampStep(_ raw: Double) -> Double {
        let stepped = (raw * 2).rounded() / 2
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    private func yPosition(for v: Double, height h: CGFloat, knob: CGFloat) -> CGFloat {
        let usable = h - knob
        let norm = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return knob / 2 + (1 - CGFloat(norm)) * usable
    }

    private func valueFor(y: CGFloat, height h: CGFloat, knob: CGFloat) -> Double {
        let usable = max(h - knob, 1)
        let norm = 1 - Double((y - knob / 2) / usable)
        return clampStep(range.lowerBound + norm * (range.upperBound - range.lowerBound))
    }
}

struct LevelMeter: View {
    @ObservedObject var live: LiveData
    let soft: Bool
    var compact = false

    var body: some View {
        let db = live.levelDB
        let over = db > 0.05
        let color = over ? (soft ? Theme.accent : Theme.red) : (db > -3 ? Theme.accent : Theme.green)
        let frac = max(0.02, min(1, (db + 48) / 54))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Уровень на выходе").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(levelText(db: db, over: over))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(color).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 8)
            if !compact && live.clips > 0 {
                Text("Перегрузов за сеанс: \(live.clips)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func levelText(db: Double, over: Bool) -> String {
        if db <= -119 { return "тишина" }
        if over { return soft ? "Сжато мягко" : String(format: "Перегруз +%.1f дБ", db) }
        return String(format: "Пик %.1f дБ", db)
    }
}

/// Makes sure the window is never moved by dragging its content (only by its title bar).
struct NoWindowDrag: NSViewRepresentable {
    final class Guard: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovableByWindowBackground = false
        }
    }
    func makeNSView(context: Context) -> NSView { Guard() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = false
    }
}
