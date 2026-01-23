
#version 300 es
precision mediump float;

in vec2 v_texcoord;
layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;

void main() {
    vec4 src = texture(tex, v_texcoord);
    vec3 unpremul = src.rgb / max(src.a, 0.00001);

    float gray = dot(unpremul, vec3(0.299, 0.587, 0.114));
    fragColor = vec4(gray * src.a, gray * src.a, gray * src.a, src.a);
}
