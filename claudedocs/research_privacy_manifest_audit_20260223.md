# AppActor iOS SDK — Privacy Manifest Audit Report

**Date:** 2026-02-23
**Scope:** PrivacyInfo.xcprivacy + Package.swift compliance with Apple requirements
**Confidence:** HIGH (20+ Apple docs & 3rd party SDK references cross-checked)

---

## Executive Summary

AppActor SDK's privacy manifest is **COMPLIANT** with Apple's requirements. One minor recommendation exists (UserDefaults reason code alternative). No blocking issues found.

---

## 1. Privacy Manifest Structure Audit

### 1.1 Top-Level Keys

| Key | Required | Our Value | Status |
|-----|----------|-----------|--------|
| `NSPrivacyTracking` | Yes | `false` | PASS — SDK does not use ATT/IDFA tracking |
| `NSPrivacyTrackingDomains` | Only if tracking=true | Omitted | PASS — Correctly omitted per [TN3181](https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest) |
| `NSPrivacyCollectedDataTypes` | Yes | 4 entries | PASS — See Section 2 |
| `NSPrivacyAccessedAPITypes` | Yes (if using required reason APIs) | 1 entry | PASS — See Section 3 |

**Source:** [Privacy manifest files — Apple Developer](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

---

## 2. Collected Data Types Audit

### 2.1 Entry-by-Entry Analysis

#### Entry 1: `NSPrivacyCollectedDataTypePurchaseHistory`

| Field | Value | Justification |
|-------|-------|---------------|
| Linked | `true` | SDK sends `appUserId` + `transactionId` + `productId` + `signedTransactionInfo` together to backend (`ReceiptsDTO.swift:4-15`) |
| Tracking | `false` | Data used for payment validation, not cross-app tracking |
| Purposes | `AppFunctionality` | Server-authoritative receipt validation |

**Comparison with RevenueCat:** RevenueCat declares PurchaseHistory with `Linked=false` (because by default they don't link unless custom IDs are used). Our SDK ALWAYS links purchase data to appUserId during receipt POST, so `Linked=true` is **more accurate and conservative** for us.
**Source:** [RevenueCat PrivacyInfo.xcprivacy on GitHub](https://github.com/RevenueCat/purchases-ios/blob/main/Sources/PrivacyInfo.xcprivacy)

**Verdict: PASS**

---

#### Entry 2: `NSPrivacyCollectedDataTypeUserID`

| Field | Value | Justification |
|-------|-------|---------------|
| Linked | `true` | SDK generates anonymous IDs (`appactor-anon-*`) and supports custom user IDs via `logIn()` — all sent to backend |
| Tracking | `false` | User IDs used for identity management, not cross-app tracking |
| Purposes | `AppFunctionality` | Identity management (identify/login/logout) |

**Code evidence:** `PaymentModels.swift:69-77` (IdentifyRequest sends appUserId), `PaymentStorage.swift` (stores appUserId in UserDefaults)

**Comparison with RevenueCat:** RevenueCat does NOT declare UserID separately — they rely on PurchaseHistory only. Our approach is **more thorough** because we explicitly manage user identities beyond just purchase context.

**Comparison with Adapty:** Adapty declares UserID under "Identifiers" category — same approach as ours.
**Source:** [Adapty Apple App Privacy](https://adapty.io/docs/apple-app-privacy)

**Verdict: PASS**

---

#### Entry 3: `NSPrivacyCollectedDataTypeOtherDataTypes`

| Field | Value | Justification |
|-------|-------|---------------|
| Linked | `true` | Device metadata sent alongside `appUserId` during `identify()` call |
| Tracking | `false` | Metadata used for analytics/debugging, not cross-app tracking |
| Purposes | `AppFunctionality` | Server uses device info for compatibility/analytics |

**Code evidence:** `PaymentConfiguration.swift:129-170` auto-collects:
- `platform` ("ios")
- `osVersion` (via `ProcessInfo.processInfo.operatingSystemVersion`)
- `appVersion` (via `Bundle.main.infoDictionary`)
- `deviceLocale` (via `Locale.current.identifier`)
- `deviceModel` (via `UIDevice.current.model`)
- `sdkVersion`

**Why `OtherDataTypes` and NOT `OtherDiagnosticData`?**
Apple defines `OtherDiagnosticData` as "data collected for measuring technical diagnostics related to the app" (crash data, performance metrics). Our SDK collects device metadata for **identity context and functionality**, not for diagnostics. Apple Developer Forums confirm device metadata like OS version and model belong in `OtherDataTypes`.
**Source:** [Apple Privacy Definitions](https://apps.apple.com/us/story/id1539235847), [Apple Developer Forums](https://developer.apple.com/forums/thread/743559)

**Verdict: PASS**

---

#### Entry 4: `NSPrivacyCollectedDataTypeAdvertisingData`

| Field | Value | Justification |
|-------|-------|---------------|
| Linked | `true` | ASA attribution token sent with `appUserId` to backend |
| Tracking | `false` | SDK does not use IDFA or cross-app tracking |
| Purposes | `AppFunctionality`, `Analytics`, `DeveloperAdvertising` | ASA attribution for install attribution & campaign measurement |

**Code evidence:** `ASAManager.swift:6` — sends `AAAttribution.attributionToken()` + attribution response + purchase events to `/v1/asa/attribution` endpoint.

**ASA data sent to backend:**
- Attribution token (`ASAManager.swift:148`)
- Apple attribution API response (`ASAManager.swift:128`)
- User ID, OS version, app version, lib version (`ASAManager.swift:147-151`)
- First install flags (`ASAManager.swift:152-153`)
- Purchase events with storefront and SK2 data (`ASAManager.swift:538-546`)

**Why 3 purposes?**
- `AppFunctionality` — Attribution data used in app's subscription flow
- `Analytics` — Campaign performance measurement
- `DeveloperAdvertising` — Apple Search Ads attribution IS developer advertising/marketing

**Comparison with Adapty:** Adapty declares similar advertising data when integrating with attribution platforms.

**Verdict: PASS**

---

### 2.2 Data Types NOT Declared (Correctly Omitted)

| Data Type | Why Not Declared |
|-----------|-----------------|
| `DeviceID` | SDK does NOT access IDFA (`ASIdentifierManager`), IDFV (`identifierForVendor`), or any system device identifier. Confirmed: zero matches in codebase. |
| `PreciseLocation` / `CoarseLocation` | SDK does not access location services |
| `PaymentInfo` | SDK does not collect credit card or payment method data |
| `CrashData` / `PerformanceData` | SDK does not collect crash or performance data |
| `ContactInfo` (Name/Email/Phone) | SDK does not collect contact information |
| `HealthData` / `FitnessData` | Not applicable |
| `BrowsingHistory` / `SearchHistory` | Not applicable |
| `ProductInteraction` | SDK sends purchase transactions (covered by PurchaseHistory), not general product interaction metrics |

---

## 3. Required Reason APIs Audit

### 3.1 APIs Declared

| API Category | Reason Code | Status |
|-------------|-------------|--------|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | PASS |

**CA92.1 definition:** "Access user defaults to read and write information that is only accessible to the app itself."

**Code evidence — 4 files using UserDefaults:**
1. `PersistenceManager.swift` — namespaced UserDefaults for SDK state
2. `PaymentStorage.swift` — stores appUserId, installId, serverUserId
3. `AppActor+Payment.swift` — passes UserDefaults suite to storage
4. `PaymentConfiguration.swift` — references UserDefaults for debug settings

**Source:** [Describing use of required reason API — Apple](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

---

### 3.2 UserDefaults Reason Code Analysis

| Code | Description | Fits Our SDK? |
|------|-------------|---------------|
| **CA92.1** | Read/write info only accessible to the app itself | **YES** — SDK stores its own data in app's UserDefaults sandbox |
| C56D.1 | Third-party SDK that wraps UserDefaults APIs | NO — Our SDK USES UserDefaults for internal storage, it doesn't WRAP UserDefaults for the app |
| 1C8F.1 | Read/write in same App Group | NO — SDK doesn't use App Groups |
| AC6B.1 | MDM managed app configuration | NO — Not applicable |

**Comparison with RevenueCat:** RevenueCat also uses **CA92.1** (confirmed from their GitHub PrivacyInfo.xcprivacy). This validates our choice.
**Source:** [RevenueCat purchases-ios PrivacyInfo.xcprivacy](https://github.com/RevenueCat/purchases-ios/blob/main/Sources/PrivacyInfo.xcprivacy)

> **NOTE:** There is a possible argument for using **C56D.1** since we are a third-party SDK. However, C56D.1 specifically says "wraps user defaults APIs, only accessing them when called by the app." Our SDK accesses UserDefaults **autonomously** (during configure, bootstrap, identity persistence) — not when called by the app to read/write UserDefaults. Therefore **CA92.1 is the correct choice.**

---

### 3.3 APIs NOT Declared (Verified Not Used)

| API Category | Codebase Search Result | Status |
|-------------|----------------------|--------|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | Searched: `creationDate`, `modificationDate`, `contentModificationDate`, `attributeModificationDate`, `fileModificationDate` → **0 matches** | CORRECTLY OMITTED |
| `NSPrivacyAccessedAPICategorySystemBootTime` | Searched: `systemUptime`, `ProcessInfo.*uptime`, `mach_absolute_time`, `bootTime` → **0 matches** | CORRECTLY OMITTED |
| `NSPrivacyAccessedAPICategoryDiskSpace` | Searched: `volumeAvailableCapacity`, `systemFreeSize`, `systemSize`, `diskSpace`, `NSFileSystemFreeSize` → **0 matches** | CORRECTLY OMITTED |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | Searched: `activeInputModes`, `GCKeyboard`, `UITextInputMode` → **0 matches** | CORRECTLY OMITTED |

**Source:** [Describing use of required reason API — Apple](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

---

## 4. SPM Distribution & Resource Bundling Audit

| Requirement | Our Implementation | Status |
|------------|-------------------|--------|
| File name `PrivacyInfo.xcprivacy` | `Sources/AppActor/Resources/PrivacyInfo.xcprivacy` | PASS |
| SPM resource bundling | `.copy("Resources/PrivacyInfo.xcprivacy")` in Package.swift | PASS |
| `.copy()` vs `.process()` | Using `.copy()` — correct for privacy manifests (must remain untouched) | PASS |
| swift-tools-version >= 5.9 | `swift-tools-version: 5.9` | PASS |
| Build verification | `swift build` produces `AppActor_AppActor.bundle/PrivacyInfo.xcprivacy` | PASS |

**Source:** [Adding Privacy Manifest to Swift Package — Apple Developer Forums](https://developer.apple.com/forums/thread/742527), [APNsPush Guide](https://apnspush.com/add-privacy-manifest-sdk)

---

## 5. App Store Enforcement Status

| Milestone | Date | Status |
|-----------|------|--------|
| WWDC23 announcement | June 2023 | Announced |
| Email warnings for missing manifests | March 13, 2024 | Active |
| **Rejection enforcement (ITMS-91053)** | **May 1, 2024** | **ACTIVE — Apps rejected without privacy manifests** |
| Third-party SDK signature requirements | May 1, 2024 | Active (binary dependencies only) |

**Impact for AppActor SDK:** Apps integrating our SDK without a privacy manifest WILL be rejected from App Store Connect. Our manifest ensures compliance.

**Source:** [Apple News — Privacy requirement reminder](https://developer.apple.com/news/?id=pvszzano), [Bitrise enforcement guide](https://bitrise.io/blog/post/enforcement-of-apple-privacy-manifest-starting-from-may-1-2024)

---

## 6. Comparison with Industry Payment SDKs

| Feature | AppActor | RevenueCat | Adapty |
|---------|----------|------------|--------|
| PurchaseHistory | Linked=true | Linked=false | Declared |
| UserID | Declared | Not declared | Declared |
| DeviceMetadata | OtherDataTypes | Not declared | Not declared |
| AdvertisingData (ASA) | Declared | Not declared | Conditional |
| UserDefaults reason | CA92.1 | CA92.1 | Not specified |
| FileTimestamp API | Not used | Declared | Not specified |
| NSPrivacyTracking | false | false | Not specified |

**Analysis:** Our manifest is **more comprehensive** than RevenueCat's because:
1. We declare UserID (they don't)
2. We declare device metadata (they don't)
3. We declare ASA advertising data (they don't have ASA features)
4. We correctly set Linked=true for PurchaseHistory (they set false)

This is the **conservative and correct** approach — better to over-declare than under-declare.

---

## 7. Valid Key Reference (Verified)

### All NSPrivacyCollectedDataType values used by our SDK:

| Key | Apple Category | Valid |
|-----|---------------|-------|
| `NSPrivacyCollectedDataTypePurchaseHistory` | Purchases | YES |
| `NSPrivacyCollectedDataTypeUserID` | Identifiers | YES |
| `NSPrivacyCollectedDataTypeOtherDataTypes` | Other Data | YES |
| `NSPrivacyCollectedDataTypeAdvertisingData` | Usage Data | YES |

### All NSPrivacyCollectedDataTypePurposes values used:

| Key | Valid |
|-----|-------|
| `NSPrivacyCollectedDataTypePurposeAppFunctionality` | YES |
| `NSPrivacyCollectedDataTypePurposeAnalytics` | YES |
| `NSPrivacyCollectedDataTypePurposeDeveloperAdvertising` | YES |

**Complete valid purposes list (6 total):**
1. `NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising`
2. `NSPrivacyCollectedDataTypePurposeDeveloperAdvertising`
3. `NSPrivacyCollectedDataTypePurposeAnalytics`
4. `NSPrivacyCollectedDataTypePurposeProductPersonalization`
5. `NSPrivacyCollectedDataTypePurposeAppFunctionality`
6. `NSPrivacyCollectedDataTypePurposeOther`

**Source:** [APNsPush Privacy Manifests Guide](https://apnspush.com/what-are-privacy-manifest-files)

---

## 8. Final Verdict

| Category | Status | Notes |
|----------|--------|-------|
| Privacy Manifest Structure | PASS | All required keys present, correct format |
| Collected Data Types | PASS | 4 types correctly declared with accurate flags |
| Required Reason APIs | PASS | UserDefaults with CA92.1, all others verified not needed |
| SPM Resource Bundling | PASS | .copy() method, correct path, builds successfully |
| App Store Compliance | PASS | Ready for submission |
| Key Validity | PASS | All keys verified against Apple documentation |

### Recommendation (Non-blocking)

No changes needed. The current manifest is production-ready.

---

## Sources (20+)

1. [Privacy manifest files — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
2. [Adding a privacy manifest to your app or third-party SDK — Apple](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
3. [Describing use of required reason API — Apple](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
4. [Describing data use in privacy manifests — Apple](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
5. [NSPrivacyCollectedDataType — Apple Developer](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
6. [NSPrivacyCollectedDataTypePurposes — Apple Developer](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes)
7. [NSPrivacyAccessedAPIType — Apple Developer](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
8. [TN3181: Debugging an invalid privacy manifest — Apple](https://developer.apple.com/documentation/technotes/tn3181-debugging-invalid-privacy-manifest)
9. [TN3183: Adding required reason API entries — Apple](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
10. [TN3184: Adding data collection details — Apple](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)
11. [Third-party SDK requirements — Apple](https://developer.apple.com/support/third-party-SDK-requirements)
12. [App Privacy Details — Apple](https://developer.apple.com/app-store/app-privacy-details/)
13. [Privacy requirement reminder (May 2024) — Apple News](https://developer.apple.com/news/?id=pvszzano)
14. [Privacy updates for App Store submissions — Apple](https://developer.apple.com/news/?id=3d8a9yyh)
15. [Get started with privacy manifests — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10060/)
16. [Adding Privacy Manifest to Swift Package — Apple Forums](https://developer.apple.com/forums/thread/742527)
17. [Privacy Manifests and Swift Packages — Apple Forums](https://developer.apple.com/forums/thread/749595)
18. [RevenueCat PrivacyInfo.xcprivacy — GitHub](https://github.com/RevenueCat/purchases-ios/blob/main/Sources/PrivacyInfo.xcprivacy)
19. [RevenueCat Apple App Privacy — Docs](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy)
20. [Adapty Apple App Privacy — Docs](https://adapty.io/docs/apple-app-privacy)
21. [Enforcement of Apple Privacy Manifest — Bitrise](https://bitrise.io/blog/post/enforcement-of-apple-privacy-manifest-starting-from-may-1-2024)
22. [How to Add Privacy Manifest to SDK — APNsPush](https://apnspush.com/add-privacy-manifest-sdk)
23. [Apple Privacy Manifests — APNsPush](https://apnspush.com/what-are-privacy-manifest-files)
24. [Privacy Manifest — Credolab Docs](https://docs.credolab.com/docs/privacy-manifest)
