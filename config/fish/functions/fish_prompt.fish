set --global fish_color_autosuggestion brblack
set --global fish_color_cancel -r

set --global fish_color_command brgreen
set --global fish_color_comment brblack

set --global fish_color_cwd green
set --global fish_color_cwd_root red
set --global fish_color_end green
set --global fish_color_error brred
set --global fish_color_escape brcyan
set --global fish_color_history_current --bold
set --global fish_color_host normal
set --global fish_color_host_remote yellow
set --global fish_color_normal normal
set --global fish_color_operator brcyan
set --global fish_color_param cyan
set --global fish_color_quote yellow
set --global fish_color_redirection yellow --bold
set --global fish_color_search_match white --background=brblack
set --global fish_color_selection white --bold --background=brblack
set --global fish_color_status red
set --global fish_color_user brgreen
set --global fish_color_valid_path --underline
set --global fish_pager_color_completion normal
set --global fish_pager_color_description yellow -i
set --global fish_pager_color_prefix normal --bold --underline
set --global fish_pager_color_progress brwhite --background=cyan
set --global fish_pager_color_selected_background -r

function fish_prompt
    # Capture last command's exit status immediately
    set -l last_status $status

    # Colors
    set -l bold_cyan  (set_color --bold cyan)
    set -l bold_green (set_color --bold green)
    set -l bold_red   (set_color --bold red)

    set -l ital_cyan  (set_color --italics cyan)

    set -l cyan       (set_color cyan)
    set -l green      (set_color green)
    set -l red        (set_color red)
    set -l gray       (set_color brblack)
    set -l yellow     (set_color yellow)
    set -l reset      (set_color normal)

    set -l dir_str ""

    # Helper: truncate a list of path parts to at most 2, prefixed with ../
    function __trunc_parts
        set -l parts $argv
        set -l n (count $parts)
        if test $n -gt 2
            echo "../"(string join "/" $parts[(math $n - 1)..$n])
        else
            echo (string join "/" $parts)
        end
    end

    set -l git_root (git rev-parse --show-toplevel 2>/dev/null)

    if test -n "$git_root"
        set -l repo_name (basename $git_root)
        set -l cwd (pwd)

        if test "$cwd" = "$git_root"
            # At the repo root – no sub-path
            set dir_str "$bold_cyan$repo_name$reset "
        else
            # Inside the repo – split the relative path and truncate
            set -l rel (string replace --regex "^$git_root/" "" "$cwd")
            set -l rel_parts (string split "/" $rel)
            set -l rel_display (__trunc_parts $rel_parts)
            set dir_str "$bold_cyan$repo_name$reset$cyan/$rel_display$reset "
        end
    else
        # Not in a git repo
        set -l cwd (pwd)
        set -l display (string replace --regex "^$HOME" "~" "$cwd")
        set -l parts (string split "/" $display)

        # Preserve a leading "~" or "" from splitting an absolute path
        set -l n (count $parts)
        if test $n -gt 2
            set display "../"(string join "/" $parts[(math $n - 1)..$n])
        end
        set dir_str "$cyan$display$reset "
    end

    # Git branch
    set -l branch_str ""
    if test -n "$git_root"
        set -l branch (git symbolic-ref --short HEAD 2>/dev/null)
        if test -z "$branch"
            set branch (git rev-parse --short HEAD 2>/dev/null)
        end
        if test -n "$branch"
            set branch_str $gray"at $ital_cyan$branch$reset "
        end
    end

    # Git status
    set -l status_str ""
    if test -n "$git_root"
        set -l gs_flags ""

        # Ahead / behind upstream
        set -l behind_count 0
        set -l ahead_count  0
        set -l ab (git rev-list --count --left-right "@{upstream}...HEAD" 2>/dev/null)
        if test -n "$ab"
            echo $ab | read --delimiter \t behind_count ahead_count
            if test "$ahead_count" -gt 0 -a "$behind_count" -gt 0
                set gs_flags "$gs_flags$bold_green$reset $ahead_count $bold_red$reset $behind_count "
            else if test "$ahead_count" -gt 0
                set gs_flags "$gs_flags$bold_green$reset $ahead_count "
            else if test "$behind_count" -gt 0
                set gs_flags "$gs_flags$bold_red$reset $behind_count "
            end
        end

        # Porcelain file statuses
        set -l conflicted 0
        set -l untracked  0
        set -l modified   0
        set -l staged     0
        set -l renamed    0
        set -l deleted    0

        while read -l line
            set -l xy (string sub -l 2 -- $line)
            set -l x  (string sub -l 1 -- $xy)
            set -l y  (string sub -s 2 -l 1 -- $xy)

            if test "$xy" = "??"
                set untracked 1
                continue
            end

            if string match -qr '^(UU|AA|DD|AU|UA|DU|UD)$' -- $xy
                set conflicted 1
                continue
            end

            switch $x
                case R;      set renamed 1
                case D;      set deleted 1
                case A C M;  set staged 1
            end

            switch $y
                case D;    set deleted 1
                case M C;  set modified 1
            end
        end < (git status --porcelain=v1 2>/dev/null | psub)

        # Stash
        set -l stashed 0
        if git stash list --format="%gd" 2>/dev/null | read -l _first
            set stashed 1
        end

        # Assemble symbols
        if test $conflicted -eq 1;  set gs_flags "$gs_flags"$red\[!\]$reset\ ; end
        if test $untracked  -eq 1;  set gs_flags "$gs_flags"$cyan\[U\]$reset\ ; end
        if test $modified   -eq 1;  set gs_flags "$gs_flags"$green\[M\]$reset\ ; end
        if test $stashed    -eq 1;  set gs_flags "$gs_flags"$gray\[S\]$reset\ ; end
        if test $staged     -eq 1;  set gs_flags "$gs_flags"$yellow\[+\]$reset\ ; end
        if test $renamed    -eq 1;  set gs_flags "$gs_flags"$cyan\[R\]$reset\ ; end
        if test $deleted    -eq 1;  set gs_flags "$gs_flags"$red\[D\]$reset\ ; end

        set status_str "$cyan$gs_flags$reset"
    end

    set -l char_str ""
    if test $last_status -eq 0
        set char_str "$bold_green❯$reset "
    else
        set char_str "$bold_red❯$reset "
    end

    echo -sn $dir_str $branch_str $status_str $char_str
end
