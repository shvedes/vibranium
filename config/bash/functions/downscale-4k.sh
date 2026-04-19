# @vibranium
# @description Downscale video (4K)
function downscale-4k() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is not installed!" >&2
    return 1
  fi

  if [[ -z "${1:-}" ]]; then
    echo "Usage: ${FUNCNAME[0]} <file>" >&2
    return 1
  fi

  local input="$1"

  if [[ ! -f "$input" ]]; then
    echo "File not found: $input" >&2
    return 1
  fi

  local base="${input%.*}"
  local output="${base}-optimized.mp4"

  ffmpeg -i "$input" \
    -c:v libx265 \
    -preset slow \
    -crf 24 \
    -c:a aac \
    -b:a 192k \
    "$output"
}
