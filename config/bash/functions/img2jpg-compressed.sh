# @vibranium
# @description Convert images to JPG (high compression level)
function img2jpg-compressed() {
  if ! command -v magick >/dev/null 2>&1; then
    echo "imagemagick is not installed!" >&2
    return 1
  fi

  if [[ -z "${1:-}" ]]; then
    echo "usage: img2jpg_compressed <image> [magick options]" >&2
    return 1
  fi

  local img="$1"
  shift
  local -a rest=("$@")

  if [[ ! -f "$img" ]]; then
    echo "File not found: $img" >&2
    return 1
  fi

  local mime
  mime=$(file --brief --mime-type "$img") || return 1
  if [[ $mime == image/jpeg ]]; then
    echo "image is already a jpeg!" >&2
    return 1
  fi

  local out="${img%.*}-compressed.jpg"

  if magick "$img" "${rest[@]}" \
    -resize '1800x>' \
    -quality 95 \
    -strip \
    "$out"; then
    echo "File saved to $out"
  else
    echo "Conversion failed for $img" >&2
    return 1
  fi
}
