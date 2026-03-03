import AppKit
import Foundation

@MainActor
final class QueryOverlayManager {
    var onOverlayHoverChanged: ((QueryResultRow.ID?) -> Void)?

    private let maxOverlayCount = 250
    private let tooltipMaxCharacters = 240
    private var isEnabled = false
    private var overlays: [QueryResultRow.ID: OverlayEntry] = [:]
    private var externalHighlightedRowID: QueryResultRow.ID?
    private var hoveredOverlayRowID: QueryResultRow.ID?
    private var tooltipWindow: OverlayTooltipWindow?
    private var hoverRefreshTimer: Timer?
    private var isRefreshingHover = false

    func setEnabled(_ enabled: Bool, rows: [QueryResultRow]) {
        TemporaryTelemetry.shared.log(
            category: "overlay",
            message: "set_enabled",
            metadata: [
                "enabled": enabled ? "true" : "false",
                "rows": String(rows.count),
            ])
        self.isEnabled = enabled
        if enabled {
            self.startHoverMonitoringIfNeeded()
            self.update(rows: rows)
        } else {
            self.teardown()
        }
    }

    func update(rows: [QueryResultRow]) {
        guard self.isEnabled else {
            self.teardown()
            return
        }

        let screens = NSScreen.screens
        guard let visibleScreenUnion = Self.unionRect(of: screens.map(\.frame)) else {
            self.teardown()
            return
        }

        let candidates = Array(rows.prefix(self.maxOverlayCount))
        var activeIDs = Set<QueryResultRow.ID>()
        var createdCount = 0
        var updatedCount = 0

        for row in candidates {
            guard let frame = row.frame else { continue }
            let convertedFrame = Self.convertAXFrameToScreen(frame).integral
            guard let overlayFrame = Self.sanitizeOverlayFrame(convertedFrame, visibleScreenUnion: visibleScreenUnion) else {
                continue
            }

            activeIDs.insert(row.id)
            let roleColor = OXQColorTheme.nsColor(forRole: row.role)

            if let overlay = self.overlays[row.id] {
                overlay.row = row
                overlay.view.update(index: row.index, color: roleColor)
                if overlay.window.frame != overlayFrame {
                    TemporaryTelemetry.shared.log(
                        category: "overlay-op",
                        message: "set_frame",
                        metadata: [
                            "row": "\(row.id)",
                            "frame": Self.frameSummary(overlayFrame),
                        ])
                    overlay.window.setFrame(overlayFrame, display: true)
                }
                if !overlay.window.isVisible {
                    TemporaryTelemetry.shared.log(
                        category: "overlay-op",
                        message: "order_front_existing",
                        metadata: ["row": "\(row.id)"])
                    overlay.window.orderFrontRegardless()
                }
                updatedCount += 1
            } else {
                let view = ResultOverlayView(frame: CGRect(origin: .zero, size: overlayFrame.size))
                view.update(index: row.index, color: roleColor)

                let window = ResultOverlayWindow(contentRect: overlayFrame, overlayView: view)
                TemporaryTelemetry.shared.log(
                    category: "overlay-op",
                    message: "order_front_new",
                    metadata: [
                        "row": "\(row.id)",
                        "frame": Self.frameSummary(overlayFrame),
                    ])
                window.orderFrontRegardless()

                self.overlays[row.id] = OverlayEntry(row: row, window: window, view: view)
                createdCount += 1
            }
        }

        let staleIDs = self.overlays.keys.filter { !activeIDs.contains($0) }
        for staleID in staleIDs {
            self.overlays[staleID]?.close()
            self.overlays.removeValue(forKey: staleID)
        }
        TemporaryTelemetry.shared.log(
            category: "overlay",
            message: "update_complete",
            metadata: [
                "rows": String(rows.count),
                "active": String(activeIDs.count),
                "created": String(createdCount),
                "updated": String(updatedCount),
                "removed": String(staleIDs.count),
            ])

        self.refreshHoveredOverlayFromPointer()
        self.applyVisualState()
    }

    func setExternalHighlightedRowID(_ rowID: QueryResultRow.ID?) {
        guard self.externalHighlightedRowID != rowID else { return }
        TemporaryTelemetry.shared.log(
            category: "hover",
            message: "external_highlight_changed",
            metadata: [
                "from": self.externalHighlightedRowID.map { "\($0)" } ?? "nil",
                "to": rowID.map { "\($0)" } ?? "nil",
            ])
        self.externalHighlightedRowID = rowID
        self.applyVisualState()
    }

