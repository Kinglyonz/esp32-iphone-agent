# iOS provider and telemetry verification — 2026-10-17

All times below are Asia/Shanghai.

## Source and installed app

- Source: clean `ios-analytics`, `08b8168e2e7c4c0d6bf58e2a504bdd919a7f5d6d`.
- Isolated implementation: `codex/ios-lan-provider`.
- Final installed app: `com.onehumanbeing.esp32agent`, version 1.0 (11), iPhone 17 Pro Max (`iPhone18,2`). Existing settings and history were retained.
- Runtime configuration: the existing `https://llm.henryht.sh/v1` interface and `qwen3.8-flash-next-nvfp4`. These values were passed at launch, not embedded in app defaults or source. The API key was injected through Henry Secret and saved by the app in Keychain.
- No temporary LAN relay or direct DGX SSH tunnel was started. The unused development app installed during initial signing verification was removed after confirming it had no Documents content.

## Functional verification

- The built-in red-image model check returned `Red` in 2.410 seconds at 04:19:36 on build 10.
- After updating to build 11, the same check used the saved configuration without reinjecting the key and returned `Red` in 2.184 seconds at 04:22:10.
- `Wi-Fi settings` was deleted through the app's `IntentStore` at 04:22:08. Preferences read-back confirmed the other three intents remained: `8 AM Mon & Tue alarm`, `Draw a smiley`, and `Note: hello`.
- Final signed simulator suite: 89 tests passed. Signed physical-device build succeeded. This verifies provider connectivity and an image check, not a complete physical board task.

## PostHog evidence

Project: ESP, 668204.

- Before this session, October 16–17 contained only `pipeline_test` at October 16 14:06:04, with app version `test` and no build/device information. This did not establish ingestion of the afternoon phone tests.
- Real `app_opened` arrived at October 17 04:16:20: app version 1.0, build 10, device `iPhone18,2`.
- Real `model_test` arrived at 04:19:36: build 10, `ok=true`, no error, first token 2.40 s, total 2.41 s, response headers 1.48 s, provider `others`.
- The existing statistics consent remained enabled. The test build's capture configuration came from Henry Secret; no credential was committed or placed in command arguments.

## Same-network route check

Five separate HTTP health requests per route, with a new curl connection each time; all returned HTTP 200. The existing Mac mini LAN route was used. No routing, proxy, DNS, or service configuration was changed.

| Route | Median total | Range | Median first byte |
| --- | ---: | ---: | ---: |
| MacBook → existing LLM HTTPS health endpoint | 876.67 ms | 810.03–1,062.44 ms | 876.36 ms |
| Mac mini → same LLM HTTPS health endpoint | 1,604.69 ms | 1,500.60–2,012.59 ms | 1,604.13 ms |
| Mac mini → existing loopback gateway health endpoint | 0.87 ms | 0.86–0.99 ms | 0.84 ms |

The existing HTTPS hostname continued through Cloudflare; sharing the LAN did not automatically select the local gateway. In this sample the Mac mini's HTTPS path was slower. The loopback measurement demonstrates a local gateway's network overhead only; it is not an exposed phone endpoint or a model-speed result. These health checks exclude DGX inference, and app connection reuse can reduce the new-connection overhead seen here. No authenticated inference comparison was run from the Mac mini.

Temporary DGX secret grants for the probe and device launcher were revoked after configuration. The phone retains its authorized Keychain configuration.
