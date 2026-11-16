--==============================================================================
-- utils/kind.lua  -  LSP symbol kind icon/text mapping for Aerial
--
-- Generates a lookup table mapping every standard LSP SymbolKind name to a
-- short text label (first letter of the name, lowercased, followed by a colon).
-- These are used by aerial.nvim as icon replacements in its outline tree.
--
-- Example output:
--   M["Function"]   -> "f:"
--   M["Variable"]   -> "v:"
--   M["Class"]      -> "c:"
--
-- This module returns a plain key-value table, not a callable module.
-- It is consumed by lua/plugins/aerial.lua  ->  opts.icons = require("utils.kind")
--==============================================================================

local M = {}

-- Complete list of LSP CompletionItemKind names as defined by the LSP spec.
-- Iterating and generating labels programmatically means adding a new kind
-- (should the spec ever grow one) is a single line addition here.
for _, name in ipairs {
  "Array", "Boolean", "Class", "Constant", "Constructor",
  "Enum", "EnumMember", "Event",
  "Field", "File", "Function",
  "Interface",
  "Key",
  "Method", "Module",
  "Namespace", "Null", "Number",
  "Object", "Operator",
  "Package", "Property",
  "String", "Struct",
  "TypeParameter",
  "Variable",
} do
  -- Label = first letter lowercased + colon. E.g. "Function" -> "f:".
  M[name] = name:sub(1, 1):lower() .. ":"
end

return M
