import AppKit
import Foundation

@MainActor
final class QueryOverlayManager {
    var onOverlayHoverChanged: ((QueryResultRow.ID?) -> Void)?

    private let maxOverlayCount = 250
    private var isEnabled = false
    private var overlays: [QueryResultRow.ID: OverlayItem] = [:]
    private var externalHighlightedRowID: QueryResultRow.ID?
    private var overlayHoveredRowID: QueryResultRow.ID?
    private var tooltipWindow: OverlayTooltipWindow?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    func setEnabled(_ enabled: Bool, rows: [QueryResultRow]) {
        self.isEnabled = enabled
        if enabled {
            self.startMouseMonitoringIfNeeded()
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

        let rowsWithFrames = rows.filter { $0.frame != nil }
        let limitedRows = Array(rowsWithFrames.prefix(self.maxOverlayCount))
        let activeIDs = Set(limitedRows.map(\.id))

        let staleIDs = self.overlays.keys.filter { !activeIDs.contains($0) }
        for staleID in staleIDs {
            self.overlays[staleID]?.close()
            self.overlays.removeValue(forKey: staleID)
        }

        for row in limitedRows {
            guard let frame = row.frame else { continue }

            let screenRect = Self.convertAXFrameToScreenCoordinates(frame)
            let color = OXQColorTheme.nsColor(forRole: row.role)

            if let item = self.overlays[row.id] {
                item.row = row
                item.view.update(index: row.index, color: color)
                item.window.setFrame(screenRect, display: true)
                item.window.orderFrontRegardless()
                continue
            }

            let view = ResultOverlayView(frame: CGRect(origin: .zero, size: screenRect.size))
            view.update(index: row.index, color: color)
            view.onHoverChanged = { [weak self] isHovering in
                self?.handleOverlayHover(rowID: row.id, isHovering: isHovering)
            }

            let window = ResultOverlayWindow(contentRect: screenRect, overlayView: view)
            window.orderFrontRegardless()

            self.overlays[row.id] = OverlayItem(row: row, window: window, view: view)
        }

        if let hoveredID = self.overlayHoveredRowID, self.overlays[hoveredID] == nil {
            self.setHoveredOverlayRowID(nil)
        }

        self.updateHoveredOverlayFromCurrentMouseLocation()
        self.applyProminenceState()
    }

    func setExternalHighlightedRowID(_ rowID: QueryResultRow.ID?) {
        self.externalHighlightedRowID = rowID
        self.applyProminenceState()
    }

    private func handleOverlayHover(rowID: QueryResultRow.ID, isHovering: Bool) {
        if isHovering {
            self.setHoveredOverlayRowID(rowID)
        } else if self.overlayHoveredRowID == rowID {
            self.setHoveredOverlayRowID(nil)
        }
    }

    private func applyProminenceState() {
        let prominentID = self.overlayHoveredRowID ?? self.externalHighlightedRowID
        for (rowID, item) in self.overlays {
            item.view.setProminent(rowID == prominentID)
        }

        if let hoveredID = self.overlayHoveredRowID, let item = self.overlays[hoveredID] {
            self.showTooltip(for: item)
        } else {
            self.hideTooltip()
        }
    }

    private func showTooltip(for item: OverlayItem) {
        if self.tooltipWindow == nil {
            self.tooltipWindow = OverlayTooltipWindow()
        }

        let label = item.row.resultsDisplayName
        let color = OXQColorTheme.nsColor(forRole: item.row.role)

        self.tooltipWindow?.show(
            text: label,
            accentColor: color,
            anchorRect: item.window.frame)
    }

    private func hideTooltip() {
        self.tooltipWindow?.orderOut(nil)
    }

    private func teardown() {
        self.setHoveredOverlayRowID(nil)
        self.externalHighlightedRowID = nil
        self.hideTooltip()
        self.stopMouseMonitoring()

        for item in self.overlays.values {
            item.close()
        }
        self.overlays.removeAll()
    }

    private func setHoveredOverlayRowID(_ rowID: QueryResultRow.ID?) {
        guard self.overlayHoveredRowID != rowID else { return }
        self.overlayHoveredRowID = rowID
        self.onOverlayHoverChanged?(rowID)
        self.applyProminenceState()
    }

    private func startMouseMonitoringIfNeeded() {
        guard self.globalMouseMonitor == nil, self.localMouseMonitor == nil else { return }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHoveredOverlayFromCurrentMouseLocation()
            }
        }
        self.localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateHoveredOverlayFromCurrentMouseLocation()
            }
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func updateHoveredOverlayFromCurrentMouseLocation() {
        guard self.isEnabled, !self.overlays.isEmpty else {
            self.setHoveredOverlayRowID(nil)
            return
        }

        let pointer = NSEvent.mouseLocation
        let hoveredID = self.overlays
            .filter { _, item in
                item.window.frame.insetBy(dx: -1, dy: -1).contains(pointer)
            }
            .min { lhs, rhs in
                let lhsArea = lhs.value.window.frame.width * lhs.value.window.frame.height
                let rhsArea = rhs.value.window.frame.width * rhs.value.window.frame.height
                return lhsArea < rhsArea
            }?
            .key

        self.setHoveredOverlayRowID(hoveredID)
    }

    private static func convertAXFrameToScreenCoordinates(_ frame: CGRect) -> CGRect {
        let normalized = frame.standardized
        var bestRect: CGRect?
        var bestScore: CGFloat = 0

        for screen in NSScreen.screens {
            // AX frames use top-left origin; AppKit windows use bottom-left origin.
            let candidate = CGRect(
                x: normalized.origin.x,
                y: screen.frame.maxY - normalized.origin.y - normalized.size.height,
                width: normalized.size.width,
                height: normalized.size.height)

            let score = self.intersectionArea(candidate, with: screen.frame)
            if score > bestScore {
                bestScore = score
                bestRect = candidate
            }
        }

        // Keep a raw fallback for unexpected coordinate systems.
        return bestRect ?? normalized
    }

    private static func intersectionArea(_ lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else {
            return 0
        }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}

