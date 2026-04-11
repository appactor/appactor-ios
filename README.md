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
    .package(url: "https://github.com/appactor/appactor-ios.git", from: "0.0.2")
]
```

### CocoaPods

```ruby
pod 'AppActor', '~> 0.0.2'
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

## Documentation

Visit [appactor.com/docs](https://appactor.com/docs) for full documentation.

## Contributing

- Open an issue for bug reports or feature requests
- Email us at [sdk@appactor.com](mailto:sdk@appactor.com)

## License

MIT License. See [LICENSE](LICENSE) for details.
