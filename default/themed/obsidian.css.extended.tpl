.theme-dark, .theme-light {
  /* Color definitions */
  --color-red: {{ red }};
  --color-red-rgb: {{ red_rgb }};

  --color-green: {{ green }};
  --color-green-rgb: {{ green_rgb }};

  --color-yellow: {{ yellow }};
  --color-yellow-rgb: {{ yellow_rgb }};

  --color-blue: {{ blue }};
  --color-blue-rgb: {{ blue_rgb }};

  --color-purple: {{ purple }};
  --color-purple-rgb: {{ purple_rgb }};

  --color-pink: {{ pink }};
  --color-pink-rgb: {{ pink_rgb }};

  --color-cyan: {{ cyan }};
  --color-cyan-rgb: {{ cyan_rgb }};

  --color-orange: {{ orange }};
  --color-orange-rgb: {{ orange_rgb }};

  /* Gradually build all base colors */
  --color-base-00: rgba({{ background_h_rgb }},0.5);
  --color-base-05: rgba({{ background_h_rgb }},1.0);
  --color-base-10: rgba({{ background_0_rgb }},0.5);
  --color-base-20: rgba({{ background_0_rgb }},1.0);
  --color-base-25: rgba({{ background_1_rgb }},0.5);
  --color-base-30: rgba({{ background_1_rgb }},1.0);
  --color-base-35: rgba({{ background_2_rgb }},0.5);
  --color-base-40: rgba({{ background_2_rgb }},1.0);
  --color-base-50: rgba({{ background_3_rgb }},0.5);
  --color-base-60: rgba({{ background_3_rgb }},1.0);
  --color-base-70: rgba({{ background_4_rgb }},1.0);
  --color-base-100: rgba({{ background5_rgb }},1.0);

  /* Core colors */
  --background-primary: {{ background_0 }};
  --background-primary-alt: {{ background_h }};
  --background-secondary: rgba({{ background_1_rgb }},0.3);
  --background-secondary-alt: {{ background_1 }};
  --text-normal: {{ foreground_0 }};

  /* Selection colors */
  --text-selection: rgba({{ foreground_0_rgb }},0.15);

  /* Border color */
  --background-modifier-border: var(--color-base-40);

  /* Semantic heading colors */
  --text-title-h1: var(--color-green);
  --text-title-h2: var(--color-cyan);
  --text-title-h3: var(--color-blue);
  --text-title-h4: var(--color-yellow);
  --text-title-h5: var(--color-orange);
  --text-title-h6: var(--color-purple);

  /* Links and accents */
  --text-link: var(--color-blue);
  --text-accent: {{ accent }};
  --text-accent-hover: var(--color-purple);
  --interactive-accent: {{ accent }};
  --interactive-accent-hover: rgba({{ accent_rgb }},0.8);

  /* Muted text */
  --text-muted: color-mix(in srgb, {{ foreground_0 }} 70%, transparent);
  --text-faint: color-mix(in srgb, {{ foreground_0 }} 55%, transparent);

  /* Code */
  --code-normal: {{ foreground_2 }};

  /* Errors and success */
  --text-error: {{ red }};
  --text-error-hover: {{ red }};
  --text-success: {{ green }};

  /* Tags */
  --tag-color: {{ yellow }};
  --tag-background: rgba({{ background_3_rgb }},0.5);

  /* Graph */
  --graph-line: {{ gray }};
  --graph-node: {{ accent }};
  --graph-node-focused: var(--color-blue);
  --graph-node-tag: var(--color-green);
  --graph-node-attachment: var(--color-yellow);
}

/* Headers */
.cm-header-1, .markdown-rendered h1 { color: var(--text-title-h1); }
.cm-header-2, .markdown-rendered h2 { color: var(--text-title-h2); }
.cm-header-3, .markdown-rendered h3 { color: var(--text-title-h3); }
.cm-header-4, .markdown-rendered h4 { color: var(--text-title-h4); }
.cm-header-5, .markdown-rendered h5 { color: var(--text-title-h5); }
.cm-header-6, .markdown-rendered h6 { color: var(--text-title-h6); }

/* Code blocks */
.markdown-rendered code {
  color: {{ foreground_2 }};
}

/* Syntax highlighting */
.cm-s-obsidian span.cm-keyword { color: var(--color-red); }
.cm-s-obsidian span.cm-string { color: var(--color-yellow); }
.cm-s-obsidian span.cm-number { color: var(--color-cyan); }
.cm-s-obsidian span.cm-comment { color: {{ gray }}; }
.cm-s-obsidian span.cm-operator { color: var(--color-purple); }
.cm-s-obsidian span.cm-def { color: var(--color-blue); }

/* Links */
.markdown-rendered a {
  color: var(--text-link);
}

/* Blockquotes */
.markdown-rendered blockquote {
  border-left-color: {{ accent }};
}

/* Active elements */
.workspace-leaf.mod-active .workspace-leaf-header-title {
  color: var(--interactive-accent);
}

.nav-file-title.is-active {
  color: var(--interactive-accent);
}

/* Search results */
.search-result-file-title {
  color: var(--interactive-accent);
}

/* vim: set ft=css: */
