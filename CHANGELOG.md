# Changelog

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
