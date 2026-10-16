# Dynamic Island phase visibility

Source baseline: `b43cd82` on `codex/ios-lan-provider`.

The minimal presentation used while Screen Mirroring shares the island displayed
only a 24-point face. Its phase description was an accessibility label, so sighted
users saw no status text. This came from `15ca11f`, replacing the text-only minimal
layout in `6e45665`; the earlier face-over-caption layout in `72d65e2` had already
been reported as cramped.

The minimal presentation now prioritizes a single explicit phase label in its
36-by-24-point content area: Wait, Plan, Think, Tap, Board, Help, or the outcome.
It preserves the complete status for VoiceOver. Empty legacy state labels fall
back to a safe status, never raw model or step detail. Compact and expanded
presentations retain the character with internal margins of 3 and 4 points.
Idle gaze updates remain disabled.

Recovery distinguishes a missing Screen Mirroring session from an active session
that has not delivered a fresh decoded image. The latter immediately says that
mirroring is connected, with a minimal Frame label. It waits 20 seconds before
suggesting restarting mirroring, and requires an image timestamp newer than the
recovery start before continuing. Focused tests cover the timestamp boundary,
the independent waiting interval, and avoiding model calls while no image exists;
the final integrated signed simulator suite passes all 123 tests.

Startup status vocabulary includes going to the Home Screen, a lost board
connection, and a board that is not responding. The full guidance explains moving
the board closer and continuing after it reconnects. App and widget catalogs include
Chinese translations; startup wiring is handled by the run-start changes.

Validation: seven `IslandTests` passed on the existing iOS 18.6 simulator, including
phase-label priority, full accessibility text, legacy/empty states, and a SwiftUI
ImageRenderer attachment showing the actual minimal view plus inset face sizes.
Catalog JSON is valid with unique keys. The test result is
`/private/tmp/ia-island-status-tests.xcresult`; exported preview is
`/private/tmp/ia-island-status-preview/B86D27D8-AC24-4678-8F42-BB83B2595F2D.png`.

The preview verifies the view content, not ActivityKit's final system composition.
Build 13 was installed on the phone. Simultaneous Screen Mirroring and Live
Activity rendering still needs visual verification during the next hardware run. Deployment target remains
iOS 18.0.
