function rm
  if command -q trash
    trash -v $argv
  else
    command rm $argv
  end
end
