#!/usr/bin/env bash
# Run the AutoChest server locally (requires Lua 5.4 + luarocks deps)
eval $(luarocks --lua-dir=/opt/homebrew/opt/lua@5.4 path)
/opt/homebrew/opt/lua@5.4/bin/lua5.4 server/main.lua
