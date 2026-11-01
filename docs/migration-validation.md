# Window identity migration: lifecycle validation

Validation date: 1 November 2026. This report separates deterministic model
coverage from the later, explicitly authorized native trial. The original
source and configuration checkouts remain intact; the installed app has been
switched between isolated candidate and rollback packages.

## Current native trial

The identity candidate was installed and exercised with ordinary moving,
resizing and closing. Both directions of the isolated old/new switch have been
tested. Wallpaper flicker persisted with AeroSpace fully exited and was resolved
by selecting fixed 144 Hz on the two affected displays; no border or lifecycle
source change was needed for that symptom.

The subsequent launch-placement candidate captures the destination workspace
before app activation. Its first version passed the complete repository gate
and 673 Swift tests. Native testing then exposed three integration gaps that
mocked tests did not cover: Ghostty's lowercase executable name, missing Finder
LaunchServices dates plus its non-window desktop accessibility entry, and the
need for app adapters to activate the exact window they create.

The corrected Ghostty adapter has passed a right-monitor placement/focus trial.
The Comet adapter has passed the same trial with creation-time bounds: its first
sampled visible frame was already on the requested monitor. Six earlier trials
verified logical placement across all three monitors but failed full focus
acceptance; those are not counted as complete UX passes. Existing windows were
preserved and starting workspace/focus restored after each trial.

Finder's native bridge repair and the complete integrated launch trial are
pending. The usual live launcher has been restored while those repairs are
verified. These checks do not establish completion of the full macOS lifecycle
checklist or long-term daily-use acceptance.

## Initial offline acceptance (historical)

The packaged source is `5d331fa5de90e5a967a029ae892cacd635345083`, version
`0.21.3-window-identity-candidate`. Later documentation-only commits do not change
that package's source revision. The isolated switcher is verified at `6c4cdf0`
in the `migration/window-identity-switching` branch of aerospace-config.

| Completed check | Result |
| --- | --- |
| Complete Swift suite | 652 tests, zero failures |
| Standard-use simulations | 24 scenarios, six fixed seeds, 600 mixed rounds and 1,801 checked transitions after repair |
| Focused lifecycle repair coverage | 22 additional tests, including delayed floating drag/drop replies |
| Parent's clean repository `./test.sh` | PASS: warnings-as-errors, tests, CLI help/version, lint, generation and clean-tree gate |
| Switcher tests | 55 pass; parent and independent reviewer reran them |
| Independent review | Both findings reproduced or confirmed, repaired and closed; no further defect found in the narrow follow-up |
| Signed release | Apple Silicon and Intel app/CLI pass signature, embedded revision and repository release validation |
| Real read-only preflight | Both candidate and rollback packages pass against the running legacy server; no switch performed |

Two complete clean release builds passed before the final floating-drag guard.
The final release reused build products, omitting only Xcode's clean step and
limiting its jobs to four; all release generation, signing, packing and validation
steps remained enabled. The final package manifest records hashes of the signed
app executable and CLI and their exact source revision.

Packages are isolated under `~/.local/share/aerospace-migration-builds/`:
`window-identity-5d331fa5` and `known-good-d33ab826`. The latter is byte-for-byte
identical to the installed app and CLI. The existing switcher does not list this
separate build root. Use the isolated aerospace-config-migration switcher for
both directions; its README contains preflight, trial and rollback commands.
It restores workspace assignments and ordinary floating/tiling state, not exact
trees, floating frames or native fullscreen/hidden/minimized state.

At this checkpoint, the candidate was ready for a controlled trial of Alpha on
upstream's new identity model. No candidate app had yet been launched or switched;
the original checkout, installed app/CLI, configuration and helper links were
verified unchanged after packaging and preflight. The current trial status above
supersedes that earlier runtime state.

## Automated coverage

`Sources/AppBundleTests/LifecycleSimulationTest.swift` runs complete command and
layout sequences. Every scenario checkpoint runs the real Focus Mode focus sync,
workspace layouts, and invariants: logical/native identity uniqueness, tree
membership, workspace/monitor ownership, workspace object uniqueness, finite
positive weights/frames, and live automatic workspace focus. Logical IDs start
above the 32-bit native-ID range. Explicit `focus --window-id` may activate an
invisible window, as intended.

The harness supplies windows, processes and native replies, not a replacement
implementation of enumeration, close handling, focus holds, or reconciliation.
Native tab tests call the production candidate/remap functions. The AX reply
hook captures a frame or size, applies a remap, then returns the captured reply;
this deterministically models a read that completes after its native window has
changed. It does not exercise macOS AX threads or private focus APIs.

