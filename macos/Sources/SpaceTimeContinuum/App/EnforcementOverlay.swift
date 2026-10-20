import AppKit
import STCCore
import SwiftUI

/// Small always-on-top panel showing the warning / lockout countdown. Never takes focus.
@MainActor
final class EnforcementOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panels: [CGDirectDisplayID: Panel] = [:]

    static let cardWidth: CGFloat = 300
    static let cardHeight: CGFloat = 190
    static let spacing: CGFloat = 8

    /// One fixed-size card per enforcement, side by side, so the panel size never depends on SwiftUI layout.
    static func width(count: Int) -> CGFloat {
        CGFloat(max(1, count)) * cardWidth + CGFloat(max(0, count - 1)) * spacing
    }

    var frames: [CGRect] { panels.values.filter(\.isVisible).map(\.frame) }

    /// Mirrors the cards onto every connected display.
    func show(model: AppModel, count: Int) {
        var live = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            live.insert(id)
            let panel = panels[id] ?? makePanel(model: model, count: count)
            panels[id] = panel
            let area = screen.visibleFrame
            let width = min(Self.width(count: count), area.width - 24)
            panel.setFrame(NSRect(x: area.midX - width / 2, y: area.maxY - Self.cardHeight - 12, width: width, height: Self.cardHeight), display: true)
            panel.orderFrontRegardless()
        }
        for id in panels.keys where !live.contains(id) {
            panels[id]?.orderOut(nil)
            panels[id] = nil
        }
    }

    private func makePanel(model: AppModel, count: Int) -> Panel {
        let panel = Panel(contentRect: CGRect(x: 0, y: 0, width: Self.width(count: count), height: Self.cardHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: EnforcementOverlayView(model: model))
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
    }
}

struct EnforcementOverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: EnforcementOverlay.spacing) {
                ForEach(model.enforcements) { card($0, now: context.date) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func card(_ e: Enforcement, now: Date) -> some View {
        let locked = e.phase == .locked
        return VStack(spacing: 8) {
            Text(locked ? "\(deviceText(e)) blocked" : "\(deviceText(e)) will be blocked")
                .font(.headline)
            Text(clock(e.remaining(at: now)))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
            Text(locked ? "until input is allowed again" : e.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !locked {
                Button("Just 5 more minutes") { model.extendWarning(e.id) }
            } else if model.settings.mistressRules.safeWordEnabled {
                Button("Escape with safe word") { model.endLockout(e.id) }
            }
        }
        .padding(16)
        .frame(width: EnforcementOverlay.cardWidth, height: EnforcementOverlay.cardHeight)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((locked ? Color.red : Color.orange).opacity(0.8), lineWidth: 2))
    }

    private func deviceText(_ e: Enforcement) -> String {
        e.device == .keyboard ? "Keyboard" : "Mouse"
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
