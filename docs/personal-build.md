# AeroSpace Alpha: build notes

These are the working notes behind [AeroSpace Alpha](../README.md), my
AeroSpace build for a Mac Studio and a laptop. The README gives the overview;
this page records how each piece works and why. It can constrain the whole
tiling workspace according to its structural rows and columns on selected
monitors, while retaining the earlier centred width rule for a lone window on
other monitors and in Focus Mode on those monitors.

![Illustration of a lone tiled window centred at 50% width on a standard 16:9 monitor](assets/single-window-width.svg)

*Illustration of the 50% rule on a standard monitor; this is not an app screenshot.*

[Watch the short single-window-width demo](assets/single-window-width-demo.mp4).

The width rules were first shared as a proof of concept for
[upstream discussion #2308](https://github.com/nikitabobko/AeroSpace/discussions/2308).
This is not an official AeroSpace release. For the standard application,
documentation, and installation instructions, see
[upstream AeroSpace](https://github.com/nikitabobko/AeroSpace).

## Adaptive widescreen layouts

The adaptive policy is disabled by default and can be enabled with a scalar
boolean or per monitor. My monitor-specific form is:

```toml
[adaptive-layout]
enabled = [{ monitor."DELL U3225QE" = true }, false]
one-column-width-percent = 33
two-column-width-percent = 66
single-row-height-percent = 90
minimum-window-width-percent = 60
```

The last boolean is the fallback for monitors that do not match. Each
percentage must be from 1 to 100, and the one-column width cannot exceed the
two-column width. When enabled, one structural column occupies 33% of the
usable monitor width, two occupy 66%, and three or more occupy all of it. A
one-column stack of two or more rows uses the two-column width and stays capped
at that width as more rows are added. One structural row occupies 90% of the
usable height; two or more occupy all of it.
The result is centred horizontally and vertically. The usable rectangle already
has outer gaps removed, and layout applies the configured inner gaps inside it.

Horizontal resize keeps each participating window readable before widening the
workspace. `minimum-window-width-percent` is the minimum physical content width
as a percentage of the normal one-column width; it is not a percentage of the
whole monitor. An application's own minimum is learned separately (see App
minimum sizes below) and raises the floor for that window only. At the
default settings on a 1920-point usable display, the one-column width is 633.6
points and the resize minimum is 380.16 points. A target first takes space
equally from neighbours that remain above that minimum. Further growth expands
the centred workspace up to the usable display width. Reversing the resize
contracts that expansion before giving space back to neighbours.
Making an uneven pair more balanced can also reduce its overall width while
honouring the requested change; another row that still needs the extra width
keeps the workspace expanded.

The minimum is applied recursively: horizontal children add their content
minimums and inner gaps, while vertical children use the widest requirement.
An accordion acts as one overlapping group and includes its horizontal reveal
padding. If all recursive minimums cannot fit on a narrow display, the display
edge wins and every child receives a positive proportional share. Existing
custom split ratios may therefore widen a workspace when this policy is first
enabled.

Keyboard resize keeps the workspace centred on every step. Mouse resize keeps
the window edge opposite the pointer fixed while the workspace can move. At a
display edge it shifts the remaining donor reduction to the side that preserves
that fixed edge, and clamps the actively dragged frame when the requested size
exceeds the feasible minimum or maximum. Releasing the pointer recentres the
derived workspace. No expanded-width flag is saved; the current tree, gaps and
split weights determine the width on each layout pass.

The structure is calculated recursively from the tiling tree. A window counts
as one column by one row. Horizontal tiles add columns and take the largest row
count; vertical tiles take the largest column count and add rows. An accordion
takes the largest footprint among its children, which prevents a focus change
from moving the workspace bounds. Floating windows, windows still awaiting an
`on-window-detected` result, and nested containers with no placed tiled windows
are excluded from both the count and the space allocation.

The bounded rectangle is applied once at the workspace boundary. Tile
proportions inside it survive area-only changes, monitor moves, and enabling or
disabling the policy. The preservation cache includes the container's
orientation, layout and participating child identities, and it scales the live
weights rather than old copies; keyboard-resized and nested uneven splits
therefore remain meaningful. A changed child set follows the normal topology
adjustment unless that would collapse a positive tile after its inner gap, in
which case the surviving positive weights are scaled proportionally.

Adaptive bounds are a layout target, not a hard per-window maximum. An app's
minimum size or refusal to accept an Accessibility frame can make its actual
window exceed the target, and nested leaves receive only their portion of the
workspace rectangle. AeroSpace full screen and Focus Mode remain explicit leaf
overrides. On a monitor where adaptive layout is enabled, Focus Mode uses the
same centred one-column width and single-row height as a lone adaptive window.
The underlying adaptive workspace geometry and weights stay intact, so leaving
either returns to the adaptive arrangement.

For normal tiling and Focus Mode on an enabled monitor, adaptive layout takes
precedence over `single-window-width-rules`. A lone window's `resize smart` and
`resize width` commands use the adaptive one-column width as their base. Focus
Mode uses the same per-window width adjustment, so resizing there carries into
a later lone adaptive layout for that window. On other monitors, Focus Mode
keeps its existing width rule or 66% fallback.

## Vertical minimum and standard-size reset

`minimum-window-height = 200` applies to tiled windows on adaptive and normal
displays. The value is in macOS display points. A vertical tile adds the
recursive minimums of its children and its inner gaps; a horizontal tile uses
the largest child requirement. Vertical accordion groups include their visible
reveal padding. Keyboard and mouse resizing stop when the target or a donor
reaches its floor. If the available height cannot fit every requested minimum,
inner vertical gaps shrink first, then the available content is divided into
positive frames that remain inside the container.

The starter binding `alt-0 = 'balance-sizes'` restores equal tiled splits on
the target workspace (since upstream `80092f3` every tile gets the average of
the existing weights, so a following `resize` behaves as if run alone). It also clears a lone window's width adjustment, Focus
Mode width and height adjustments, and learned app minimum sizes, and cancels an active resize gesture so a
queued mouse event cannot restore stale weights. Floating window frames are not
changed.

## App minimum sizes

Apps have their own minimum window size (a browser will not go much below
570 points wide), and macOS offers no Accessibility attribute to read it. A
tile narrower than that minimum used to leave the window at its own size,
spilling over its neighbour. After writing a window's frame, AeroSpace now
reads the size back. A window that stayed larger than requested has shown its
minimum; AeroSpace reads the size again 150 ms later, so an app that applies
frames asynchronously is not mistaken for one that refused, then remembers the
settled size for that window and lays the workspace out again.

The learned width and height then act like `minimum-window-width-percent` and
`minimum-window-height` for that window only, whichever is larger. On an
adaptive display the centred workspace widens as it does for the configured
floor; a vertical stack takes the widest minimum of its windows. Normal
displays have no configured width floor, so there the learned minimums take
space from neighbouring tiles while they all fit, and leave the split as it is
when they cannot. Keyboard and mouse resizing stop at the learned minimum.

A minimum lasts for the window's lifetime. It is replaced when the app refuses
a smaller size again (a sidebar opened, so the minimum grew), forgotten when the
window accepts a size below it, and cleared by `balance-sizes`, which is the
way to retest a window whose minimum has shrunk.

## Single-window width

Alpha adapts the single-window and accordion aspect-ratio work in
[PR #2093](https://github.com/nikitabobko/AeroSpace/pull/2093) to the newer
AeroSpace code, then adds `single-window-width-rules`. Each rule sets the width
of a lone tiled window as a percentage of usable monitor width when the monitor
meets a minimum width in macOS scaled display points. The highest matching
threshold wins. If no width rule matches, the window keeps its usual width
unless an aspect-ratio setting also applies.

My configuration in `~/.aerospace.toml` is:

```toml
single-window-width-rules = [
  { min-monitor-width = 0, width-percent = 66 },
  { min-monitor-width = 2000, width-percent = 50 },
]
apply-aspect-to-accordion = 'none'
```

This gives the laptop's 1512-point display a 66%-width lone window and the
Studio's 2560-point displays a 50%-width lone window. The optional PR #2093
sizing of an accordion (a stack of overlapping windows) is disabled here, so
multiple tiled windows use the normal layout. AeroSpace full screen still
fills the display. The width rules can be edited for other monitors and setups.
On a monitor with adaptive layout enabled, its one-column percentage replaces
this rule for normal tiling and Focus Mode. The rule still applies on other
monitors.

While a tiled window is alone, my `resize width +100` and
`resize width -100` bindings widen or narrow it by 100 display points and keep
it centred. The adjustment belongs only to that window and lasts until it
closes or AeroSpace restarts. With multiple tiled windows, the same commands
continue to resize tiles normally; on a window inside a vertical stack they
widen or narrow the whole stack, where `resize smart` would change its height.

The [width-rules commit](https://github.com/JasonBates/AeroSpace-Alpha/commit/92be41f)
shows the additional implementation and tests.

## Focus Mode experiment

Focus Mode is a reversible centred view for the focused window.
On an adaptive display it uses the lone-window width and single-row height,
including the vertical margins. On other displays it uses the lone-window
width rule, or 66% of the usable display width when no rule is configured.
Width and height resize commands adjust this centred frame. Focus Mode has a
600-point minimum height, capped by the usable display height on smaller screens. A translucent dark layer dims the other
windows on every display. The layer does not take keyboard or mouse input.
On a multi-display setup the focused window appears on the middle display
(or the macOS main display when there are two). It returns to its original
position when Focus Mode ends. A single-display setup behaves as before.

[Watch the short Focus Mode demo](assets/focus-mode-demo.mp4). The video is a
schematic animation, not a screen recording.

The starter config binds Option+Return to `focus-mode --stay-on-monitor`.
My personal Caps Lock setup instead uses the binding below, which permits the
middle/main-display behaviour. Stock AeroSpace does not recognise `focus-mode`:

```toml
ctrl-alt-cmd-z = 'focus-mode'
```

Pressing it again returns to the existing tiled view. Keyboard focus commands
can select another window in the same workspace. Clicking outside the focused
window, switching workspaces, or disabling AeroSpace exits Focus Mode. It
preserves the workspace tree and tile weights;
for a floating window it also restores the original frame. AeroSpace full
screen takes precedence and exits Focus Mode.


## App-specific border corners

Some apps draw different rounded corners. Keep a default radius and override
individual apps by their exact bundle ID, without changing other windows:

```toml
focused-window-border-radius = 10
focused-window-border-radius-by-app = { 'com.apple.mail' = 24 }
```

Unlisted apps use the default radius. Radius values are non-negative macOS
display points. Colour, thickness and inset still use the shared border settings.

## Upstream pull requests included

Alpha merges these open upstream pull requests, which fix bugs that affect
my multi-monitor setup. Each is merged
unchanged except where noted.

- [#2232](https://github.com/nikitabobko/AeroSpace/pull/2232): avoid a crash
  while displays are being reconfigured.
- [#2281](https://github.com/nikitabobko/AeroSpace/pull/2281): avoid a `focus`
  crash when a floating window moves or closes during the command.
- [#2220](https://github.com/nikitabobko/AeroSpace/pull/2220): a window made
  floating by `on-window-detected` no longer stays at its tile position.
- [#2299](https://github.com/nikitabobko/AeroSpace/pull/2299): a cancelled
  focus request no longer steals focus from a newer one.
- [#2179](https://github.com/nikitabobko/AeroSpace/pull/2179): with separate
  Spaces per display, focus lands on the requested window of a multi-window app
  rather than one on another monitor (issue #101). Adapted to the upstream
  `Monitor` to `MonitorInfo` rename.
- [#2201](https://github.com/nikitabobko/AeroSpace/pull/2201): restore focus
  after a transient dialog closes.
- [#2348](https://github.com/nikitabobko/AeroSpace/pull/2348): when the last
  floating window of a workspace closes (a Touch ID or 1Password prompt), the
  empty floating container stayed the most recent child, so `toLiveFocus()`
  fell back to the first window in tree order. It now skips MRU children
  without windows (`mostRecentNonEmptyWindowRecursive`). Covers the paths
  #2201 does not, such as workspace switches.
- [#2225](https://github.com/nikitabobko/AeroSpace/pull/2225): a new native
  tab (Finder, Ghostty) takes its predecessor's place in the tree (issue #68).
  One line resolved by hand to keep #2220's change as well. Narrowed so that a
  window closing is not taken for a tab switch (see the Cmd-W paragraph under
  Further additions).
- [#2174](https://github.com/nikitabobko/AeroSpace/pull/2174): a window
  returns to its place in the layout after macOS native full screen.
- [#2317](https://github.com/nikitabobko/AeroSpace/pull/2317): the windows of
  an app that hangs or is too busy to answer Accessibility requests are no
  longer treated as closed (issue #1216). Resolved by hand against #2225 in
  the same function, so retired native tabs stay dead; unit tests added.
- [#2326](https://github.com/nikitabobko/AeroSpace/pull/2326): when an app
  does not answer the window enumeration in time (issue #1615), the refresh
  is retried with exponential backoff instead of leaving its windows
  undetected. Ported by hand onto #2317's liveness check, so the PR's own
  liveness enum is not needed; backoff unit-tested.
- [#2280](https://github.com/nikitabobko/AeroSpace/pull/2280): activating an
  app with windows on two monitors no longer pulls a hidden workspace onto the
  other monitor. Narrowed from the PR, which ignored every macOS focus on an
  invisible workspace and so would have stopped Cmd-Tab, Dock and notification
  clicks from bringing a hidden workspace up: the off-screen window is ignored
  only while the same app has a window on a visible workspace
  (`isActivationArtifact`, unit-tested).
- [#2316](https://github.com/nikitabobko/AeroSpace/pull/2316): apps that
  macOS 27 reports with process id -1 (Xcode 27 Device Hub, Java apps started
  through a launcher script) are detected and managed. Resolved by hand
  against the native-tab code: closures capture the resolved pid.
- [#2167](https://github.com/nikitabobko/AeroSpace/pull/2167): a window's
  frame is written only when the layout changed it. Focus Mode had to record
  the frame it applies rather than the tile rect, or the tile frame was never
  written back when Focus Mode ended; FocusModeCommandTest caught it.
- [#2310](https://github.com/nikitabobko/AeroSpace/pull/2310): `balance-sizes`
  resets the closed-windows cache.
- [#2319](https://github.com/nikitabobko/AeroSpace/pull/2319): `move` can wrap
  around all monitors with `--boundaries-action wrap-around-all-monitors`.
- [#2248](https://github.com/nikitabobko/AeroSpace/pull/2248): `move` moves
  floating windows, by `--floating-pixels` or a tenth of the monitor.
- [#2107](https://github.com/nikitabobko/AeroSpace/pull/2107): a native
  focused-window border, off by default (`focused-window-border = true`).
  Reworked for speed (`FocusedWindowBorder`): the frame comes from
  `CGWindowListCopyWindowInfo` instead of an AX call, `setFocus` redraws at
  once, and a 60 Hz timer follows the window while a mouse button is held.
  Also refreshed at the end of `layoutWorkspaces`.

## Further additions

Alpha also carries four additions
and fixes for hidden windows and disappearing monitors,
each covered by unit tests and checked live on a three-monitor Mac.

- `center` centres a floating window on its monitor, shrinking it if it is
  larger than the monitor ([upstream issue #494](https://github.com/nikitabobko/AeroSpace/issues/494)).
- `resize` works on floating windows ([upstream issue #9](https://github.com/nikitabobko/AeroSpace/issues/9)).
  The window is resized around its centre and kept inside its monitor. `width`
  and `height` change one side; `smart` changes the longer side and
  `smart-opposite` the shorter one, keeping the aspect ratio.
- `aerospace subscribe` gains `window-closed` and `window-moved` events, so a
  workspace bar can follow windows without polling `list-windows`.
  `window-moved` also reports moves made by `on-window-detected` callbacks, and
  minimizing (no `workspace`) or restoring (no `prevWorkspace`) a window.
- `move --boundaries all-monitors-outer-frame --tile-before-monitor` first
  tiles a multi-window workspace along the requested axis when needed, then
  crosses to the neighboring monitor when the move is repeated.

It also changes where hidden windows are parked. AeroSpace hides the windows of
invisible workspaces in a bottom corner of their monitor. When both bottom
corners of a monitor touch a neighbouring monitor, as for the middle of three
side-by-side monitors, macOS and some apps (Activity Monitor) pull the parked
window onto the neighbour, AeroSpace parks it again, and it flickers at the
bottom of that monitor. Such a monitor now parks its hidden windows in the
nearest clean outer corner of another monitor.

Each parking corner that has windows in it is covered by an opaque,
click-through strip one point wide and 160 points tall (`HideCornerCovers`).
A parked window keeps a one-point column on screen, because macOS keeps its
title bar visible, and that column keeps `NSWindow.occlusionState` at
`.visible`, so browsers and Electron apps render their hidden windows at full
rate ([upstream discussion #2323](https://github.com/nikitabobko/AeroSpace/discussions/2323)).
With the strip in front, every parked window reports itself as occluded.
`hidden-windows-occlusion-cover = false` disables the covers.

It also fixes a crash when a monitor disappears. During display
reconfiguration, such as closing the lid with external displays attached or
every display being briefly off, AeroSpace could ask for the workspace of a
monitor that macOS no longer reports. The lookup retried by calling itself,
which could never succeed, and recursed until the stack overflowed. Since
upstream's October 2026 restructure the lookup lives in `Monitor.swift`
(`toMonitorOrRearrangeMonitors`) and still recurses there, so Alpha carries
the fix on top: a stale monitor borrows the closest live one until the next
refresh, and `rearrangeMonitors` keeps the known monitors when every display
is momentarily off instead of dying on the empty list. The fix is ported from
[AeroSpace-edge](https://github.com/vitorebatista/AeroSpace-edge)
([PR #64](https://github.com/vitorebatista/AeroSpace-edge/pull/64)).

The same restructure made workspaces tree children of their monitor, which
changed two more things that Alpha puts back:

- When a monitor disappears, upstream moves its workspaces to the main monitor
  for good, and a monitor that comes back shows an empty stub. Alpha remembers
  where each workspace lived (`workspaceNameToHomeMonitorPoint`) and returns
  them, with the workspace that was visible there, when a monitor appears at
  that point again, as the old per-workspace monitor assignment did. A
  workspace placed explicitly in the meantime, or shown on another monitor,
  stays where it is.
- Each `Monitor` caches its `MonitorInfo`, and upstream refreshes the cache
  only when the number of monitors changes, so a Dock, menu-bar or resolution
  change laid out against the old visible rect. `gcMonitors` also refreshes
  when a monitor's rect, visible rect, name or index changes.

Upstream's garbage collection of empty workspaces also left them bound in
their monitor's container, where a later lookup under the same name could
find the dead object next to the live one. Alpha unbinds them as they are
collected. `MonitorTest` covers all of this.

Neither build observed screen changes at all: a lid, a cable or a wake reached
AeroSpace only through some unrelated refresh, often one that ran while macOS
was still reporting in-between sizes, and the tiles kept those until the next
click. `GlobalObserver` now refreshes on `didChangeScreenParametersNotification`
and the two wake notifications, and once more a second later, when the menu
bar and Dock have followed the screen. A screen change also clears each
window's `lastAppliedLayoutPhysicalRect` (`forgetAppliedWindowFrames`): macOS
moves windows itself meanwhile, and the redundant-write skip from
[discussion #2137](https://github.com/nikitabobko/AeroSpace/discussions/2137)
would otherwise leave a window where macOS put it whenever its tile came out
unchanged.

Reading the natively focused window asks the frontmost app over AX, and an app
losing focus can take about 100 ms to answer. An answer that arrived after a
newer session had adopted the next app flicked AeroSpace's focus back to the
old one. `syncFocusFromMacOs` now drops an answer when the frontmost app
changed during the read; the race is in upstream's code as well.

A window closing never changes the workspace. When the focused window goes,
macOS hands focus to some other window wherever it is: Cmd-W on a browser
window keys the browser's long-lived window on another workspace, and an app
that quits with its last window activates the next app. Upstream adopts that
focus and switches workspace. Alpha treats it as fallout of the close. When
the focused tiled or floating window leaves the tree, its workspace is held
(`WorkspaceFocusHold`): focus macOS reports on a window outside it is not
adopted, and AeroSpace keys the workspace's own window instead, so
keystrokes do not go to the parked one. The hold ends as soon as macOS
reports one of the workspace's windows, or AeroSpace itself on an emptied
workspace (`hasFocusSettledOnHeldWorkspace`), which takes milliseconds, so a
Cmd-Tab straight after the close is adopted; it lasts a second at most. A workspace the close left empty
stays focused and empty, as after `aerospace workspace`, and AeroSpace makes
itself the active app (`takeKeystrokesForEmptyWorkspace`). It has no window
that can become key, so typing or a second Cmd-W goes nowhere instead of into
the parked window. Its app menu drops the Quit and Hide shortcuts, so Cmd-Q
meant for the closed window cannot quit AeroSpace; Quit stays in the menu bar
menu. Cmd-N goes nowhere too, and the menu bar shows AeroSpace until a window
is picked. Any app, empty or
populated. A command that moves focus elsewhere ends the hold, since the
focused workspace no longer matches, and so does a click. A native
fullscreen window starts no hold: switching away from its Space looks the
same to AeroSpace as a close.

The hold starts in both places a window can leave the tree, `garbageCollect`
and `discardNativeTabWindow`, because #2225's `nativeTabReplacementCandidate`
reads a closed window, gone from AXWindows while the app focuses another, as
a native tab switched away from. Without the hold there, such a close skipped
the close path and AeroSpace followed the browser. Tabs of one group share a
workspace, so when the newly focused window is one AeroSpace already manages
on another workspace, the old window now goes through `garbageCollect`
(`isWindowCloseRatherThanTabSwitch`), which reports `window-closed` and
returns focus to the workspace's previous window. A second window of the same
app on the same workspace still reads as a tab switch: focus stays on the
workspace but goes to the app's window. Telling those apart needs the tab
group itself (`AXTabGroup`). All of it is unit-tested.

With these, a rule can open a window floating, sized and centred:

```toml
[[on-window-detected]]
    if.app-id = 'com.apple.QuickTimePlayerX'
    run = ['layout floating', 'resize smart 1600', 'center']
```

## Building

`./build-personal-release.sh [label] [--laptop]` builds a signed release of the
current commit against Xcode's SDK, stages it in
`~/.local/share/aerospace-builds/<label>-<hash>/` and, with `--laptop`, copies it
to the laptop. `aerospace-switch <label>-<hash>` (in `JasonBates/aerospace-config`)
installs it and keeps every window on its workspace across the restart. The
signing identity and the laptop address are read from
`~/.config/aerospace/env` (`AEROSPACE_CODESIGN_IDENTITY`, `AEROSPACE_LAPTOP`;
template in `personal-build.env.example`), which is never committed.

## After merging upstream

Alpha takes upstream `main` by merging it in, in ordered chunks when upstream
has restructured something, so each chunk compiles and passes the tests on its
own. It is not rebased: the twenty "Merge upstream PR" commits keep their
hand-resolution notes, and nothing upstream is rewritten. The October 2026
update was three merges (`23d5205`, `c419f4b`, `c736e8e`).

Upstream's `.github/` carries automation for its own contribution policy: a
workflow that closes and locks issues from anyone but its maintainers, one that
labels every outside pull request `not-actionable`, issue and discussion
templates that point at upstream, and a `FUNDING.yml` for upstream's sponsors.
Alpha accepts discussions, issues and pull requests, so if a merge brings those
back, delete them again and keep Alpha's own `pull_request_template.md`. The
`build.yml` and `release.yml` workflows stay.

Other things to check after a merge:

- Upstream's `.gitignore` ignores every file in the repository root by
  default, so a new root script needs `git add -f`.
- Run `./generate.sh` when upstream edited `docs/aerospace-*.adoc`, or
  `./test.sh` fails on uncommitted generated files.
- Multi-monitor tests call `setMonitorInfosForTests([...])`, which rebuilds the
  `Monitor` tree nodes; assigning `monitorInfosForTests` alone leaves them
  stale.
- With only the Command Line Tools selected, the tests fail to compile
  (`SwiftUIMacros` is missing). Run them as
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./test.sh`.
