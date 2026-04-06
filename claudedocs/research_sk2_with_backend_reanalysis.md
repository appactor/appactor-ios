# AppActor iOS SDK -- Backend ile Yeniden Degerlendirme

**Date:** 2026-02-13
**Context:** SDK kendi backend'ine sahip olacak (App Store Server Notifications V2)

---

## Backend Ne Degistiriyor?

Backend ile App Store Server Notifications V2 alabilirsiniz. Bu sunlari saglar:

| Olay | Client-Only | Backend ile |
|------|-------------|-------------|
| Consumable refund | Transaction.updates (uygulama aciksa) | REFUND notification (her zaman) |
| Subscription expiry | Transaction.updates ATESLEMEZ | EXPIRED notification (her zaman) |
| Subscription renewal | Transaction.updates (uygulama aciksa) | DID_RENEW notification (her zaman) |
| Grace period baslangici | Client-side kontrol | GRACE_PERIOD notification |
| Billing retry | Client-side kontrol | DID_FAIL_TO_RENEW notification |
| Revocation | Transaction.updates (uygulama aciksa) | REVOKE notification (her zaman) |

---

## Yeniden Degerlendirme

### 1. Consumable Revocation Handling
**Onceki: MEDIUM --> Yeni: LOW**

Backend App Store Server Notifications V2 ile `REFUND` bildirimi alacak. Server-side consumable bakiyesini dusurur. Client SDK'nin local bakiyeyi dusurme zorunlulugu azalir cunku backend source of truth olur.

**Yine de yapilmali:** Client SDK'da `handleVerifiedTransaction()` icinde `revocationDate` kontrolu eklemek hala iyi pratik. Cunku kullanici online olmadan once UI yanlis bakiye gosterir.

---

### 2. Consumable Refund Detection at Boot
**Onceki: MEDIUM --> Yeni: KALDIRILDI**

Bu tamamen backend tarafindan cozuluyor. `REFUND` notification server'a gelir, server bakiyeyi gunceller, client bir sonraki sync'te dogru bakiyeyi alir. Client-side `Transaction.all` taramasi gereksiz.

---

### 3. processedTransactionIDs Buyumesi
**Onceki: LOW --> Yeni: LOW (ama daha az onemli)**

Backend transaction dedup'u handle edebilir. Client-side dedup hala faydali (offline durumlar, Transaction.updates duplicate'leri) ama backend zaten ikinci bir kontrol katmani saglar.

---

### 4. UserDefaults Guvenilirligi
**Onceki: LOW --> Yeni: LOW (ama daha az kritik)**

Backend source of truth oldugu icin UserDefaults sadece local cache olur. Sessiz data loss olsa bile, bir sonraki backend sync'te duzeltilir. Yine de `isProtectedDataAvailable` kontrolu iyi pratik.

---

### 5. Pasif Expiration Handling
**Onceki: PASS --> Yeni: PASS (backend ile daha da gucleniyor)**

`onAppForeground()` + 5-dk TTL hala gerekli (client-side aninda UI guncellemesi icin). Ama backend `EXPIRED` notification alir ve server-side state'i gunceller. Client bir sonraki API call'da dogru state'i alir.

**Onemli:** Client SDK'nin `onAppForeground()` mantigi backend'den bagimsiz olmali. Cunku:
- Offline kullanici
- Backend gecikmeleri
- Aninda UI guncellemesi gerekliligi

---

### 6. Client SDK + Backend Mimarisi Icin Oneriler

```
Kullanici Islem Yapar
     |
     v
[Client SDK] ---> StoreKit 2 ---> transaction.finish()
     |                                    |
     v                                    v
Backend API <--- sync ---> App Store Server Notifications V2
     |
     v
Dogru CustomerInfo --> Client SDK'ya doner
```

**Client SDK'nin backend ile entegrasyonu icin gerekli degisiklikler:**

1. **configure() icinde backend URL parametresi** -- API endpoint
2. **Transaction receipt'i backend'e gonderme** -- Satin alma sonrasi server-side validation
3. **getCustomerInfo() backend'den okuma** -- Local cache + backend sync
4. **Consumable balance backend'den okuma** -- UserDefaults sadece cache
5. **Webhook endpoint** -- App Store Server Notifications V2 icin

---

## Guncel Durum Tablosu (Backend ile)

| # | Kontrol | Onceki Rating | Backend ile Rating | Neden |
|---|---------|---------------|-------------------|-------|
| 1 | Boot sequence | PASS | PASS | Degismez -- client-side SK2 dogrudan |
| 2 | Transaction finishing | PASS | PASS | Degismez -- client MUST finish |
| 3 | Pasif expiration | PASS | PASS | Daha guclu -- backend EXPIRED bildirir |
| 4 | Auto-renewable eval | PASS | PASS | Degismez -- client-side aninda UI |
| 5 | Non-consumable handling | PASS | PASS | Degismez |
| 6 | **Consumable revocation** | **MEDIUM** | **LOW** | Backend REFUND alir, client optional |
| 7 | **Refund delivery gap** | **MEDIUM** | **KALDIRILDI** | Backend REFUND bildirir her zaman |
| 8 | Transaction ID dedup | PASS | PASS | Degismez + backend ek katman |
| 9 | Concurrency model | PASS | PASS | Degismez |
| 10 | Task.detached | PASS | PASS | Degismez |
| 11 | Grace/billing retry | PASS | PASS | Degismez + backend notification |
| 12 | Family Sharing | PASS | PASS | Degismez |
| 13 | Consumable persistence | PASS | PASS | Backend source of truth olur |
| 14 | Non-renewable | PASS | PASS | Degismez |
| 15 | Products pre-fetch | PASS | PASS | Degismez |
| 16 | Entitlement resolution | PASS | PASS | Degismez |
| 17 | CustomerInfo persistence | PASS | PASS | Backend source of truth olur |

---

## Sonuc

Backend ile:
- **0 CRITICAL**
- **0 MEDIUM** (onceki 2 medium backend ile cozuluyor)
- **2 LOW** (consumable revocationDate client check + processedTransactionIDs pruning)
- **15 PASS**

Client SDK'nin mevcut mimarisi backend entegrasyonu icin uygun. Temel degisiklikler:
1. `configure()` icinde backend URL/API key eklenmesi
2. Satin alma sonrasi transaction receipt'in backend'e gonderilmesi
3. `getCustomerInfo()` icinde backend sync opsiyonu
4. Consumable balance'in backend'den okunmasi

**Mevcut client-side SK2 koduna dokunulmasi GEREKMEZ.** Backend katmani uzerine eklenir.
