<h1 align="center" style="border-bottom: none">
<b>
    <a href="https://appactor.com">
        AppActor
    </a>
</b>
<br>In-App Purchase Infrastructure
<br>for iOS
</h1>

<p align="center">
<a href="https://github.com/appactor/appactor-ios/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
<img src="https://img.shields.io/badge/iOS-15%2B-blue.svg">
<img src="https://img.shields.io/badge/Swift-5.9%2B-orange.svg">
<img src="https://img.shields.io/badge/SwiftPM-compatible-orange.svg">
</p>

AppActor handles in-app purchases, subscriptions, and entitlements so you can focus on building your app.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/appactor/appactor-ios.git", from: "0.1.2")
]
```

### CocoaPods

```ruby
pod 'AppActor', '~> 0.1.2'
```

## Quick Start

```swift
// Configure once
await AppActor.configure(apiKey: "pk_YOUR_API_KEY")

// Fetch offerings
let offerings = try await AppActor.shared.offerings()

// Make a purchase
let result = try await AppActor.shared.purchase(package: offerings.current?.monthly!)

// Check entitlements
let isPremium = AppActor.shared.customerInfo.hasActiveEntitlement("premium")
```

## Payment Restore & Retry Policy

`configure()` starts the SDK, identifies the local AppActor user, fetches offerings,
starts the StoreKit watcher, drains any locally queued receipts, and refreshes
customer info. It does **not** call `AppStore.sync()`, auto-restore the full
StoreKit history, or quietly scan all historical purchases during startup.

For anonymous users, an app reinstall creates a new local AppActor user unless
your app passes a stable `appUserId`. To recover previous App Store purchases
after reinstall, call `syncPurchases()` from your own account recovery flow or
show a user-triggered restore button that calls `restorePurchases()`.

Apps with their own account system should configure AppActor with the same stable
`appUserId` for that account on every install. That keeps entitlements attached to
the account and avoids relying on restore as the primary identity mechanism.

Consumable, token, and credit products should be granted only after your backend
accepts the receipt and AppActor returns an `ok` receipt result/customer update.
Retryable receipt failures remain queued for later delivery and should not be
treated as final backend credit grants.

## Documentation

Visit [appactor.com/docs](https://appactor.com/docs) for full documentation.

## Contributing

- Open an issue for bug reports or feature requests
- Email us at [sdk@appactor.com](mailto:sdk@appactor.com)

## License

MIT License. See [LICENSE](LICENSE) for details.
