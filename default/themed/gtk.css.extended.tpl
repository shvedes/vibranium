@define-color background {{ background_0 }};
@define-color foreground {{ foreground_0 }};

@define-color accent {{ accent }};
@define-color black {{ background_0 }};
@define-color red {{ red }};
@define-color green {{ green }};
@define-color yellow {{ yellow }};
@define-color blue {{ blue }};
@define-color magenta {{ purple }};
@define-color cyan {{ cyan }};
@define-color white {{ white }};
@define-color bright_black {{ black_bright }};
@define-color bright_red {{ red_bright }};
@define-color bright_green {{ green_bright }};
@define-color bright_yellow {{ yellow_bright }};
@define-color bright_blue {{ blue_bright }};
@define-color bright_magenta {{ purple_bright }};
@define-color bright_cyan {{ cyan_bright }};
@define-color bright_white {{ white_bright }};

/* Adwaita Color Overrides */
@define-color accent_bg_color @accent;
@define-color accent_fg_color @background;
@define-color accent_color @accent;
@define-color window_bg_color @background;
@define-color window_fg_color @foreground;

/* Sidebar */
@define-color view_bg_color @black;
@define-color view_fg_color @foreground;
@define-color sidebar_bg_color @black;
@define-color sidebar_fg_color @foreground;
@define-color sidebar_backdrop_color @black;
@define-color sidebar_shade_color @black;

/* Secondary sidebar (libadwaita) */
@define-color secondary_sidebar_bg_color {{ background_h }};
@define-color secondary_sidebar_fg_color @foreground;
@define-color secondary_sidebar_backdrop_color {{ background_h }};
@define-color secondary_sidebar_shade_color {{ background_h }};

/* Headerbar */
@define-color headerbar_bg_color @background;
@define-color headerbar_fg_color @foreground;
@define-color headerbar_backdrop_color @black;
@define-color headerbar_shade_color @black;
@define-color headerbar_border_color alpha(@foreground, 0.1);

/* Cards and popovers */
@define-color card_bg_color @background;
@define-color card_fg_color @foreground;
@define-color popover_bg_color @black;
@define-color popover_fg_color @foreground;

/* Dialogs */
@define-color dialog_bg_color @background;
@define-color dialog_fg_color @foreground;

/* OSD (on-screen display, e.g. volume overlay) */
@define-color osd_bg_color {{ background_1 }};
@define-color osd_fg_color @foreground;

/* Thumbnails and banners */
@define-color thumbnail_bg_color {{ background_2 }};
@define-color thumbnail_fg_color @foreground;
@define-color banner_bg_color {{ background_2 }};
@define-color banner_fg_color @foreground;

/* Scrollbar and shade */
@define-color shade_color {{ background_1 }};
@define-color scrollbar_outline_color {{ background_1 }};

/* Semantic states */
@define-color destructive_bg_color @red;
@define-color destructive_fg_color @background;
@define-color success_bg_color @green;
@define-color success_fg_color @background;
@define-color warning_bg_color @yellow;
@define-color warning_fg_color @background;
@define-color error_bg_color @red;
@define-color error_fg_color @background;

/* Borders */
@define-color borders alpha(@foreground, 0.1);

/* GTK3 Adwaita Legacy Color Variables */
@define-color theme_fg_color @foreground;
@define-color theme_text_color @foreground;
@define-color theme_bg_color @background;
@define-color theme_base_color @black;
@define-color theme_selected_bg_color @accent;
@define-color theme_selected_fg_color @background;
@define-color insensitive_bg_color @background;
@define-color insensitive_fg_color @bright_black;
@define-color insensitive_base_color @black;
@define-color theme_unfocused_fg_color @foreground;
@define-color theme_unfocused_text_color @foreground;
@define-color theme_unfocused_bg_color @background;
@define-color theme_unfocused_base_color @black;
@define-color theme_unfocused_selected_bg_color @accent;
@define-color theme_unfocused_selected_fg_color @background;
@define-color unfocused_insensitive_color @bright_black;
@define-color unfocused_borders alpha(@foreground, 0.1);
@define-color warning_color @yellow;
@define-color error_color @red;
@define-color success_color @green;
@define-color destructive_color @red;

/* GTK3 legacy extras */
@define-color selected_bg_color @accent;
@define-color selected_fg_color @background;
@define-color tooltip_bg_color {{ background_1 }};
@define-color tooltip_fg_color @foreground;
@define-color link_color @blue;
@define-color visited_link_color @magenta;
@define-color placeholder_text_color @bright_black;

/* Content View Colors */
@define-color content_view_bg @black;
@define-color text_view_bg @black;

/* Window manager decoration colors */
@define-color wm_bg_color @background;
@define-color wm_fg_color @foreground;
@define-color wm_border_color alpha(@foreground, 0.1);
@define-color wm_button_hover_color {{ background_1 }};
@define-color wm_button_active_color {{ background_2 }};
@define-color wm_close_hover_color @red;
@define-color wm_close_active_color @bright_red;

/* GtkMessageDialog styling */
/* Target the entire dialog's background */
messagedialog {
    background-color: @dialog_bg_color;
}

/* Target the main message label inside the dialog */
messagedialog label {
    color: @dialog_fg_color;
}

/* Target the secondary, more detailed text (if any) */
messagedialog .secondary-text {
    font-size: 9pt;
    font-style: italic;
}

/* Target the buttons in the dialog's action area */
messagedialog button {
    background-color: @black;
    color: @foreground;
    border: 1px solid @bright_black;
}

messagedialog button:hover {
    background-color: {{ accent }};
}

banner revealer widget {
    background: @bright_black;
    color: @foreground;
}

/* GtkAlertDialog styling */
alertdialog.background {
    background-color: @dialog_bg_color;
    color: @dialog_fg_color;
}

alertdialog .titlebar {
    background-color: @headerbar_bg_color;
    color: @headerbar_fg_color;
}

alertdialog box {
    background-color: @dialog_bg_color;
}

alertdialog label {
    color: @dialog_fg_color;
}

filechooser .dialog-action-box {
    border-top: 1px solid @bright_black;
}

filechooser .dialog-action-box:backdrop {
    border-top-color: @black;
}

filechooser #pathbarbox {
    border-bottom: 1px solid {{ background_3 }};
}

filechooserbutton:drop(active) {
    box-shadow: none;
    border-color: transparent;
}

toast {
    background-color: @black;
    color: @foreground;
}

toast button.circular.flat.image-button:hover {
    color: @background;
    background-color: @red;
}

* {
    border-radius: 0;
}

/* vim: set ft=css: */
