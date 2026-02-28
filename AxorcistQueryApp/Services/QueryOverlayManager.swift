import AppKit
import Foundation

@MainActor
final class QueryOverlayManager {
    var onOverlayHoverChanged: ((QueryResultRow.ID?) -> Void)?

    private let maxOverlayCount = 250
    private var isEnabled = false
    private var overlays: [QueryResultRow.ID: OverlayEntry] = [:]
    private var externalHighlightedRowID: QueryResultRow.ID?
    private var hoveredOverlayRowID: QueryResultRow.ID?
    private var tooltipWindow: OverlayTooltipWindow?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverRefreshTimer: Timer?

    func setEnabled(_ enabled: Bool, rows: [QueryResultRow]) {
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

        let candidates = Array(rows.prefix(self.maxOverlayCount))
        var activeIDs = Set<QueryResultRow.ID>()

        for row in candidates {
            guard let frame = row.frame else { continue }
            let convertedFrame = Self.convertAXFrameToScreen(frame).integral
            guard convertedFrame.width > 1, convertedFrame.height > 1 else { continue }

            activeIDs.insert(row.id)
            let roleColor = OXQColorTheme.nsColor(forRole: row.role)

            if let overlay = self.overlays[row.id] {
                overlay.row = row
                overlay.view.update(index: row.index, color: roleColor)
                overlay.window.setFrame(convertedFrame, display: true)
                overlay.window.orderFrontRegardless()
            } else {
                let view = ResultOverlayView(frame: CGRect(origin: .zero, size: convertedFrame.size))
                view.update(index: row.index, color: roleColor)

                let window = ResultOverlayWindow(contentRect: convertedFrame, overlayView: view)
                window.orderFrontRegardless()

                self.overlays[row.id] = OverlayEntry(row: row, window: window, view: view)
            }
        }

        let staleIDs = self.overlays.keys.filter { !activeIDs.contains($0) }
        for staleID in staleIDs {
            self.overlays[staleID]?.close()
            self.overlays.removeValue(forKey: staleID)
        }

        self.refreshHoveredOverlayFromPointer()
        self.applyVisualState()
    }

    func setExternalHighlightedRowID(_ rowID: QueryResultRow.ID?) {
        self.externalHighlightedRowID = rowID
        self.applyVisualState()
    }

    private func setHoveredOverlayRowID(_ rowID: QueryResultRow.ID?) {
        guard self.hoveredOverlayRowID != rowID else { return }
        self.hoveredOverlayRowID = rowID
        self.onOverlayHoverChanged?(rowID)
        self.applyVisualState()
    }

    private func refreshHoveredOverlayFromPointer() {
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
        self.tooltipWindow?.show(
            text: hovered.row.resultsDisplayName,
            accentColor: OXQColorTheme.nsColor(forRole: hovered.row.role),
            anchorRect: hovered.window.frame)
    }

    private func startHoverMonitoringIfNeeded() {
        guard self.globalMouseMonitor == nil, self.localMouseMonitor == nil else { return }

        let trackedEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
        ]

        self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: trackedEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshHoveredOverlayFromPointer()
            }
        }

        self.localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: trackedEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.refreshHoveredOverlayFromPointer()
            }
            return event
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshHoveredOverlayFromPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.hoverRefreshTimer = timer
    }

    private func stopHoverMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
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
        let prominence: CGFloat = self.isProminent ? 1 : 0
        let fillAlpha = 0.12 + (0.14 * prominence)
        let strokeAlpha = 0.58 + (0.30 * prominence)
        let lineWidth = 1.6 + (1.2 * prominence)

        let frameRect = self.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let rounded = NSBezierPath(roundedRect: frameRect, xRadius: 7, yRadius: 7)

        self.roleColor.withAlphaComponent(fillAlpha).setFill()
        rounded.fill()
        self.roleColor.withAlphaComponent(strokeAlpha).setStroke()
        rounded.lineWidth = lineWidth
        rounded.stroke()

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
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let maxWidth = max(120, screenFrame.width - 12)
        let size = self.tooltipView.measure(text: text, maxWidth: maxWidth)

        var originX = anchorRect.minX
        var originY = anchorRect.minY - size.height - 6
        if originY < screenFrame.minY + 4 {
            originY = anchorRect.maxY + 6
        }
        originX = min(max(originX, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)

        self.tooltipView.configure(text: text, accentColor: accentColor)
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
