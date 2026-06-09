# Changelog

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
