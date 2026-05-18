# core colors
set --global fish_color_normal normal
set --global fish_color_command brgreen
set --global fish_color_param cyan
set --global fish_color_operator brcyan
set --global fish_color_quote yellow
set --global fish_color_escape brcyan
set --global fish_color_redirection brpurple --bold
set --global fish_color_end green

# status / state
set --global fish_color_error brred
set --global fish_color_status red
set --global fish_color_cancel -r
set --global fish_color_valid_path --underline
set --global fish_color_history_current --bold

# context
set --global fish_color_cwd green
set --global fish_color_cwd_root red
set --global fish_color_user brgreen
set --global fish_color_host normal
set --global fish_color_host_remote yellow

# UI / helpers
set --global fish_color_autosuggestion brblack
set --global fish_color_comment brblack
set --global fish_color_selection white --bold --background=brblack
set --global fish_color_search_match white --background=brblack

# pager
set --global fish_pager_color_completion normal
set --global fish_pager_color_description yellow -i
set --global fish_pager_color_prefix normal --bold --underline
set --global fish_pager_color_progress brwhite --background=cyan
set --global fish_pager_color_selected_background -r

if command -q starship
    starship init fish | source
else
    echo -e -n (set_color yellow)"\nWarning: "(set_color normal)
    echo -e "Starship not found!"
    echo -e "Using one of the fish's default prompts"
    source /usr/share/fish/prompts/scales.fish
end
