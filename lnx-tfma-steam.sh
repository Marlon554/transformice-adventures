#!/usr/bin/env bash
set -euo pipefail

# lnx-tfma-steam.sh
# Linux script that injects a remote patch loader into Transformice Adventures Demo (main.js)
# No backups are created (as requested). Injected block contains markers for easy removal.
# Usage: chmod +x lnx-tfma-steam.sh && ./lnx-tfma-steam.sh

GAME_SUBPATH="steamapps/common/Transformice Adventures Demo/resources/app"
MAIN_FILE_NAME="main.js"
PATCH_MARKER="hadaward.github.io/transformice-adventures/patch.js"
INJECTION_MARKER="window.gamePatched"

# Candidate Steam installation roots (user, flatpak, system)
CANDIDATE_STEAM_ROOTS=(
  "$HOME/.local/share/Steam"
  "$HOME/.steam/steam"
  "$HOME/.steam/root"
  "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"  # Flatpak
  "/usr/share/steam"
  "/opt/steam"
)

# Also check common mounts (external drives)
for m in /media/"$USER"/* /run/media/"$USER"/* /mnt/*; do
  CANDIDATE_STEAM_ROOTS+=("$m/Steam")
done

# Normalize: remove duplicates and keep only existing directories
unique_paths=()
declare -A seen
for p in "${CANDIDATE_STEAM_ROOTS[@]}"; do
  [[ -z "$p" ]] && continue
  abs="$(readlink -f "$p" 2>/dev/null || printf "%s" "$p")"
  if [[ -d "$abs" && -z "${seen[$abs]:-}" ]]; then
    unique_paths+=("$abs")
    seen[$abs]=1
  fi
done

# Function to collect library folders from libraryfolders.vdf (simple extraction)
collect_lib_paths_from_vdf() {
  local vdf="$1"
  if [[ -f "$vdf" ]]; then
    while IFS= read -r line; do
      echo "$line" | awk -F\" '{ for(i=1;i<=NF;i++) if($i ~ /[\/\\]Steam/) print $i }'
    done < "$vdf" | while IFS= read -r path; do
      pnorm="$(readlink -f "$path" 2>/dev/null || printf "%s" "$path")"
      if [[ -d "$pnorm" && -z "${seen[$pnorm]:-}" ]]; then
        seen[$pnorm]=1
        echo "$pnorm"
      fi
    done
  fi
}

# Gather additional library paths from each candidate
for base in "${unique_paths[@]}"; do
  libvdf="$base/steamapps/libraryfolders.vdf"
  if [[ -f "$libvdf" ]]; then
    while IFS= read -r newp; do
      unique_paths+=("$newp")
    done < <(collect_lib_paths_from_vdf "$libvdf")
  fi
done

# Final dedupe
final_roots=()
declare -A final_seen
for p in "${unique_paths[@]}"; do
  if [[ -d "$p" && -z "${final_seen[$p]:-}" ]]; then
    final_roots+=("$p")
    final_seen[$p]=1
  fi
done

if [[ ${#final_roots[@]} -eq 0 ]]; then
  echo "No Steam installations found in standard locations."
  echo "Please make sure Steam is installed and run this script again."
  exit 1
fi

echo "Detected Steam directories:"
for r in "${final_roots[@]}"; do
  echo " - $r"
done

modified_any=0

for steam_root in "${final_roots[@]}"; do
  game_path="$steam_root/$GAME_SUBPATH"
  main_file="$game_path/$MAIN_FILE_NAME"

  if [[ ! -d "$game_path" ]]; then
    continue
  fi

  if [[ ! -f "$main_file" ]]; then
    echo "Found game directory at: $game_path  (but $MAIN_FILE_NAME does not exist)"
    continue
  fi

  # Check if patch already present
  if grep -qF "$PATCH_MARKER" "$main_file" || grep -qF "$INJECTION_MARKER" "$main_file"; then
    echo "$main_file already appears to be modified — skipping to avoid duplication."
    continue
  fi

  # Append injected block (no backup)
  cat >> "$main_file" <<'EOF'

/* ---- injected by lnx-tfma-steam.sh - load remote patch ---- */
app.on('web-contents-created', (_, webContents) => {
  webContents.on('did-finish-load', function(){
    win.webContents.executeJavaScript(`
    if (!window.gamePatched)
    {
      const requireScript = document.querySelector('script[src*="lib/require.js"]');
      const script = document.createElement('script');
      script.src = 'https://hadaward.github.io/transformice-adventures/patch.js?' + Date.now();
      requireScript.parentNode.insertBefore(script, requireScript);
      window.gamePatched = true;
    }
    `);
  });
});
/* ---- end injected block ---- */

EOF

  echo "Injection completed in: $main_file"
  modified_any=1
done

if [[ "$modified_any" -eq 1 ]]; then
  echo ""
  echo "Done! Open the Transformice Adventures Demo standalone again to load the patch."
  echo "⚠️ It is recommended NOT to run this script more than once without checking the files."
else
  echo ""
  echo "No modifications were necessary (game not found in checked roots, or already modified)."
fi

echo "Injected block markers are: '/* ---- injected by lnx-tfma-steam.sh - load remote patch ---- */' and '/* ---- end injected block ---- */'."

