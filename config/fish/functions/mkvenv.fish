function mkvenv
  if test (count $argv) -eq 0
    echo "you must provide a name" >&2
    return 1
  end

  python -m venv $argv
  source $argv/bin/activate.fish
end
