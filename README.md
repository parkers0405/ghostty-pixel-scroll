<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## Ghostty Pixel Scroll Fork

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) with smooth pixel-level scrolling, spring-based animations, an embedded Neovim GUI mode, and a slide-out panel system. Everything runs on Ghostty's existing GPU renderer (Metal/OpenGL) -- no external dependencies.

Drop-in replacement for stock Ghostty. Pixel scrolling and scroll animation are on by default.

### Quick Start

Add to `~/.config/ghostty/config`:

```
# Recommended defaults (these are already on -- listed for reference)
pixel-scroll = true
cursor-animation-duration = 0.06
scroll-animation-duration = 0.15

# Optional: matte ink rendering for a refined look
matte-rendering = 0.5

# Optional: more scroll bounce (try 0.3 for a Neovide-like feel)
# scroll-animation-duration = 0.3
# scroll-animation-bounciness = 0.2
```

For Neovim GUI mode, type `nvim-gui` in the terminal -- no config needed.

---

## Terminal Mode

Your normal shell. These options control scrolling, cursor animation, and visual rendering in terminal mode. All animations use critically damped springs (same physics as Neovide).

### Scrolling

| Option | Default | Description |
|---|---|---|
| `pixel-scroll` | `true` | Sub-line pixel scrolling for trackpads/mice. Viewport moves by actual pixels, not whole lines. Text stays crisp (rounded to integer pixels). |
| `scroll-animation-duration` | `0.15` | Spring animation duration for scroll events and content arrival (seconds). 0 = instant snap. Higher = more glide. |
| `scroll-animation-bounciness` | `0.0` | Scroll spring overshoot. 0 = critically damped (no bounce). Values up to 1.0 add progressively more bounce/oscillation. |
| `invert-touchpad-scroll` | `false` | Invert scroll direction for precision devices (touchpads only). Does not affect mouse wheel. |

**How terminal scroll animation works:** All scroll events (user scrollback, content arrival, page jumps) feed into a single critically damped spring. The spring position represents lines of visual offset from the true viewport position. As new output arrives or you scroll, the spring accumulates the delta and decays smoothly to zero. Small jumps get a quick ease, large jumps (page-up, `cat bigfile`) get a satisfying spring settle. The cursor stays in sync with the spring -- it visually tracks the content offset during animation.

When `pixel-scroll` is true and `scroll-animation-duration` is 0, the auto-default kicks in and sets scroll animation to 0.3s. Set `scroll-animation-duration = 0.001` if you genuinely want pixel scrolling with no spring animation.

### Cursor

| Option | Default | Description |
|---|---|---|
| `cursor-animation-duration` | `0.06` | Spring animation duration for cursor movement (seconds). 0 = instant teleport. The cursor glides between grid positions with a 4-corner stretchy effect. |
| `cursor-animation-bounciness` | `0.0` | Cursor spring overshoot. 0 = critically damped. Up to 1.0 for bounce. |

The cursor animation is Neovide-style: a 2D spring moves the cursor center, and 4 independent corner points trail behind with stretch/squash. Works in both terminal mode and Neovim GUI mode.

When `pixel-scroll` is true and `cursor-animation-duration` is 0, the auto-default kicks in and sets it to 0.06s. Set `cursor-animation-duration = 0.001` to explicitly disable.

### Visual / Rendering

| Option | Default | Description |
|---|---|---|
| `matte-rendering` | `0.0` | Ink/matte post-processing intensity (0.0-1.0). Adds subtle desaturation, shadow lift, and cool-tinted shadows. Recommended: `0.5`. |
| `text-gamma` | `0.0` | Glyph weight. Positive = thicker/bolder, negative = thinner/lighter. |
| `text-contrast` | `0.0` | Glyph edge sharpness. Higher values steepen the alpha curve for crisper text. |

### Panel GUI

Slide-out panels that run alongside your terminal. The terminal grid shrinks to make room (split, not overlay). Panels slide in/out with spring animations.

