#!/bin/sh
# ==========================================================================
#  nvim.command - start the Neovim kit on a Mac. Double-click it in Finder,
#  or run it from a terminal with files to open:   ./nvim.command notes.org
#
#  Neovim ships already unpacked in the nvim-macos-arm64 folder next to
#  this file (the official Apple Silicon build), so there is nothing to
#  install: no admin, no Homebrew, no PATH edits, no network. This script
#  only finds nvim and starts it with the nvim folder next to this file as
#  the config. It never deletes, moves or unpacks anything.
#
#  Where it looks, in order:
#    1. nvim-macos-arm64/bin/nvim next to this file (an Apple Silicon Mac)
#    2. any complete Neovim under this folder that this Mac can run, however
#       it is nested (a copy unpacked by hand: nvim-macos-x86_64 on an Intel
#       Mac)
#    3. nvim on PATH (Homebrew)
#
#  A copy that came down with a browser (Download ZIP) is quarantined, and
#  macOS will not start the Neovim inside it, nor load the org parser. The
#  first run clears that mark from this folder, which needs no admin for
#  files you own. That is the only thing it ever changes.
# ==========================================================================

KIT=$(cd "$(dirname "$0")" && pwd)
ARCH=$(uname -m)
EXE=

if [ "$ARCH" = arm64 ] && [ -f "$KIT/nvim-macos-arm64/bin/nvim" ]; then
  EXE=$KIT/nvim-macos-arm64/bin/nvim
fi

# complete = bin/nvim with the runtime folder beside its bin folder, built
# for this Mac (file names the architecture; an Intel Mac cannot run the
# arm64 build, an Apple Silicon Mac can run either)
find_nvim() {
  find "$KIT" -type f -path '*/bin/nvim' 2>/dev/null | while IFS= read -r f; do
    [ -f "${f%/bin/nvim}/share/nvim/runtime/filetype.lua" ] || continue
    if [ "$ARCH" != arm64 ] && ! file "$f" | grep -q "$ARCH"; then continue; fi
    printf '%s\n' "$f"
    break
  done
}
if [ -z "$EXE" ]; then
  EXE=$(find_nvim)
fi

if [ -z "$EXE" ]; then
  EXE=$(command -v nvim 2>/dev/null)
fi

if [ -z "$EXE" ]; then
  echo
  echo "  Could not find Neovim. It should be here:"
  echo "    $KIT/nvim-macos-arm64/bin/nvim"
  if [ "$ARCH" = arm64 ]; then
    echo "  This copy of the repo is incomplete. Download it again (GitHub: Code,"
    echo "  Download ZIP), extract everything, and run nvim.command from the new copy."
  else
    echo "  This is an Intel Mac, and that is the Apple Silicon build. Get the Intel"
    echo "  one: download nvim-macos-x86_64.tar.gz from"
    echo "    https://github.com/neovim/neovim/releases/tag/v0.12.5"
    echo "  double-click it to unpack, and move the nvim-macos-x86_64 folder next"
    echo "  to this file. (Or install Neovim 0.12 with Homebrew.)"
  fi
  echo
  [ -t 0 ] && { printf '  Press Return to close this window. '; read -r _; }
  exit 1
fi

# the quarantine mark: on nvim itself, or on the org parser when nvim comes
# from somewhere else (Homebrew) and only this folder was downloaded
for f in "$EXE" "$KIT/nvim/org-parser/org-macos.so"; do
  if xattr -p com.apple.quarantine "$f" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$KIT" 2>/dev/null
    break
  fi
done

XDG_CONFIG_HOME=$KIT
export XDG_CONFIG_HOME
"$EXE" "$@"
RC=$?
[ "$RC" -eq 0 ] && exit 0

# --- failure: say what happened and keep the window open ------------------
echo
echo "  Neovim stopped with an error (exit code $RC)."
echo "    nvim: $EXE"
echo "  If macOS said it could not verify or open it (company policy), the kit"
echo "  cannot get around that."
echo
[ -t 0 ] && { printf '  Press Return to close this window. '; read -r _; }
exit "$RC"