| Daily-use sequence | Automated model coverage | Checkpoints | macOS-only portion |
| --- | --- | ---: | --- |
| Browser windows on three workspaces/monitors | Same process; create pairs, focus, resize +/−, close background and focused windows, leave workspace empty, reopen with new identity, intentional workspace switch; real close-hold policy rejects remote survivor | 24 | Actual garbage collection creates the hold, window-closed delivery, native key-window fallout and empty-workspace keystroke capture |
| Interleaved apps and dialog | Distinct process identities; editor floating dialog over browser, resize/center, close focused dialog and background browser; independently managed windows cannot remap | 8 | AX dialog classification, Cmd-Tab and native activation/focus delivery |
| Native fullscreen | Nested unequal adaptive layout; enter, layout and normalize, exit; unrelated floating creation/closure; later neighbour move/close/new tiled window and safe fallback | 13 | Native Spaces notifications, app-owned fullscreen geometry and AX enumeration timing |
| Focus Mode | Three monitors, middle stage and `--stay-on-monitor`; width/height +/−, same-app focus changes, background creation/close, workspace switch/return and exit; user offsets and underlying weights checked | 27 | Dimmer, native raising, keyboard routing and visual appearance |
| Move and resize | Tiled workspace/monitor moves, floating conversion and monitor move, smart/width/height +/−, centering/bounds, app-refused minimum confirmation and balance reset | 22 | Actual app minima, frame refusal/asynchronous application and monitor constraints |
| Invisible placeholders | Sixteen nested adaptive hide/return cycles, no writes/weight donation to hidden node, visible sibling reclaims height, explicit hidden-ID focus, exact restored frames/order | 67 | Native visibility observations and `MacApp.reconcileKnownWindows` automatic focus repair; direct lifeStatus changes do not claim to test that orchestration |
| Minimize/restore | Four cycles through production `normalizeLayoutReason`, no-workspace minimize event, no-prevWorkspace restore event, stable logical identity/focus | 9 | AX minimize attribute and Dock restoration notification delivery; app-hide follows a MacApp-only path |
| Native tabs under Focus Mode | Eight remaps during pending minimum reads; logical tree/weights/focus/offsets retained, native mapping updated, stale minimum discarded, no spurious move/hold; close/new and ambiguous transitions rejected | 13 | Complete/incomplete enumeration snapshots, detecting actual tab groups, close/detect notification delivery and queued AX writes |
| Monitor lifecycle | Five all-off → one-display → three-display cycles during Focus Mode; populated workspaces return to homes/visibility with same objects, focused window and user sizing | 20 | Display/wake notifications and delayed refresh, hardware resolutions/Dock changes, macOS moving windows |
| Late floating resize frame | Remap during floating resize's AX frame read; replacement's own frame must survive the old reply | 2 | AX async scheduling and frame-job cancellation |
| Late Focus Mode frame | Remap during floating Focus Mode start; exit must not restore previous native tab's frame | 3 | AX async scheduling and native tab geometry |
| Seeded workdays | 120 mixed rounds for each of 1/2/3 monitors; focus, resize, move, float/tile, creation/background closure, Focus Mode, invisibility/return, balance and workspace changes; invariants after every checkpoint | 810 | Uses synthetic topology/visibility and direct command execution; no desktop stress test |

The three fixed stress seeds are `0xA110`, `0xB220`, and `0xC330`. Each runs 270
checked transitions (810 total). The suite has 1,018 checkpoints in the original twelve tests, including
batched opening/closing setup steps. A failure reports its seed, action index,
command/transition, focus, and workspace tree. Reproduce with:

```sh
PATH=/opt/homebrew/bin:$PATH \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swiftly run swift test --jobs 4 --filter LifecycleSimulationTest
```

## Expanded standard-use combinations

`StandardUseSimulationTest.swift` adds twelve further sequences after the user
requested broader standard-use coverage. The shared scenario helper calls the
real focus callback/history check as well as layout. The example configuration's
mouse-moving monitor callback and external workspace hooks are disabled in the
shared test fixture; tests opt into callbacks explicitly. Before this isolation
fix, an earlier run could post the example callback's pointer event. No app was
launched, installed, switched, or sent live window-management commands.

