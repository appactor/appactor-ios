# Bridge and Plugin Parity Contract

## Goal
Lock the cross-platform wrapper contract so iOS and Android can be treated as one SDK surface at the bridge/plugin layer.

## Canonical Contract
- `configure` payload:
  - `api_key`
  - `options.log_level`
  - `options.platform_info.flavor`
  - `options.platform_info.version`
- `get_offerings` payload:
  - `fetch_policy`
  - values: `freshIfStale`, `returnCachedThenRefresh`, `cacheOnly`
- Receipt pipeline event types:
  - `POSTED_OK`
  - `DEFERRED_WAITING_FOR_IDENTITY`
  - `RETRY_SCHEDULED`
  - `PERMANENTLY_REJECTED`
  - `DEAD_LETTERED`
  - `DUPLICATE_SKIPPED`
- Verification values:
  - `notRequested`
  - `verified`
  - `verifiedOnDevice`
  - `failed`
- Bridge error diagnostics:
  - `backendCode`
  - `requestId`
  - `scope`
  - `retryAfterSeconds`

## Guardrails
- New wrapper-facing fields must be added bridge-first, then implemented on both native SDKs.
- Legacy top-level configure aliases stay for one compatibility window only.
- Any release that changes bridge/plugin payload shape must update tests and this file together.

## Release Checklist
- iOS bridge and plugin tests cover canonical `options.platform_info`.
- iOS bridge/plugin tests cover `fetch_policy`.
- iOS bridge/plugin tests cover `DEFERRED_WAITING_FOR_IDENTITY`.
- iOS bridge error serialization includes structured diagnostics.
