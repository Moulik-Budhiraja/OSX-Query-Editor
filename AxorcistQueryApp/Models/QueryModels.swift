import AXorcist
import Foundation

enum SelectorInteractionKind: String, CaseIterable, Identifiable {
    case click
    case press
    case focus
    case setValue = "set-value"
    case setValueSubmit = "set-value-submit"
    case sendKeystrokesSubmit = "send-keystrokes-submit"

    var id: String { rawValue }

    var requiresValue: Bool {
        switch self {
        case .setValue, .setValueSubmit, .sendKeystrokesSubmit:
            true
        default:
            false
        }
    }
}

struct RunningAppOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let pid: pid_t

    var selectorToken: String {
        bundleIdentifier ?? String(pid)
    }
}

struct QueryRequest {
    let appIdentifier: String
    let selector: String
    let maxDepth: Int
}

enum QueryExecutionMode {
    case liveRefresh
    case useWarmCache
}

struct QueryInteractionRequest {
    let resultIndex: Int
    let action: SelectorInteractionKind
    let value: String?
}

struct QueryStats {
    let elapsedMilliseconds: Double
    let usedWarmCache: Bool
    let traversedCount: Int
    let matchedCount: Int
    let appIdentifier: String
    let selector: String
}

struct QueryResultRow: Identifiable {
    let id: Int
    let index: Int
    let role: String
    let frame: CGRect?
    let name: String
    let nameSource: String?
    let title: String?
    let value: String?
    let identifier: String?
    let descriptionText: String?
    let enabled: Bool?
    let focused: Bool?
    let childCount: Int?
    let path: String?

    var resultsDisplayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedValue.isEmpty else { return trimmedName }
        guard !trimmedName.isEmpty else { return trimmedValue }

        if trimmedValue.count > trimmedName.count,
           (trimmedValue.contains(trimmedName) || trimmedName.contains(trimmedValue))
        {
            return trimmedValue
        }

        return trimmedName
    }

    func matches(search: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        let fields: [String?] = [
            role,
            name,
            nameSource,
            title,
            value,
            identifier,
            descriptionText,
            path,
        ]
        return fields.compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
    }
}

struct QueryExecutionResult {
    let stats: QueryStats
    let rows: [QueryResultRow]
}

enum QueryWorkbenchError: LocalizedError {
    case missingAppIdentifier
    case missingSelector
    case invalidMaxDepth
    case selfTargetUnsupported
    case focusedAppUnavailable
    case applicationNotFound(String)
    case interactionTargetOutOfBounds(index: Int, matchedCount: Int)
    case interactionFailed(action: String, index: Int)
    case interactionValueRequired(SelectorInteractionKind)

    var errorDescription: String? {
        switch self {
        case .missingAppIdentifier:
            return "An app identifier is required (bundle id, app name, PID, or focused)."
        case .missingSelector:
            return "A selector query is required."
        case .invalidMaxDepth:
            return "Max depth must be greater than 0."
        case .selfTargetUnsupported:
            return "Querying Axorcist Query App itself is not supported. Choose another app."
        case .focusedAppUnavailable:
            return "Focused app resolved to Axorcist Query App. Focus another app first, then run the query."
        case let .applicationNotFound(identifier):
            return "Could not find a running app for '\(identifier)'."
        case let .interactionTargetOutOfBounds(index, matchedCount):
            return "Result index \(index) is out of bounds for \(matchedCount) matches."
        case let .interactionFailed(action, index):
            return "Interaction '\(action)' failed for result \(index)."
        case let .interactionValueRequired(action):
            return "A value is required for '\(action.rawValue)'."
        }
    }
}
