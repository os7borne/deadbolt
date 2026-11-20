import AppKit
import SwiftUI

/// A small floating note, top centre of the screen, shown while Deadbolt waits for Touch ID on behalf of the browser.
/// The Touch ID sheet says what it's for, but the person is looking at Chrome; this says "that's Deadbolt, for this site".
/// Never takes focus, ignores the mouse, and is gone a moment after the answer.
@MainActor
final class PasskeyHUD {
    static let shared = PasskeyHUD()

    @MainActor @Observable
    final class Model {
        var title = ""
        var detail = ""
        var busy = true
        var success = true
    }

    private let model = Model()
    private var panel: NSPanel?
    private var token = 0

    /// Waiting for the person: pulses until `finish` or `hide`.
    func show(_ title: String, detail: String) {
        token += 1
        model.title = title; model.detail = detail; model.busy = true; model.success = true
        present()
    }

    /// The answer: a result for ~2 seconds, then it goes away.
    func finish(success: Bool, _ title: String, detail: String) {
        token += 1
        let mine = token
        model.title = title; model.detail = detail; model.busy = false; model.success = success
        present()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.token == mine { self?.hide() }
        }
    }

    func hide() {
        token += 1
        panel?.orderOut(nil)
    }

    private func present() {
        let p = panel ?? makePanel()
        panel = p
        let size = CGSize(width: 340, height: 68)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 14, width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()   // above Chrome without activating Deadbolt
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }
}

private struct HUDView: View {
    let model: PasskeyHUD.Model
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.busy {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DB.brass, lineWidth: 2)
                        .frame(width: 40, height: 40)
                        .scaleEffect(pulse ? 1.3 : 0.9).opacity(pulse ? 0 : 0.8)
                }
                if model.busy {
                    DeadboltMark(size: 38)
                } else {
                    Image(systemName: model.success ? "checkmark" : "xmark").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(model.success ? DB.good : DB.danger)
                        .frame(width: 38, height: 38).background(DB.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.db(14, .semibold)).foregroundStyle(DB.text).lineLimit(1)
                Text(model.detail).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(width: 340, height: 68)
        .background(DB.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DB.lineStrong))
        .onAppear {
            guard !reduceMotion else { pulse = true; return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}
