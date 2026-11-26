# 智音 Privacy Policy

智音 (Zhiyin) is a self-use translation app. It has no account system, no ads, and no analytics. It does not run its own server.

## What goes where

智音 only sends data to the services you configure, over HTTPS, and only when you use the matching feature:

- **Text, photo, and PDF translation** — the text to translate (and, for PDF, the text extracted from the document) is sent to the translation provider you selected in Settings: DeepSeek by default, or Tongyi Qwen-MT when you use it as the backup. The model returns a translation; nothing else is uploaded.
- **Voice input and live interpretation** — microphone audio is sent to Volcano (Doubao) speech services for recognition and synthesis. No audio is stored by 智音 after the session.
- **“我的声音” voice cloning** — the voice samples you record are sent to Alibaba (DashScope / Qwen-Audio) to create your personal voice. The samples and the cloned voice live in your Alibaba workspace, not in 智音.
- **Camera / photo OCR** — text recognition on photos runs on-device with Apple's Vision framework; the image never leaves your phone for OCR.

No other data leaves the device. 智音 never uploads your history, glossary, or settings to any 智音-operated server (there is none).

## API keys

There is **no built-in default key**. Every provider key is one you type yourself in Settings, and it is stored only in the iOS Keychain on your device. Keys are never written into the app's code, never synced, and never sent anywhere except as the Authorization header of your own requests to that provider.

## Local storage

Providers, prompts, glossary, settings, translation history, and in-progress PDF translations are stored on your device (local database and app storage). They are not uploaded by 智音 to anyone.

## Third-party providers

DeepSeek, Tongyi (Alibaba), and Volcano (Doubao) process requests under their own terms and privacy policies. Only send text or audio that you are comfortable sharing with the provider you selected.

## Analytics and tracking

智音 does not use advertising identifiers and does not track you across apps or websites.

## Contact

For support or privacy questions, open an issue at:

https://github.com/yonghuxieyi/zhiyin/issues