| Option | Default | Description |
|---|---|---|
| `panel-gui-1` | `""` | First panel slot. Format: `position:module` (e.g. `right:menu`, `bottom:lazygit`). |
| `panel-gui-2` | `""` | Second panel slot. Same format. |
| `panel-gui-size` | `0.35` | Panel width/height as fraction of the surface (0.0-1.0). |

**Positions:** `right`, `left`, `top`, `bottom`
**Modules:** `menu` (interactive launcher with favorites, recent commands, file explorer) or any program name (`lazygit`, `htop`, `lazydocker`, etc.)

**Default keybind:** `Ctrl+/` toggles the menu panel. Custom keybinds:

```
keybind = ctrl+shift+p=toggle_panel:panel
keybind = ctrl+shift+g=toggle_panel:lazygit
```

The `menu` module has vim-style navigation (j/k/h/l), section expand/collapse, fuzzy search (`/`), favorites management (a/e/d keys), git status indicators in the file tree, and `o` to open files in nvim-gui mode.

---

## Neovim GUI Mode

Type `nvim-gui` in the terminal to transform the current session into a native Neovim GUI. The shell function sends OSC 1338 which switches Ghostty from terminal rendering to a full Neovim multigrid UI renderer. Completely separate rendering path from terminal mode -- different scroll system, different cursor handling, different everything.

**Features:**

- Per-window scroll springs -- each Neovim window animates independently
- Scroll region awareness -- statusline, winbar, cmdline stay fixed while content scrolls
- 4-corner stretchy cursor animation (Neovide-style)
- Sonicboom VFX ring on Vim mode changes (normal/insert/visual)
- Floating window rendering with z-order, clipping, and opacity springs
- Window position springs for smooth layout transitions
- All your Neovim plugins and config work normally

### Neovim GUI Config

| Option | Default | Description |
|---|---|---|
| `neovim-gui` | `""` | Set to `spawn` (recommended), `embed`, or a socket path. Empty = normal terminal. |
| `neovim-gui-alias` | `nvim-gui` | Shell function name for entering GUI mode. Set to empty to disable. |
| `neovim-corner-radius` | `0.0` | SDF rounded corners on Neovim windows (pixels). Auto-defaults to `8.0` in GUI mode. |
| `neovim-gap-color` | `#0a0a0a` | Color visible between windows when corner radius > 0. |

> **You don't need `neovim-gui` in your config.** Just type `nvim-gui` (or whatever you set `neovim-gui-alias` to) in the terminal. It sends OSC 1338 to switch to GUI mode on the fly. Only set `neovim-gui = spawn` if you want Ghostty to always launch as a Neovim GUI.

### Neovim GUI Animation

The GUI mode shares the same config keys as terminal mode but they behave differently:

| Option | Terminal behavior | Neovim GUI behavior |
|---|---|---|
| `scroll-animation-duration` | Single spring for all scroll events. Default `0.15`. | Per-window springs. Auto-defaults to `0.3` if set to 0. Matches Neovide's `scroll_animation_length`. |
| `scroll-animation-bounciness` | Controls spring overshoot. | Not used -- GUI windows are always critically damped. |
| `cursor-animation-duration` | 2D spring + corner stretch. Default `0.06`. | Same spring + corner stretch, plus sonicboom VFX on mode change. Auto-defaults to `0.06`. |
| `cursor-animation-bounciness` | Controls cursor spring overshoot. | Same. |

**Auto-defaults:** When Neovim GUI is active (via config or OSC 1338) and values are at 0, sensible Neovide-like defaults apply automatically:
- `cursor-animation-duration` -> `0.06`
- `scroll-animation-duration` -> `0.3`
- `neovim-corner-radius` -> `8.0`

Your explicit values always take priority. Set a tiny value like `0.001` to genuinely disable an animation.

Pass extra args to Neovim via `GHOSTTY_NVIM_ARGS="--clean"` environment variable.

---

## All Config Options (Reference)

### Animation & Scrolling

