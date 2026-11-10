## Downloads

| | |
|---|---|
| **`xnet-lua-0.4.1.zip`** | The Lua edition. Runs on any server. |
| **`xnet-native-0.4.1.zip`** | The Lua edition plus the server module for all four platforms. |

Extract either zip into your server's `garrysmod` folder and restart. Each zip has an `INSTALL.txt`, and the [README](https://github.com/exliipso/XNet#install) has the details. Players never download a binary.

## What's new

- **Licensed under Apache 2.0.** The zips now carry `LICENSE` and `NOTICE` in `addons/xnet/`, and the native zip carries the notices for the third-party code compiled into the modules. See [License and attribution](https://github.com/exliipso/XNet#license-and-attribution).
- No changes to networking: the code is the same as 0.4.0.

0.4.0 added batching, the native module's batch buffers, safer native errors and a fix for the first messages under a new name; see its release notes.

## Tested

- Lua edition: on a live 32-bit Linux server with a client connected, and in the test harness on Garry's Mod's 64-bit LuaJIT.
- `gmsv_xnet_linux.dll` (32-bit Linux): on the live server.
- `gmsv_xnet_win64.dll`: the full test suite on Garry's Mod's own 64-bit `lua_shared`.
- `gmsv_xnet_win32.dll`, `gmsv_xnet_linux64.dll`: built from the same code by CI, not yet run on a server.
