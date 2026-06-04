hl.window_rule({
  match = {
    title =
        "(?i)^("
        .. "Save\\s+as|"
        .. "(Open|Choose|All|Select|Save)\\s(?:\\w+\\s)?(?:Image|Folder.*|(?:All\\s)?Files?)|"
        .. "(Image|Video)\\sfile|"
        .. "Local\\sfile|"
        .. "File\\supload|"
        .. "New\\sarchive"
        .. ")$",
  },
  tag = "+fileDialog",
})

hl.window_rule({
  match = { tag = "fileDialog" },

  float = true,
  size = "monitor_w*0.7 monitor_h*0.7",
  dim_around = true,
  center = true
})

-- Thunar special rules.
-- Keeps small contextual windows always visible and focused.
-- To revert, just tile the window.
hl.window_rule({
  name = "Thunar: File Operation",
  match = {
    class = "[Tt]hunar",
    title = "(Rename\\s.*|Create (New Folder|Document from template.*)|File Operation Progress|New\\s.*)"
  },
  float = true,
  center = true,
  dim_around = true,
})