| Additional sequence | Assertions beyond generic invariants |
| --- | --- |
| Workspace/focus history, empty break, summon and whole-workspace monitor moves | Correct previous workspace/window, intentional focus with/without focus-follows-window, same workspace/window object out and back |
| Join/split/swap, nested accordion/tiles and DFS/directional boundaries with floating dialog | Exact swap and unclamped resize round trips, accordion bounds independent of focus, explicit failure/stop/wrap semantics, floating dialog survives |
| Arriving window callback moves, floats, resizes and centres | Callback targets arrival while original editor retains focus/frame; pending window excludes layout; one-shot next-window override is consumed once; no duplicate pending move event |
| Focus Mode, minimize/restore, native fullscreen, close and workspace return | Active mode follows a surviving logical window, stops for native fullscreen/empty workspace, preserves user adjustment through minimize, refuses unsupported entry |
| Mouse reversal plus topology, monitor and Focus Mode changes | Gesture reversal restores exact frames; topology/display changes suppress queued events; Focus Mode must preserve underlying tiling |
| Native remap during mouse gesture, queued old event, release and fresh drag | Logical sizing survives remap, old event cannot alter replacement split, fresh gesture uses current replacement geometry |
| Unequal negative-origin, portrait and vertically arranged displays | Whole-workspace out/back preserves frames; same-count visibleRect changes refresh caches; reconnect restores homes under mixed geometries |
| Runtime adaptive policy and gap changes, resize, hide/return and balance | Order/identity retained; floating frame unaffected; restoring normal policy and balancing restores standard frames; no config-watcher claim |
| Unclamped width/smart, native-independent fullscreen and float/tile round trips | Exact geometry where reversible; float/tile restores saved size and centre when explicitly centred; fullscreen guards and no-op failure codes classified |
| Twelve batches of same/different-app churn with close-all | Closed logical IDs never reappear, surviving anchor keeps workspace, unrelated four-window workspace unchanged, 48 arriving windows retained or closed correctly |
| Three shuffled standard sessions | Eight seeded shuffles of ten supported operations per topology; small laptop, portrait/large pair, and negative-origin/upper display triple; unclamped floating resize symmetry and per-step invariants |
| Tile-before-monitor, monitor wrap/reverse, and boundary fail/stop | First tiles locally, next crosses monitor, wrap/reverse preserves identity and symmetric geometry, expected no-op/failure preserves focus |

The shuffled seeds are `0xD440`, `0xE550`, and `0xF660`. They use 80 action rounds
each, in different reproducible orders. The runner prints actual checkpoint
counts for every scenario, including the extra centering commands required to
avoid treating monitor clamping as a reversible floating resize.

Recorded counts are 187, 188 and 188 for these three seeds (563 shuffled
checkpoints). The twelve expanded tests total 784 checkpoints; combined with the
original 1,018, the **24 new tests execute 1,802 invariant checkpoints**. These
totals come from runner output, not estimated loop counts. The regression checkpoint had 630 tests: the existing 606 passed; nineteen new
tests passed and five failed with 83 assertion failures before source repair.
The original 1,802 checkpoints remain the pre-repair comparison count. Safe
cancellation of the stale Focus Mode start removes its conditional exit command,
so the repaired simulations execute 1,801 checkpoints with the same assertions.

```sh
PATH=/opt/homebrew/bin:$PATH \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swiftly run swift test --jobs 4 --filter StandardUseSimulationTest
```

## Defects found before repair

The first complete targeted run had 12 tests: eight passed and four failed,
with 82 assertion failures. The failing assertions remain normal regressions;
they are not skipped or marked as expected failures.

1. **Fullscreen restore loses an unchanged nested adaptive layout.** Start with
   `h_tiles[left, v_tiles[top, bottom]]`, resize the nested split and its column,
   enter native fullscreen on `top`, apply normal layout, normalize, and exit.
   The result is `h_tiles[left, bottom, top]`, losing both the stack and sizing.
   Layout's own geometry/weight changes make the restore-point guard reject the
   original parent. No intervening user edit is needed. The test also continues
   through genuine topology edits to check safe fallback.
2. **Invisible/return cycles accumulate split drift.** An unequal vertical stack
   begins at heights 619.5/459.5. Hiding its bottom window lets the top reclaim
   height, but returning produces 795.25/283.75, then 879/200 on the second cycle.
   The hidden node retains its weight; the visible sibling's temporary expanded
   weight persists and changes the restored split.
3. **A late floating resize reply writes old-native geometry to the replacement.**
   During a read of a 600×400 frame, remap to a new native window with its own
   900×650 frame. `resize width +100` then writes 700×400 using the old reply.
   `ResizeCommand.resizeFloating` does not recheck the native geometry generation.
