#!/usr/bin/env bash
# Render every UI entry headlessly (light + dark) and check each PNG came out.
#
#   scripts/ci/render-smoke.sh [out-dir]     # default build/render
#
# Catches views that crash or fail to draw. Run after `swift build`.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-build/render}"
app="$(swift build --show-bin-path)/BatterySoH"
[[ -x "$app" ]] || { echo "error: $app missing; run swift build first" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
"$app" --render "$out"

shopt -s nullglob
pngs=("$out"/*.png)
(( ${#pngs[@]} > 0 )) || { echo "error: --render wrote no PNGs" >&2; exit 1; }
for png in "${pngs[@]}"; do
    [[ -s "$png" ]] || { echo "error: empty render $png" >&2; exit 1; }
done
light=("$out"/*-light.png)
dark=("$out"/*-dark.png)
(( ${#light[@]} == ${#dark[@]} )) || {
    echo "error: ${#light[@]} light renders but ${#dark[@]} dark ones" >&2
    exit 1
}
echo "render smoke: ${#pngs[@]} PNGs (${#light[@]} light + ${#dark[@]} dark) in $out"