| Option | Default | Applies to | Description |
|---|---|---|---|
| `pixel-scroll` | `true` | Terminal | Sub-line pixel scrolling. |
| `scroll-animation-duration` | `0.15` | Both | Scroll spring duration (seconds). 0 = snap. GUI auto-defaults to 0.3. |
| `scroll-animation-bounciness` | `0.0` | Terminal | Scroll spring overshoot (0.0-1.0). |
| `cursor-animation-duration` | `0.06` | Both | Cursor spring duration (seconds). 0 = teleport. |
| `cursor-animation-bounciness` | `0.0` | Both | Cursor spring overshoot (0.0-1.0). |
| `invert-touchpad-scroll` | `false` | Terminal | Invert touchpad scroll direction. |

### Neovim GUI

| Option | Default | Description |
|---|---|---|
| `neovim-gui` | `""` | `spawn`, `embed`, socket path, or empty. |
| `neovim-gui-alias` | `nvim-gui` | Shell function name for entering GUI mode. |
| `neovim-corner-radius` | `0.0` | Window corner radius (px). Auto-defaults to 8. |
| `neovim-gap-color` | `#0a0a0a` | Gap color between windows. |

### Panel GUI

| Option | Default | Description |
|---|---|---|
| `panel-gui-1` | `""` | Panel slot 1 (`position:module`). |
| `panel-gui-2` | `""` | Panel slot 2 (`position:module`). |
| `panel-gui-size` | `0.35` | Panel size (fraction of surface). |

### Visual

| Option | Default | Description |
|---|---|---|
| `matte-rendering` | `0.0` | Ink post-processing (0.0-1.0). |
| `text-gamma` | `0.0` | Glyph weight adjustment. |
| `text-contrast` | `0.0` | Glyph edge sharpness. |

---

## How It Works

### Terminal Pixel Scrolling

Normal terminals scroll by jumping whole lines. This fork tracks scroll input as raw pixel deltas and maintains a sub-line offset. The renderer loads one extra row above the viewport. As you scroll, the offset shifts the entire grid by actual pixels. When the offset crosses a cell height, the viewport advances one line and the offset wraps.

On the GPU, both the background fragment shader and text vertex shader receive the same `pixel_scroll_offset_y` uniform, rounded to whole pixels so text stays on integer boundaries (no sub-pixel blur). At 165hz with ~20px cells you get ~20 distinct positions per line -- completely smooth.

### Terminal Scroll Animation

All scroll events (output arrival, user scrollback, page jumps) accumulate into a critically damped spring. The spring position is in lines. Each frame, the spring decays toward zero and the fractional position maps to `pixel_scroll_offset_y`. The cursor corners track this offset so the cursor moves in sync with content during animation.

### Neovim GUI Scrolling

Completely different system. Neovim sends scroll region info via the multigrid UI protocol. Each window gets its own independent spring. The shader applies per-cell Y offsets only to cells inside the scroll region -- statusline, winbar, and cmdline stay fixed. Floating windows have their own z-order, clipping, and opacity/position springs. This is the same approach Neovide uses, running inside Ghostty's renderer.

### Idle Cost

The animation timer only ticks while something is moving. Once all springs settle, the timer stops and Ghostty returns to pure event-driven rendering with zero animation overhead.

---

## Linux Refresh Rate

On macOS, the animation timer uses CVDisplayLink for refresh rate detection. On Linux the timer defaults to **~165hz** (hardcoded `display_refresh_ns` in `src/renderer/generic.zig`).

Animation timing is wall-clock based -- a 0.15s spring takes 0.15s at any refresh rate. Lower refresh rates just show fewer intermediate frames. To change the timer rate, edit `display_refresh_ns` (e.g. `16_666_666` for 60hz, `6_944_444` for 144hz).

## Platform Support

Tested on **Linux (OpenGL)**. macOS Metal shaders mirror the OpenGL implementation but are untested.

## Known Issues

- [ ] Paste doesn't work correctly in nvim-gui mode
- [ ] Mouse scroll direction inverted in nvim-gui (natural scrolling)
- [ ] Linux emoji/unicode rendering issues (works in stock Ghostty)
- [ ] Linux animation timer hardcoded to ~165hz (needs auto-detection)
- [ ] macOS Metal shaders untested

