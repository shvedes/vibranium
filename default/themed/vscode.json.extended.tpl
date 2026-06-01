{
  "name": "Vibranium",
  "semanticHighlighting": true,

  "semanticTokenColors": {
    "operator":          "{{ foreground_0 }}",
    "punctuation":       "{{ foreground_0 }}",
    "selfKeyword":       "{{ blue }}",
    "selfTypeKeyword":   "{{ blue }}"
  },

  "colors": {

    // -- Welcome Page ----------------------------------------
    "textLink.foreground":              "{{ accent }}",
    "textLink.activeForeground":        "{{ accent_bright }}",

    "welcomePage.tileBackground":       "{{ background_2 }}",
    "welcomePage.tileHoverBackground":  "{{ background_3 }}",
    "welcomePage.progress.background":  "{{ background_3 }}",
    "welcomePage.progress.foreground":  "{{ accent }}",

    "button.secondaryBackground":       "{{ background_2 }}",
    "button.secondaryForeground":       "{{ foreground_1 }}",
    "button.secondaryHoverBackground":  "{{ background_3 }}",

    "descriptionForeground":            "{{ foreground_4 }}",

    // -- Editor ------------------------------------------------
    "editor.background":                  "{{ background_0 }}",
    "editor.foreground":                  "{{ foreground_0 }}",
    "editor.lineHighlightBackground":     "{{ background_1 }}",
    "editor.selectionBackground":         "{{ background_2 }}",
    "editor.inactiveSelectionBackground": "{{ background_1|lightness=-0.05 }}",
    "editorCursor.foreground":            "{{ foreground_0 }}",
    "editorLineNumber.foreground":        "{{ background_5 }}",
    "editorLineNumber.activeForeground":  "{{ foreground_2 }}",
    "editorIndentGuide.background1":      "{{ background_1 }}",
    "editorIndentGuide.activeBackground1":"{{ background_2 }}",

    // -- Activity Bar ------------------------------------------
    "activityBar.background":             "{{ background_1 }}",
    "activityBar.foreground":             "{{ foreground_1 }}",
    "activityBar.inactiveForeground":     "{{ foreground_3 }}",
    "activityBarBadge.background":        "{{ background_2 }}",
    "activityBarBadge.foreground":        "{{ foreground_2 }}",

    // -- Side Bar ----------------------------------------------
    "sideBar.background":                 "{{ background_1 }}",
    "sideBar.foreground":                 "{{ foreground_1 }}",
    "sideBar.border":                     "{{ background_3 }}",
    "sideBarTitle.foreground":            "{{ foreground_h }}",
    "sideBarSectionHeader.background":    "{{ background_1 }}",
    "sideBarSectionHeader.foreground":    "{{ foreground_1 }}",

    // -- Status Bar --------------------------------------------
    "statusBar.background":               "{{ background_2 }}",
    "statusBar.foreground":               "{{ foreground_2 }}",
    "statusBar.noFolderBackground":       "{{ background_2 }}",
    "statusBar.debuggingBackground":      "{{ orange_dim }}",

    // -- Title Bar ---------------------------------------------
    "titleBar.activeBackground":          "{{ background_0 }}",
    "titleBar.activeForeground":          "{{ foreground_0 }}",
    "titleBar.inactiveBackground":        "{{ background_1 }}",
    "titleBar.inactiveForeground":        "{{ foreground_1 }}",

    // -- Tabs --------------------------------------------------
    "tab.activeBackground":               "{{ background_1 }}",
    "tab.activeForeground":               "{{ foreground_h }}",
    "tab.inactiveBackground":             "{{ background_0 }}",
    "tab.inactiveForeground":             "{{ foreground_3 }}",
    "tab.border":                         "{{ background_0 }}",
    "tab.activeBorder":                   "{{ background_3 }}",
    "editorGroupHeader.tabsBackground":   "{{ background_0 }}",

    // -- Panel -------------------------------------------------
    "panel.background":                   "{{ background_1 }}",
    "panel.border":                       "{{ background_5 }}",
    "panelTitle.activeForeground":        "{{ foreground_h }}",
    "panelTitle.inactiveForeground":      "{{ foreground_3 }}",

    // -- Input / Dropdown --------------------------------------
    "input.background":                   "{{ background_1 }}",
    "input.foreground":                   "{{ foreground_1 }}",
    "input.border":                       "{{ background_3 }}",
    "input.placeholderForeground":        "{{ foreground_4 }}",
    "dropdown.background":                "{{ background_1 }}",
    "dropdown.foreground":                "{{ foreground_1 }}",

    // -- Lists -------------------------------------------------
    "list.activeSelectionBackground":     "{{ background_1 }}",
    "list.activeSelectionForeground":     "{{ foreground_h }}",
    "list.inactiveSelectionBackground":   "{{ background_1 }}",
    "list.hoverBackground":               "{{ background_2 }}",
    "list.focusBackground":               "{{ background_2 }}",
    "list.highlightForeground":           "{{ foreground_h }}",

    // -- Buttons -----------------------------------------------
    "button.background":                  "{{ accent|alpha=0.7 }}",
    "button.foreground":                  "{{ foreground_h }}",
    "button.hoverBackground":             "{{ accent }}",

    // -- Scrollbar ---------------------------------------------
    "scrollbarSlider.background":         "{{ gray_dim }}",
    "scrollbarSlider.hoverBackground":    "{{ gray }}",
    "scrollbarSlider.activeBackground":   "{{ gray_bright }}",

    // -- Badge -------------------------------------------------
    "badge.background":                   "{{ background_4 }}",
    "badge.foreground":                   "{{ foreground_h }}",

    // -- Notifications -----------------------------------------
    "notifications.background":           "{{ background_2 }}",
    "notifications.foreground":           "{{ foreground_1 }}",
    "notificationCenterHeader.background":"{{ accent_dim }}",

    // -- Breadcrumb --------------------------------------------
    "breadcrumb.background":                "{{ background_1 }}",
    "breadcrumb.foreground":                "{{ foreground_3 }}",
    "breadcrumb.activeSelectionForeground": "{{ background_3 }}",

    // -- Git Decorations ---------------------------------------
    "gitDecoration.modifiedResourceForeground":    "{{ green }}",
    "gitDecoration.deletedResourceForeground":     "{{ red_dim }}",
    "gitDecoration.untrackedResourceForeground":   "{{ foreground_0|alpha=0.5 }}",
    "gitDecoration.ignoredResourceForeground":     "{{ orange }}",
    "gitDecoration.conflictingResourceForeground": "{{ red }}",

    // -- Quick Input / Search ----------------------------------

    "quickInput.border":                  "{{ background_4 }}",
    "quickInput.background":              "{{ background_1 }}",
    "quickInput.foreground":              "{{ foreground_1 }}",
    "quickInputTitle.background":         "{{ background_0 }}",
    "quickInputTitle.foreground":         "{{ foreground_h }}",

    "widget.shadow":                      "{{ accent_dim }}",

    "pickerGroup.background":             "{{ red }}",
    "pickerGroup.border":                 "{{ background_3 }}",
    "pickerGroup.foreground":             "{{ foreground_1 }}",

    "quickInputList.focusBackground":     "{{ background_2 }}",
    "quickInputList.focusForeground":     "{{ foreground_h }}",
    "quickInputList.focusIconForeground": "{{ foreground_h }}",

    // -- Global -----------------------------------------------
    "focusBorder":                          "{{ accent_dim }}",
    "selection.background":                 "{{ background_2 }}",

    // -- Editor Group -----------------------------------------
    "editorGroup.border":                   "{{ background_3 }}",
    "editorGroup.dropBackground":           "{{ background_2 }}",

    // -- Editor Find / Word Highlights ------------------------
    "editor.findMatchBackground":           "{{ accent_dim }}",
    "editor.findMatchHighlightBackground":  "{{ background_3 }}",
    "editor.wordHighlightBackground":       "{{ background_2 }}",
    "editor.wordHighlightStrongBackground": "{{ background_3 }}",
    "editor.rangeHighlightBackground":      "{{ background_1 }}",

    // -- Editor Diagnostics -----------------------------------
    "editorError.foreground":               "{{ red }}",
    "editorWarning.foreground":             "{{ orange }}",
    "editorInfo.foreground":                "{{ blue }}",

    // -- Editor Bracket Match ---------------------------------
    "editorBracketMatch.background":        "{{ background_3 }}",
    "editorBracketMatch.border":            "{{ foreground_3 }}",

    // -- Editor Gutter (git diff line markers) ----------------
    "editorGutter.addedBackground":         "{{ green_dim }}",
    "editorGutter.modifiedBackground":      "{{ blue }}",
    "editorGutter.deletedBackground":       "{{ red_dim }}",

    // -- Editor Code Lens -------------------------------------
    "editorCodeLens.foreground":            "{{ foreground_4 }}",

    // -- Editor Inlay Hints -----------------------------------
    "editorInlayHint.background":           "{{ background_2 }}",
    "editorInlayHint.foreground":           "{{ foreground_4 }}",
    "editorInlayHint.typeForeground":       "{{ cyan }}",
    "editorInlayHint.parameterForeground":  "{{ foreground_3 }}",

    // -- Suggest Widget ---------------------------------------
    "editorSuggestWidget.background":        "{{ background_1 }}",
    "editorSuggestWidget.border":            "{{ background_3 }}",
    "editorSuggestWidget.foreground":        "{{ foreground_1 }}",
    "editorSuggestWidget.selectedBackground":"{{ background_2 }}",
    "editorSuggestWidget.highlightForeground":"{{ foreground_h }}",

    // -- Hover Widget -----------------------------------------
    "editorHoverWidget.background":         "{{ background_1 }}",
    "editorHoverWidget.border":             "{{ background_3 }}",
    "editorHoverWidget.foreground":         "{{ foreground_1 }}",

    // -- Sticky Scroll ----------------------------------------
    "editorStickyScroll.background":        "{{ background_1 }}",
    "editorStickyScrollHover.background":   "{{ background_2 }}",

    // -- Peek View --------------------------------------------
    "peekView.border":                         "{{ accent_dim }}",
    "peekViewEditor.background":               "{{ background_1 }}",
    "peekViewEditor.matchHighlightBackground": "{{ accent_dim }}",
    "peekViewResult.background":               "{{ background_0 }}",
    "peekViewResult.fileForeground":           "{{ foreground_h }}",
    "peekViewResult.lineForeground":           "{{ foreground_2 }}",
    "peekViewResult.matchHighlightBackground": "{{ accent_dim }}",
    "peekViewResult.selectionBackground":      "{{ background_2 }}",
    "peekViewResult.selectionForeground":      "{{ foreground_h }}",
    "peekViewTitle.background":                "{{ background_2 }}",
    "peekViewTitleLabel.foreground":           "{{ foreground_h }}",
    "peekViewTitleDescription.foreground":     "{{ foreground_3 }}",

    // -- Diff Editor ------------------------------------------
    "diffEditor.insertedLineBackground":    "{{ green_dim }}",
    "diffEditor.removedLineBackground":     "{{ red_dim }}",
    "diffEditor.insertedTextBackground":    "{{ green_dim }}",
    "diffEditor.removedTextBackground":     "{{ red_dim }}",

    // -- Minimap ----------------------------------------------
    "minimap.background":                   "{{ background_0 }}",
    "minimap.findMatchHighlight":           "{{ accent_dim }}",
    "minimap.selectionHighlight":           "{{ background_3 }}",
    "minimapSlider.background":             "{{ gray_dim|alpha=0.3 }}",
    "minimapSlider.hoverBackground":        "{{ gray|alpha=0.3 }}",
    "minimapSlider.activeBackground":       "{{ gray_bright|alpha=0.5 }}",

    // -- Terminal ---------------------------------------------
    "terminal.background":                  "{{ background_0 }}",
    "terminal.foreground":                  "{{ foreground_1 }}",
    "terminal.selectionBackground":         "{{ background_2 }}",
    "terminalCursor.foreground":            "{{ foreground_0 }}",
    "terminal.ansiBlack":                   "{{ background_3 }}",
    "terminal.ansiRed":                     "{{ red }}",
    "terminal.ansiGreen":                   "{{ green }}",
    "terminal.ansiYellow":                  "{{ orange }}",
    "terminal.ansiBlue":                    "{{ blue }}",
    "terminal.ansiMagenta":                 "{{ purple }}",
    "terminal.ansiCyan":                    "{{ cyan }}",
    "terminal.ansiWhite":                   "{{ foreground_2 }}",
    "terminal.ansiBrightBlack":             "{{ gray_bright }}",
    "terminal.ansiBrightRed":               "{{ red_bright }}",
    "terminal.ansiBrightGreen":             "{{ green_bright }}",
    "terminal.ansiBrightYellow":            "{{ orange_bright }}",
    "terminal.ansiBrightBlue":              "{{ blue_bright }}",
    "terminal.ansiBrightMagenta":           "{{ purple_bright }}",
    "terminal.ansiBrightCyan":              "{{ cyan_bright }}",
    "terminal.ansiBrightWhite":             "{{ foreground_h }}",

    // -- Menu -------------------------------------------------
    "menu.background":                      "{{ background_1 }}",
    "menu.foreground":                      "{{ foreground_1 }}",
    "menu.selectionBackground":             "{{ background_2 }}",
    "menu.selectionForeground":             "{{ foreground_h }}",
    "menu.separatorBackground":             "{{ background_3 }}",
    "menu.border":                          "{{ background_3 }}",

    // -- Status Bar Items -------------------------------------
    "statusBarItem.errorBackground":        "{{ red_dim }}",
    "statusBarItem.errorForeground":        "{{ foreground_h }}",
    "statusBarItem.warningBackground":      "{{ orange_dim }}",
    "statusBarItem.warningForeground":      "{{ foreground_h }}",
    "statusBarItem.remoteBackground":       "{{ accent_dim }}",
    "statusBarItem.remoteForeground":       "{{ foreground_h }}",

    // -- Panel Section ----------------------------------------
    "panelSectionHeader.background":        "{{ background_2 }}",
    "panelSectionHeader.foreground":        "{{ foreground_h }}",
    "panelSection.border":                  "{{ background_3 }}"
  },

  "tokenColors": [

      // -- Comments ----------------------
      {
        "name": "Comments",
        "scope": ["comment", "punctuation.definition.comment"],
        "settings": { "foreground": "{{ green }}", "fontStyle": "italic" }
      },

      // -- Strings ---------------------
      {
        "name": "Strings",
        "scope": ["string", "string.template"],
        "settings": { "foreground": "{{ orange }}" }
      },

      // -- Escape sequences ----------------
      {
        "name": "String escape sequences",
        "scope": ["constant.character.escape"],
        "settings": { "foreground": "{{ orange_dim }}" }
      },

      // -- Generic keywords ---------------------
      {
        "name": "Keywords",
        "scope": ["keyword"],
        "settings": { "foreground": "{{ blue }}" }
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
        "settings": { "foreground": "{{ purple }}" }
      },

      // -- Storage types: const, let, var, function, class, def, ... --
      {
        "name": "Storage types",
        "scope": ["storage", "storage.type"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Storage modifiers: public, private, static, async, export, ... --
      {
        "name": "Storage modifiers",
        "scope": ["storage.modifier"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Operators ----------------
      {
        "name": "Operators",
        "scope": ["keyword.operator"],
        "settings": { "foreground": "{{ foreground_0 }}" }
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
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Language variables (this/self) -------
      {
        "name": "Language variables",
        "scope": ["variable.language"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Function parameters --------------
      {
        "name": "Function parameters",
        "scope": ["variable.parameter"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Functions ---------------------
      {
        "name": "Functions",
        "scope": ["entity.name.function", "support.function"],
        "settings": { "foreground": "{{ purple }}" }
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
        "settings": { "foreground": "{{ cyan }}" }
      },

      // -- Numbers ------------------------
      {
        "name": "Numbers",
        "scope": [
          "constant.numeric",
          "keyword.operator.plus.exponent",
          "keyword.operator.minus.exponent"
        ],
        "settings": { "foreground": "{{ green }}" }
      },

      // -- Language constants (true/false/null) -
      {
        "name": "Language constants",
        "scope": ["constant.language"],
        "settings": { "foreground": "{{ blue }}" }
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
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Punctuation and brackets -----------------------------
      // Explicit sub-scopes prevent default inherited rules from
      // winning via higher specificity
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
        "settings": { "foreground": "{{ foreground_0 }}" }
      },

      // -- Tags (HTML/XML) --
      {
        "name": "Tags",
        "scope": ["entity.name.tag"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Attributes --
      {
        "name": "Attributes",
        "scope": ["entity.other.attribute-name"],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Object / property keys ---
      {
        "name": "Property and object keys",
        "scope": [
          "meta.object-literal.key",
          "support.type.property-name",
          "entity.name.tag.yaml"
        ],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Decorators --
      {
        "name": "Decorators",
        "scope": [
          "entity.name.function.decorator",
          "meta.decorator",
          "punctuation.decorator"
        ],
        "settings": { "foreground": "{{ foreground_h }}" }
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
        "settings": { "foreground": "{{ red }}" }
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
        "settings": { "foreground": "{{ orange }}" }
      },

      // -- Template literal interpolation --
      {
        "name": "Template expression punctuation",
        "scope": [
          "punctuation.definition.template-expression",
          "punctuation.section.embedded"
        ],
        "settings": { "foreground": "{{ blue }}" }
      },

      // -- Markup headings --
      {
        "name": "Markup headings",
        "scope": ["markup.heading", "entity.name.section"],
        "settings": { "foreground": "{{ blue }}", "fontStyle": "bold" }
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
        "settings": { "foreground": "{{ orange }}" }
      },

      // -- Markup block quotes -----------------
      {
        "name": "Markup block quotes",
        "scope": ["markup.quote"],
        "settings": { "foreground": "{{ green }}", "fontStyle": "italic" }
      },

      // -- Invalid ----------------
      {
        "name": "Invalid",
        "scope": ["invalid"],
        "settings": { "foreground": "{{ red }}", "fontStyle": "strikethrough" }
      }
    ]
}

// vim:ft=jsonc
