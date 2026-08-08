#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

out vec4 finalColor;

uniform float u_time;

void main() {
    float red = 0.5 + 0.5 * sin(u_time);
    float green = 0.5 + 0.5 * cos(u_time);
    float blue = 0.5 + 0.5 * sin(u_time * 0.5);
    // finalColor = vec4(red, green, blue, 1.0);
    finalColor = vec4(1.0, 0.0, 0.0, 1.0); // Solid red color
}