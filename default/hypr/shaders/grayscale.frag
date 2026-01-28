#version 300 es
precision mediump float;

// Interpolated texture coordinates from the vertex shader
in vec2 v_texcoord;

// Output fragment color, explicitly bound to location 0
layout(location = 0) out vec4 fragColor;

// Input texture sampler
uniform sampler2D tex;

void main() {
    // Sample the source texture at the given UV coordinates
    vec4 src = texture(tex, v_texcoord);

    // Un-premultiply RGB by alpha to get the original color
    // max() prevents division by zero for fully transparent pixels
    vec3 unpremul = src.rgb / max(src.a, 0.00001);

    // Convert color to grayscale using luminance coefficients
    // These weights approximate human perception of brightness
    float gray = dot(unpremul, vec3(0.299, 0.587, 0.114));

    // Re-apply alpha (premultiply) and output final grayscale color
    fragColor = vec4(gray * src.a, gray * src.a, gray * src.a, src.a);
}