4. **Focus Mode saves an old-native floating restore frame.** The same remap
   during `FocusMode.start` saves the old 600×400 reply. Exiting restores it to
   the new 900×650 native window. The read lacks a generation recheck.
5. **A fresh mouse resize during Focus Mode changes the underlying tiles.**
   After releasing any previous gesture, start Focus Mode and deliver a width
   change to `resizeWithMouse`. Weights change from 690/615/615 to 810/555/555.
   The adaptive branch suppresses an existing gesture when Focus Mode starts,
   but a fresh event falls through to the legacy horizontal resize branch.
   Focus Mode's visual override must leave the tile weights intact.

Minimum-size confirmation already rejects late replies correctly. The seeded
workdays pass: their invariants detect structural/identity/geometry corruption,
while the targeted regressions additionally assert exact restoration semantics.

## Source repair semantics

Fullscreen restore now distinguishes automatic layout weight changes from explicit
resize and balance edits. It retains the original order, identity, layout and
workspace guards, and restores the matching adaptive proportion cache with the
saved structure. Deliberate edits, moved neighbours and closed neighbours use the
existing safe fallback rather than overwriting the new layout.

A container with invisible placeholders computes a temporary visible allocation
synchronously and restores retained logical shares before recursive layout can
await or call a child. Visible siblings reclaim the display area without absorbing
the invisible share. Keyboard and mouse resizing redistribute the retained visible
pool only, so a deliberate visible split edit survives later hide/show cycles.
The all-visible allocation retains its existing behavior.

Floating resize cancels with a failure if its AX frame read spans a native remap,
parent/workspace change or loss of liveness. Focus Mode setup and focus sync also
validate native generation, binding, liveness, focused window, workspace and the
current mode request after their frame reads. A saved floating restore frame is
valid only for the native generation that supplied it. If that floating window
remaps while Focus Mode is active, focus sync ends the mode without applying the
old restore frame; subsequent layout uses the replacement's own frame.

Native mouse resize while Focus Mode is active is ignored and normal view layout
restores the Focus Mode frame. Existing keyboard width/height adjustments remain
supported. The legacy mouse path also replays an established edge back to its
baseline while retaining the initial noise threshold; its stored baseline expires
on native, topology or monitor changes and on release.

## Floating drag completion follow-up

Independent review found a separate delayed-read path after the five repairs:
`bindFloatingWindowToMonitorUnderCenter` could use an old native centre to move
a replacement tab to another monitor's workspace, or reinsert a closed/unbound
window into the tree. The same helper runs during dragging and on release.

`FloatingMoveLifecycleTest.swift` adds nine focused tests. Before the source
guard, six tests failed with 48 assertion failures and three positive tests
passed. The captured `TestWindow.onGetAxRect` reply reproduces both remapping
and closure while the centre read is pending; all failing assertions remain
ordinary regression assertions. Coverage also includes invisible/dead bound
windows, explicit workspace moves, conversion to tiling/native fullscreen,
invalid initial states, missing geometry, unchanged binding order, two/three
monitor crossings in both directions, and successful/stale release cleanup.

The helper now requires an alive, bound floating window before reading its
centre. It captures native geometry generation, parent and workspace, then
rechecks them, liveness and floating state after the read, before choosing or
committing the new binding. Stale replies leave the current binding intact.
The remap regression checks the actual production mapping helper, logical and
native identity, replacement workspace/frame and absence from the stale target;
closed/unbound regressions check that the node never returns to the tree.

This is deterministic model evidence using a captured reply at the production
await boundary. It does not execute native AX threads, actual MacApp garbage
collection, observer/session scheduling or a physical mouse drag. Display
disconnect/wake during a drag remains controlled live-trial work. These tests
do not establish native daily-use acceptance.

## Automated checks

Toolchain: pinned Swift 6.4.2, Xcode developer directory, at most four build jobs.
The full test command is:

```sh
PATH=/opt/homebrew/bin:$PATH \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swiftly run swift test --jobs 4
```

The source repair adds `LifecycleRepairTest.swift`, with thirteen focused tests
covering adaptive and normal layout, nested invisible shares, physical keyboard
and mouse resize round trips, synchronous projection restoration before a child
frame callback, fullscreen user-edit fallback, delayed floating reads, Focus Mode
native-generation expiry, and gesture invalidation. The existing fullscreen
fixture now identifies its simulated automatic normalization writes explicitly;
its original restoration assertions are unchanged.

