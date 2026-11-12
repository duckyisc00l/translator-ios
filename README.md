# Translator (iOS)

An offline Spanish ⇄ English translator for iPhone with a Google-Translate-style look.

- **Offline translation** with Apple's on-device Translation engine (iOS 18+). Download the languages once, then it works in airplane mode.
- **Smart translation** (iPhone 15 Pro or newer, iOS 26 with Apple Intelligence): a second on-device pass makes the result sound natural, offers other ways to say it, explains idioms and slang, and lets you pick informal (tú) or formal (usted) and Latin America or Spain Spanish.
- Voice input (on-device speech recognition), read aloud, copy, share, history and saved (starred) translations, auto-detect "Translate from Spanish?" suggestion.
- 20 languages available; Spanish and English are the defaults.

## Build

Every push to `main` builds an unsigned `Translator.ipa` with GitHub Actions and attaches it to a new release. Install it with Sideloadly, AltStore or SideStore.

Project is generated with XcodeGen (`project.yml`).
