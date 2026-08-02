#!/usr/bin/env bash
# deploy.sh -- sync suite scripts from the repo into the live game.
#
# WHY: files were hand-copied ~20 times today and it went wrong once -- a stale
# build ran for a whole play session while I reasoned about the new code. This
# makes the repo the single source of truth and reports exactly what landed.
#
# Also enforces the hygiene rule learned the hard way:
#   scripts/init/  -> AUTO-RUNS at game start   (shipped systems only)
#   scripts/       -> manual dofile only        (probes, diagnostics)
# Eight answered probes were auto-running at startup, adding pure crash surface.
#
# Usage:
#   ./tools/deploy.sh            # lint, then deploy
#   ./tools/deploy.sh --force    # deploy even if lint finds problems
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME="/d/SteamLibrary/steamapps/common/Kenshi/mods/KenshiLua/scripts"
PY="/d/Epic Games/UE_5.7/Engine/Binaries/ThirdParty/Python3/Win64/python.exe"
FORCE="${1:-}"

echo "repo: $REPO"
echo "game: $GAME"
echo

if [[ ! -d "$GAME" ]]; then
  echo "ERROR: game script dir not found -- is KenshiLua installed?" >&2
  exit 2
fi

# ---- lint first: a bad deploy costs a restart at best, a save at worst ----
if [[ -f "$REPO/tools/lua_check.py" && -x "$PY" ]]; then
  echo "--- lua_check ---"
  if ! "$PY" "$REPO/tools/lua_check.py"; then
    if [[ "$FORCE" != "--force" ]]; then
      echo
      echo "REFUSING TO DEPLOY -- findings above. Re-run with --force to override." >&2
      exit 1
    fi
    echo "(--force: deploying despite findings)"
  fi
  echo
fi

mkdir -p "$GAME/init" "$GAME/_disabled"

echo "--- init/ (auto-runs at game start) ---"
for f in "$REPO"/mods/suite_scripts/scripts/init/*.lua; do
  [[ -e "$f" ]] || continue
  cp "$f" "$GAME/init/" && echo "  -> $(basename "$f")"
done

echo "--- scripts/ (manual dofile only) ---"
for f in "$REPO"/mods/suite_scripts/scripts/*.lua; do
  [[ -e "$f" ]] || continue
  cp "$f" "$GAME/" && echo "  -> $(basename "$f")"
done

echo
echo "deployed at $(date '+%H:%M:%S')"
echo
echo "REMINDER: restart Kenshi OR dofile -- never both."
echo "  init/ already auto-loads at startup; a dofile on top makes a SECOND copy"
echo "  (that produced doubled casts and two divergent tallies)."
