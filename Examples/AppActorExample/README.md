# AppActor Example App

A modern SwiftUI app for testing the AppActor Billing SDK on a real device.

## Setup

### 1. Open the project

```bash
open Examples/AppActorExample/AppActorExample.xcodeproj
```

### 2. Configure signing

In Xcode, select the **AppActorExample** target > **Signing & Capabilities** and set your **Team**.

### 3. Run on device

Select your iPhone and press **Cmd+R**.

### 4. Replace the placeholder API key

Open `AppActorExample/App/AppState.swift` and replace `pk_your_public_api_key` with your real public API key (starting with `pk_`).

## Manual Test Steps

### Happy path

1. **Launch** — the app auto-configures on startup using the API key from `App/AppState.swift`
2. **Login** — enter a user ID and tap Login to switch identity
3. **Fetch Offerings** — tap to see available offerings, packages, and products
4. **Fetch Customer** — tap to see server customer info
5. **Is Premium?** — check premium status
6. **Logout** — tap Logout to reset to a new anonymous identity
7. **Reset** — tap Reset to fully wipe SDK state and start fresh

### Console output

After each action, the console panel shows:

- **Status badge** — colored status hint (green=200, yellow=304, red=error)
- **Request ID** — server-assigned request ID for debugging
- **Output** — pretty-printed JSON response or formatted data

### Error handling

- Try fetching before configuring — shows "not configured" error
- Try an invalid API key — shows server error with HTTP status
- Go offline — shows network error

### Reset vs Logout

- **Configure** — immediately establishes the local identity (reuses cached ID or creates a new anonymous one)
- **Logout** — local-only identity switch to a fresh anonymous ID
- **Reset** — local-only full wipe of all SDK state (clears everything, requires reconfigure)

## Project Structure

```
Examples/AppActorExample/
├── AppActorExample.xcodeproj/    # Xcode project (local SPM dependency on ../../)
├── AppActorExample/
│   ├── AppActorExampleApp.swift  # App entry point
│   ├── App/                      # AppState, tabs, splash, logs
│   ├── Features/                 # Configure, identity, offerings, customer, restore, diagnostics
│   ├── DesignSystem/             # Shared cards, buttons, theme, helper views
│   └── Assets.xcassets/          # App icon & accent color
└── README.md
```

The Xcode project references the AppActor package via a **local path dependency** (`../..`), so any changes to the SDK source are immediately reflected when you build.
