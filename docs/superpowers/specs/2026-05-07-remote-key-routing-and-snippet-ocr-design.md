# Remote Key Routing & Snippet-OCR — Design

Date: 2026-05-07
Status: Approved (pending implementation plan)

## Goal

Two user-visible changes to Overlook's in-session input handling:

1. **Keyboard routing:** While the Overlook window is focused and keyboard
   capture is active, forward all command-combos to the remote by default —
   including `cmd+C` and `cmd+V`. Three explicit exceptions stay local:
   `cmd+Tab`, `option+Tab`, and everything with `cmd+shift+*`.
2. **Replace OCR mode with a one-shot snippet tool:** Remove the current
   "toggle OCR mode + live text overlay + result sheet" flow. Add a
   `cmd+shift+C` shortcut that opens a single drag-to-select overlay on the
   remote video; the selected region is OCR'd and the recognized text is
   copied straight to the Mac clipboard.

## Non-Goals

- No global/system-wide hotkey for the snippet tool. It only works when the
  Overlook window is focused.
- No OCR of the actual macOS screen. Capture targets the remote video
  frame, not the desktop. No ScreenCaptureKit dependency, no new
  permissions.
- No changes to mouse routing, WebRTC, or HID protocol.
- Existing menu-bar `cmd+shift+V` (Quick Connect) and `cmd+shift+R` (Scan)
  global shortcuts remain unchanged.

## Current behavior (baseline)

Relevant files: [Overlook/InputManager.swift](../../../Overlook/InputManager.swift),
[Overlook/OCRManager.swift](../../../Overlook/OCRManager.swift),
[Overlook/OCRViews.swift](../../../Overlook/OCRViews.swift),
[Overlook/VideoSurfaceView.swift](../../../Overlook/VideoSurfaceView.swift),
[Overlook/ContentView.swift](../../../Overlook/ContentView.swift),
[Overlook/MenuBarAgent.swift](../../../Overlook/MenuBarAgent.swift).

- `InputManager.handleKeyEvent` intercepts `cmd+C` (keyCode 8) to toggle
  OCR mode and `cmd+V` (keyCode 9) to call `pasteClipboardToRemote()`,
  which types the Mac clipboard to the remote via the GLKVM HID "print
  text" API. All other `cmd+X` (including `cmd+shift+X`) are forwarded to
  the remote as `Meta+Key` via the GLKVM WebSocket.
- OCR mode, once toggled on, runs a periodic `detectTextRegions` task that
  paints green Live-Text-style boxes over the video. A drag selects a
  region; on release, `recognizeTextInRegion` runs and the result appears
  in an `OCRResultView` sheet with Copy/Close buttons.
- `MenuBarAgent` registers `cmd+shift+O` as a global OCR toggle (only
  fires when Overlook is not focused).

## Target behavior

### Keyboard routing rule (in-session, capture enabled)

Evaluation happens inside
`NSEvent.addLocalMonitorForEvents`-based `handleKeyEvent`:

| Key event                                                | Handling                                               |
|----------------------------------------------------------|--------------------------------------------------------|
| `cmd+Tab` (keyCode 48, `.command` only)                  | Local. Return event unchanged; nothing sent to remote. |
| `option+Tab` (keyCode 48, `.option` only)                | Local. Return event unchanged.                         |
| `cmd+shift+V` (keyCode 9 + `.command`+`.shift`)          | Local, consumed. Runs `pasteClipboardToRemote()`.      |
| `cmd+shift+C` (keyCode 8 + `.command`+`.shift`)          | Local, consumed. Posts `.overlookStartSnippet`.        |
| any other `cmd+shift+*`                                  | Local. Return event unchanged.                         |
| any other `cmd+*` (incl. `cmd+C`, `cmd+V`, `cmd+Q`, …)   | Remote, as today (`Meta+Key` via HID).                 |
| everything else                                          | Remote, as today.                                      |

The rule only applies while `isKeyboardCaptureEnabled` is true. When
capture is off (e.g. Settings panel open), all keys are local — unchanged
from current behavior.