The repaired full run passes **643 XCTest tests with zero failures**: all 630
regression-checkpoint tests plus thirteen focused repair tests. The 24 original
simulation tests retain all their assertions and now pass; the six seeds and 600
mixed action rounds are unchanged.

The floating drag completion follow-up passes **652 XCTest tests with zero
failures**, including all nine new regressions and the previous 643 tests. Its
focused command is `swiftly run swift test --jobs 4 --filter FloatingMoveLifecycleTest`.
Exact before/after logs and follow-up checks are recorded in
`.claude/work-orders/runs/floating-move-lifecycle-report.md`.

The parent owns independent clean-tree `./test.sh`, release/package validation
and any live trial. Exact commands and results are recorded in
`.claude/work-orders/runs/lifecycle-repair-report.md`.

The parent added a source safety guard in `MoveMouseCommand` so unit-test mode
returns before constructing or posting a CGEvent. The final run rebuilds after
that guard; cached pre-guard binaries are not sufficient. Clearing callbacks in
the shared fixture isolates scenario state; the low-level guard provides the
native-input boundary. Earlier runs cannot be guaranteed to have emitted no
cursor event through the inherited example callback.

## Controlled live trial still required

Perform these only in an explicitly scheduled trial after repairs and a fresh
full-suite pass. This checklist does not authorize switching the installed app.

- Open two windows of one browser on each of three workspaces/monitors. Resize
  and close a background window, then close the focused last local window.
  Its workspace must remain visible and empty; no remote survivor should become
  the destination for typing or Cmd-W. Reopen locally, then Cmd-Tab/Dock/click
  deliberately to another app/workspace and confirm the close hold ends promptly.
- Interleave browser/editor windows and a floating app dialog. Confirm separate
  logical IDs and correct app PID/native ID exports; close events identify only
  the actual closed logical window. A dialog must not steal or merge a browser's
  logical identity.
- In an unequal nested adaptive layout, fullscreen and return without edits,
  then repeat while creating, moving and closing neighbours. Unchanged layouts
  must restore exact order/sizing; changed topology must produce a valid local
  fallback without duplicate windows or crashes.
- Enter Focus Mode from an outer monitor, verify the middle stage, resize both
  axes, switch same-app windows, create/close another window, switch workspace,
  return and exit. Repeat with `--stay-on-monitor`. Verify per-window adjustments,
  floating restoration, original tiling, dimmer, border and keyboard destination.
- Drag/move tiled and floating windows across workspaces and monitors, resize
  repeatedly against app minima, and run `balance-sizes`. Native/logical exports
  must remain coherent; minimum-size refusals may exceed targets, but accepted
  geometry must remain positive and avoid unintended overlap.
- Repeat native Space and browser-tab visibility changes in nested layouts.
  Invisible placeholders retain logical placement and user sizing, visible
  siblings reclaim space, automatic focus/navigation/listing skip placeholders,
  and explicit ID focus can activate one. Minimize/restore and app-hide/show must
  emit the correct move semantics without false close/detect pairs.
- Switch native macOS window tabs in Finder and Ghostty (and a browser that
  actually exposes native window tabs) while resizing and during Focus Mode.
  Ordinary browser page tabs alone do not establish native-window remapping.
  Delay/stress
  AX responses with a busy app, then confirm the replacement tab receives no
  previous-native frame/minimum. Try tab dragging, early AXFocusedWindow before
  AXWindows, timeouts/retries and simultaneous transitions. Ambiguous cases may
  detect ordinary independent windows; they must never merge known windows.
- With populated workspaces and Focus Mode active, disconnect/reconnect a display,
  change resolution/Dock/menu-bar geometry, close/open the laptop lid, and sleep/
  wake. Workspace homes and visibility recover unless deliberately moved while
  disconnected; no duplicate workspace object or stale frame remains after the
  delayed refresh. Confirm border/native focus uses the current native identity.
- Reproduce the standard keyboard sequences with actual floating dialogs and
  native tabs: join/split/swap, accordion/tiles, workspace/focus history, summon,
  monitor wrap and expected no-op boundaries. Actual mouse drags must preserve
  the Focus Mode override and discard queued events after remaps/topology changes.
- Exercise actual on-window-detected callback timing, runtime config reload and
  subscribed event delivery. The synthetic suite directly runs the callback and
  mutates config fields; it does not establish AX enumeration, config watcher,
  socket delivery or real pointer-event behaviour.

Record app versions, monitor topology, exact action sequence, logical/native/PID
exports and observed events for any failure. Synthetic tests cannot establish
that these OS-specific behaviours have passed.
