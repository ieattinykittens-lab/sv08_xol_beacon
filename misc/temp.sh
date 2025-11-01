#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/misc/old_config"
mkdir -p "$DEST"

# Add or remove paths here as needed
FILES_TO_MOVE=(
  "$HOME/printer_data/config/options/probe/eddy.cfg"
  "$HOME/printer_data/config/options/probe/stock.cfg"
)

for src in "${FILES_TO_MOVE[@]}"; do
  if [[ -e "$src" ]]; then
    base="${src##*/}"
    dest="$DEST/$base"

    # If destination exists, append a timestamp to avoid overwriting
    if [[ -e "$dest" ]]; then
      ts="$(date +%Y%m%d%H%M%S)"
      dest="$dest.bak.$ts"
      echo "Destination exists; will save as: $dest"
    fi

    mv -- "$src" "$dest"
    echo "Moved: $src -> $dest"
  else
    echo "Not found (skip): $src"
  fi
done


