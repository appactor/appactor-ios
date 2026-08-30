import Foundation

/// A screen document as it arrives from remote config.
///
/// Delivery rides the existing `/v1/remote-config` channel under the reserved
/// `screen.<lookupKey>` key — no new endpoint, no new table, no SDK release
/// train. That also means the document arrives as an ``AppActorConfigValue``
/// tree rather than as bytes, so the first job here is turning it back into
/// something `JSONSerialization` will accept.
///
/// Almost nothing about the document's *contents* is validated on this side.
/// The publisher validates against the full schema before anything is written,
/// the API refuses a document whose `lookupKey` disagrees with its key, and
/// every component in the tree carries a `fallback` so the runtime degrades
/// instead of blanking when it meets something it does not know. A second
/// opinion here would only add a way for an old SDK to reject a document a new
/// runtime could have rendered.
struct AppActorScreenDocument {

    let lookupKey: String
    /// The document as a JSON object graph, ready to become an `init` payload.
    let json: [String: Any]

    /// `packageId` → the `packageId` its `compareTo` names.
    ///
    /// Extracted here because `compareTo` sits on the document's `package`
    /// components but `discountPercent` has to be computed natively — the
    /// runtime treats every `package.*` field as pass-through.
    let comparisons: [String: String]

    /// Package ids the document actually renders, in document order.
    ///
    /// Used to decide which packages are worth resolving StoreKit products
    /// for. A paywall naming three of an offering's nine packages should not
    /// wait on six `Product` lookups it will never display.
    let packageIds: [String]
}

enum AppActorScreenDocumentError: Error, Equatable {
    case missing(lookupKey: String)
    case notAnObject
    case lookupKeyMismatch(expected: String, found: String?)

    var message: String {
        switch self {
        case .missing(let key):
            return "No screen document found for lookupKey \"\(key)\". Publish it, or check that getRemoteConfigs() has run."
        case .notAnObject:
            return "The screen document was not a JSON object."
        case .lookupKeyMismatch(let expected, let found):
            let got = found.map { "\"\($0)\"" } ?? "nothing"
            return "The screen document under \"\(expected)\" declares lookupKey \(got)."
        }
    }
}

extension AppActorScreenDocument {

    /// Remote config key for a screen. Mirrors `remoteConfigKey()` in
    /// `spec/url.ts`; the API reserves this prefix and rejects anything under
    /// it that is not a screen.
    static func remoteConfigKey(for lookupKey: String) -> String { "screen.\(lookupKey)" }

    /// Mirrors `LOOKUP_KEY_RE` in `spec/url.ts`. Narrow because the key is
    /// immutable once published -- it travels to the receipt as `placement` --
    /// and because it ends up in a URL path.
    static func isValidLookupKey(_ key: String) -> Bool {
        key.range(of: "^[a-z0-9][a-z0-9_-]{1,62}[a-z0-9]$", options: .regularExpression) != nil
    }

    static func parse(_ value: AppActorConfigValue?, lookupKey: String) throws -> AppActorScreenDocument {
        guard let value else { throw AppActorScreenDocumentError.missing(lookupKey: lookupKey) }
        guard case .dictionary = value, let json = foundationValue(value) as? [String: Any] else {
            throw AppActorScreenDocumentError.notAnObject
        }

        // The one contents check worth keeping. `lookupKey` leaves the device
        // as `placement` on the receipt, so a document filed under the wrong
        // key silently misattributes revenue to another screen — and unlike a
        // rendering fault, nothing downstream ever surfaces it.
        let declared = json["lookupKey"] as? String
        guard declared == lookupKey else {
            throw AppActorScreenDocumentError.lookupKeyMismatch(expected: lookupKey, found: declared)
        }

        let packages = collectPackages(json)
        return AppActorScreenDocument(
            lookupKey: lookupKey,
            json: json,
            comparisons: packages.comparisons,
            packageIds: packages.order
        )
    }

    /// Walks every slot for `package` components.
    ///
    /// Iterative, with an explicit node budget: the document is server-supplied
    /// and a hand-edited one could nest deeply enough to exhaust the stack. The
    /// budget matches the schema's own node ceiling, so a document that passed
    /// publish validation always fits.
    private static func collectPackages(_ document: [String: Any]) -> (comparisons: [String: String], order: [String]) {
        let maxNodes = 400
        var comparisons: [String: String] = [:]
        var order: [String] = []
        var seen = Set<String>()
        var visited = 0

        var queue: [Any] = []
        if let slots = document["slots"] as? [String: Any] {
            // Slot iteration order is unspecified for a dictionary, so sort it:
            // the package the runtime selects by default is the first one in
            // document order, and "first" must not change between launches.
            for name in slots.keys.sorted() {
                if let list = slots[name] as? [Any] { queue.append(contentsOf: list) }
            }
        }

        while !queue.isEmpty, visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1
            guard let object = node as? [String: Any] else { continue }

            if object["type"] as? String == "package", let id = object["packageId"] as? String, !id.isEmpty {
                if seen.insert(id).inserted { order.append(id) }
                if let against = object["compareTo"] as? String, !against.isEmpty {
                    comparisons[id] = against
                }
            }

            if let children = object["children"] as? [Any] { queue.append(contentsOf: children) }
            // A `package` can hide behind an unknown component's fallback, and
            // that fallback is exactly what an older runtime will render.
            if let fallback = object["fallback"] { queue.append(fallback) }
        }

        return (comparisons, order)
    }

    /// ``AppActorConfigValue`` → a `JSONSerialization`-compatible graph.
    ///
    /// The enum already preserves arbitrary nested JSON — nothing was coerced
    /// to a string on the way in — so this is a shape change, not a re-parse.
    static func foundationValue(_ value: AppActorConfigValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .int(let number): return number
        case .double(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map { foundationValue($0) }
        case .dictionary(let entries):
            var out: [String: Any] = [:]
            out.reserveCapacity(entries.count)
            for (key, item) in entries { out[key] = foundationValue(item) }
            return out
        }
    }
}
