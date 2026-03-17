# @vibranium
function extract --description "Extract archives"
  if test (count $argv) -eq 0
    echo "Error: provide a file to extract" >&2
    return 1
  end

  set file $argv[1]

  switch $file
    case "*.tar.gz" "*.tgz"
      tar -xzf $file
    case "*.tar.xz"
      tar -xJf $file
    case "*.zip"
      if not command -q unzip
        echo "Couldn't extract $file: command unzip not found" >&2
        return 1
      end
      unzip $file
    case "*.7z"
      if not command -q 7z
        echo "Couldn't extract $file: command 7z not found" >&2
        return 1
      end
      7z x $file
    case "*"
      echo "Unknown format: $file" >&2
      return 1
  end
end
