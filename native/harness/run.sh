#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 exliipso
# Originally developed by exliipso

# Builds the harness and runs the given scripts (after prelude.lua) on Garry's
# Mod's LuaJIT. Set GMOD to the game folder if it isn't in the default place,
# and XNET_LUA_SERVER=1 to run the server side without the native module.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
gmod="${GMOD:-/c/Program Files (x86)/Steam/steamapps/common/GarrysMod}"

(cd "$here/.." && cargo build --release --example harness 2>&1 | grep -E "^(error|warning)|-->" || true)

scripts=()
[ "${XNET_LUA_SERVER:-}" = "1" ] && scripts+=("$here/lua_server.lua")
scripts+=("$here/prelude.lua")
for s in "$@"; do scripts+=("$here/$s"); done

cd "$gmod"
PATH="$PWD/bin/win64:$PATH" "$here/../target/release/examples/harness.exe" "${scripts[@]}"
