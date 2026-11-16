#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
echo "Building Salient. See docs/building.md for developer prerequisites."
exec ./script/build_and_run.sh run