Contributions welcome.

## Building

**With Nix (recommended):**

```bash
nix-shell --run "zig build -Doptimize=ReleaseFast"
```

**Without Nix:**

Zig 0.15+ and stock Ghostty dependencies (GTK4, libadwaita, etc). See Ghostty's [build docs](https://ghostty.org/docs/install/build), then:

```bash
zig build -Doptimize=ReleaseFast
```

Binary: `zig-out/bin/ghostty`

```bash
# Hyprland
bind = SUPER, Return, exec, /path/to/zig-out/bin/ghostty

# Sway
bindsym $mod+Return exec /path/to/zig-out/bin/ghostty

# Or just run it
./zig-out/bin/ghostty
```

---

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

In all categories, I am not trying to claim that Ghostty is the
best (i.e. the fastest, most feature-rich, or most native). But
Ghostty is competitive in all three categories and Ghostty
doesn't make you choose between them.

Ghostty also intends to push the boundaries of what is possible with a
terminal emulator by exposing modern, opt-in features that enable CLI tool
developers to build more feature rich, interactive applications.

While aiming for this ambitious goal, our first step is to make Ghostty
one of the best fully standards compliant terminal emulator, remaining
compatible with all existing shells and software while supporting all of
the latest terminal innovations in the ecosystem. You can use Ghostty
as a drop-in replacement for your existing terminal emulator.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

The high-level ambitious plan for the project, in order:

|  #  | Step                                                      | Status |
| :-: | --------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                    |   ✅   |
|  2  | Competitive performance                                   |   ✅   |
|  3  | Basic customizability -- fonts, bg colors, etc.           |   ✅   |
|  4  | Richer windowing features -- multi-window, tabbing, panes |   ✅   |
|  5  | Native Platform Experiences (i.e. Mac Preference Panel)   |   ⚠️   |
|  6  | Cross-platform `libghostty` for Embeddable Terminals      |   ⚠️   |
|  7  | Windows Terminals (including PowerShell, Cmd, WSL)        |   ❌   |
|  N  | Fancy features (to be expanded upon later)                |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements enough control sequences to be used by hundreds of
testers daily for over the past year. Further, we've done a
[comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

We believe Ghostty is one of the most compliant terminal emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

We need better benchmarks to continuously verify this, but Ghostty is
generally in the same performance category as the other highest performing
terminal emulators.

For rendering, we have a multi-renderer architecture that uses OpenGL on
Linux and Metal on macOS. As far as I'm aware, we're the only terminal
emulator other than iTerm that uses Metal directly. And we're the only
terminal emulator that has a Metal renderer that supports ligatures (iTerm
uses a CPU renderer if ligatures are enabled). We can maintain around 60fps
under heavy load and much more generally -- though the terminal is
usually rendering much lower due to little screen changes.

For IO, we have a dedicated IO thread that maintains very little jitter
under heavy IO load (i.e. `cat <big file>.txt`). On benchmarks for IO,
we're usually within a small margin of other fast terminal emulators.
For example, reading a dump of plain text is 4x faster compared to iTerm and
Kitty, and 2x faster than Terminal.app. Alacritty is very fast but we're still
around the same speed (give or take) and our app experience is much more
feature rich.

> [!NOTE]
> Despite being _very fast_, there is a lot of room for improvement here.

#### Richer Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- The Linux app is built with GTK.

There are more improvements to be made. The macOS settings window is still
a work-in-progress. Similar improvements will follow with Linux.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate actually libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. At the time of
writing this, the API isn't stable yet and we haven't tagged an official
release, but the core logic is well proven (since Ghostty uses it) and
we're working hard on it now.

The ultimate goal is not hypothetical! The macOS app is a `libghostty` consumer.
The macOS app is a native Swift app developed in Xcode and `main()` is
within Swift. The Swift app links to `libghostty` and uses the C API to
render terminals.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
