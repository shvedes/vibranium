# @vibranium
function ccd --description "Create directory and cd into it"
  if test (count $argv) -eq 0
    echo "Error: you must provide a directory name" >&2
    return 1
  end

  mkdir -p $argv[1] && cd $argv[1]
end
