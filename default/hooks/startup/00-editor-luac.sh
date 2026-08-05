#!/bin/bash

# Rebuild outdated / removed / stale Lua bytecode.
luac -o "$VIBRANIUM_CACHE/editor.luac" "$VIBRANIUM/default/hypr/lib/editor.lua"
