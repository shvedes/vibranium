# @vibranium
# @description Downscale video (1080p)
function downscale-1080p() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is not installed!" >&2
    return 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${funcstack[1]} <file>"
    echo "Downscales video to 1080p (1920x1080) using H.264"
    echo "Output: <input-name>-1080p.mp4"
    return 0
  fi

  if [[ -z "${1:-}" ]]; then
    echo "Usage: ${funcstack[1]} <file>" >&2
    return 1
  fi

  local input="$1"

  if [[ ! -f "$input" ]]; then
    echo "File not found: $input" >&2
    return 1
  fi

  local base="${input%.*}"
  local output="${base}-1080p.mp4"

  ffmpeg -i "$input" \
    -vf scale=1920:1080 \
    -c:v libx264 \
    -preset fast \
    -crf 23 \
    -c:a copy \
    "$output"

  echo "Done: $output"
}
