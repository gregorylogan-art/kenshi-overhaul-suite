#!/usr/bin/env bash
# Clone Kenshi modding toolchain next to this repo (or into ./third_party).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/third_party}"
mkdir -p "$DEST"
cd "$DEST"
clone() {
  local url="$1" name="$2"
  if [[ -d "$name/.git" ]]; then
    echo "Updating $name..."
    git -C "$name" pull --ff-only || true
  else
    echo "Cloning $name..."
    git clone --depth 1 "$url" "$name"
  fi
}
clone https://github.com/BFrizzleFoShizzle/RE_Kenshi.git RE_Kenshi
clone https://github.com/BFrizzleFoShizzle/KenshiLib.git KenshiLib
clone https://github.com/BFrizzleFoShizzle/KenshiLib_Examples.git KenshiLib_Examples
clone https://github.com/Genpretz/KenshiLua.git KenshiLua
clone https://github.com/Lucius64/KenshiExtensionPlugin.git KenshiExtensionPlugin
echo "Done. Toolchain at: $DEST"
ls -la "$DEST"
