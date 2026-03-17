# @vibranium
function mkvenv --description "Make and enter python venvs with a single command"
  if test (count $argv) -eq 0
    echo "you must provide a name" >&2
    return 1
  end

  python -m venv $argv
  source $argv/bin/activate.fish
end
