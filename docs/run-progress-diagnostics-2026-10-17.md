# Run progress diagnostics

The local debug log separates a run being accepted from a model request starting:

- `run_started` is captured before leaving the app and obtaining the first screen. It does not prove that an HTTP request was sent.
- `model request starting (planner|actor)` is written after the foreground and screen checks, immediately before the model call. It includes the requested model, token limit and image size, without task or prompt content.
- `llm →` includes the actual client's endpoint origin (scheme, host and explicit port), requested model and payload sizes. It excludes URL credentials, path, query and fragment.
- Existing HTTP-header, completion and error lines show whether the server answered and how long the request took. These local diagnostics add no analytics fields.

The phone's build 11 debug log and traces were retrieved on October 17, 2026
(Asia/Shanghai). Neither reported run reached its first model call:

- **04:26:03:** startup reached the background, then its first `snap` waited
  129 seconds before timing out. A retry ended when the board disconnected.
- **04:33:01:** startup reached the background, then `snap` returned
  `err no video (start screen mirroring)` in 22 ms. A mirroring session being
  connected did not establish that its video buffer contained a usable screen.

This explains the missing `model_request` events. The missing `run_ended` events
were a separate startup error-path gap: the catch previously wrote a local trace
but did not capture a terminal analytics event. Both startup failure/cancellation
and normal completion now flush a terminal event immediately. Every completed
model request and model test also flushes immediately, including while backgrounded. Delivery uses a
bounded background execution allowance and retries queued failures on foreground;
these events contain counts and timing, never task or screen content.

The small image test at 04:22:10 took 2.18 seconds with 217 reasoning characters.
It was not a planner benchmark. The imported extra request body had been cleared,
so the intended provider option to disable thinking was absent. The optional
`-llm-extra-body` flag now validates and persists that option without embedding a
provider-specific default. Keep the public HTTPS endpoint because the phone joins
the board's hotspot during a run.

The snap path now rejects a command acknowledgement unless a new, healthy image
was decoded. Its decoder-drain wait is bounded and cancellable, including while
the decoder queue is blocked. Tests cover stale images, delayed decoding, video
sequence gaps after a decoded frame, and cancelling a blocked decoder wait.

Final phone verification: build 13 retained the public endpoint and thinking-disabled
options across an app update and relaunch without configuration flags. Its image
check completed at 04:56:52 in 1.404 seconds, with 0 reasoning characters and 2
completion tokens. The immediate model-test batch was accepted by PostHog at
04:56:52.705. The 123-test signed simulator suite passed; no complete physical
board task was run in this verification.
