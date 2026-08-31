# Changelog

## Unreleased

- Added: `AppActor.shared.presentScreen(_:)` presents a server-driven screen — a JSON document published from the dashboard, rendered on device in a `WKWebView` behind a narrow message handler that carries only purchase, restore, close, `openUrl` and telemetry. Returns `.purchased`, `.restored` or `.dismissed`; throws rather than presenting a screen that did not render, so a bundled paywall stays a usable fallback.
- Added: `AppActor.shared.onScreenEvent` delivers screen analytics (`impression`, `screen_view`, `cta_tap`, `purchase_started`, `purchase_completed`, `purchase_cancelled`, `dismiss`, `fallback_shown`, `slow_first_paint`).
- The screen runtime is embedded in the SDK rather than fetched, so a published screen opens with no connection once its document has been cached. Regenerate it with `./scripts/sync_screen_runtime.sh`.
- Fixed: a presented screen could navigate away from the page the SDK built for it. Only the exact request handed to `loadSimulatedRequest` is allowed now, and only once — a document that reached `location.href` can no longer replace the shell while the purchase bridge stays live.
- Fixed: `presentScreen(_:)` no longer suspends forever when UIKit refuses the presentation (a presenter already presenting, or mid-transition). It throws, and releases the one-screen-at-a-time claim, instead of leaving every later call to refuse.
- Fixed: `protocol_version` is compared exactly. `1.5` and `true` were both read as version 1 and their messages processed.
- Fixed: the walk that collects a document's packages counted array elements against its node budget instead of components, so a screen well inside the schema's limit could silently drop a plan near the end of the tree.
- Fixed: `openUrl`'s length bound counts UTF-16 units, matching the shared policy it backstops. Grapheme clusters made the native copy the looser of the two.
- Fixed: the init context sends a BCP 47 language tag (`en-US`), not an ICU identifier (`en_US`), as the bridge contract specifies.
- Fixed: the screen's message handler is removed on the main actor in `finish()` rather than in `deinit`, which is not guaranteed to run there.
- Changed: `AppActorScreenEvent` is `Sendable`, so an analytics layer behind an actor can capture it.
- Added: `image { ref: … }` sources are reported at presentation time. The SDK has no asset base to resolve them against yet, and they would otherwise render as nothing with no diagnostic.
- Fixed: a screen (and every other remote-config value) no longer fails to load offline after the app is relaunched. The SDK probed without the user context, fell back to a good document on disk, then discarded it before a user-context refetch that could not reach the network — so the copy it already had was thrown away. It is now kept until an answer exists to replace it. A failed refetch also no longer records "this project needs the user context", which had pinned every later call to a context it could not fetch.
- Added: `scripts/test_ios.sh` runs the suite on a simulator. `swift test` targets macOS, where 721 lines of screen tests are compiled out.

## 0.1.13

- Fixed: the launch sweep now posts every unfinished StoreKit transaction and finishes each after the server accepts it. Older renewals are no longer parked waiting for a server field the API stopped returning, so `Transaction.unfinished` no longer accumulates; unverified unfinished transactions are finished immediately.
- Added: `AppActorOffering.offeringKey` (the dashboard lookup key), `AppActorOfferings.offering(_:)` / `offerings["key"]` / `allOfferings` (current first), and `AppActor.shared.offering(_:fetchPolicy:)` to fetch and look up in one call.
- Added: `AppActor.shared.experiment(_:)` returns an `AppActorExperiment` that is never optional — `isEnrolled`, `variantKey`, `isVariant(_:)`, `boolValue / stringValue / intValue / doubleValue(default:)`, and `["key"]` for JSON payloads. `getExperimentAssignment(experimentKey:)` is unchanged underneath.
- Removed: `AppActorOfferings.offering(lookupKey:)` — use `offering(_:)` with the offering key (a one-line rename).
- Changed: `AppTransaction.shared` is fetched once per process and shared by every receipt; `AppActorReceiptCustomerUpdateContext` no longer carries `sourceIntent`, `originalTransactionId`, or `syncedOriginalTransactionId`.

## 0.1.12

- Added: entitlement state now renders from the persisted (or StoreKit-derived) cache at launch, before the network refresh, so customer info is available immediately instead of after a round-trip.
- Improved: the automatic device-attribute sync is skipped when nothing changed since the last confirmed delivery, removing a redundant per-launch network write.

## 0.1.11

- Fixed: the iOS `PluginNonSubscription` surrogate now emits `original_transaction_identifier`, matching the Android surrogate and the Dart/React Native models. (audit flutter-6)
- Fixed: the StoreKit product cache now expires entries on a TTL (default 1h) instead of caching for the whole process lifetime; stale entries are served immediately and refreshed in the background so a refresh never blocks the purchase path. (audit ios-7)

## 0.1.10

- Fixed: `postReceipt` now forwards `syncedOriginalTransactionId`, so the 0.1.9 coalesced-renewal finishing actually fires (the value was previously dropped on the success-rebuild, leaving that cleanup a dead path). (audit ios-3)
- Fixed: payment-mode entitlement helpers `isInGracePeriod` / `isInPaymentRetry` / `isRevoked` now reflect the real server status instead of always returning `false`. (audit ios-2)
- Fixed: customer DTO decode no longer swallows shape-drift errors and silently drops paid entitlements; it fails loudly and preserves the prior snapshot. (audit ios-16)
- Fixed: the plugin event bridge re-arms all four event types after `reset()`. (audit ios-17)
- Fixed: a monotonic ordering guard prevents concurrent receipt POSTs from publishing a stale customer snapshot over a newer one. (audit ios-19)
- Cleanup: deduplicated server error-envelope mapping; `AppActorOffering` Codable now round-trips `packages`; removed dead write-only payment state. (audit ios-10/ios-24/ios-25)

## 0.1.9

- Finished coalesced unfinished renewal cleanups even when a quiet sync response arrives after an app-user identity change.
- Kept quiet `syncPurchases()` renewal coalescing from replaying skipped StoreKit renewals after account switches.

## 0.1.8

- Harden automatic profile context sync during identity transitions and keep post-transition refreshes off the `logIn`/`logOut` return path.

## 0.1.7

- Automatically sync privacy-safe profile context during `configure()`/bootstrap.
- Breaking: removed the public `collectProfileContext()` and plugin `collect_profile_context` surfaces; use `collectDeviceIdentifiers()` only for explicit identifier opt-in.
- Log automatic profile context sync failures during bootstrap while keeping startup best-effort.

## 0.1.6

- Coalesced passive StoreKit unfinished renewal backlogs by original transaction chain during app-open sweep.
- Finished coalesced skipped renewals only after the backend returns a proven synced original transaction id for the chain.
- Aligned bridge and plugin `syncPurchases` semantics with quiet StoreKit sync while keeping explicit queue drain available separately.
