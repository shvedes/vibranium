# @vibranium
function backup --description "Create backups"
  if test (count $argv) -eq 0
    echo "Error: provide file(s) or directory(ies) to backup" >&2
    return 1
  end

  for item in $argv
    cp -r $item $item.bak
    echo "Copied $item to $item.bak"
  end
end
