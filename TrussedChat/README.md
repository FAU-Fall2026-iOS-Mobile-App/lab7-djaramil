# TrussedChat

Minimal SwiftUI iOS chat client for the FAU CoECS **Trussed AI** OpenAI-compatible chat completions API.

- **Endpoint (default):** `https://trussed.eng.fau.edu/provider/generic/chat/completions`
- **Model (default):** `gemma4-vibe`
- **Deployment target:** iOS 17.0
- **Swift:** 5.0 (SwiftUI + `URLSession`, no third-party packages)

## Requirements

- Xcode 26.x (or recent Xcode 16+) with the iOS SDK
- A Trussed API key from FAU CoECS (never commit it to git)

## Open in Xcode

1. Copy or clone this folder onto your Mac.
2. Open `TrussedChat.xcodeproj`.
3. Select the **TrussedChat** scheme and an iOS Simulator (or device).
4. Build and run (**⌘R**).

### Command-line build

```bash
xcodebuild -project TrussedChat.xcodeproj \
  -scheme TrussedChat \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## API key (priority order)

The app never embeds a key in source. Resolution order:

1. **Keychain** — save in the in-app **Settings** sheet (highest priority).
2. **Environment variable** — Xcode → **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**, add `TRUSSED_API_KEY`.
3. **Info.plist / build setting** — copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` (gitignored) and set:

   ```
   TRUSSED_API_KEY = your_key_here
   ```

If no key is available at runtime, an inline banner explains how to configure one; the project still **builds** without `Secrets.xcconfig`.

## App features

- Multi-turn chat with scroll-to-latest and a typing indicator
- User bubbles (accent/blue, right); assistant bubbles (secondary background, left, selectable text)
- Toolbar: clear conversation, Settings (model, endpoint URL, API key)
- Errors show HTTP status and a response snippet (extra tips for 401/403/404)

## Project layout

```
TrussedChat/
├── TrussedChatApp.swift
├── Models/ChatMessage.swift
├── Services/TrussedAPIClient.swift
├── Services/KeychainStore.swift
├── ViewModels/ChatViewModel.swift
├── Views/ChatView.swift
├── Views/SettingsView.swift
├── Assets.xcassets/
└── Info.plist          # TRUSSED_API_KEY = $(TRUSSED_API_KEY)
Config/
├── Project.xcconfig    # #include? "Secrets.xcconfig"
└── Secrets.xcconfig.example
```

## Security notes

- Do **not** commit `Config/Secrets.xcconfig`.
- Prefer Keychain on device over checked-in configuration.
- Follow the FAU CoECS Student Guide for Trussed API usage.

## License

Educational sample for FAU CoECS Trussed AI. Use responsibly.