@MainActor
private final class OverlayItem {
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
    var onHoverChanged: ((Bool) -> Void)?

    private var roleColor = NSColor.systemBlue
    private var index = 0
    private var isProminent = false
    private var tracking: NSTrackingArea?

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

    override func updateTrackingAreas() {
        if let tracking {
            self.removeTrackingArea(tracking)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect,
        ]
        let tracking = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        self.addTrackingArea(tracking)
        self.tracking = tracking

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        self.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        self.onHoverChanged?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlightStrength: CGFloat = self.isProminent ? 1 : 0
        let fillAlpha = 0.11 + (0.16 * highlightStrength)
        let strokeAlpha = 0.55 + (0.35 * highlightStrength)
        let lineWidth = 1.7 + (1.1 * highlightStrength)

        let rect = self.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let rounded = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        self.roleColor.withAlphaComponent(fillAlpha).setFill()
        rounded.fill()

        self.roleColor.withAlphaComponent(strokeAlpha).setStroke()
        rounded.lineWidth = lineWidth
        rounded.stroke()

        let badgeText = "\(self.index)" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let badgeSize = badgeText.size(withAttributes: textAttrs)
        let badgeRect = NSRect(
            x: rect.minX + 7,
            y: rect.maxY - badgeSize.height - 10,
            width: badgeSize.width + 12,
            height: badgeSize.height + 4)

        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        self.roleColor.withAlphaComponent(0.92).setFill()
        badgePath.fill()

        let textRect = NSRect(
            x: badgeRect.minX + 6,
            y: badgeRect.minY + 2,
            width: badgeSize.width,
            height: badgeSize.height)
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
        self.tooltipView.configure(text: text, accentColor: accentColor)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ]
        let measuredWidth = (text as NSString).size(withAttributes: textAttributes).width
        let width = min(max(ceil(measuredWidth) + 18, 120), 760)
        let height: CGFloat = 28

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        var originX = anchorRect.minX
        var originY = anchorRect.minY - height - 6

        if originY < screenFrame.minY + 4 {
            originY = anchorRect.maxY + 6
        }

        originX = min(max(originX, screenFrame.minX + 4), screenFrame.maxX - width - 4)

        self.setFrame(
            CGRect(x: originX, y: originY, width: width, height: height),
            display: true)
        self.orderFrontRegardless()
    }
}

@MainActor
private final class OverlayTooltipView: NSView {
    private var text = ""
    private var accentColor = NSColor.systemBlue

    override var isFlipped: Bool { true }

    func configure(text: String, accentColor: NSColor) {
        self.text = text
        self.accentColor = accentColor
        self.invalidateIntrinsicContentSize()
        self.needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)]
        let measured = (self.text as NSString).size(withAttributes: attrs)
        return NSSize(width: measured.width + 18, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.78).setFill()
        background.fill()

        self.accentColor.withAlphaComponent(0.75).setStroke()
        background.lineWidth = 1.1
        background.stroke()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textRect = NSRect(
            x: 9,
            y: 7,
            width: max(0, bounds.width - 18),
            height: max(0, bounds.height - 14))
        (self.text as NSString).draw(in: textRect, withAttributes: textAttrs)
    }
}
