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
# Interpreter candidates, first working one wins. `python` on PATH is a Windows
# Store alias stub that prints an install advert and exits non-zero, so it is
# deliberately NOT trusted -- it is tried last and only accepted if it actually
# reports a version.
PY_CANDIDATES=(
  "/d/Epic Games/UE_5.7/Engine/Binaries/ThirdParty/Python3/Win64/python.exe"
  "/c/Users/grego/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
)
PY=""
for cand in "${PY_CANDIDATES[@]}"; do
  if [[ -x "$cand" ]] && "$cand" -V >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [[ -z "$PY" ]] && command -v python3 >/dev/null 2>&1 && python3 -V >/dev/null 2>&1; then
  PY="$(command -v python3)"
fi
FORCE="${1:-}"

echo "repo: $REPO"
echo "game: $GAME"
echo

if [[ ! -d "$GAME" ]]; then
  echo "ERROR: game script dir not found -- is KenshiLua installed?" >&2
  exit 2
fi

# ---- lint first: a bad deploy costs a restart at best, a save at worst ----
#
# FAIL CLOSED. This used to read `if [[ -f lua_check.py && -x "$PY" ]]`, so a
# missing or broken interpreter SKIPPED the entire gate in silence and deployed
# unlinted code while still printing the usual success line. That is the same
# fail-open shape as the hasRoomForItem bug this project just spent a day on:
# a check that only refuses when it positively fails, and waves everything
# through when it cannot run at all.
#
# A safety gate that cannot run is a FAILED gate, not an absent one.
if [[ ! -f "$REPO/tools/lua_check.py" ]]; then
  echo "ERROR: tools/lua_check.py missing -- refusing to deploy unlinted." >&2
  echo "       Re-run with --force only if you know why it is gone." >&2
  [[ "$FORCE" == "--force" ]] || exit 3
elif [[ -z "$PY" ]]; then
  echo "ERROR: no working python found -- cannot lint, refusing to deploy." >&2
  echo "       Tried: ${PY_CANDIDATES[*]} and python3 on PATH." >&2
  [[ "$FORCE" == "--force" ]] || exit 3
fi

# ---- headless regression tests -------------------------------------------
# Lint proves syntax; these prove BEHAVIOUR, and every case in them is a bug
# this project actually shipped. They need no Kenshi and no game running, so
# there is no excuse for a deploy that skips them.
if [[ -f "$REPO/tools/luarun.py" && -n "$PY" ]]; then
  echo "--- regression tests ---"
  if ! "$PY" "$REPO/tools/luarun.py" --tests \
        --modules "05_wsm.lua,08_items.lua,10_fishing.lua,24_cooking.lua" 2>&1 \
        | grep -iE "passed, [0-9]+ failed|FAILED|error|expected"; then
    echo "  (no test output)"
  fi
  if ! "$PY" "$REPO/tools/luarun.py" --tests \
        --modules "05_wsm.lua,08_items.lua,10_fishing.lua,24_cooking.lua" >/dev/null 2>&1; then
    if [[ "$FORCE" != "--force" ]]; then
      echo "REFUSING TO DEPLOY -- regression tests failed." >&2
      exit 4
    fi
    echo "(--force: deploying despite test failures)"
  fi
  echo
fi


if [[ -f "$REPO/tools/lua_check.py" && -n "$PY" ]]; then
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
