{
  "name": "Vibranium",
  "semanticHighlighting": true,

  "semanticTokenColors": {
    "operator":          "{{ foreground }}",
    "punctuation":       "{{ foreground }}",
    "selfKeyword":       "{{ blue }}",
    "selfTypeKeyword":   "{{ blue }}"
  },

  "colors": {

    // -- Welcome Page ----------------------------------------
    "textLink.foreground":              "{{ accent }}",
    "textLink.activeForeground":        "{{ accent|pop=0.10 }}",

    "welcomePage.tileBackground":       "{{ background|pop=0.12 }}",
    "welcomePage.tileHoverBackground":  "{{ background|pop=0.18 }}",
    "welcomePage.progress.background":  "{{ background|pop=0.18 }}",
    "welcomePage.progress.foreground":  "{{ accent }}",

    "button.secondaryBackground":       "{{ background|pop=0.12 }}",
    "button.secondaryForeground":       "{{ foreground|dim=0.06 }}",
    "button.secondaryHoverBackground":  "{{ background|pop=0.18 }}",

    "descriptionForeground":            "{{ foreground|dim=0.24 }}",

    // -- Editor ------------------------------------------------
    "editor.background":                  "{{ background }}",
    "editor.foreground":                  "{{ foreground }}",
    "editor.lineHighlightBackground":     "{{ background|pop=0.06 }}",
    "editor.selectionBackground":         "{{ background|pop=0.12 }}",
    "editor.inactiveSelectionBackground": "{{ background|pop=0.06|lightness=-0.05 }}",
    "editorCursor.foreground":            "{{ foreground }}",
    "editorLineNumber.foreground":        "{{ background|pop=0.30 }}",
    "editorLineNumber.activeForeground":  "{{ foreground|dim=0.12 }}",
    "editorIndentGuide.background1":      "{{ background|pop=0.06 }}",
    "editorIndentGuide.activeBackground1":"{{ background|pop=0.12 }}",

    // -- Activity Bar ------------------------------------------
    "activityBar.background":             "{{ background|pop=0.06 }}",
    "activityBar.foreground":             "{{ foreground|dim=0.06 }}",
    "activityBar.inactiveForeground":     "{{ foreground|dim=0.18 }}",
    "activityBarBadge.background":        "{{ background|pop=0.12 }}",
    "activityBarBadge.foreground":        "{{ foreground|dim=0.12 }}",

    // -- Side Bar ----------------------------------------------
    "sideBar.background":                 "{{ background|pop=0.06 }}",
    "sideBar.foreground":                 "{{ foreground|dim=0.06 }}",
    "sideBar.border":                     "{{ background|pop=0.18 }}",
    "sideBarTitle.foreground":            "{{ foreground|pop=0.06 }}",
    "sideBarSectionHeader.background":    "{{ background|pop=0.06 }}",
    "sideBarSectionHeader.foreground":    "{{ foreground|dim=0.06 }}",

    // -- Status Bar --------------------------------------------
    "statusBar.background":               "{{ background|pop=0.12 }}",
    "statusBar.foreground":               "{{ foreground|dim=0.12 }}",
    "statusBar.noFolderBackground":       "{{ background|pop=0.12 }}",
    "statusBar.debuggingBackground":      "{{ orange|dim=0.10 }}",

    // -- Title Bar ---------------------------------------------
    "titleBar.activeBackground":          "{{ background }}",
    "titleBar.activeForeground":          "{{ foreground }}",
    "titleBar.inactiveBackground":        "{{ background|pop=0.06 }}",
    "titleBar.inactiveForeground":        "{{ foreground|dim=0.06 }}",

    // -- Tabs --------------------------------------------------
    "tab.activeBackground":               "{{ background|pop=0.06 }}",
    "tab.activeForeground":               "{{ foreground|pop=0.06 }}",
    "tab.inactiveBackground":             "{{ background }}",
    "tab.inactiveForeground":             "{{ foreground|dim=0.18 }}",
    "tab.border":                         "{{ background }}",
    "tab.activeBorder":                   "{{ background|pop=0.18 }}",
    "editorGroupHeader.tabsBackground":   "{{ background }}",

    // -- Panel -------------------------------------------------
    "panel.background":                   "{{ background|pop=0.06 }}",
    "panel.border":                       "{{ background|pop=0.30 }}",
    "panelTitle.activeForeground":        "{{ foreground|pop=0.06 }}",
    "panelTitle.inactiveForeground":      "{{ foreground|dim=0.18 }}",

    // -- Input / Dropdown --------------------------------------
    "input.background":                   "{{ background|pop=0.06 }}",
    "input.foreground":                   "{{ foreground|dim=0.06 }}",
    "input.border":                       "{{ background|pop=0.18 }}",
    "input.placeholderForeground":        "{{ foreground|dim=0.24 }}",
    "dropdown.background":                "{{ background|pop=0.06 }}",
    "dropdown.foreground":                "{{ foreground|dim=0.06 }}",

    // -- Lists -------------------------------------------------
    "list.activeSelectionBackground":     "{{ background|pop=0.06 }}",
    "list.activeSelectionForeground":     "{{ foreground|pop=0.06 }}",
    "list.inactiveSelectionBackground":   "{{ background|pop=0.06 }}",
    "list.hoverBackground":               "{{ background|pop=0.12 }}",
    "list.focusBackground":               "{{ background|pop=0.12 }}",
    "list.highlightForeground":           "{{ foreground|pop=0.06 }}",

    // -- Buttons -----------------------------------------------
    "button.background":                  "{{ accent|alpha=0.7 }}",
    "button.foreground":                  "{{ foreground|pop=0.06 }}",
    "button.hoverBackground":             "{{ accent }}",

    // -- Scrollbar ---------------------------------------------
    "scrollbarSlider.background":         "{{ gray|dim=0.10 }}",
    "scrollbarSlider.hoverBackground":    "{{ gray }}",
    "scrollbarSlider.activeBackground":   "{{ gray|pop=0.10 }}",

    // -- Badge -------------------------------------------------
    "badge.background":                   "{{ background|pop=0.24 }}",
    "badge.foreground":                   "{{ foreground|pop=0.06 }}",

    // -- Notifications -----------------------------------------
    "notifications.background":           "{{ background|pop=0.12 }}",
    "notifications.foreground":           "{{ foreground|dim=0.06 }}",
    "notificationCenterHeader.background":"{{ accent|dim=0.10 }}",

    // -- Breadcrumb --------------------------------------------
    "breadcrumb.background":                "{{ background|pop=0.06 }}",
    "breadcrumb.foreground":                "{{ foreground|dim=0.18 }}",
    "breadcrumb.activeSelectionForeground": "{{ background|pop=0.18 }}",

    // -- Git Decorations ---------------------------------------
    "gitDecoration.modifiedResourceForeground":    "{{ green }}",
    "gitDecoration.deletedResourceForeground":     "{{ red|dim=0.10 }}",
    "gitDecoration.untrackedResourceForeground":   "{{ foreground|alpha=0.5 }}",
    "gitDecoration.ignoredResourceForeground":     "{{ orange }}",
    "gitDecoration.conflictingResourceForeground": "{{ red }}",

    // -- Quick Input / Search ----------------------------------

    "quickInput.border":                  "{{ background|pop=0.24 }}",
    "quickInput.background":              "{{ background|pop=0.06 }}",
    "quickInput.foreground":              "{{ foreground|dim=0.06 }}",
    "quickInputTitle.background":         "{{ background }}",
    "quickInputTitle.foreground":         "{{ foreground|pop=0.06 }}",

    "widget.shadow":                      "{{ accent|dim=0.10 }}",

    "pickerGroup.background":             "{{ red }}",
    "pickerGroup.border":                 "{{ background|pop=0.18 }}",
    "pickerGroup.foreground":             "{{ foreground|dim=0.06 }}",

    "quickInputList.focusBackground":     "{{ background|pop=0.12 }}",
    "quickInputList.focusForeground":     "{{ foreground|pop=0.06 }}",
    "quickInputList.focusIconForeground": "{{ foreground|pop=0.06 }}",

    // -- Global -----------------------------------------------
    "focusBorder":                          "{{ accent|dim=0.10 }}",
    "selection.background":                 "{{ background|pop=0.12 }}",

    // -- Editor Group -----------------------------------------
    "editorGroup.border":                   "{{ background|pop=0.18 }}",
    "editorGroup.dropBackground":           "{{ background|pop=0.12 }}",

    // -- Editor Find / Word Highlights ------------------------
    "editor.findMatchBackground":           "{{ accent|dim=0.10 }}",
    "editor.findMatchHighlightBackground":  "{{ background|pop=0.18 }}",
    "editor.wordHighlightBackground":       "{{ background|pop=0.12 }}",
    "editor.wordHighlightStrongBackground": "{{ background|pop=0.18 }}",
    "editor.rangeHighlightBackground":      "{{ background|pop=0.06 }}",

    // -- Editor Diagnostics -----------------------------------
    "editorError.foreground":               "{{ red }}",
    "editorWarning.foreground":             "{{ orange }}",
    "editorInfo.foreground":                "{{ blue }}",

    // -- Editor Bracket Match ---------------------------------
    "editorBracketMatch.background":        "{{ background|pop=0.18 }}",
    "editorBracketMatch.border":            "{{ foreground|dim=0.18 }}",

    // -- Editor Gutter (git diff line markers) ----------------
    "editorGutter.addedBackground":         "{{ green|dim=0.10 }}",
    "editorGutter.modifiedBackground":      "{{ blue }}",
    "editorGutter.deletedBackground":       "{{ red|dim=0.10 }}",

    // -- Editor Code Lens -------------------------------------
    "editorCodeLens.foreground":            "{{ foreground|dim=0.24 }}",

    // -- Editor Inlay Hints -----------------------------------
    "editorInlayHint.background":           "{{ background|pop=0.12 }}",
    "editorInlayHint.foreground":           "{{ foreground|dim=0.24 }}",
    "editorInlayHint.typeForeground":       "{{ cyan }}",
    "editorInlayHint.parameterForeground":  "{{ foreground|dim=0.18 }}",

    // -- Suggest Widget ---------------------------------------
    "editorSuggestWidget.background":        "{{ background|pop=0.06 }}",
    "editorSuggestWidget.border":            "{{ background|pop=0.18 }}",
    "editorSuggestWidget.foreground":        "{{ foreground|dim=0.06 }}",
    "editorSuggestWidget.selectedBackground":"{{ background|pop=0.12 }}",
    "editorSuggestWidget.highlightForeground":"{{ foreground|pop=0.06 }}",

    // -- Hover Widget -----------------------------------------
    "editorHoverWidget.background":         "{{ background|pop=0.06 }}",
    "editorHoverWidget.border":             "{{ background|pop=0.18 }}",
    "editorHoverWidget.foreground":         "{{ foreground|dim=0.06 }}",

    // -- Sticky Scroll ----------------------------------------
    "editorStickyScroll.background":        "{{ background|pop=0.06 }}",
    "editorStickyScrollHover.background":   "{{ background|pop=0.12 }}",

    // -- Peek View --------------------------------------------
    "peekView.border":                         "{{ accent|dim=0.10 }}",
    "peekViewEditor.background":               "{{ background|pop=0.06 }}",
    "peekViewEditor.matchHighlightBackground": "{{ accent|dim=0.10 }}",
    "peekViewResult.background":               "{{ background }}",
    "peekViewResult.fileForeground":           "{{ foreground|pop=0.06 }}",
    "peekViewResult.lineForeground":           "{{ foreground|dim=0.12 }}",
    "peekViewResult.matchHighlightBackground": "{{ accent|dim=0.10 }}",
    "peekViewResult.selectionBackground":      "{{ background|pop=0.12 }}",
    "peekViewResult.selectionForeground":      "{{ foreground|pop=0.06 }}",
    "peekViewTitle.background":                "{{ background|pop=0.12 }}",
    "peekViewTitleLabel.foreground":           "{{ foreground|pop=0.06 }}",
    "peekViewTitleDescription.foreground":     "{{ foreground|dim=0.18 }}",

    // -- Diff Editor ------------------------------------------
    "diffEditor.insertedLineBackground":    "{{ green|dim=0.10 }}",
    "diffEditor.removedLineBackground":     "{{ red|dim=0.10 }}",
    "diffEditor.insertedTextBackground":    "{{ green|dim=0.10 }}",
    "diffEditor.removedTextBackground":     "{{ red|dim=0.10 }}",

    // -- Minimap ----------------------------------------------
    "minimap.background":                   "{{ background }}",
    "minimap.findMatchHighlight":           "{{ accent|dim=0.10 }}",
    "minimap.selectionHighlight":           "{{ background|pop=0.18 }}",
    "minimapSlider.background":             "{{ gray|dim=0.10|alpha=0.3  }}",
    "minimapSlider.hoverBackground":        "{{ gray|alpha=0.3 }}",
    "minimapSlider.activeBackground":       "{{ gray|pop=0.10|alpha=0.5  }}",

    // -- Terminal ---------------------------------------------
    "terminal.background":                  "{{ background }}",
    "terminal.foreground":                  "{{ foreground|dim=0.06 }}",
    "terminal.selectionBackground":         "{{ background|pop=0.12 }}",
    "terminalCursor.foreground":            "{{ foreground }}",
    "terminal.ansiBlack":                   "{{ background|pop=0.18 }}",
    "terminal.ansiRed":                     "{{ red }}",
    "terminal.ansiGreen":                   "{{ green }}",
    "terminal.ansiYellow":                  "{{ orange }}",
    "terminal.ansiBlue":                    "{{ blue }}",
    "terminal.ansiMagenta":                 "{{ purple }}",
    "terminal.ansiCyan":                    "{{ cyan }}",
    "terminal.ansiWhite":                   "{{ foreground|dim=0.12 }}",
    "terminal.ansiBrightBlack":             "{{ gray|pop=0.10 }}",
    "terminal.ansiBrightRed":               "{{ red|pop=0.10 }}",
    "terminal.ansiBrightGreen":             "{{ green|pop=0.10 }}",
    "terminal.ansiBrightYellow":            "{{ orange|pop=0.10 }}",
    "terminal.ansiBrightBlue":              "{{ blue|pop=0.10 }}",
    "terminal.ansiBrightMagenta":           "{{ purple|pop=0.10 }}",
    "terminal.ansiBrightCyan":              "{{ cyan|pop=0.10 }}",
    "terminal.ansiBrightWhite":             "{{ foreground|pop=0.06 }}",

    // -- Menu -------------------------------------------------
    "menu.background":                      "{{ background|pop=0.06 }}",
    "menu.foreground":                      "{{ foreground|dim=0.06 }}",
    "menu.selectionBackground":             "{{ background|pop=0.12 }}",
    "menu.selectionForeground":             "{{ foreground|pop=0.06 }}",
    "menu.separatorBackground":             "{{ background|pop=0.18 }}",
    "menu.border":                          "{{ background|pop=0.18 }}",

    // -- Status Bar Items -------------------------------------
    "statusBarItem.errorBackground":        "{{ red|dim=0.10 }}",
    "statusBarItem.errorForeground":        "{{ foreground|pop=0.06 }}",
    "statusBarItem.warningBackground":      "{{ orange|dim=0.10 }}",
    "statusBarItem.warningForeground":      "{{ foreground|pop=0.06 }}",
    "statusBarItem.remoteBackground":       "{{ accent|dim=0.10 }}",
    "statusBarItem.remoteForeground":       "{{ foreground|pop=0.06 }}",

    // -- Panel Section ----------------------------------------
    "panelSectionHeader.background":        "{{ background|pop=0.12 }}",
    "panelSectionHeader.foreground":        "{{ foreground|pop=0.06 }}",
    "panelSection.border":                  "{{ background|pop=0.18 }}"
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
        "settings": { "foreground": "{{ orange|dim=0.10 }}" }
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
        "settings": { "foreground": "{{ foreground }}" }
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
        "settings": { "foreground": "{{ foreground|pop=0.06 }}" }
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
