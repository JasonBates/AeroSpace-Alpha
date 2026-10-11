# Setting up AeroSpace Alpha with an AI assistant

This page is written for an AI coding agent (Claude Code, Codex, or similar)
that has been asked to install [AeroSpace Alpha](../README.md) and set it up
the way I use it: AeroSpace as the window manager, **Caps Lock as the single
modifier key** for every AeroSpace shortcut, and **three-finger trackpad
swipes** to change workspace. A person can follow it too.

If you are the agent, read the whole page before running anything, then work
through the sections in order. Each section ends with a check. Do not move on
until the check passes.

Everything here except the Alpha-only config keys applies to stock
AeroSpace as well.

## Ground rules for the agent

- **Nothing here needs `sudo`, and nothing disables System Integrity
  Protection.** If a step seems to require either, stop and re-read it.
- **Three steps need a click in System Settings that you cannot make:**
  granting Accessibility to AeroSpace, granting Input Monitoring and the
  driver extension to Karabiner-Elements, and granting Accessibility to
  SwipeAeroSpace. At each one, tell the user exactly what to click, wait for
  them to say it is done, then run the check. Do not try to script these
  permissions.
- **Back up before you overwrite.** Copy an existing `~/.aerospace.toml` or
  `~/.config/karabiner/karabiner.json` to a dated backup first, and tell the
  user where it is.
- **If the user already has a config, merge rather than replace.** Add the
  keys this page introduces and keep their bindings. Ask before changing a
  shortcut they already use.
