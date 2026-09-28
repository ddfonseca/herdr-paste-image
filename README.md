# herdr-paste-image

[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![herdr ≥ 0.7.0](https://img.shields.io/badge/herdr-%E2%89%A5%200.7.0-8b5cf6.svg)](https://herdr.dev)
[![platforms: WSL · Linux · macOS · Windows](https://img.shields.io/badge/platforms-WSL%20%C2%B7%20Linux%20%C2%B7%20macOS%20%C2%B7%20Windows-lightgrey.svg)](#requirements)

Paste a screenshot into a coding agent running inside [herdr](https://herdr.dev).

Press the key, and the image sitting in your system clipboard is written to a
file and its **path** is typed into the focused pane — which is what Claude
Code, Codex & friends actually need in order to look at an image. It's
[`tmux-paste-image`](https://github.com/jkhas8/tmux-paste-image), ported to
herdr's plugin API.

## How it works

Two plugin actions, same job, one per platform family:

- `herdr-paste-image.paste` (`paste-image.sh`) — WSL, Linux, macOS
- `herdr-paste-image.paste-windows` (`paste-image.ps1`) — native Windows

Bind whichever one matches your herdr install to a key in herdr's config. On
each press:

1. it reads the image out of the system clipboard — WSL (Windows clipboard
   through PowerShell), Wayland (`wl-paste`), X11 (`xclip`), macOS
   (`pngpaste`/`osascript`), or native Windows
   (`System.Windows.Forms.Clipboard`);
2. writes it to `~/.cache/herdr-paste-image/image_<timestamp>.png`
   (`%LOCALAPPDATA%\herdr-paste-image\image_<timestamp>.png` on native
   Windows);
3. types that path into the focused pane with `herdr pane send-text` — **without
   pressing Enter**, so you can keep typing your prompt around it.

herdr injects `$HERDR_PANE_ID` (the focused pane) and `$HERDR_BIN_PATH` into
every plugin action, so the script always knows where to paste.

WSL counts as "linux" here: it's the Linux side of herdr that loads the
`bash` action, which then reaches across to the Windows clipboard via
`powershell.exe` interop. The Windows action is for when herdr *itself* is
the native `x86_64-pc-windows-msvc` build instead — that install reports
platform `windows`, not `linux`, so the WSL action's `platforms = ["linux",
"macos"]` excludes it (`platform_unsupported` if you try anyway).

If the clipboard holds a *copied image file* instead of raw image bytes (you
hit Ctrl+C on a PNG in Explorer/Finder/a file manager), the existing path is
pasted as-is — no copy, no re-encode.

## Requirements

- herdr `>= 0.7.0`
- A clipboard source:
  - **WSL** — works out of the box, no extra install: the Windows clipboard is
    read through `powershell.exe` (WSL interop)
  - **Wayland** — `wl-paste` (`wl-clipboard`)
  - **X11** — `xclip`
  - **macOS** — `pngpaste` recommended, `osascript` fallback
  - **Native Windows** — works out of the box: `powershell.exe` on `PATH`
    (ships with Windows), no WSL required
- Tested on WSL2 and native Windows (`x86_64-pc-windows-msvc` herdr build);
  Linux and macOS backends follow the same shape as WSL

## Install

```bash
herdr plugin install ddfonseca/herdr-paste-image   # from GitHub
# or, for a local checkout:
herdr plugin link /path/to/herdr-paste-image

herdr plugin action list --plugin herdr-paste-image
```

Then bind a key in `~/.config/herdr/config.toml` (WSL, Linux, macOS):

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "herdr-paste-image.paste"
description = "paste clipboard image as a file path"
```

Or, on a native Windows herdr install, in `%APPDATA%\herdr\config.toml`:

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "herdr-paste-image.paste-windows"
description = "paste clipboard image as a file path"
```

Reload herdr's config (`prefix+shift+r`, or `herdr server reload-config`) or
restart.

Coming from tmux and want the same `prefix+P`? Use `key = "prefix+shift+p"` —
but that's herdr's default `rename_pane`, so move it first (e.g.
`rename_pane = "prefix+shift+n"`) or the binding is ignored.

## Configuration

Environment variables, or a config file in the plugin's config dir
(`herdr plugin config-dir herdr-paste-image`) with the same names — `config.env`
for the WSL/Linux/macOS action, `config.ps1` for the Windows one. The
environment wins.

| Variable | Default | What it does |
|---|---|---|
| `HERDR_PASTE_IMAGE_DIR` | `~/.cache/herdr-paste-image` (`%LOCALAPPDATA%\herdr-paste-image` on Windows) | Where images are saved |
| `HERDR_PASTE_IMAGE_KEEP_DAYS` | `14` | Delete saved images older than this on each paste; `0` disables |
| `HERDR_PASTE_IMAGE_QUIET` | `0` | `1` suppresses the herdr notification toasts |

```bash
# ~/.config/herdr/plugins/config/herdr-paste-image/config.env
HERDR_PASTE_IMAGE_DIR="$HOME/screenshots"
HERDR_PASTE_IMAGE_KEEP_DAYS=0
```

```powershell
# %APPDATA%\herdr\plugins\config\herdr-paste-image\config.ps1
$saveDir = "$env:USERPROFILE\screenshots"
$keepDays = 0
```

## Notes & tradeoffs

- **Nothing is submitted.** The path lands in the pane's input with a trailing
  space; you press Enter. Paths containing whitespace get single-quoted so they
  survive a shell — agents still resolve them.
- **Failures are toasts, not crashes.** No image in the clipboard, no focused
  pane, missing clipboard tool: each shows a herdr notification and exits
  non-zero. `herdr plugin log list --plugin herdr-paste-image` has the details.
  A PowerShell error on WSL (interop missing, clipboard access denied) is
  reported as itself, not disguised as an empty clipboard.
- **Save paths with apostrophes or accents work on WSL.** The path crosses into
  PowerShell through `WSLENV`, not through the command line — the command line
  eats backslashes and non-ASCII, and a plain env var doesn't cross the
  WSL/Win32 boundary at all.
- **Native Windows uses a separate action.** `herdr-paste-image.paste`
  declares `platforms = ["linux", "macos"]` and stays WSL/Linux/macOS-only;
  `herdr-paste-image.paste-windows` (`paste-image.ps1`) is the native Windows
  path, `platforms = ["windows"]`. If you sync one `config.toml` between a
  WSL herdr and a native Windows herdr, bind both action IDs to the same key
  — each install only loads the action for its own platform, so the other is
  simply inert there.
- **`-STA` is required on native Windows.** `System.Windows.Forms.Clipboard`
  throws on a plain (MTA) PowerShell thread; the manifest's `command` passes
  `-STA` so the action works when herdr invokes it.
- **Non-PNG clipboards on Wayland** keep their real extension (`image/jpeg` →
  `.jpg`) instead of being mislabelled as PNG.
- **Housekeeping is lazy.** Old images are pruned when you paste, not on a
  timer — the cache only shrinks while you're using it.

## Credits

The idea, and the workflow it replaces, come from
[`jkhas8/tmux-paste-image`](https://github.com/jkhas8/tmux-paste-image) — the
tmux plugin this is a port of.

## License

MIT
