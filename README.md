<p align="center">
  <img src="docs/assets/alpha-logo.svg" width="168" alt="AeroSpace Alpha logo">
</p>

<h1 align="center">AeroSpace α</h1>

<p align="center">
  A personal build of <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>, the i3-like tiling window manager for macOS,<br>
  with the fixes it is waiting for and a few things it does not have.
</p>

<p align="center">
  <a href="https://github.com/nikitabobko/AeroSpace">upstream</a> ·
  <a href="docs/personal-build.md">build notes</a> ·
  <a href="LICENSE.txt">MIT</a>
</p>

<br>

## How it differs

<p align="center">
  <img src="docs/assets/how-alpha-differs.svg" width="100%" alt="Three layers: upstream AeroSpace at the bottom, nine pending upstream fixes in the middle, Alpha's own features on top">
</p>

Alpha is upstream `main` with two layers on top. The middle layer is a set of open upstream pull requests merged as they are, so bugs that upstream has fixes for are fixed here now. The top layer is what I built for a three-monitor desk and a laptop. Everything else, from the config format to the CLI to the docs, is upstream's.

## What Alpha adds

### Single-window width

A lone tiled window no longer fills the screen. `single-window-width-rules` gives it a percentage of the usable width, chosen by monitor size, and keeps it centred. On a 27-inch display a text editor at 50% is readable; on the laptop the same rule gives 66%.

<p align="center">
  <img src="docs/assets/single-window-width-demo.gif" width="720" alt="Animation: a lone window shrinks to half the display width and centres itself">
</p>

```toml
single-window-width-rules = [
  { min-monitor-width = 0,    width-percent = 66 },
  { min-monitor-width = 2000, width-percent = 50 },
]
```

`resize smart +100` and `-100` widen or narrow the lone window by 100 points and keep it centred.

### Focus Mode

`focus-mode` centres the focused window at the same width and dims every other window on every display behind a translucent layer. Press it again, click elsewhere or switch workspace and the layout returns exactly as it was, tree and tile weights intact. On three displays the window moves to the middle one.

<p align="center">
  <img src="docs/assets/focus-mode-demo.gif" width="720" alt="Animation: the focused window moves to the centre and the rest of the desktop dims">
</p>

```toml
ctrl-alt-cmd-z = 'focus-mode'
```

### Floating windows that behave

- **`center`** centres a floating window on its monitor, shrinking it first if it is larger than the screen.
- **`resize` works on floating windows.** The window resizes around its centre and stays inside its monitor. `width` and `height` change one side; `smart` changes the longer side and `smart-opposite` the shorter, keeping the aspect ratio.

Together with `on-window-detected` a rule can open a window floating, sized and centred:

```toml
[[on-window-detected]]
    if.app-id = 'com.apple.QuickTimePlayerX'
    run = ['layout floating', 'resize smart 1600', 'center']
```

### Events for workspace bars

`aerospace subscribe` gains `window-closed` and `window-moved`, so a bar can follow windows without polling `list-windows`. `window-moved` also reports moves made by `on-window-detected` callbacks, and minimising or restoring a window.

### Hidden windows stay hidden

AeroSpace parks the windows of invisible workspaces in a bottom corner of their monitor. When a monitor sits between two others, both of its bottom corners touch a neighbour, macOS pulls the parked window back onto that neighbour, and it flickers at the edge of the screen. Such a monitor now parks hidden windows in the nearest clean outer corner of another monitor.

### Aspect ratio for a lone window

The single-window and accordion aspect-ratio work from upstream [PR #2093](https://github.com/nikitabobko/AeroSpace/pull/2093), adapted to the current code. Alpha's width rules build on it.

## Upstream fixes included

Open upstream pull requests merged unchanged, except where noted. Credit belongs to their authors.

| PR | Fixes |
|---|---|
| [#2179](https://github.com/nikitabobko/AeroSpace/pull/2179) | With separate Spaces per display, focus lands on the requested window of a multi-window app instead of one on another monitor ([#101](https://github.com/nikitabobko/AeroSpace/issues/101)). Adapted to the `MonitorInfo` rename. |
| [#2225](https://github.com/nikitabobko/AeroSpace/pull/2225) | A new native tab in Finder or Ghostty takes its predecessor's place in the tree ([#68](https://github.com/nikitabobko/AeroSpace/issues/68)). |
| [#2174](https://github.com/nikitabobko/AeroSpace/pull/2174) | A window returns to its place in the layout after macOS native full screen. |
| [#2201](https://github.com/nikitabobko/AeroSpace/pull/2201) | Focus is restored after a transient dialog closes. |
| [#2299](https://github.com/nikitabobko/AeroSpace/pull/2299) | A cancelled focus request no longer steals focus from a newer one. |
| [#2220](https://github.com/nikitabobko/AeroSpace/pull/2220) | A window made floating by `on-window-detected` no longer stays at its tile position. |
| [#2281](https://github.com/nikitabobko/AeroSpace/pull/2281) | No `focus` crash when a floating window moves or closes during the command. |
| [#2232](https://github.com/nikitabobko/AeroSpace/pull/2232) | No crash while displays are being reconfigured. |
| [#1944](https://github.com/nikitabobko/AeroSpace/pull/1944) | `move-workspace-to-monitor` chooses the replacement workspace before moving. |

## Things to know

- **This is a personal build.** There are no releases, no issue tracker and no support. It is public so the code can be read and borrowed, and so it can be built from source.
- **It tracks upstream.** The branch is rebased onto upstream `main`; nothing upstream is rewritten. Current base: v0.21.3-Beta.
- **#2179 uses a private macOS API.** Upstream has chosen not to ship private APIs. Alpha calls two undocumented SkyLight functions to fix cross-monitor focus, with a guard that falls back to stock behaviour if a macOS update removes them.
- **The config is not backward compatible.** Stock AeroSpace rejects `single-window-width-rules` and the other new keys. Remove them before going back to a stock build.
- **Building:** `./build-personal-release.sh` produces a signed app and CLI from a clean working tree. It reads the signing identity from `~/.config/aerospace/env`; see `personal-build.env.example` and the [build notes](docs/personal-build.md).

## Credit

AeroSpace is by [Nikita Bobko](https://github.com/nikitabobko) and its contributors, MIT licensed. The upstream fixes above are the work of their respective authors. The documentation for everything not listed on this page is [upstream's](https://nikitabobko.github.io/AeroSpace/guide).
