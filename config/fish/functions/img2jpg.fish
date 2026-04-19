# @vibranium
function img2jpg --description "Convert images to JPG"
    function __img2jpg_help
        echo "Usage: img2jpg <image> [magick options]"
        echo ""
        echo "Converts an image to JPG using ImageMagick."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Example:"
        echo "  img2jpg photo.png"
        echo "  img2jpg input.webp -resize 50%"
    end

    if test (count $argv) -eq 0
        __img2jpg_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __img2jpg_help
        return 0
    end

    if not command -q magick
        echo "imagemagick is not installed!"
        return 1
    end

    set img $argv[1]
    set rest $argv[2..]

    if not test -f "$img"
        echo "file not found: $img"
        return 1
    end

    if file --brief --mime-type $img | string match -q image/jpeg
        echo "image is already a jpeg!"
        return 1
    end

    set out (string replace -r '\.[^.]+$' '' $img)-converted.jpg

    magick $img $rest -quality 95 -strip $out

    echo "File saved to $out"
end
