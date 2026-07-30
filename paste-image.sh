#!/usr/bin/env bash
#
# herdr-paste-image — save the clipboard image and type its path into the pane
#
# Invoked by a herdr keybind as a plugin action (no arguments). herdr injects
# HERDR_PANE_ID (the focused pane) and HERDR_BIN_PATH into the environment.
#
# Flow: read the image out of the system clipboard -> write it to
# $HERDR_PASTE_IMAGE_DIR/image_<timestamp>.png -> `herdr pane send-text` that
# path into the focused pane, without submitting. Agents like Claude Code pick
# up a bare image path on their own.
#
# Clipboard backends, picked in this order: WSL (Windows clipboard through
# PowerShell), Wayland (wl-paste), X11 (xclip), macOS (pngpaste/osascript).

set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"

# --- Configuration -----------------------------------------------------------
#
# Everything is overridable from the environment (which wins) or from
# config.env in the plugin's config dir — `herdr plugin config-dir
# herdr-paste-image`.

env_dir="${HERDR_PASTE_IMAGE_DIR:-}"
env_keep="${HERDR_PASTE_IMAGE_KEEP_DAYS:-}"
env_quiet="${HERDR_PASTE_IMAGE_QUIET:-}"

config_dir="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/herdr-paste-image}"
if [ -f "$config_dir/config.env" ]; then
  # shellcheck disable=SC1091
  . "$config_dir/config.env"
fi

save_dir="${env_dir:-${HERDR_PASTE_IMAGE_DIR:-$HOME/.cache/herdr-paste-image}}"
keep_days="${env_keep:-${HERDR_PASTE_IMAGE_KEEP_DAYS:-14}}"
quiet="${env_quiet:-${HERDR_PASTE_IMAGE_QUIET:-0}}"

save_dir="${save_dir/#\~/$HOME}"

notify() {
  [ "$quiet" = "1" ] && return 0
  "$herdr" notification show "$1" ${2:+--body "$2"} >/dev/null 2>&1 || true
}

fail() {
  notify "Paste image" "$1"
  echo "herdr-paste-image: $1" >&2
  exit 1
}

[ -n "$pane" ] || fail "No focused pane to paste into."

mkdir -p "$save_dir"

# Housekeeping: drop images older than keep_days. 0 disables it.
if [ "$keep_days" -gt 0 ] 2>/dev/null; then
  find "$save_dir" -maxdepth 1 -type f -name 'image_*' -mtime "+$keep_days" -delete 2>/dev/null || true
fi

stamp="$(date +%Y-%m-%d_%H-%M-%S)"
file_path="$save_dir/image_$stamp.png"

# --- Clipboard -> file -------------------------------------------------------
#
# Each backend either writes $file_path, or sets $file_path to a path that
# already exists on disk (when the clipboard holds a copied *file* rather than
# raw image bytes — copying a PNG in Explorer/Finder/a file manager).

is_image_file() {
  case "${1,,}" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.svg|*.avif|*.tiff|*.tif|*.ico|*.heic) return 0 ;;
    *) return 1 ;;
  esac
}

if grep -qi microsoft /proc/version 2>/dev/null; then
  # WSL: the clipboard lives on the Windows side.
  command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe not found in PATH (needed on WSL)."
  win_path="$(wslpath -w "$file_path")"

  ps_out="$(powershell.exe -NoProfile -STA -Command "
      Add-Type -AssemblyName System.Windows.Forms
      \$img = [System.Windows.Forms.Clipboard]::GetImage()
      if (\$img) {
          \$img.Save('$win_path', [System.Drawing.Imaging.ImageFormat]::Png)
          Write-Output 'SAVED'
      } else {
          \$files = [System.Windows.Forms.Clipboard]::GetFileDropList()
          if (\$files -and \$files.Count -ge 1) {
              Write-Output ('FILE:' + \$files[0])
          } else {
              Write-Output 'NO_IMAGE'
          }
      }
  " 2>&1 | tr -d '\r')"

  case "$ps_out" in
    FILE:*)
      win_src="${ps_out#FILE:}"
      lin_src="$(wslpath -u "$win_src" 2>/dev/null || true)"
      [ -n "$lin_src" ] && [ -f "$lin_src" ] || fail "Clipboard file is not reachable: $win_src"
      is_image_file "$lin_src" || fail "Clipboard holds a file, but not an image: $(basename "$lin_src")"
      file_path="$lin_src"
      ;;
    *SAVED*) ;;
    *) fail "No image in the clipboard." ;;
  esac

elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
  types="$(wl-paste --list-types 2>/dev/null || true)"
  mime="$(printf '%s\n' "$types" | grep -m1 '^image/' || true)"
  if [ -n "$mime" ]; then
    wl-paste --type "$mime" > "$file_path" 2>/dev/null || true
    case "$mime" in
      image/png) ;;
      *) # Keep the real extension so agents/editors don't get a mislabelled PNG.
         ext="${mime#image/}"; ext="${ext%%[;+]*}"
         mv "$file_path" "${file_path%.png}.$ext" && file_path="${file_path%.png}.$ext" ;;
    esac
  elif printf '%s\n' "$types" | grep -q '^text/uri-list$'; then
    uri="$(wl-paste --type text/uri-list 2>/dev/null | head -1 | tr -d '\r')"
    src="${uri#file://}"
    src="$(printf '%b' "${src//%/\\x}")"
    [ -f "$src" ] && is_image_file "$src" || fail "Clipboard holds a file, but not an image."
    file_path="$src"
  else
    fail "No image in the clipboard."
  fi

elif command -v xclip >/dev/null 2>&1; then
  targets="$(xclip -selection clipboard -t TARGETS -o 2>/dev/null || true)"
  mime="$(printf '%s\n' "$targets" | grep -m1 '^image/' || true)"
  [ -n "$mime" ] || fail "No image in the clipboard."
  xclip -selection clipboard -t "$mime" -o > "$file_path" 2>/dev/null || true

elif [ "$(uname -s)" = "Darwin" ]; then
  if command -v pngpaste >/dev/null 2>&1; then
    pngpaste "$file_path" >/dev/null 2>&1 || fail "No image in the clipboard."
  else
    osascript -e "set f to (open for access POSIX file \"$file_path\" with write permission)" \
              -e "try" \
              -e "  write (the clipboard as «class PNGf») to f" \
              -e "  close access f" \
              -e "on error" \
              -e "  close access f" \
              -e "  error \"no image\"" \
              -e "end try" >/dev/null 2>&1 || fail "No image in the clipboard (install pngpaste for better support)."
  fi

else
  fail "No clipboard tool available (need wl-paste, xclip, pngpaste, or WSL)."
fi

# --- File -> pane ------------------------------------------------------------

if [ ! -s "$file_path" ]; then
  rm -f "$file_path"
  fail "No image in the clipboard."
fi

# Quote only when needed, so the common case stays a bare path (which is what
# agents sniff for) and paths with spaces still survive a shell.
text="$file_path"
case "$file_path" in
  *[[:space:]]*) text="'$file_path'" ;;
esac

"$herdr" pane send-text "$pane" "$text " >/dev/null

notify "Image pasted" "$(basename "$file_path")"
