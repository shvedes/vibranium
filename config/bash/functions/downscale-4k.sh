# @vibranium
# @description Downscale video (4K)
function downscale-4k() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is not installed!" >&2
    return 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: ${FUNCNAME[0]} <file>"
    echo "Converts video to H.265 (HEVC) with reduced size"
    echo "Output: <input-name>-optimized.mp4"
    return 0
  fi

  if [[ -z "${1:-}" ]]; then
    echo "Usage: downscale-4k <file>" >&2
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

  echo "Done: $output"
}