- **Do not invent config keys or commands.** Alpha's additions are listed in
  the [README](../README.md); everything else is documented in the
  [upstream guide](https://nikitabobko.github.io/AeroSpace/guide) and
  [command reference](https://nikitabobko.github.io/AeroSpace/commands).
- **Homebrew is assumed** for Karabiner-Elements and SwipeAeroSpace. If
  `brew` is missing, ask the user whether to install it or to install those
  two apps by hand from their release pages.
- **Finish with the report in the last section.** The user should learn what
  changed, what to press, and how to undo it.

## What you are installing

| Piece | What it does | Where it comes from |
|---|---|---|
| AeroSpace Alpha | The tiling window manager. A build of upstream AeroSpace with pending fixes and extra features; see the [README](../README.md). | [Releases page](https://github.com/JasonBates/AeroSpace-Alpha/releases/latest), a signed and notarized zip |
| Karabiner-Elements | Keyboard remapper. One rule turns Caps Lock into `ctrl+alt+cmd` when held and Escape when tapped, so every AeroSpace shortcut is Caps Lock plus one key. | `brew install --cask karabiner-elements` |
| SwipeAeroSpace | Menu bar app that turns three-finger horizontal swipes into workspace changes, and a swipe up into a workspace overview. | `brew install --cask mediosz/tap/swipeaerospace` |

Why Caps Lock: AeroSpace needs a modifier that no app uses, and `alt` on its
own collides with typed characters on many keyboards. `ctrl+alt+cmd` collides
with nothing, and Caps Lock is a large, idle key under the little finger. The
tap-for-Escape part is a bonus for Vim users and costs nothing.

## 1. Before you start

Run these and note the answers.

```bash
sw_vers -productVersion                 # needs macOS 13 or later
command -v brew                         # Homebrew present?
pgrep -x AeroSpace && echo "AeroSpace is running"
ls -la ~/.aerospace.toml ~/.config/aerospace/aerospace.toml 2>/dev/null
brew list --cask 2>/dev/null | grep -E '^(aerospace|karabiner-elements|swipeaerospace)$'
pgrep -lx 'yabai|Amethyst|Rectangle|Magnet'   # other window managers
```

What to do with the answers:

- **Stock AeroSpace is installed.** Alpha replaces it in place, at
  `/Applications/AeroSpace.app`. If it was installed with Homebrew, remove the
  cask first so Homebrew does not later overwrite Alpha on an upgrade. The
  config file is left alone.

  ```bash
  brew uninstall --cask aerospace
  ```

- **AeroSpace is running.** Quit it before installing.

  ```bash
  osascript -e 'quit app "AeroSpace"'
  ```

- **A config file exists.** Back it up now and merge later (section 3).

  ```bash
  cp ~/.aerospace.toml ~/.aerospace.toml.bak-$(date +%Y%m%d)
  ```

- **Another tiling manager is running** (yabai, Amethyst, Rectangle, Magnet).
  Two window managers fight. Ask the user to quit it, and ask whether to
  remove it from login items.

## 2. Install AeroSpace Alpha

Find the latest release asset, download it to a fresh directory, and unpack
it. The zip contains `AeroSpace.app`, the `aerospace` command line tool under
`bin/`, man pages and shell completion.

```bash
mkdir -p ~/Downloads/aerospace-alpha && cd ~/Downloads/aerospace-alpha
url=$(curl -s https://api.github.com/repos/JasonBates/AeroSpace-Alpha/releases/latest \
      | grep browser_download_url | grep '\.zip' | cut -d'"' -f4)
curl -L -o alpha.zip "$url"
unzip -q alpha.zip
ls AeroSpace-Alpha-v*/
```

Install the app and the command line tool. Use a `bin` directory that is on
the user's `PATH`; `/opt/homebrew/bin` on Apple silicon or `/usr/local/bin`
on Intel are the usual choices, `~/.local/bin` if the user keeps one.

```bash
rm -rf /Applications/AeroSpace.app
ditto AeroSpace-Alpha-v*/AeroSpace.app /Applications/AeroSpace.app
install -m 755 AeroSpace-Alpha-v*/bin/aerospace /opt/homebrew/bin/aerospace
```

Optionally install the man pages and completion for the user's shell:

```bash
mkdir -p ~/.local/share/man/man1 && cp AeroSpace-Alpha-v*/manpage/*.1 ~/.local/share/man/man1/
ls AeroSpace-Alpha-v*/shell-completion/      # zsh, bash and fish completion
```

Launch it:

```bash
open -a AeroSpace
```

**Hand over to the user.** On first launch macOS asks for Accessibility
access. The user must open System Settings, go to Privacy & Security, then
Accessibility, and switch on AeroSpace. AeroSpace does nothing until this is
granted. Wait for the user to confirm.

**Check.** Both lines should show the same version, and the version should be
Alpha's short `0.x` number followed by a commit hash, not upstream's
`0.21.x-Beta`. The monitor list should name every connected display.

```bash
aerospace --version
aerospace list-monitors
```

If `aerospace` reports it cannot connect to the server, Accessibility has not
been granted yet, or the app is not running. Do not continue until this check
passes.

## 3. Write the config

AeroSpace reads `~/.aerospace.toml` (or `~/.config/aerospace/aerospace.toml`).
The starter below is a trimmed version of my daily config. It assumes the
Karabiner rule from section 4, so every binding is `ctrl-alt-cmd-…`, which the
user will press as Caps Lock plus the key.

**If the user has no config,** write this file as `~/.aerospace.toml`.

**If the user has a config,** keep their file and add only these parts to it:
the two Alpha keys (`single-window-width-rules` and
`apply-aspect-to-accordion`), the SwipeAeroSpace line in
`after-startup-command`, and whichever bindings they want. Ask before changing
their modifier. If they keep `alt` bindings, the Karabiner rule still works;
Caps Lock then simply adds a second modifier set.

```toml
config-version = 2
start-at-login = true
auto-reload-config = true

# SwipeAeroSpace (section 5) is started here. It reconnects by itself within a
# few seconds if AeroSpace restarts, so it never needs relaunching.
after-startup-command = [
  'exec-and-forget open -a SwipeAeroSpace',
]

enable-normalization-flatten-containers = true
enable-normalization-opposite-orientation-for-nested-containers = true
accordion-padding = 30
default-root-container-layout = 'tiles'
default-root-container-orientation = 'auto'

# Alpha only. A lone tiled window is centred at a percentage of the monitor's
# usable width; the highest matching min-monitor-width wins. Stock AeroSpace
# rejects these two keys, so remove them before going back to stock.
single-window-width-rules = [
  { min-monitor-width = 0,    width-percent = 66 },
  { min-monitor-width = 2000, width-percent = 50 },
]
apply-aspect-to-accordion = 'none'

# Keep the pointer where it is when keyboard focus changes monitors.
on-focused-monitor-changed = []
automatically-unhide-macos-hidden-apps = false

# Only the workspaces with shortcuts. SwipeAeroSpace steps through every
# workspace that exists, so an empty A to Z would make swiping tedious.
persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

key-mapping.preset = 'qwerty'

# Smaller gaps on a laptop's built-in display, 10 points elsewhere.
gaps.inner.horizontal = [{ monitor."built-in" = 6 }, 10]
gaps.inner.vertical   = [{ monitor."built-in" = 6 }, 10]
gaps.outer.left       = [{ monitor."built-in" = 6 }, 10]
gaps.outer.bottom     = [{ monitor."built-in" = 6 }, 10]
gaps.outer.top        = [{ monitor."built-in" = 6 }, 10]
gaps.outer.right      = [{ monitor."built-in" = 6 }, 10]

[mode.main.binding]
    # Caps Lock (remapped by Karabiner to ctrl+alt+cmd) is the only modifier.
    # Focus and move use all-monitors-outer-frame so h/l cross monitor edges.
    ctrl-alt-cmd-h = 'focus --boundaries all-monitors-outer-frame left'
    ctrl-alt-cmd-j = 'focus --boundaries all-monitors-outer-frame down'
    ctrl-alt-cmd-k = 'focus --boundaries all-monitors-outer-frame up'
    ctrl-alt-cmd-l = 'focus --boundaries all-monitors-outer-frame right'
    ctrl-alt-cmd-left  = 'focus --boundaries all-monitors-outer-frame left'
    ctrl-alt-cmd-down  = 'focus --boundaries all-monitors-outer-frame down'
    ctrl-alt-cmd-up    = 'focus --boundaries all-monitors-outer-frame up'
    ctrl-alt-cmd-right = 'focus --boundaries all-monitors-outer-frame right'

    ctrl-alt-cmd-shift-h = 'move --boundaries all-monitors-outer-frame left'
    ctrl-alt-cmd-shift-j = 'move --boundaries all-monitors-outer-frame down'
    ctrl-alt-cmd-shift-k = 'move --boundaries all-monitors-outer-frame up'
    ctrl-alt-cmd-shift-l = 'move --boundaries all-monitors-outer-frame right'
    ctrl-alt-cmd-shift-left  = 'move --boundaries all-monitors-outer-frame left'
    ctrl-alt-cmd-shift-down  = 'move --boundaries all-monitors-outer-frame down'
    ctrl-alt-cmd-shift-up    = 'move --boundaries all-monitors-outer-frame up'
    ctrl-alt-cmd-shift-right = 'move --boundaries all-monitors-outer-frame right'

    ctrl-alt-cmd-1 = 'workspace 1'
    ctrl-alt-cmd-2 = 'workspace 2'
    ctrl-alt-cmd-3 = 'workspace 3'
    ctrl-alt-cmd-4 = 'workspace 4'
    ctrl-alt-cmd-5 = 'workspace 5'
    ctrl-alt-cmd-6 = 'workspace 6'
    ctrl-alt-cmd-7 = 'workspace 7'
    ctrl-alt-cmd-8 = 'workspace 8'
    ctrl-alt-cmd-9 = 'workspace 9'
    ctrl-alt-cmd-shift-1 = 'move-node-to-workspace 1'
    ctrl-alt-cmd-shift-2 = 'move-node-to-workspace 2'
    ctrl-alt-cmd-shift-3 = 'move-node-to-workspace 3'
    ctrl-alt-cmd-shift-4 = 'move-node-to-workspace 4'
    ctrl-alt-cmd-shift-5 = 'move-node-to-workspace 5'
    ctrl-alt-cmd-shift-6 = 'move-node-to-workspace 6'
    ctrl-alt-cmd-shift-7 = 'move-node-to-workspace 7'
    ctrl-alt-cmd-shift-8 = 'move-node-to-workspace 8'
    ctrl-alt-cmd-shift-9 = 'move-node-to-workspace 9'

    ctrl-alt-cmd-tab       = 'workspace-back-and-forth'
    ctrl-alt-cmd-shift-tab = 'move-workspace-to-monitor --wrap-around next'
    ctrl-alt-cmd-f     = 'layout floating tiling'
    ctrl-alt-cmd-enter = 'fullscreen'
    ctrl-alt-cmd-slash = 'layout tiles horizontal vertical'
    ctrl-alt-cmd-comma = 'layout accordion horizontal vertical'
    ctrl-alt-cmd-q     = 'close'

    # Alpha only: Focus Mode, and resizing that also works on a lone centred
    # window and on floating windows.
    ctrl-alt-cmd-z     = 'focus-mode'
    ctrl-alt-cmd-minus = 'resize smart -100'
    ctrl-alt-cmd-equal = 'resize smart +100'

    ctrl-alt-cmd-shift-semicolon = 'mode service'

[mode.service.binding]
    esc = ['reload-config', 'mode main']
    r = ['flatten-workspace-tree', 'mode main']         # reset layout
    f = ['layout floating tiling', 'mode main']
    backspace = ['close-all-windows-but-current', 'mode main']
    alt-shift-h = ['join-with left', 'mode main']
    alt-shift-j = ['join-with down', 'mode main']
    alt-shift-k = ['join-with up', 'mode main']
    alt-shift-l = ['join-with right', 'mode main']

# Settings and utility windows float instead of tiling.
[[on-window-detected]]
    if.app-id = 'com.apple.systempreferences'
    run = 'layout floating'

[[on-window-detected]]
    if.app-id = 'org.pqrs.Karabiner-Elements.Settings'
    run = 'layout floating'

[[on-window-detected]]
    if.app-id = 'org.pqrs.Karabiner-EventViewer'
    run = 'layout floating'

[[on-window-detected]]
    if.app-id = 'com.apple.calculator'
    run = 'layout floating'
```

Reload and check for errors. `reload-config` prints any problem and exits
non-zero; with `auto-reload-config = true` later saves reload by themselves.

```bash
aerospace reload-config && echo "config OK"
aerospace config --config-path
aerospace config --get mode.main.binding.ctrl-alt-cmd-z    # prints: focus-mode
```

**Check.** The three commands above succeed, and the user sees a window
shrink to the centre of the screen when it is the only tiled window on a
workspace. Nothing can be pressed yet; the shortcuts need section 4.

## 4. Caps Lock as the modifier with Karabiner-Elements

Install and launch it. The first launch creates `~/.config/karabiner/` and
opens the settings window.

```bash
brew install --cask karabiner-elements
open -a "Karabiner-Elements"
```

**Hand over to the user.** Karabiner needs two approvals, and macOS asks for
them in its own dialogs:

1. **Driver extension.** System Settings, General, Login Items & Extensions,
   Driver Extensions (on older macOS, Privacy & Security, then Allow). Switch
   on Karabiner-VirtualHIDDevice-Manager.
2. **Input Monitoring.** System Settings, Privacy & Security, Input
   Monitoring. Switch on `karabiner_grabber` (and `Karabiner-EventViewer` if
   it appears).

The Karabiner settings window shows a warning banner until both are done.
Wait for the user to confirm the banner has gone.

Now add the rule. Write it as a Karabiner asset file first, so the user can
also see and toggle it in the settings window under Complex Modifications:

```bash
mkdir -p ~/.config/karabiner/assets/complex_modifications
cat > ~/.config/karabiner/assets/complex_modifications/aerospace-caps-lock.json <<'JSON'
{
  "title": "AeroSpace modifier",
  "rules": [
    {
      "description": "Caps Lock → ctrl+alt+cmd when held, Escape when tapped (AeroSpace modifier)",
      "manipulators": [
        {
          "type": "basic",
          "from": { "key_code": "caps_lock", "modifiers": { "optional": ["any"] } },
          "to": [
            { "key_code": "left_control", "modifiers": ["left_option", "left_command"] }
          ],
          "to_if_alone": [ { "key_code": "escape" } ]
        }
      ]
    }
  ]
}
JSON
"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli" \
  --lint-complex-modifications ~/.config/karabiner/assets/complex_modifications/aerospace-caps-lock.json
```

Then enable it in the selected profile. Either ask the user to open
Karabiner-Elements, Complex Modifications, Add rule, and enable "AeroSpace
modifier", or do it for them by appending the rule to `karabiner.json`.
Karabiner reloads the file as soon as it is saved. The script backs the file
up and is safe to run twice.

```bash
python3 - <<'PY'
import json, pathlib, shutil, datetime
home = pathlib.Path.home()
cfg = home / ".config/karabiner/karabiner.json"
asset = home / ".config/karabiner/assets/complex_modifications/aerospace-caps-lock.json"
rule = json.loads(asset.read_text())["rules"][0]
data = json.loads(cfg.read_text())
shutil.copy(cfg, cfg.with_suffix(".json.bak-" + datetime.date.today().isoformat()))
profiles = [p for p in data["profiles"] if p.get("selected")] or data["profiles"][:1]
for p in profiles:
    rules = p.setdefault("complex_modifications", {}).setdefault("rules", [])
    if not any(r.get("description") == rule["description"] for r in rules):
        rules.append(rule)
        print("added to profile:", p["name"])
    else:
        print("already present in profile:", p["name"])
cfg.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n")
PY
```

Tell the user what has changed on their keyboard: Caps Lock no longer toggles
capitals. Held, it is the AeroSpace modifier; tapped, it is Escape. If they
want to keep Caps Lock, change `"key_code": "caps_lock"` in the asset file to
another idle key, `right_command` or `right_option` for example, and re-run
the script.

**Check.** Ask the user to hold Caps Lock and press `2`, then `1`. Each
press should change the focused workspace:

```bash
aerospace list-workspaces --focused
```

If nothing happens, see Troubleshooting. If a stray `^⌥⌘` appears in a text
field instead, Karabiner is working and AeroSpace is not receiving the chord;
check `aerospace reload-config` for errors.

## 5. Trackpad swipes with SwipeAeroSpace

```bash
brew install --cask mediosz/tap/swipeaerospace
open -a SwipeAeroSpace
```

**Hand over to the user.** SwipeAeroSpace needs Accessibility: System
Settings, Privacy & Security, Accessibility, switch on SwipeAeroSpace. Wait
for confirmation.

It is started by the `after-startup-command` line in the config, so it does
not need its own login item; it reconnects by itself if AeroSpace restarts.
Its settings live in the menu bar app, and an optional file overrides them.
This is the one I use (the misspelt directory name is the app's own):

```bash
mkdir -p ~/.config/swipeareospace
cat > ~/.config/swipeareospace/config.toml <<'TOML'
# SwipeAeroSpace: three-finger swipe between AeroSpace workspaces.
threshold = 2.0      # travel needed before a swipe counts; default 1.0, higher = less sensitive
multiSwipe = false   # one swipe = exactly one workspace, never several
wrap = false
skip-empty = false
TOML
```

The app reloads the file on save and shows any error in its Settings window.

**Check.** The app is running and a three-finger horizontal swipe changes the
focused workspace. Ask the user to swipe, then run:

```bash
pgrep -x SwipeAeroSpace && aerospace list-workspaces --focused
```

If the user prefers macOS's own three-finger swipe between Spaces, that
gesture is already taken; set SwipeAeroSpace to four fingers in its settings,
or change the macOS gesture under System Settings, Trackpad, More Gestures.

## 6. Final check

Run the lot and compare with the expected results.

| Command | Expect |
|---|---|
| `aerospace --version` | Client and server agree, Alpha `0.x` with a commit hash |
| `aerospace list-monitors` | Every connected display |
| `aerospace reload-config` | No output, exit 0 |
| `aerospace config --get mode.main.binding.ctrl-alt-cmd-z` | `focus-mode` |
| `karabiner_cli --show-current-profile-name` (full path as in section 4) | The profile the rule was added to |
| `pgrep -x SwipeAeroSpace` | A process id |
| User holds Caps Lock and presses `2` | `aerospace list-workspaces --focused` prints `2` |
| User holds Caps Lock and presses `z` twice | The window centres and the rest dims, then returns |
| User swipes three fingers left and right | The focused workspace changes |

## Troubleshooting

- **Caps Lock does nothing.** In order: the Karabiner banner is still
  showing (permissions), the rule was added to a profile that is not
  selected (`karabiner_cli --list-profile-names`), or Karabiner-Elements is
  not running (`pgrep -x karabiner_grabber`). Karabiner-EventViewer shows
  what each key sends; holding Caps Lock should show `left_control` with
  `left_option` and `left_command`.
- **Shortcuts work but focus lands on the wrong window across monitors.**
  That is the bug Alpha fixes. Confirm `aerospace --version` reports the
  Alpha build and not a stock one that Homebrew reinstalled.
- **`aerospace` cannot connect.** The app is not running or lacks
  Accessibility. `open -a AeroSpace`, then check System Settings.
- **Swipes do nothing.** SwipeAeroSpace lacks Accessibility, is not running,
  or the three-finger gesture is taken by macOS Spaces (section 5).
- **Config error after an edit.** `aerospace reload-config` prints the line.
  A key stock AeroSpace does not know, such as `single-window-width-rules`,
  means a stock build is running.
- **Going back to stock AeroSpace.** Remove the Alpha-only keys
  (`single-window-width-rules`, `apply-aspect-to-accordion`) and the
  Alpha-only bindings (`focus-mode`, and `resize smart` on floating or lone
  windows), then install upstream. The Karabiner rule and SwipeAeroSpace keep
  working with stock.

## 7. Report to the user

End with a short summary that covers:

- What was installed and where: the app, the `aerospace` tool, Karabiner,
  SwipeAeroSpace, and the paths of the config files written.
- What was backed up and where.
- The shortcuts, in one table: Caps Lock plus `h j k l` or arrows to focus,
  with Shift to move, `1` to `9` for workspaces, with Shift to send a window
  there, `Tab` to flip back, `Enter` for full screen, `f` to float, `z` for
  Focus Mode, `-` and `=` to resize, `q` to close, Shift `;` for the service
  mode.
- What is now different about Caps Lock, and how to pick another key.
- Which permissions were granted and where to revoke them.
- A link to the [README](../README.md) for what Alpha changes, and to the
  [upstream guide](https://nikitabobko.github.io/AeroSpace/guide) for
  everything else.
