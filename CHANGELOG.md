# Changelog

## 0.1.6

- Coalesced passive StoreKit unfinished renewal backlogs by original transaction chain during app-open sweep.
- Finished coalesced skipped renewals only after the backend returns a proven synced original transaction id for the chain.
- Aligned bridge and plugin `syncPurchases` semantics with quiet StoreKit sync while keeping explicit queue drain available separately.