    private func setHoveredOverlayRowID(_ rowID: QueryResultRow.ID?) {
        guard self.hoveredOverlayRowID != rowID else { return }
        TemporaryTelemetry.shared.log(
            category: "hover",
            message: "overlay_hover_row_changed",
            metadata: [
                "from": self.hoveredOverlayRowID.map { "\($0)" } ?? "nil",
                "to": rowID.map { "\($0)" } ?? "nil",
            ])
        self.hoveredOverlayRowID = rowID
        self.onOverlayHoverChanged?(rowID)
        self.applyVisualState()
    }

    private func refreshHoveredOverlayFromPointer() {
        guard !self.isRefreshingHover else { return }
        self.isRefreshingHover = true
        defer { self.isRefreshingHover = false }

        guard self.isEnabled, !self.overlays.isEmpty else {
            self.setHoveredOverlayRowID(nil)
            return
        }

        let pointer = NSEvent.mouseLocation
        let hoveredID = self.overlays.values
            .filter { $0.window.frame.insetBy(dx: -1, dy: -1).contains(pointer) }
            .min { lhs, rhs in
                let lhsArea = lhs.window.frame.width * lhs.window.frame.height
                let rhsArea = rhs.window.frame.width * rhs.window.frame.height
                if lhsArea == rhsArea {
                    return lhs.row.index < rhs.row.index
                }
                return lhsArea < rhsArea
            }?
            .row
            .id

        self.setHoveredOverlayRowID(hoveredID)
    }

    private func applyVisualState() {
        let prominentID = self.hoveredOverlayRowID ?? self.externalHighlightedRowID
        for entry in self.overlays.values {
            entry.view.setProminent(entry.row.id == prominentID)
        }

        guard let hoveredID = self.hoveredOverlayRowID, let hovered = self.overlays[hoveredID] else {
            self.tooltipWindow?.orderOut(nil)
            return
        }

        if self.tooltipWindow == nil {
            self.tooltipWindow = OverlayTooltipWindow()
        }
        let tooltipText = String(hovered.row.resultsDisplayName.prefix(self.tooltipMaxCharacters))
        self.tooltipWindow?.show(
            text: tooltipText,
            accentColor: OXQColorTheme.nsColor(forRole: hovered.row.role),
            anchorRect: hovered.window.frame)
    }

    private func startHoverMonitoringIfNeeded() {
        guard self.hoverRefreshTimer == nil else { return }
        TemporaryTelemetry.shared.log(category: "overlay", message: "start_hover_monitoring")

        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.refreshHoveredOverlayFromPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.hoverRefreshTimer = timer
    }

    private func stopHoverMonitoring() {
        TemporaryTelemetry.shared.log(category: "overlay", message: "stop_hover_monitoring")
        self.hoverRefreshTimer?.invalidate()
        self.hoverRefreshTimer = nil
    }

    private func teardown() {
        self.stopHoverMonitoring()
        self.externalHighlightedRowID = nil
        self.setHoveredOverlayRowID(nil)
        self.tooltipWindow?.orderOut(nil)

        for entry in self.overlays.values {
            entry.close()
        }
        self.overlays.removeAll()
    }

    private static func convertAXFrameToScreen(_ frame: CGRect) -> CGRect {
        let normalized = frame.standardized
        guard normalized.width.isFinite, normalized.height.isFinite, normalized.minX.isFinite, normalized.minY.isFinite else {
            return .zero
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return normalized
        }

        // AX geometry is top-left based. Use a stable reference screen rather than NSScreen.main,
        // which can change when this app window is moved between monitors.
        let referenceScreen = screens.first(where: { screen in
            abs(screen.frame.minX) < 0.5 && abs(screen.frame.minY) < 0.5
        }) ?? screens[0]

        let referenceBased = CGRect(
            x: normalized.minX,
            y: referenceScreen.frame.maxY - normalized.maxY,
            width: normalized.width,
            height: normalized.height)

        if screens.contains(where: { !$0.frame.intersection(referenceBased).isNull }) {
            return referenceBased
        }

        // Fallback: evaluate per-screen conversions and choose the one that intersects most.
        var candidates = [referenceBased]
        candidates.append(contentsOf: screens.map { screen in
            CGRect(
                x: normalized.minX,
                y: screen.frame.maxY - normalized.maxY,
                width: normalized.width,
                height: normalized.height)
        })

        var bestRect = referenceBased
        var bestScore: CGFloat = 0
        for candidate in candidates {
            for screen in screens {
                let score = Self.intersectionArea(candidate, with: screen.frame)
                if score > bestScore {
                    bestScore = score
                    bestRect = candidate
                }
            }
        }

        if bestScore > 0 {
            return bestRect
        }

        // If AX coordinates were already AppKit-space for this element, keep them as-is.
        if screens.contains(where: { !$0.frame.intersection(normalized).isNull }) {
            return normalized
        }

        return bestRect
    }

