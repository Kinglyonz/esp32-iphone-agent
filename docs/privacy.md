# ESP32 Agent — Privacy Policy

Last updated: 2026-10-16

ESP32 Agent is an open-source app that lets an AI model of your choice operate your iPhone through a small
ESP32 USB board. The developer runs no servers for it and receives nothing from it, except anonymous usage
stats if you turn them on.

## What the app does with your data

- **Screen and run data.** To decide each step, the app sends screenshots of your iPhone screen and your task
  text to the model endpoint **you** set up (a cloud API or your own server). That provider's privacy policy
  applies to those requests. Nothing is sent anywhere else.
- **On your iPhone only.** Runs (steps, model replies, screenshots, screen video), the debug log and crash
  reports from iOS are stored in the app's own storage. You can delete runs in the app, or delete the app to
  remove everything.
- **API key.** Your model API key is stored in the iOS Keychain on this device and is never written to logs
  or exports.
- **Bluetooth and Wi-Fi.** The app connects to the ESP32 board over Bluetooth and may join the board's own
  Wi-Fi hotspot. It does not scan for or record other devices or networks.
- **Sharing.** Run archives and logs leave the phone only when you export or share them yourself, e.g. to
  attach to a bug report.

## Anonymous usage stats (off by default)

If you turn on "Share anonymous usage stats" (first launch or Settings › Privacy), the app sends a short,
fixed list of events to PostHog (US), which the developer uses to see where setup and runs get stuck:

- setup pages reached and finished; board connected, screen mirroring started, calibration done or failed
  (with its accuracy), the model connection test passing or failing
- run started, blocked (why: model not set, pointer not calibrated) and ended: outcome, number of steps,
  duration, whether it came from a saved intent
- the model provider (e.g. OpenRouter) and, for a known provider, the model ID; never the address or key
- app version, iOS version, device model (e.g. iPhone17,2), language

Each event carries a random ID created on this install; turning the switch off deletes it. No location
(GeoIP is disabled), no person profiles, no IDFA, and never your tasks, screenshots, screen video, typed
text, model replies, API keys or endpoint addresses. Builds made from the source code send nothing.

## What the app does not do

No accounts, no advertising, no tracking across apps or websites, no data sold or shared, and no
third-party SDKs.

## Apple

If you install a TestFlight build or allow "Share with App Developers" in iOS settings, Apple may pass crash
reports and usage statistics to the developer under Apple's own privacy policy.

## Contact

Open an issue at https://github.com/onehumanbeing/esp32-iphone-agent/issues.
