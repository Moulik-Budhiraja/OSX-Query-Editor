import OSXQuery
import Foundation

enum WorkbenchEditorMode: String, CaseIterable, Identifiable {
    case query
    case action

    var id: String { rawValue }
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
    let reference: String?
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
            reference,
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

struct QueryAttributeDetail: Identifiable {
    let name: String
    let value: String

    var id: String { name }
}

enum QueryWorkbenchError: LocalizedError {
    case missingAppIdentifier
    case missingSelector
    case invalidMaxDepth
    case selfTargetUnsupported
    case focusedAppUnavailable
    case applicationNotFound(String)
    case elementReferenceUnavailable(String)
    case attributeInspectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAppIdentifier:
            return "An app identifier is required (bundle id, app name, PID, or focused)."
        case .missingSelector:
            return "A selector query is required."
        case .invalidMaxDepth:
            return "Max depth must be greater than 0."
        case .selfTargetUnsupported:
            return "Querying OSX Query Editor itself is not supported. Choose another app."
        case .focusedAppUnavailable:
            return "Focused app resolved to OSX Query Editor. Focus another app first, then run the query."
        case let .applicationNotFound(identifier):
            return "Could not find a running app for '\(identifier)'."
        case let .elementReferenceUnavailable(reference):
            return "Reference '\(reference)' is no longer available. Re-run query to refresh snapshot refs."
        case let .attributeInspectionFailed(details):
            return "Failed to inspect element attributes: \(details)"
        }
    }
}