Modifier forwarding subtlety: cmd is already buffered today (sent to
remote only when paired with a non-modifier key,
[InputManager.swift:297-302](../../../Overlook/InputManager.swift#L297-L302)),
so a `cmd+shift+*` that turns out to be local never sends cmd-down to the
remote. Shift and option continue to be forwarded on `flagsChanged`
immediately (needed for remote-side typing of shifted characters and
alt-combos); when a combo turns out to be local, the already-forwarded
shift/option-down stays in effect on the remote until the user releases
the modifier on the Mac, at which point the normal flagsChanged handler
sends the matching modifier-up. Brief, harmless stickiness on the remote.

### Snippet-OCR flow

1. `cmd+shift+C` in `InputManager` consumes the event and posts
   `NotificationCenter.default` notification `.overlookStartSnippet`.
2. `VideoSurfaceView` observes this and flips new state
   `isSnippetModeActive = true`. While active:
   - A transparent overlay sits over the video and captures drag gestures
     (reuses the current blue selection-rectangle drawing from
     `OCRSelectionOverlay`, minus the green text-region boxes).
   - Mouse routing to the remote is disabled for the duration (same
     `guard !isSnippetModeActive` pattern currently used for
     `isOCRModeEnabled`).
   - Escape cancels the mode without an OCR attempt (see "Key handling
     while snippet mode is active" below).
3. On drag end:
   - A click or tiny rectangle (smaller than ~4×4 pt in view space) is
     treated as a cancel — no OCR, just exit the mode.
   - A valid rectangle is normalized into video coordinates (same math
     as current `performOCR(inViewRect:in:)`,
     [VideoSurfaceView.swift:283-321](../../../Overlook/VideoSurfaceView.swift#L283-L321)),
     then passed to `OCRManager.recognizeTextInRegion(region, in:
     webRTCManager.currentFrame)`.
4. Result handling:
   - Success with non-empty text → `NSPasteboard.general` is cleared and
     the text is written as `.string`. A brief HUD toast
     (`"Text kopiert"`, SwiftUI view overlayed top-center of the video,
     auto-hides after ~1.5 s) provides feedback. No modal sheet.
   - Success but empty result / `OCRError.noTextFound` → HUD toast
     `"Kein Text erkannt"`, clipboard untouched.
   - Other errors → HUD toast with a short error string, clipboard
     untouched. Error is also logged via `print` (consistent with current
     code).
5. `isSnippetModeActive = false` at the end of every path (success,
   cancel, error).

### Key handling while snippet mode is active

`InputManager` exposes a `setSnippetModeActive(_:)` method. While active:

- Every keyDown/keyUp is consumed (returned `nil` from the local monitor)
  and nothing is forwarded to the remote. This prevents stray typing from
  reaching the remote while the user is drawing the selection rectangle.
- Escape (keyCode 53) on keyDown posts `.overlookCancelSnippet`, which
  `VideoSurfaceView` observes and treats identically to a click-without-
  drag cancel.
- Modifier flagsChanged events are also swallowed while the mode is
  active; when the mode exits, the `InputManager`'s own modifier state
  (`pendingCommandKeyCode`, `activeCommandKeyCode`, etc.) is reset so no
  stale state carries over.

`VideoSurfaceView` calls `inputManager.setSnippetModeActive(true)` when
activating the overlay and `setSnippetModeActive(false)` on every exit
path.

`WebRTCManager.setFrameCaptureEnabled(true)` is toggled on at the moment
the snippet mode activates and toggled off again after OCR completes —
this replaces the current behavior where frame capture stays on for the
entire time OCR mode is enabled.

### Removed / renamed

- `isOCRModeEnabled` state + bindings → removed.
- Toolbar button "Enable/Disable OCR Selection" (both normal and
  fullscreen hover toolbars in `ContentView`) → removed.
- `OCRResultView` sheet and its `isShowingOCRResult` / `selectedText`
  bindings → removed.
- `OCRSelectionOverlay`'s live-text region drawing → removed. The blue
  drag-rectangle drawing is salvaged into a new, simpler
  `SnippetSelectionOverlay`.
- Periodic `detectTextRegions` task in `VideoSurfaceView.setOCRMode` →
  removed.
- `OCRManager`: `detectTextRegions`, `textObservationRequest`,
  `performTextDetection`, `recognizedRegions`, `handleTextObservation`,
  `getTextAtLocation`, and the point-based `recognizeText(at:in:)` /
  `performTextRecognition(at:in:...)` path → removed. Only
  `recognizeTextInRegion` + its helper `performRegionTextRecognition`
  survives.
- `MenuBarAgent` `cmd+shift+O` handler + corresponding menu item →
  removed.
- Notification `.overlookToggleCopyMode` → renamed to
  `.overlookStartSnippet`.

### New

- Notifications `Notification.Name.overlookStartSnippet` and
  `Notification.Name.overlookCancelSnippet`.
- `@State var isSnippetModeActive: Bool` in `VideoSurfaceView` (or a
  small `SnippetController` helper if the view body grows awkward).
- `SnippetSelectionOverlay` SwiftUI view (successor to
  `OCRSelectionOverlay`).
- `SnippetHUD` SwiftUI view for the toast.
- `InputManager.shouldKeepLocal(...)` helper returning a small enum of
  local actions (`passthrough | pasteClipboard | startSnippet`).

## Components and interfaces

### `InputManager`

```swift
private enum LocalKeyAction {
    case passthrough          // cmd+Tab, option+Tab, other cmd+shift+*
    case pasteClipboard       // cmd+shift+V
    case startSnippet         // cmd+shift+C
}

private func localActionFor(keyCode: UInt16,
                            modifiers: NSEvent.ModifierFlags) -> LocalKeyAction?
```

`handleKeyEvent`'s `.keyDown` branch calls `localActionFor` first:

- `nil` → existing remote-forwarding logic runs.
- `.passthrough` → clear any pending cmd state, do not forward anything,
  allow event through.
- `.pasteClipboard` → clear pending cmd, consume event, call
  `pasteClipboardToRemote()`.
- `.startSnippet` → clear pending cmd, consume event, post
  `.overlookStartSnippet`.

Key-up events for `keyCode 8` / `keyCode 9` that were part of local
actions use the existing `suppressedKeyUps` set so they are not leaked to
the remote.

### `VideoSurfaceView`

- New `@State private var isSnippetModeActive: Bool = false`.
- `.onChange(of: isSnippetModeActive)` calls
  `inputManager.setSnippetModeActive(_:)` and
  `webRTCManager.setFrameCaptureEnabled(_:)` to keep those in sync.
- `.onReceive(NotificationCenter.default.publisher(for: .overlookCancelSnippet))`
  sets `isSnippetModeActive = false`.
- Existing OCR-mode drag logic at
  [VideoSurfaceView.swift:100-128](../../../Overlook/VideoSurfaceView.swift#L100-L128)
  is simplified (no click-to-OCR small-area, no "are we near a region"
  logic; just drag → rect → OCR).
- `.onReceive(NotificationCenter.default.publisher(for: .overlookStartSnippet))`
  triggers `isSnippetModeActive = true` and briefly enables frame capture.
- Mouse passthrough guards change from `!isOCRModeEnabled` to
  `!isSnippetModeActive`.

### `OCRManager`

Trimmed to a single request (`textRecognitionRequest`) and a single
public async entry point:

```swift
func recognizeTextInRegion(_ region: CGRect,
                           in pixelBuffer: CVPixelBuffer?) async throws -> String
```

Plus a small convenience:

```swift
func copyTextToClipboard(_ text: String)  // already exists, kept
```

`region` is normalized to the video (0…1), same as today. On empty result
the function throws `OCRError.noTextFound` so the caller can branch into
the "kein Text erkannt" toast.

### `ContentView`

- Remove `isOCRModeEnabled`, `isShowingOCRResult`, `selectedText` state
  and their bindings to `VideoSurfaceView`.
- Remove the OCR toolbar button in both the regular toolbar and the
  fullscreen hover controls.
- Remove the `.sheet(isPresented: $isShowingOCRResult)` attached to the
  body.
- Remove the `.onReceive(...overlookToggleCopyMode)` handler.

### `MenuBarAgent`

- Remove `cmd+shift+O` case from `handleGlobalKeyEvent`.
- Remove the "Toggle OCR" menu item if present.
- Keep `cmd+shift+V` (Quick Connect) and `cmd+shift+R` (Scan Devices).

## Error handling

- OCR failures (empty result, Vision error) surface only through the HUD
  toast; they never block the UI, never open a sheet.
- Snippet cancellation (Escape, tiny rect) is silent — no toast, no
  clipboard write.
- Paste-to-remote errors keep the existing behavior (logged via `print`
  at [InputManager.swift:382](../../../Overlook/InputManager.swift#L382)).

## Testing

Primarily manual, exercised against a live GLKVM session. Checklist:

- In-session shortcuts route as specified in the table above:
  - `cmd+C` produces `Meta+C` on remote; `cmd+V` produces `Meta+V` on
    remote; old clipboard-bridge is gone from `cmd+V`.
  - `cmd+shift+V` types the Mac clipboard to the remote via HID print.
  - `cmd+shift+C` opens the snippet overlay.
  - `cmd+Tab` switches macOS apps without sending anything to remote.
  - `option+Tab` passes through without sending anything to remote.
  - `cmd+shift+<letter>` does not reach the remote (letter does not show
    up in remote keystrokes).
  - Disabling keyboard capture (Settings panel open) restores full local
    behavior for every combo.
- Snippet flow:
  - Drag selects a region → clipboard contains recognized text, HUD
    shows "Text kopiert", snippet mode exits.
  - Drag over text-less area → HUD "Kein Text erkannt", clipboard
    untouched.
  - Click without drag or tiny rect → mode exits silently.
  - Escape during snippet mode → mode exits silently.
- Old OCR surfaces gone: no OCR toolbar button, no green live-text
  overlay, no Recognized Text sheet, no `cmd+shift+O` global toggle.
- Regression sweep: paste-to-remote via `cmd+shift+V` still produces the
  same HID print output that the old `cmd+V` did; WebRTC mouse routing
  unaffected; fullscreen hover toolbar unaffected apart from the removed
  button.

Unit tests are not added — there is no existing unit-test harness in the
repo and the logic lives in view/event layers that are hard to isolate.

## Follow-ups explicitly out of scope

- No changes to the Cocoa menu structure beyond removing the stale OCR
  items.
- README update to reflect the new shortcuts is a doc-only follow-up; it
  is included in the implementation plan but listed as a separate step.
