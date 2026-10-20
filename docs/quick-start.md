# Start using AeroSpace Alpha

AeroSpace Alpha works with a normal Mac keyboard. Karabiner-Elements and
SwipeAeroSpace are optional. Install the app using the [download instructions](../README.md#download),
launch it, and grant Accessibility access when macOS asks.

With no existing AeroSpace config, Alpha uses its bundled starter configuration.
If you already have `~/.aerospace.toml` or `~/.config/aerospace/aerospace.toml`,
Alpha keeps using it: upgrading does not replace your shortcuts or settings.
The defaults below apply to builds containing the current
[starter configuration](config-examples/default-config.toml); an older release
may still contain the upstream defaults.

## Your first shortcuts

`Option` is called `alt` in the configuration file. H/J/K/L mean
left/down/up/right. These shortcuts are active while AeroSpace is enabled;
if you use Option to type special characters, choose other modifiers in the config.

| Action | Shortcut |
|---|---|
| Focus a window, including on another monitor | Option + H/J/K/L |
| Move a window | Option + Shift + H/J/K/L |
| Focus Mode: centre the window and dim the others; press again to restore | Option + Return |
| Fill the monitor with the focused window; press again to restore | Option + Shift + Return |
| Resize the split, or the width of a lone/focused window | Option + minus/equal |
| Resize height | Option + Shift + minus/equal |
| Switch workspace | Option + 1–9 |
| Send a window to a workspace | Option + Shift + 1–9 |
| Toggle horizontal/vertical tiling | Option + slash |
| Toggle accordion layout (overlapping windows) | Option + comma |
| Return to the previous workspace | Option + Tab |

Focus Mode stays on the current monitor. To move its window to the middle
display of a three-display setup (or the main display with two), remove
`--stay-on-monitor` from the `alt-enter` binding.

Moving perpendicular to the workspace's root arrangement first makes an outer
row or column before crossing to a neighbouring monitor. Move outward again to
cross. A lone window crosses directly; nested layouts retain their intermediate
swaps and moves out of containers.

## Comfortable sizing on a normal display

A lone tiled window is centred at 66% of usable width, or 50% when the monitor
is at least 2000 macOS display points wide. macOS scaling determines display
points; a panel's advertised pixel resolution is not the same measurement.
Multiple tiled windows use the full working area. No monitor names, workspace
assignments or app-specific rules are assumed.

Use the AeroSpace menu bar's **Open config** action to edit these choices. With
no existing config, it creates an editable copy at `~/.aerospace.toml`. After
saving, select **Reload config** from the same menu. Set
`single-window-width-rules = []` if you prefer a lone window to fill the area.

## Add margins on a large display

Run `aerospace list-monitors` to find its name. The starter config contains four
commented `adaptive-layout` lines above `[mode.main.binding]`. Replace
`YOUR MONITOR NAME` and uncomment them:

```toml
adaptive-layout.enabled = [{ monitor."YOUR MONITOR NAME" = true }, false]
adaptive-layout.one-column-width-percent = 33
adaptive-layout.two-column-width-percent = 66
adaptive-layout.single-row-height-percent = 90
```

Reload the config. On the selected monitor, a lone window uses 33% width; two
columns or one vertical stack of two or more rows use 66%; three or more columns
use the full width. One row uses 90% height, and multiple rows use full height.
Other monitors keep normal sizing. Focus Mode and fullscreen still work.

## Existing users and optional extras

Existing configs are not merged with the starter config automatically. Copy
only the settings and bindings you want, keeping top-level sizing settings
above `[mode.main.binding]` and shortcuts inside that section. Avoid defining
the same key twice. Back up your config before replacing it wholesale.

The [optional Caps Lock and trackpad setup](agent-setup.md) explains how to add
Karabiner and SwipeAeroSpace. Neither is required for any layout feature above.
