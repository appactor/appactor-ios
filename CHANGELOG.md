# Changelog

## 0.2.1

- Fixed: nonce responses (customer info, login, purchases, restore and sync) are also verified against the API key the SDK sent. Every AppActor project is signed with the same key, so a proxy on the device could swap in its own project's API key and pass that project's signed answer (say, an entitlement it granted itself) off as the app's. The SDK now sends `X-AppActor-Signature-Api-Key: include`, which the AppActor API signs from API #606 on (live). (2026-09-27 re-audit, Y-1)

## 0.2.0

The minimum is now iOS 16, and this release carries the fixes from the 2026-09-26 SDK audit (merges fda73b0, 5294be0, 9525295, bb13fe5, #16 and #17). Audit ids in parentheses. Nonce responses are verified with the request binding and the status signing the AppActor API added for them (API #599 and #604, both live).

Behaviour changes apps can see:

- Changed: the minimum is iOS 16 (macOS 13 for SwiftPM builds on a Mac), and the iOS 15 code paths are gone. An app that still supports iOS 15 stays on 0.1.x: CocoaPods doesn't pick 0.2.0 for an iOS 15 target, but SwiftPM's `from: "0.1.x"` resolves it anyway, so pin `.upToNextMinor(from: "0.1.13")` there. On iOS 16+, a two-part `~> 0.1` pod pin moves to 0.2.0; a three-part one such as `~> 0.1.13` stays on 0.1.x.
- Changed: placeholder appUserIds (`"null"`, `"guest"`, `"0"`, ...) given to `configure()` mean signed out: it keeps the stored anonymous id or starts a new one, never the last signed-in user's. Ids longer than 255 UTF-16 units or containing `/` or a control character make `configure()` fail (a blank one still means none), and `logIn()` rejects all of these and blank ids. A stored id the backend rejects is replaced with a new anonymous id, and receipts an older version queued under it move to the current user. (S1-1)
- Changed: the app user id is used verbatim everywhere; the pending-purchase and identity-transition buffers, remote config and experiments no longer trim it. The API key is trimmed the way the backend trims it. (E6b, S2-5)
- Changed: `configure()` waits for the first unlock after a reboot when the stored identity can't be read yet, instead of starting a new anonymous user; attribute writes throw `notAvailable` until then. (D1)
- Changed: attribute writes no longer jam the queue. A value the backend rejects for good (400, 409, 413, 422) is logged and dropped, splitting a rejected batch so only the bad keys go; 401 and 403 keep the queue; a 404 on an attribute DELETE counts as done. (S5-1, S5-3)
- Changed: offerings and remote config refuse an unsigned 2xx. Unverified cache entries written by older versions are deleted once, in `configure()`. (E5a)
- Changed: a 304 counts only when it answers the ETag the SDK sent (`W/` ignored); otherwise the SDK asks once more without it, and a 304 to a request without an ETag is refused (`CACHE_INCONSISTENCY`), after which offerings serve their cache. (E5b)
- Changed: `restorePurchases()` finishes only the transactions the backend reports as restored or unchanged; the ones it reports as a conflict or invalid stay unfinished and queued. (E3)
- Changed: a pending (Ask to Buy) purchase is matched only by the appAccountToken it was made with, and `configure(appUserId:)` with another user rotates the token, as `logIn()` and `logOut()` do. (E4, E6a)
- Changed: a `logIn()` that `reset()` cut off throws `notConfigured` and writes nothing; a failed `logIn()` leaves the current user's caches as they were. `logIn()` retries the backend's "concurrent identity merge in progress" 409 before failing. (S6-3, S6-2, E9b)
- Changed: `reset()` cancels the SDK's shared fetches instead of waiting for them (up to about 96 s on a stalled network). During `logOut()`, `reset()` or a cancelled startup, a `getCustomerInfo()`, `offerings()`, restore or sync that shares a cancelled fetch throws `CancellationError` (bridge `UNKNOWN`). A `configure()` made while a startup is still running returns once that startup settles. (E8b, E8a)
- Changed: error codes. `offerings()` maps StoreKit's own product-loading errors to `network` (2005) or `storeKitProductsMissing` with code `STOREKIT_PRODUCTS_UNAVAILABLE` (2008), and `purchase(package:)` maps them like purchase errors; bad fallback JSON is a `decoding` error (2006); a remote-config or experiment read the SDK's own state changes keep cancelling ends with a transient `network` error, code `STATE_CHANGED` (2005). All of these were `UNKNOWN` (2099). (E9d, E10a, E9c)
- Changed: `setFallbackOfferings` also accepts a saved `GET /v1/payment/offerings` body (`{"data": ...}`, the shape Android takes). (E10a)
- Changed: `cachedOfferings` (and the plugin's `get_cached_offerings`) also returns the offerings `configure()` loaded, until an `offerings()` call publishes its own. The plugin always emits `"current"`, `null` when there is none. (E10c, S7-2)
- Changed: offering and package metadata with non-string JSON values no longer fail the offerings decode; values are turned into strings as on Android (`null` is `""`, numbers and booleans as text, arrays and objects in Kotlin's collection format). (E2)
- Changed: `ownershipType` reads the backend's `family_shared` as `.familyShared` (the plugin emits `"familyShared"`); it was `.unknown`. (E10b)
- Changed: placements longer than 255 UTF-16 units are left out, as the backend counts them. (E12a)
- Changed: the privacy manifest declares Name, Email Address and Phone Number (`setDisplayName`, `setEmail`, `setPhoneNumber`), so the app's Xcode privacy report lists them. (E12c)
- Changed: logged request paths mask the app user id. (E12b)
- Changed: bridge receipt-pipeline events arrive on the main thread, in order. (S7-1)

Fixes:

- Fixed: response signatures are checked over the body bytes as received and, for nonce requests, over the method, path and query, request body hash and response status too, so a signed 304 or another request's answer can't be passed off as this one's. (S2-1, G-4, E5c)
- Fixed: `getCustomerInfo()` sends the app user id encoded once, so ids such as `auth0|...` resolve; the experiment key likewise. `+` in query values is sent as `%2B`. (S2-2, S2-4)
- Fixed: a remote-config or experiment number beyond `Int`'s range returns `nil` from `intValue` instead of crashing. (E1)
- Fixed: purchase intents held by the plugin, or arriving during or after `reset()`, are dropped instead of bought in the next session. (K1)
- Fixed: one user's state leaking into another's. A result fetched before a `logIn()`, `logOut()` or `reset()` isn't published for the next user (remote config, experiments); offline entitlement keys read the current user; an older customer snapshot no longer replaces a newer one. (S4-2, E9c, E7a, E7b)
- Fixed: receipts. A POST cut off by the app dying is posted at the next launch; a revoked re-delivery of a posted transaction is posted once; a response the SDK can't verify backs off up to 10 minutes instead of re-posting every 3 s; quiet sync skips refunded transactions; restore builds the customer from the full customer view. (S3-2, G-1, E9a, iR2C-3, S2-3)
- Fixed: the payment queue. A queue file that can't be read before the first unlock is no longer treated as empty and written over; a queue saved by 0.0.6 or 0.0.7 loads instead of being emptied; an item queued under an app user id the backend rejects waits to be moved to the current user instead of being posted and lost. (S3-4, E11b)
- Fixed: a pending purchase approved after the anonymous user who made it logged in still fires `onDeferredPurchaseResolved`, across relaunches; that user's queued attribute writes move to the account they logged in to instead of landing after newer ones. (E6c, S5-4)
- Fixed: offerings. A 304 after a new payload failed to enrich serves that payload instead of the older one in memory; bundled fallback offerings used at startup are stale at once; the offline product catalog is refreshed from every payload the backend serves or confirms. (E11c, S4-5, S4-6)
- Fixed: customer info. The launch seed carries the verification it was stored with; a caller that joins a forced refresh still falls back to the cache; a paying user's launch no longer deletes the remote-config and experiment caches; the 5-minute refresh also starts in a first session launched into the foreground; an offline launch runs one customer retry cycle instead of two. (G-3, S4-4, S6-1, E11d, E8c)
- Fixed: experiment assignments stored by an earlier session are no longer erased by the first online fetch. (S4-3)
- Fixed: a remote-config value no longer fails to load offline after the app is relaunched. The SDK probed without the user context, fell back to a good document on disk, then discarded it before a user-context refetch that could not reach the network — so the copy it already had was thrown away. It is now kept until an answer exists to replace it. A failed refetch also no longer records "this project needs the user context", which had pinned every later call to a context it could not fetch. In projects whose remote config needs the user context, the SDK discards the public copy once a user-context fetch succeeds, so an offline or 5xx call that probed without the user (after a relaunch, or once the remembered decision expired after 5 minutes) found nothing and threw; it now falls back to the user's own cached copy. (S4-1)
- Added: `scripts/test_ios.sh` runs the suite on a simulator. `swift test` targets macOS, where anything fenced on `canImport(UIKit)` is compiled out.

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
