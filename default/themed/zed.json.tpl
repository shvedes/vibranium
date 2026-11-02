{
  "$schema": "https://zed.dev/schema/themes/v0.2.0.json",
  "name": "Vibranium",
  "author": "Herehs",
  "themes": [
    {
      "name": "Vibranium",
      "appearance": "dark",
      "style": {

        // -- Borders -----------------------------------------
        "border":                         "{{ background|pop=0.18 }}",
        "border.variant":                 "{{ background|pop=0.12 }}",
        "border.focused":                 "{{ accent|dim=0.10 }}",
        "border.selected":                "{{ background|pop=0.18 }}",
        "border.transparent":             "#00000000",
        "border.disabled":                "{{ background|pop=0.12 }}",

        // -- Surfaces / Elements -----------------------------
        "elevated_surface.background":    "{{ background|pop=0.06 }}",
        "surface.background":             "{{ background|pop=0.06 }}",
        "background":                     "{{ background }}",
        "element.background":             "{{ background|pop=0.06 }}",
        "element.hover":                  "{{ background|pop=0.12 }}",
        "element.active":                 "{{ background|pop=0.18 }}",
        "element.selected":               "{{ background|pop=0.12 }}",
        "element.disabled":               "{{ background|pop=0.06 }}",

        "drop_target.background":         "{{ background|pop=0.12|alpha=0.5 }}",
        "ghost_element.background":       "#00000000",
        "ghost_element.hover":            "{{ background|pop=0.12 }}",
        "ghost_element.active":           "{{ background|pop=0.18 }}",
        "ghost_element.selected":         "{{ background|pop=0.12 }}",
        "ghost_element.disabled":         "{{ background|pop=0.06 }}",

        // -- Text --------------------------------------------
        "text":                           "{{ foreground }}",
        "text.muted":                     "{{ foreground|dim=0.12 }}",
        "text.placeholder":               "{{ foreground|dim=0.24 }}",
        "text.disabled":                  "{{ foreground|dim=0.30 }}",
        "text.accent":                    "{{ accent }}",

        // -- Icons -------------------------------------------
        "icon":                           "{{ foreground|dim=0.06 }}",
        "icon.muted":                     "{{ foreground|dim=0.18 }}",
        "icon.disabled":                  "{{ foreground|dim=0.30 }}",
        "icon.placeholder":               "{{ foreground|dim=0.24 }}",
        "icon.accent":                    "{{ accent }}",

        // -- Bars / Tabs -------------------------------------
        "status_bar.background":          "{{ background|pop=0.12 }}",
        "title_bar.background":           "{{ background }}",
        "title_bar.inactive_background":  "{{ background|pop=0.06 }}",
        "toolbar.background":             "{{ background }}",
        "tab_bar.background":             "{{ background }}",
        "tab.inactive_background":        "{{ background }}",
        "tab.active_background":          "{{ background|pop=0.06 }}",

        // -- Search ------------------------------------------
        "search.match_background":        "{{ accent|alpha=0.4 }}",
        "search.active_match_background": "{{ orange|alpha=0.4 }}",

        // -- Panels ------------------------------------------
        "panel.background":               "{{ background|pop=0.06 }}",
        "panel.focused_border":           null,
        "pane.focused_border":            null,

        // -- Scrollbar ---------------------------------------
        "scrollbar.thumb.background":       "{{ gray|dim=0.10|alpha=0.5 }}",
        "scrollbar.thumb.hover_background": "{{ gray }}",
        "scrollbar.thumb.border":           "{{ gray|dim=0.10 }}",
        "scrollbar.track.background":       "#00000000",
        "scrollbar.track.border":           "{{ background }}",

        // -- Editor ------------------------------------------
        "editor.foreground":                          "{{ foreground }}",
        "editor.background":                          "{{ background }}",
        "editor.gutter.background":                   "{{ background }}",
        "editor.subheader.background":                "{{ background|pop=0.06 }}",
        "editor.active_line.background":              "{{ background|pop=0.06 }}",
        "editor.highlighted_line.background":         "{{ background|pop=0.06 }}",
        "editor.line_number":                         "{{ background|pop=0.30 }}",
        "editor.active_line_number":                  "{{ foreground|dim=0.12 }}",
        "editor.hover_line_number":                   "{{ foreground|dim=0.06 }}",
        "editor.invisible":                           "{{ background|pop=0.30 }}",
        "editor.wrap_guide":                          "{{ foreground|alpha=0.05 }}",
        "editor.active_wrap_guide":                   "{{ foreground|alpha=0.10 }}",
        "editor.indent_guide":                        "{{ background|pop=0.06 }}",
        "editor.indent_guide_active":                 "{{ background|pop=0.12 }}",
        "editor.document_highlight.read_background":  "{{ blue|alpha=0.10 }}",
        "editor.document_highlight.write_background": "{{ background|pop=0.18|alpha=0.4 }}",

        // -- Terminal ----------------------------------------
        "terminal.background":              "{{ background }}",
        "terminal.foreground":              "{{ foreground|dim=0.06 }}",
        "terminal.bright_foreground":       "{{ foreground|pop=0.06 }}",
        "terminal.dim_foreground":          "{{ foreground|dim=0.24 }}",

        "terminal.ansi.black":              "{{ background|pop=0.18 }}",
        "terminal.ansi.bright_black":       "{{ gray|pop=0.10 }}",
        "terminal.ansi.dim_black":          "{{ background|pop=0.12 }}",

        "terminal.ansi.red":                "{{ red }}",
        "terminal.ansi.bright_red":         "{{ red|pop=0.10 }}",
        "terminal.ansi.dim_red":            "{{ red|dim=0.30 }}",

        "terminal.ansi.green":              "{{ green }}",
        "terminal.ansi.bright_green":       "{{ green|pop=0.10 }}",
        "terminal.ansi.dim_green":          "{{ green|dim=0.30 }}",

        "terminal.ansi.yellow":             "{{ orange }}",
        "terminal.ansi.bright_yellow":      "{{ orange|pop=0.10 }}",
        "terminal.ansi.dim_yellow":         "{{ orange|dim=0.30 }}",

        "terminal.ansi.blue":               "{{ blue }}",
        "terminal.ansi.bright_blue":        "{{ blue|pop=0.10 }}",
        "terminal.ansi.dim_blue":           "{{ blue|dim=0.30 }}",

        "terminal.ansi.magenta":            "{{ purple }}",
        "terminal.ansi.bright_magenta":     "{{ purple|pop=0.10 }}",
        "terminal.ansi.dim_magenta":        "{{ purple|dim=0.30 }}",

        "terminal.ansi.cyan":               "{{ cyan }}",
        "terminal.ansi.bright_cyan":        "{{ cyan|pop=0.10 }}",
        "terminal.ansi.dim_cyan":           "{{ cyan|dim=0.30 }}",

        "terminal.ansi.white":              "{{ foreground|dim=0.12 }}",
        "terminal.ansi.bright_white":       "{{ foreground|pop=0.06 }}",
        "terminal.ansi.dim_white":          "{{ foreground|dim=0.24 }}",

        // -- Links -------------------------------------------
        "link_text.hover":                  "{{ accent|pop=0.10 }}",

        // -- Version control ---------------------------------
        "version_control.added":                  "{{ green }}",
        "version_control.modified":               "{{ orange }}",
        "version_control.word_added":             "{{ green|alpha=0.35 }}",
        "version_control.word_deleted":           "{{ red|dim=0.10|alpha=0.8 }}",
        "version_control.deleted":                "{{ red|dim=0.10 }}",
        "version_control.conflict_marker.ours":   "{{ green|alpha=0.10 }}",
        "version_control.conflict_marker.theirs": "{{ blue|alpha=0.10 }}",

        // -- Status colors -----------------------------------
        "conflict":              "{{ orange }}",
        "conflict.background":   "{{ orange|alpha=0.10 }}",
        "conflict.border":       "{{ orange|dim=0.60 }}",
        "created":               "{{ green }}",
        "created.background":    "{{ green|alpha=0.10 }}",
        "created.border":        "{{ green|dim=0.60 }}",
        "deleted":               "{{ red|dim=0.10 }}",
        "deleted.background":    "{{ red|dim=0.10|alpha=0.10 }}",
        "deleted.border":        "{{ red|dim=0.60 }}",
        "error":                 "{{ red }}",
        "error.background":      "{{ red|alpha=0.10 }}",
        "error.border":          "{{ red|dim=0.60 }}",
        "hidden":                "{{ foreground|dim=0.30 }}",
        "hidden.background":     "{{ foreground|dim=0.30|alpha=0.10 }}",
        "hidden.border":         "{{ background|pop=0.18 }}",
        "hint":                  "{{ cyan }}",
        "hint.background":       "{{ cyan|alpha=0.10 }}",
        "hint.border":           "{{ cyan|dim=0.60 }}",
        "ignored":               "{{ foreground|dim=0.30 }}",
        "ignored.background":    "{{ foreground|dim=0.30|alpha=0.10 }}",
        "ignored.border":        "{{ background|pop=0.18 }}",
        "info":                  "{{ blue }}",
        "info.background":       "{{ blue|alpha=0.10 }}",
        "info.border":           "{{ blue|dim=0.60 }}",
        "modified":              "{{ orange }}",
        "modified.background":   "{{ orange|alpha=0.10 }}",
        "modified.border":       "{{ orange|dim=0.60 }}",
        "predictive":            "{{ foreground|dim=0.24 }}",
        "predictive.background": "{{ foreground|dim=0.24|alpha=0.10 }}",
        "predictive.border":     "{{ background|pop=0.18 }}",
        "renamed":               "{{ blue }}",
        "renamed.background":    "{{ blue|alpha=0.10 }}",
        "renamed.border":        "{{ blue|dim=0.60 }}",
        "success":               "{{ green }}",
        "success.background":    "{{ green|alpha=0.10 }}",
        "success.border":        "{{ green|dim=0.60 }}",
        "unreachable":           "{{ foreground|dim=0.12 }}",
        "unreachable.background":"{{ foreground|dim=0.12|alpha=0.10 }}",
        "unreachable.border":    "{{ background|pop=0.18 }}",
        "warning":               "{{ orange }}",
        "warning.background":    "{{ orange|alpha=0.10 }}",
        "warning.border":        "{{ orange|dim=0.60 }}",

        // -- Multiplayer / cursors ---------------------------
        "players": [
          { "cursor": "{{ blue }}",         "background": "{{ blue }}",         "selection": "{{ blue|alpha=0.24 }}" },
          { "cursor": "{{ red }}",          "background": "{{ red }}",          "selection": "{{ red|alpha=0.24 }}" },
          { "cursor": "{{ orange }}",       "background": "{{ orange }}",       "selection": "{{ orange|alpha=0.24 }}" },
          { "cursor": "{{ purple }}",       "background": "{{ purple }}",       "selection": "{{ purple|alpha=0.24 }}" },
          { "cursor": "{{ cyan }}",         "background": "{{ cyan }}",         "selection": "{{ cyan|alpha=0.24 }}" },
          { "cursor": "{{ red|dim=0.10 }}", "background": "{{ red|dim=0.10 }}", "selection": "{{ red|dim=0.10|alpha=0.24 }}" },
          { "cursor": "{{ green }}",        "background": "{{ green }}",        "selection": "{{ green|alpha=0.24 }}" },
          { "cursor": "{{ accent }}",       "background": "{{ accent }}",       "selection": "{{ accent|alpha=0.24 }}" }
        ],

        // -- Syntax ------------------------------------------
        "syntax": {

          // Comments
          "comment":      { "color": "{{ green }}", "font_style": "italic", "font_weight": null },
          "comment.doc":  { "color": "{{ green }}", "font_style": "italic", "font_weight": null },

          // Strings
          "string":                 { "color": "{{ orange }}", "font_style": null, "font_weight": null },
          "string.escape":          { "color": "{{ orange|pop=0.10 }}", "font_style": null, "font_weight": null },
          "string.regex":           { "color": "{{ red }}", "font_style": null, "font_weight": null },
          "string.special":         { "color": "{{ orange }}", "font_style": null, "font_weight": null },
          "string.special.symbol":  { "color": "{{ orange }}", "font_style": null, "font_weight": null },
          "text.literal":           { "color": "{{ orange }}", "font_style": null, "font_weight": null },

          // Keywords / storage
          "keyword":   { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "preproc":   { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "boolean":   { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "constant":  { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "label":     { "color": "{{ blue }}", "font_style": null, "font_weight": null },

          // Functions / constructors
          "function":     { "color": "{{ purple }}", "font_style": null, "font_weight": null },
          "constructor":  { "color": "{{ purple }}", "font_style": null, "font_weight": null },
          "variant":      { "color": "{{ purple }}", "font_style": null, "font_weight": null },

          // Types
          "type":       { "color": "{{ cyan }}", "font_style": null, "font_weight": null },
          "enum":       { "color": "{{ cyan }}", "font_style": null, "font_weight": null },
          "namespace":  { "color": "{{ cyan }}", "font_style": null, "font_weight": null },

          // Numbers
          "number":     { "color": "{{ green }}", "font_style": null, "font_weight": null },

          // Variables / properties
          "variable":            { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "variable.parameter":  { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "variable.special":    { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "property":            { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "attribute":           { "color": "{{ blue }}", "font_style": null, "font_weight": null },

          // Operators / punctuation
          "operator":                { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "primary":                 { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "embedded":                { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation":             { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation.bracket":     { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation.delimiter":   { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation.list_marker": { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation.markup":      { "color": "{{ foreground }}", "font_style": null, "font_weight": null },
          "punctuation.special":     { "color": "{{ orange }}", "font_style": null, "font_weight": null },

          // Tags / selectors
          "tag":              { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "selector":         { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "selector.pseudo":  { "color": "{{ blue }}", "font_style": null, "font_weight": null },

          // Markup
          "title":            { "color": "{{ blue }}", "font_style": null, "font_weight": 700 },
          "emphasis":         { "color": "{{ blue }}", "font_style": null, "font_weight": null },
          "emphasis.strong":  { "color": "{{ blue }}", "font_style": null, "font_weight": 700 },
          "link_text":        { "color": "{{ cyan }}", "font_style": "italic", "font_weight": null },
          "link_uri":         { "color": "{{ cyan }}", "font_style": null, "font_weight": null },

          // Misc
          "hint":        { "color": "{{ cyan }}", "font_style": null, "font_weight": null },
          "predictive":  { "color": "{{ foreground|dim=0.24 }}", "font_style": "italic", "font_weight": null },

          // Diff
          "diff.plus":   { "color": "{{ green }}", "font_style": null, "font_weight": null },
          "diff.minus":  { "color": "{{ red|dim=0.10 }}", "font_style": null, "font_weight": null }
        }
      }
    }
  ]
}

// vim:ft=jsonc
