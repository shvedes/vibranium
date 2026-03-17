function copy
    if test (count $argv) -eq 0
        echo "Error: provide text or file(s)" >&2
        return 1
    end

    set files
    set texts

    for arg in $argv
        if test -f $arg
            set files $files $arg
        else
            set texts $texts $arg
        end
    end

    if test (count $files) -gt 0
        for f in $files
            echo "file://"(realpath $f)
        end | wl-copy --primary --type text/uri-list
    end

    if test (count $texts) -gt 0
        printf "%s\n" $texts | wl-copy --primary --type text/plain
    end
end
