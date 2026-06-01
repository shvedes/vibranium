{
  "name": "Vibranium",
  "semanticHighlighting": true,

  "semanticTokenColors": {
    "operator":          "{{ foreground }}",
    "punctuation":       "{{ foreground }}",
    "selfKeyword":       "{{ color4 }}",
    "selfTypeKeyword":   "{{ color4 }}"
  },

  "colors": {

    // -- Welcome Page ----------------------------------------
    "textLink.foreground":              "{{ accent }}",
    "textLink.activeForeground":        "{{ accent|lightness=+0.10 }}",

    "welcomePage.tileBackground":       "{{ background|lightness=+0.10 }}",
    "welcomePage.tileHoverBackground":  "{{ background|lightness=+0.15  }}",
    "welcomePage.progress.background":  "{{ background|lightness=+0.15 }}",
    "welcomePage.progress.foreground":  "{{ accent }}",

    "button.secondaryBackground":       "{{ background|lightness=+0.10 }}",
    "button.secondaryForeground":       "{{ background|lightness=+0.05 }}",
    "button.secondaryHoverBackground":  "{{ background|lightness=+0.15 }}",

    "descriptionForeground":            "{{ foreground|lightness=-0.25 }}",

    // -- Editor ------------------------------------------------
    "editor.background":                  "{{ background }}",
    "editor.foreground":                  "{{ background }}",
    "editor.lineHighlightBackground":     "{{ background|lightness=+0.05 }}",
    "editor.selectionBackground":         "{{ background|lightness=+0.15 }}",
    "editor.inactiveSelectionBackground": "{{ background|lightness=+0.07 }}",
    "editorCursor.foreground":            "{{ foreground }}",
    "editorLineNumber.foreground":        "{{ background|lightness=+0.25 }}",
    "editorLineNumber.activeForeground":  "{{ foreground|lightness=-0.10 }}",
    "editorIndentGuide.background1":      "{{ background|lightness=+0.05 }}",
    "editorIndentGuide.activeBackground1":"{{ background|lightness=+0.10 }}",

    // -- Activity Bar ------------------------------------------
    "activityBar.background":             "{{ background|lightness=+0.05 }}",
    "activityBar.foreground":             "{{ foreground|lightness=-0.05 }}",
    "activityBar.inactiveForeground":     "{{ foreground|lightness=-0.15 }}",
    "activityBarBadge.background":        "{{ background|lightness=+0.10 }}",
    "activityBarBadge.foreground":        "{{ foreground|lightness=-0.10 }}",

    // -- Side Bar ----------------------------------------------
    "sideBar.background":                 "{{ background|lightness=+0.05 }}",
    "sideBar.foreground":                 "{{ foreground|lightness=-0.05 }}",
    "sideBar.border":                     "{{ background|lightness=+0.15 }}",
    "sideBarTitle.foreground":            "{{ foreground|lightness=+0.05 }}",
    "sideBarSectionHeader.background":    "{{ background|lightness=+0.10 }}",
    "sideBarSectionHeader.foreground":    "{{ foreground|lightness=-0.05 }}",

    // -- Status Bar --------------------------------------------
    "statusBar.background":               "{{ background|lightness=+0.10 }}",
    "statusBar.foreground":               "{{ foreground|lightness=-0.10 }}",
    "statusBar.noFolderBackground":       "{{ background|lightness=+0.10 }}",
    "statusBar.debuggingBackground":      "{{ color11 }}", // orange, defined in colors.toml

    // -- Title Bar ---------------------------------------------
    "titleBar.activeBackground":          "{{ background }}",
    "titleBar.activeForeground":          "{{ foreground }}",
    "titleBar.inactiveBackground":        "{{ background|lightness=+0.05 }}",
    "titleBar.inactiveForeground":        "{{ foreground|lightness=-0.05 }}",

    // -- Tabs --------------------------------------------------
    "tab.activeBackground":               "{{ background|lightness=+0.05 }}",
    "tab.activeForeground":               "{{ foreground|lightness=+0.05 }}",
    "tab.inactiveBackground":             "{{ background }}",
    "tab.inactiveForeground":             "{{ foreground|lightness=-0.15 }}",
    "tab.border":                         "{{ background }}",
    "tab.activeBorder":                   "{{ background|lightness=+0.15 }}",
    "editorGroupHeader.tabsBackground":   "{{ background }}",

    // -- Panel -------------------------------------------------
    "panel.background":                   "{{ background|lightness=+0.05 }}",
    "panel.border":                       "{{ background|lightness=+0.25 }}",
    "panelTitle.activeForeground":        "{{ foreground|lightness=+0.05 }}",
    "panelTitle.inactiveForeground":      "{{ foreground|lightness=-0.15 }}",

    // -- Input / Dropdown --------------------------------------
    "input.background":                   "{{ background|lightness=+0.05 }}",
    "input.foreground":                   "{{ foreground|lightness=-0.05 }}",
    "input.border":                       "{{ background|lightness=+0.15 }}",
    "input.placeholderForeground":        "{{ foreground|lightness=-0.20 }}",
    "dropdown.background":                "{{ background|lightness=+0.05 }}",
    "dropdown.foreground":                "{{ foreground|lightness=-0.05 }}",

    // -- Lists -------------------------------------------------
    "list.activeSelectionBackground":     "{{ background|lightness=+0.05 }}",
    "list.activeSelectionForeground":     "{{ foreground|lightness=+0.05 }}",
    "list.inactiveSelectionBackground":   "{{ background|lightness=+0.05 }}",
    "list.hoverBackground":               "{{ background|lightness=+0.10 }}",
    "list.focusBackground":               "{{ background|lightness=+0.10 }}",
    "list.highlightForeground":           "{{ foreground|lightness=+0.05 }}",

    // -- Buttons -----------------------------------------------
    "button.background":                  "{{ accent|alpha=0.7 }}",
    "button.foreground":                  "{{ foreground|lightness=+0.05 }}",
    "button.hoverBackground":             "{{ accent }}",

    // -- Scrollbar ---------------------------------------------
    "scrollbarSlider.background":         "{{ background|lightness=+0.10 }}",
    "scrollbarSlider.hoverBackground":    "{{ background|lightness=+0.15 }}",
    "scrollbarSlider.activeBackground":   "{{ background|lightness=+0.20 }}",

    // -- Badge -------------------------------------------------
    "badge.background":                   "{{ background|lightness=+0.20 }}",
    "badge.foreground":                   "{{ foreground|lightness=+0.05 }}",

    // -- Notifications -----------------------------------------
    "notifications.background":           "{{ background|lightness=+0.10 }}",
    "notifications.foreground":           "{{ foreground|foreground=-0.05 }}",
    "notificationCenterHeader.background":"{{ accent|alpha=0.7 }}",

    // -- Breadcrumb --------------------------------------------
    "breadcrumb.background":                "{{ background|lightness=+0.05 }}",
    "breadcrumb.foreground":                "{{ foreground|lightness=-0.15 }}",
    "breadcrumb.activeSelectionForeground": "{{ background|lightness=+0.15 }}",

    // -- Git Decorations ---------------------------------------
    "gitDecoration.modifiedResourceForeground":    "{{ color2 }}",
    "gitDecoration.deletedResourceForeground":     "{{ color1|alpha=0.7 }}",
    "gitDecoration.untrackedResourceForeground":   "{{ foreground|alpha=0.5 }}",
    "gitDecoration.ignoredResourceForeground":     "{{ color11 }}",
    "gitDecoration.conflictingResourceForeground": "{{ color1 }}",

    // -- Quick Input / Search ----------------------------------

    "quickInput.border":                  "{{ background|lightness=+0.20 }}",
    "quickInput.background":              "{{ background|lightness=+0.05 }}",
    "quickInput.foreground":              "{{ foreground|lightness=-0.05 }}",
    "quickInputTitle.background":         "{{ background }}",
    "quickInputTitle.foreground":         "{{ foreground|lightness=+0.05 }}",

    "widget.shadow":                      "{{ accent|alpha=0.7 }}",

    "pickerGroup.background":             "{{ color1 }}",
    "pickerGroup.border":                 "{{ background|lightness=+0.15 }}",
    "pickerGroup.foreground":             "{{ foreground|lightness=-0.05 }}",

    "quickInputList.focusBackground":     "{{ background|lightness=+0.10 }}",
    "quickInputList.focusForeground":     "{{ foreground|lightness=+0.05 }}",
    "quickInputList.focusIconForeground": "{{ foreground|lightness=+0.05 }}",

    // -- Global -----------------------------------------------
    "focusBorder":                          "{{ accent|alpha=0.07 }}",
    "selection.background":                 "{{ background|lightness=+0.10 }}",

    // -- Editor Group -----------------------------------------
    "editorGroup.border":                   "{{ background|lightness=+0.15 }}",
    "editorGroup.dropBackground":           "{{ background|lightness=+0.10 }}",

    // -- Editor Find / Word Highlights ------------------------
    "editor.findMatchBackground":           "{{ accent|alpha=0.7 }}",
    "editor.findMatchHighlightBackground":  "{{ background|lightness=+0.15 }}",
    "editor.wordHighlightBackground":       "{{ background|lightness=+0.10 }}",
    "editor.wordHighlightStrongBackground": "{{ background|lightness=+0.15 }}",
    "editor.rangeHighlightBackground":      "{{ background|lightness=+0.05 }}",

    // -- Editor Diagnostics -----------------------------------
    "editorError.foreground":               "{{ color1 }}",
    "editorWarning.foreground":             "{{ color11 }}",
    "editorInfo.foreground":                "{{ color4 }}",

    // -- Editor Bracket Match ---------------------------------
    "editorBracketMatch.background":        "{{ background|lightness=+0.15 }}",
    "editorBracketMatch.border":            "{{ foreground|lightness=-0.15 }}",

    // -- Editor Gutter (git diff line markers) ----------------
    "editorGutter.addedBackground":         "{{ color2|alpha=0.7 }}",
    "editorGutter.modifiedBackground":      "{{ color4 }}",
    "editorGutter.deletedBackground":       "{{ color1|alpha=0.7 }}",

    // -- Editor Code Lens -------------------------------------
    "editorCodeLens.foreground":            "{{ foreground|lightness=-0.20 }}",

    // -- Editor Inlay Hints -----------------------------------
    "editorInlayHint.background":           "{{ background|lightness=+0.10 }}",
    "editorInlayHint.foreground":           "{{ foreground|lightness=-0.20 }}",
    "editorInlayHint.typeForeground":       "{{ color6 }}",
    "editorInlayHint.parameterForeground":  "{{ foreground|lightness=-0.15 }}",

    // -- Suggest Widget ---------------------------------------
    "editorSuggestWidget.background":        "{{ background|lightness=+0.05 }}",
    "editorSuggestWidget.border":            "{{ background|lightness=+0.15 }}",
    "editorSuggestWidget.foreground":        "{{ foreground|lightness=-0.05 }}",
    "editorSuggestWidget.selectedBackground":"{{ background|lightness=+0.10 }}",
    "editorSuggestWidget.highlightForeground":"{{ foreground|lightness=+0.05 }}",

    // -- Hover Widget -----------------------------------------
    "editorHoverWidget.background":         "{{ background|lightness=+0.05 }}",
    "editorHoverWidget.border":             "{{ background|lightness=+0.15 }}",
    "editorHoverWidget.foreground":         "{{ foreground|lightness=-0.05 }}",

    // -- Sticky Scroll ----------------------------------------
    "editorStickyScroll.background":        "{{ background|lightness=+0.05 }}",
    "editorStickyScrollHover.background":   "{{ background|lightness=+0.10 }}",

    // -- Peek View --------------------------------------------
    "peekView.border":                         "{{ accent|alpha=0.7 }}",
    "peekViewEditor.background":               "{{ background|lightness=+0.05 }}",
    "peekViewEditor.matchHighlightBackground": "{{ accent|alpha=0.7 }}",
    "peekViewResult.background":               "{{ background }}",
    "peekViewResult.fileForeground":           "{{ foreground|lightness=+0.05 }}",
    "peekViewResult.lineForeground":           "{{ foreground|lightness=-0.10 }}",
    "peekViewResult.matchHighlightBackground": "{{ accent|alpha=0.7 }}",
    "peekViewResult.selectionBackground":      "{{ background|lightness=+0.10 }}",
    "peekViewResult.selectionForeground":      "{{ foreground|lightness=+0.05 }}",
    "peekViewTitle.background":                "{{ background|lightness=+0.10 }}",
    "peekViewTitleLabel.foreground":           "{{ foreground|lightness=+0.05 }}",
    "peekViewTitleDescription.foreground":     "{{ foreground|lightness=-0.15 }}",

    // -- Diff Editor ------------------------------------------
    "diffEditor.insertedLineBackground":    "{{ color2|alpha=0.7 }}",
    "diffEditor.removedLineBackground":     "{{ color1|alpha=0.7 }}",
    "diffEditor.insertedTextBackground":    "{{ color2|alpha=0.7 }}",
    "diffEditor.removedTextBackground":     "{{ color1|alpha=0.7 }}",

    // -- Minimap ----------------------------------------------
    "minimap.background":                   "{{ background }}",
    "minimap.findMatchHighlight":           "{{ accent|alpha=0.7 }}",
    "minimap.selectionHighlight":           "{{ background|lightness=+0.15 }}",
    "minimapSlider.background":             "{{ background|lightness=+0.40|alpha=0.3 }}",
    "minimapSlider.hoverBackground":        "{{ background|lightness=+0.50|alpha=0.3 }}",
    "minimapSlider.activeBackground":       "{{ background|lightness=+0.50|alpha=0.5 }}",

    // -- Terminal ---------------------------------------------
    "terminal.background":                  "{{ background }}",
    "terminal.foreground":                  "{{ foreground|lightness=-0.05 }}",
    "terminal.selectionBackground":         "{{ background|lightness=+0.10 }}",
    "terminalCursor.foreground":            "{{ foreground }}",
    "terminal.ansiBlack":                   "{{ background|lightness=+0.15 }}",
    "terminal.ansiRed":                     "{{ color1 }}",
    "terminal.ansiGreen":                   "{{ color2 }}",
    "terminal.ansiYellow":                  "{{ color3 }}",
    "terminal.ansiBlue":                    "{{ color4 }}",
    "terminal.ansiMagenta":                 "{{ color5 }}",
    "terminal.ansiCyan":                    "{{ color6 }}",
    "terminal.ansiWhite":                   "{{ foreground|lightness=-0.10 }}",
    "terminal.ansiBrightBlack":             "{{ background|lightness=+0.25 }}",
    "terminal.ansiBrightRed":               "{{ color1|lightness=+0.10 }}",
    "terminal.ansiBrightGreen":             "{{ color2|lightness=+0.10 }}",
    "terminal.ansiBrightYellow":            "{{ color3|lightness=+0.10 }}",
    "terminal.ansiBrightBlue":              "{{ color4|lightness=+0.10 }}",
    "terminal.ansiBrightMagenta":           "{{ color5|lightness=+0.10 }}",
    "terminal.ansiBrightCyan":              "{{ color6|lightness=+0.10 }}",
    "terminal.ansiBrightWhite":             "{{ foreground }}",

    // -- Menu -------------------------------------------------
    "menu.background":                      "{{ background|lightness=+0.05 }}",
    "menu.foreground":                      "{{ foreground|lightness=-0.05 }}",
    "menu.selectionBackground":             "{{ background|lightness=+0.10 }}",
    "menu.selectionForeground":             "{{ foreground|lightness=+0.05 }}",
    "menu.separatorBackground":             "{{ background|lightness=+0.15 }}",
    "menu.border":                          "{{ background|lightness=+0.15 }}",

    // -- Status Bar Items -------------------------------------
    "statusBarItem.errorBackground":        "{{ color1|alpha=0.7 }}",
    "statusBarItem.errorForeground":        "{{ foreground|lightness=+0.05 }}",
    "statusBarItem.warningBackground":      "{{ color11|alpha=0.7 }}",
    "statusBarItem.warningForeground":      "{{ foreground|lightness=+0.05 }}",
    "statusBarItem.remoteBackground":       "{{ accent|alpha=0.7 }}",
    "statusBarItem.remoteForeground":       "{{ foreground|lightness=+0.05 }}",

    // -- Panel Section ----------------------------------------
    "panelSectionHeader.background":        "{{ background|lightness=+0.10 }}",
    "panelSectionHeader.foreground":        "{{ foreground|lightness=+0.05 }}",
    "panelSection.border":                  "{{ background|lightness=+0.15 }}"
  },

  "tokenColors": [

    // -- Comments ----------------------
    {
      "name": "Comments",
      "scope": ["comment", "punctuation.definition.comment"],
      "settings": { "foreground": "{{ color2 }}" }
    },

    // -- Strings ---------------------
    {
      "name": "Strings",
      "scope": ["string", "string.template"],
      "settings": { "foreground": "{{ color11 }}" }
    },

    // -- Escape sequences ----------------
    {
      "name": "String escape sequences",
      "scope": ["constant.character.escape"],
      "settings": { "foreground": "{{ color11|alpha=0.7 }}" }
    },

    // -- Generic keywords ---------------------
    {
      "name": "Keywords",
      "scope": ["keyword"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Control flow: if, else, return, for, while, new, delete, using, ... --
    {
      "name": "Control flow keywords",
      "scope": [
        "keyword.control",
        "keyword.other.using",
        "keyword.other.operator",
        "keyword.operator.delete",
        "keyword.operator.new"
      ],
      "settings": { "foreground": "{{ color5 }}" }
    },

    // -- Storage types: const, let, var, function, class, def, ... --
    {
      "name": "Storage types",
      "scope": ["storage", "storage.type"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Storage modifiers: public, private, static, async, export, ... --
    {
      "name": "Storage modifiers",
      "scope": ["storage.modifier"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Operators ----------------
    {
      "name": "Operators",
      "scope": ["keyword.operator"],
      "settings": { "foreground": "{{ foreground }}" }
    },

    // -- Variables ------------------------
    {
      "name": "Variables",
      "scope": [
        "variable",
        "variable.other",
        "support.variable",
        "entity.name.variable",
        "meta.definition.variable.name"
      ],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Language variables (this/self) -------
    {
      "name": "Language variables",
      "scope": ["variable.language"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Function parameters --------------
    {
      "name": "Function parameters",
      "scope": ["variable.parameter"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Functions ---------------------
    {
      "name": "Functions",
      "scope": ["entity.name.function", "support.function"],
      "settings": { "foreground": "{{ color5 }}" }
    },

    // -- Types, classes -----------
    {
      "name": "Types, classes, namespaces",
      "scope": [
        "entity.name.type",
        "entity.name.class",
        "entity.name.namespace",
        "entity.name.module",
        "entity.name.scope-resolution",
        "entity.other.inherited-class",
        "support.class",
        "support.type",
        "support.other.namespace"
      ],
      "settings": { "foreground": "{{ color5 }}" }
    },

    // -- Numbers ------------------------
    {
      "name": "Numbers",
      "scope": [
        "constant.numeric",
        "keyword.operator.plus.exponent",
        "keyword.operator.minus.exponent"
      ],
      "settings": { "foreground": "{{ color2 }}" }
    },

    // -- Language constants (true/false/null) -
    {
      "name": "Language constants",
      "scope": ["constant.language"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Enum members / other constants --
    {
      "name": "Enum members and other constants",
      "scope": [
        "variable.other.constant",
        "variable.other.enummember",
        "constant.character",
        "constant.other"
      ],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Punctuation and brackets -----------------------------
    {
      "name": "Punctuation and brackets",
      "scope": [
        "punctuation",
        "punctuation.section",
        "punctuation.section.block",
        "punctuation.section.block.begin",
        "punctuation.section.block.end",
        "punctuation.section.arguments",
        "punctuation.section.arguments.begin",
        "punctuation.section.arguments.end",
        "punctuation.section.parameters",
        "punctuation.section.parameters.begin",
        "punctuation.section.parameters.end",
        "punctuation.section.group",
        "punctuation.section.group.begin",
        "punctuation.section.group.end",
        "punctuation.section.brackets",
        "punctuation.section.brackets.begin",
        "punctuation.section.brackets.end",
        "punctuation.separator",
        "punctuation.terminator",
        "punctuation.accessor",
        "meta.brace.round",
        "meta.brace.curly",
        "meta.brace.square"
      ],
      "settings": { "foreground": "{{ foreground }}" }
    },

    // -- Tags (HTML/XML) --
    {
      "name": "Tags",
      "scope": ["entity.name.tag"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Attributes --
    {
      "name": "Attributes",
      "scope": ["entity.other.attribute-name"],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Object / property keys ---
    {
      "name": "Property and object keys",
      "scope": [
        "meta.object-literal.key",
        "support.type.property-name",
        "entity.name.tag.yaml"
      ],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Decorators --
    {
      "name": "Decorators",
      "scope": [
        "entity.name.function.decorator",
        "meta.decorator",
        "punctuation.decorator"
      ],
      "settings": { "foreground": "{{ foreground|lightness=+0.05 }}" }
    },

    // -- Regexp character classes --
    {
      "name": "Regular expression character classes",
      "scope": [
        "string.regexp",
        "constant.regexp",
        "constant.character.character-class.regexp",
        "constant.other.character-class.set.regexp",
        "constant.other.character-class.regexp",
        "constant.character.set.regexp"
      ],
      "settings": { "foreground": "{{ color1 }}" }
    },

    // -- Regexp groups / punctuation --
    {
      "name": "Regular expression groups and punctuation",
      "scope": [
        "punctuation.definition.group.regexp",
        "punctuation.definition.character-class.regexp",
        "punctuation.character.set.begin.regexp",
        "punctuation.character.set.end.regexp",
        "support.other.parenthesis.regexp"
      ],
      "settings": { "foreground": "{{ color11 }}" }
    },

    // -- Template literal interpolation --
    {
      "name": "Template expression punctuation",
      "scope": [
        "punctuation.definition.template-expression",
        "punctuation.section.embedded"
      ],
      "settings": { "foreground": "{{ color4 }}" }
    },

    // -- Markup headings --
    {
      "name": "Markup headings",
      "scope": ["markup.heading", "entity.name.section"],
      "settings": { "foreground": "{{ color4  }}", "fontStyle": "bold" }
    },

    // -- Markup bold / italic ---------------------------------
    {
      "name": "Markup bold",
      "scope": ["markup.bold"],
      "settings": { "fontStyle": "bold" }
    },
    {
      "name": "Markup italic",
      "scope": ["markup.italic"],
      "settings": { "fontStyle": "italic" }
    },

    // -- Markup inline code -----------------
    {
      "name": "Markup inline code",
      "scope": ["markup.inline.raw", "markup.raw.inline"],
      "settings": { "foreground": "{{ color11 }}" }
    },

    // -- Markup block quotes -----------------
    {
      "name": "Markup block quotes",
      "scope": ["markup.quote"],
      "settings": { "foreground": "{{ color2 }}" }
    },

    // -- Invalid ----------------
    {
      "name": "Invalid",
      "scope": ["invalid"],
      "settings": { "foreground": "{{ color1 }}" }
    }
  ]
}

// vim:ft=jsonc