    private static func intersectionArea(_ lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    fileprivate static func frameSummary(_ frame: CGRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    private static func sanitizeOverlayFrame(_ frame: CGRect, visibleScreenUnion: CGRect) -> CGRect? {
        let normalized = frame.standardized
        guard normalized.minX.isFinite, normalized.minY.isFinite, normalized.width.isFinite, normalized.height.isFinite else {
            return nil
        }
        guard normalized.width > 1, normalized.height > 1 else { return nil }
        guard abs(normalized.minX) < 1_000_000, abs(normalized.minY) < 1_000_000 else { return nil }
        guard normalized.width < 1_000_000, normalized.height < 1_000_000 else { return nil }

        let clipped = normalized.intersection(visibleScreenUnion).integral
        guard !clipped.isNull, !clipped.isInfinite else { return nil }
        guard clipped.width > 1, clipped.height > 1 else { return nil }
        guard clipped.minX.isFinite, clipped.minY.isFinite else { return nil }
        return clipped
    }

    private static func unionRect(of rects: [CGRect]) -> CGRect? {
        guard !rects.isEmpty else { return nil }
        var union = rects[0]
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }
        guard union.minX.isFinite, union.minY.isFinite, union.width.isFinite, union.height.isFinite else {
            return nil
        }
        guard !union.isNull, !union.isInfinite, union.width > 1, union.height > 1 else { return nil }
        return union
    }
}

@MainActor
private final class OverlayEntry {
    var row: QueryResultRow
    let window: ResultOverlayWindow
    let view: ResultOverlayView

    init(row: QueryResultRow, window: ResultOverlayWindow, view: ResultOverlayView) {
        self.row = row
        self.window = window
        self.view = view
    }

    func close() {
        self.window.orderOut(nil)
        self.window.close()
    }
}

@MainActor
private final class ResultOverlayWindow: NSPanel {
    init(contentRect: CGRect, overlayView: ResultOverlayView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        self.level = .statusBar
        self.hasShadow = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none

        overlayView.autoresizingMask = [.width, .height]
        overlayView.frame = CGRect(origin: .zero, size: contentRect.size)
        self.contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ResultOverlayView: NSView {
    private var roleColor = NSColor.systemBlue
    private var index = 0
    private var isProminent = false

    override var wantsUpdateLayer: Bool { false }

    func update(index: Int, color: NSColor) {
        self.index = index
        self.roleColor = color
        self.needsDisplay = true
    }

    func setProminent(_ prominent: Bool) {
        guard self.isProminent != prominent else { return }
        self.isProminent = prominent
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            self.bounds.minX.isFinite,
            self.bounds.minY.isFinite,
            self.bounds.width.isFinite,
            self.bounds.height.isFinite,
            self.bounds.width > 0.5,
            self.bounds.height > 0.5
        else {
            return
        }

        let prominence: CGFloat = self.isProminent ? 1 : 0
        let fillAlpha = 0.12 + (0.14 * prominence)
        let strokeAlpha = 0.58 + (0.30 * prominence)
        let maxSafeLineWidth = max(0.8, min(self.bounds.width, self.bounds.height) - 0.4)
        let lineWidth = min(1.6 + (1.2 * prominence), maxSafeLineWidth)
        guard lineWidth.isFinite, lineWidth > 0 else { return }

        let frameRect = self.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2).standardized
        guard frameRect.width > 0.4, frameRect.height > 0.4 else { return }

        let maxRadius = max(0, min(frameRect.width, frameRect.height) / 2)
        let cornerRadius = min(7, maxRadius)
        guard cornerRadius.isFinite else { return }

        let rounded = NSBezierPath(roundedRect: frameRect, xRadius: cornerRadius, yRadius: cornerRadius)

        self.roleColor.withAlphaComponent(fillAlpha).setFill()
        rounded.fill()
        self.roleColor.withAlphaComponent(strokeAlpha).setStroke()
        rounded.lineWidth = lineWidth
        rounded.stroke()

        // Tiny overlays cannot reliably render the index badge; skip it.
        if frameRect.width < 48 || frameRect.height < 24 {
            return
        }

        let badgeText = "\(self.index)" as NSString
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = badgeText.size(withAttributes: textAttrs)
        let badgeRect = NSRect(
            x: frameRect.minX + 8,
            y: frameRect.maxY - textSize.height - 10,
            width: textSize.width + 12,
            height: textSize.height + 4)
        guard badgeRect.width > 2, badgeRect.height > 2 else { return }

        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        self.roleColor.withAlphaComponent(0.92).setFill()
        badgePath.fill()

        let textRect = NSRect(
            x: badgeRect.minX + 6,
            y: badgeRect.minY + 2,
            width: textSize.width,
            height: textSize.height)
        badgeText.draw(in: textRect, withAttributes: textAttrs)
    }
}

@MainActor
private final class OverlayTooltipWindow: NSPanel {
    private let tooltipView = OverlayTooltipView(frame: .zero)

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)

