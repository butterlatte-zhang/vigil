import SwiftUI
import VigilCore

// Right-top notification card stack, aggregated app-globally: notices from EVERY
// session appear here. Sessions are all claude, and codex has no per-approval channel —
// "global" currently means exactly "all claude sessions", nothing more. Ordering: newest
// first, same-session cards kept adjacent (grouped by session). Each card carries its
// project·session identity line; CLICK = select that session + focus the node's terminal.
// Cards are perm events (idle cards produce none) plus the queued-inject card — they
// survive clicks and die only when their cause actually resolves (perm: PostToolUse
// pairing / scrape / prompt / node death; queued-inject: the hold releases). Positioning
// is the integrator's job (OverlayColumn); this view is the 322pt-wide content only.
//
// Timestamps: AgentNotice.arrivedAt is the real arrival clock — shown as honest relative
// time, never fabricated, and it survives view remounts. Permission cards render only
// after their ~2.5s grace (displayAfter) so an instant approval never flashes a card.

struct NotifStack: View {
    let app: AppModel
    @Environment(\.vg) private var vg

    var body: some View {
        let entries = gather()
        if entries.isEmpty {
            EmptyView()   // notice-zero is the calm product default: top-right stays clean
        } else {
            // Periodic tick keeps the relative timestamps live; while a permission card
            // sits inside its grace window we tick fast so it appears right when the
            // grace ends. Scrolling belongs to the enclosing OverlayColumn.
            let inGrace = entries.contains { $0.notice.displayAfter > Date() }
            TimelineView(.periodic(from: .now, by: inGrace ? 0.5 : 30)) { ctx in
                VStack(spacing: 10) {
                    ForEach(entries.filter { $0.notice.displayAfter <= ctx.date },
                            id: \.notice.id) { e in
                        NotifCard(
                            agent: e.session.agentKey,
                            context: contextLabel(e.session),
                            title: nodeName(e),
                            subtitle: e.notice.text,
                            time: relTime(e.notice.arrivedAt, now: ctx.date),
                            selected: app.activeSessionID == e.session.id
                                      && e.session.selectedID == e.notice.nodeID
                        ) {
                            app.openNotice(sessionID: e.session.id, node: e.notice.nodeID)
                        }
                        .accessibilityIdentifier(
                            "notif.card.\(e.session.id).\(e.notice.nodeID.raw)")
                    }
                }
                .frame(width: VGLayout.overlayWidth)
            }
        }
    }

    // MARK: aggregation

    private struct Entry {
        let session: SessionVM
        let notice: AgentNotice
    }

    /// All sessions' notices, newest first with same-session cards adjacent: sessions
    /// are ordered by their newest notice, notices within a session by arrival (desc).
    /// Ties break on seq / allSessions order so the stack order is deterministic.
    private func gather() -> [Entry] {
        var groups: [(order: Int, session: SessionVM, notices: [AgentNotice])] = []
        for (i, vm) in app.allSessions.enumerated() where !vm.store.notices.isEmpty {
            let ns = vm.store.notices.sorted {
                $0.arrivedAt == $1.arrivedAt ? $0.seq > $1.seq : $0.arrivedAt > $1.arrivedAt
            }
            groups.append((i, vm, ns))
        }
        groups.sort {
            let a = $0.notices[0].arrivedAt, b = $1.notices[0].arrivedAt
            return a == b ? $0.order < $1.order : a > b
        }
        return groups.flatMap { g in g.notices.map { Entry(session: g.session, notice: $0) } }
    }

    // MARK: helpers

    /// Card identity line: project · session. Scratch sessions have no project — the
    /// sidebar files them under the Chats bucket, mirror that here.
    private func contextLabel(_ vm: SessionVM) -> String {
        if let p = app.projects.first(where: { $0.sessions.contains(where: { $0.id == vm.id }) }) {
            return "\(p.name) · \(vm.name)"
        }
        return "Chats · \(vm.name)"
    }

    private func nodeName(_ e: Entry) -> String {
        guard let n = e.session.store.tree[e.notice.nodeID], !n.title.isEmpty else {
            return e.notice.nodeID.raw
        }
        return n.title
    }

    /// Real relative time since arrival (no fake timestamps).
    private func relTime(_ d: Date, now: Date) -> String {
        let r = VGDuration.relative(d, now: now)
        return r == "just now" ? r : r + " ago"
    }
}

// MARK: - One card

private struct NotifCard: View {
    let agent: String          // agents.json entry key — badge: claude / codex
    let context: String        // project · session identity line
    let title: String
    let subtitle: String
    let time: String
    let selected: Bool
    let onTap: () -> Void

