# Completion

Gate: `"${CODEX_HOME:-$HOME/.codex}/scripts/gate" --root "$PWD" --profile other` — PASS (common, other, and Git diff checks).

Evaluator:
NOT RUN — pending packaged-app read-back after the user handles the macOS Keychain authorization dialog.

Correction or repair context:
The user reported that Start still did not work after the prior PASS. External Accessibility reproduced a packaged Start press that left the popover unchanged because the detached SwiftUI alert was not presented. The proof was strengthened to require an inline confirmation, Continue, and Cancel inside the actual popover before activation. A separate AppKit/shadow-state race exposed during proof was repaired by deriving visibility from `NSPopover.isShown` and the actual window.
