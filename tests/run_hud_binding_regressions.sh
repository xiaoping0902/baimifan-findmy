#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binding_binary="$(mktemp -d)/hud-binding-regressions"
trap 'rm -rf "$(dirname "$binding_binary")"' EXIT
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -Iapp/Sources/HUD \
    tests/hud_target_binding_regressions.cpp -o "$binding_binary"
"$binding_binary"