    @Environment(\.vg) private var vg
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(context)
                    .font(VGFont.ui(10.5))
                    .foregroundStyle(vg.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(title)
                    .font(VGFont.ui(13, weight: .bold))     // 680 → bold
                    .foregroundStyle(vg.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(VGFont.ui(12))
                    .foregroundStyle(vg.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right column: timestamp top, chevron bottom (space-between over icon height).
            VStack(alignment: .trailing) {
                Text(time)
                    .font(VGFont.ui(11))
                    .foregroundStyle(vg.text3)
                Spacer(minLength: 0)
                Text("›")
                    .font(VGFont.ui(15))
                    .foregroundStyle(hover ? vg.accent : vg.text3)
                    .offset(x: hover ? 2 : 0)
                    .animation(VGMotion.gated(.easeOut(duration: 0.14)), value: hover)
            }
            .frame(height: 38)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .background {
            // Frosted-glass base + tint: in dark mode the material's sampled gray would
            // otherwise bloat the card into a bluish light-gray slab. The α.62/.50 tint
            // keeps the card face a dark neutral in the canvas family, leaving the glass
            // only a faint translucency. Selected state does not use an accent-wash
            // background (under the amber accent that reads as a dirty-orange rinse) —
            // see the stroke ring in the overlay instead.
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape.fill(.regularMaterial)
            shape.fill((vg.theme == .dark ? Color(hex: 0x1A1B20) : .white)
                .opacity(vg.theme == .dark ? 0.62 : 0.50))
            if selected { shape.fill(vg.accent.opacity(0.06)) }
        }
        .overlay {
            // Border: normal = 1px top-bright/bottom-dark gradient highlight (dark) / very faint black line (light);
            // selected = accent stroke ring (passive focus echo).
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if selected {
                shape.strokeBorder(vg.accent.opacity(0.65), lineWidth: 1)
            } else if vg.theme == .dark {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            } else {
                shape.strokeBorder(Color.k(0.08), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(vg.theme == .dark ? 0.38 : 0.16),
                radius: hover ? 18 : 13, y: hover ? 8 : 5)
        .animation(VGMotion.gated(.easeOut(duration: 0.16)), value: hover)
        .animation(VGMotion.gated(.easeOut(duration: 0.14)), value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
    }

    // 38×38 radius-10 agent badge: the card tells you WHICH agent is waiting —
    // claude = #D97757 + white starburst; codex = white + gradient ring (drawn even
    // though only claude sessions exist today, ready for when codex workers land).
    @ViewBuilder
    private var icon: some View {
        if agent == "codex" {
            CodexBadge()
        } else {
            ClaudeBadge()
        }
    }
}

/// Claude glyph: the 11-ray starburst traced from the design SVG (24×24 space), drawn
/// app-icon style: subtle gradient base + top inner highlight + thickened round-cap
/// rays, tuned to stay crisp on the frosted glass background.
private struct ClaudeBadge: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Canvas { ctx, size in
            let s = size.width / 24
            let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (13.3, 12.0, 20.0, 12.0), (13.1, 11.3, 17.9, 8.2), (12.5, 10.8, 15.3, 4.5),
                (11.9, 10.7, 11.4, 5.4), (11.2, 11.0, 7.0, 6.0), (10.8, 11.6, 5.9, 10.0),
                (10.7, 12.3, 4.4, 14.0), (11.1, 13.0, 7.6, 16.9), (11.8, 13.3, 10.6, 20.0),
                (12.5, 13.2, 14.9, 18.2), (13.1, 12.7, 18.5, 16.1),
            ]
            for r in rays {
                var p = Path()
                p.move(to: CGPoint(x: r.0 * s, y: r.1 * s))
                p.addLine(to: CGPoint(x: r.2 * s, y: r.3 * s))
                ctx.stroke(p, with: .color(.white),
                           style: StrokeStyle(lineWidth: 2.3 * s, lineCap: .round))
            }
        }
        .frame(width: 25, height: 25)
        .frame(width: 38, height: 38)
        .background(
            LinearGradient(colors: [Color(hex: 0xE0835F), Color(hex: 0xCF6C48)],
                           startPoint: .top, endPoint: .bottom),
            in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
    }
}

/// Codex glyph: gradient circle flower + white ›_ marks (approximation of the design's
/// userSpaceOnUse gradient; unreachable until the codex worker lands).
private struct CodexBadge: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            let petals: [(CGFloat, CGFloat, CGFloat)] = [
                (12, 12, 6), (17.2, 12, 3.5), (15.68, 8.32, 3.5), (12, 6.8, 3.5),
                (8.32, 8.32, 3.5), (6.8, 12, 3.5), (8.32, 15.68, 3.5), (12, 17.2, 3.5),
                (15.68, 15.68, 3.5), (12, 12, 3.5),
            ]
            var flower = Path()
            for p in petals {
                flower.addEllipse(in: CGRect(x: (p.0 - p.2) * s, y: (p.1 - p.2) * s,
                                             width: p.2 * 2 * s, height: p.2 * 2 * s))
            }
            ctx.fill(flower, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x9BA0EC), Color(hex: 0x4B50CE)]),
                startPoint: CGPoint(x: 12 * s, y: 3 * s), endPoint: CGPoint(x: 12 * s, y: 21 * s)))
            var chev = Path()
            chev.move(to: CGPoint(x: 8.3 * s, y: 9.5 * s))
            chev.addLine(to: CGPoint(x: 11.8 * s, y: 12 * s))
            chev.addLine(to: CGPoint(x: 8.3 * s, y: 14.5 * s))
            ctx.stroke(chev, with: .color(.white),
                       style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
            var bar = Path()
            bar.move(to: CGPoint(x: 13.7 * s, y: 14.5 * s))
            bar.addLine(to: CGPoint(x: 17.2 * s, y: 14.5 * s))
            ctx.stroke(bar, with: .color(.white),
                       style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
        }
        .frame(width: 28, height: 28)
        .frame(width: 38, height: 38)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.k(0.09), lineWidth: 1))
    }
}