        self.level = .statusBar
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.animationBehavior = .none
        self.contentView = self.tooltipView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(text: String, accentColor: NSColor, anchorRect: CGRect) {
        guard
            anchorRect.minX.isFinite,
            anchorRect.minY.isFinite,
            anchorRect.width.isFinite,
            anchorRect.height.isFinite,
            anchorRect.width > 1,
            anchorRect.height > 1
        else {
            self.orderOut(nil)
            return
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        guard !screenFrame.isNull, !screenFrame.isInfinite, screenFrame.width > 1, screenFrame.height > 1 else {
            self.orderOut(nil)
            return
        }
        let maxWidth = max(120, screenFrame.width - 12)
        let size = self.tooltipView.measure(text: text, maxWidth: maxWidth)

        var originX = anchorRect.minX
        var originY = anchorRect.minY - size.height - 6
        if originY < screenFrame.minY + 4 {
            originY = anchorRect.maxY + 6
        }
        originX = min(max(originX, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)

        self.tooltipView.configure(text: text, accentColor: accentColor)
        TemporaryTelemetry.shared.log(
            category: "overlay-op",
            message: "tooltip_show",
            metadata: [
                "anchor": QueryOverlayManager.frameSummary(anchorRect),
                "size": "\(Int(size.width))x\(Int(size.height))",
                "text_length": String(text.count),
            ])
        self.setFrame(CGRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        self.orderFrontRegardless()
    }
}

@MainActor
private final class OverlayTooltipView: NSView {
    private var text = ""
    private var accentColor = NSColor.systemBlue

    private let horizontalPadding: CGFloat = 9
    private let verticalPadding: CGFloat = 7
    private let cornerRadius: CGFloat = 7

    override var isFlipped: Bool { true }

    func configure(text: String, accentColor: NSColor) {
        self.text = text
        self.accentColor = accentColor
        self.needsDisplay = true
    }

    func measure(text: String, maxWidth: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ]
        let measured = (text as NSString).size(withAttributes: attrs)
        let width = min(max(ceil(measured.width) + (self.horizontalPadding * 2), 120), maxWidth)
        let height = max(28, ceil(measured.height) + (self.verticalPadding * 2))
        return CGSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: self.cornerRadius, yRadius: self.cornerRadius)

        NSColor.black.withAlphaComponent(0.78).setFill()
        backgroundPath.fill()
        self.accentColor.withAlphaComponent(0.75).setStroke()
        backgroundPath.lineWidth = 1.1
        backgroundPath.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]

        let textRect = NSRect(
            x: self.horizontalPadding,
            y: self.verticalPadding,
            width: max(0, bounds.width - (self.horizontalPadding * 2)),
            height: max(0, bounds.height - (self.verticalPadding * 2)))

        (self.text as NSString).draw(in: textRect, withAttributes: textAttrs)
    }
}
