// Deck Video Player: film grain (docs/DECISIONS.md D69).
//
// Fine, moving, colourless grain, strongest in the mid-tones (as film's),
// on the scaled image (SCALED), so only the video area is touched, never
// the black bars, subtitles or the app's interface. Grain also hides what
// old low-bitrate video shows on smooth areas: banding and faint blocks.
// The grains are about the same size relative to the picture on any
// screen (a pixel on a Steam Deck, about three on a 4K TV, soft-edged).
//
// Copyright 2026 nicocarbone. GPL-2.0-or-later, like the rest of the app.

//!PARAM dvp_grain
//!DESC Grain amount (set by the app)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.5
0.05

//!HOOK SCALED
//!BIND HOOKED
//!DESC Deck Video Player: grain

float hash(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Value noise: random values on a grid of cells, smoothly interpolated
// (round grains rather than square ones when a cell spans pixels).
float grain(vec2 p, vec2 seed) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i + seed);
    float b = hash(i + vec2(1.0, 0.0) + seed);
    float c = hash(i + vec2(0.0, 1.0) + seed);
    float d = hash(i + vec2(1.0, 1.0) + seed);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) - 0.5;
}

vec4 hook() {
    vec3 c = max(HOOKED_tex(HOOKED_pos).rgb, vec3(0.0));
    // On gamma-encoded values, as the eye sees them.
    vec3 g = pow(c, vec3(1.0 / 2.2));
    float lum = dot(g, vec3(0.2126, 0.7152, 0.0722));
    // Up to the Steam Deck's 800 lines (any aspect ratio) a grain is one
    // pixel; larger screens get proportionally larger, interpolated grains.
    float cell = max(1.0, HOOKED_size.y / 800.0);
    vec2 seed = vec2(float(frame % 509) * 17.0, float(frame % 397) * 29.0);
    // gl_FragCoord is at pixel centres (x + 0.5): floor() for the pixel's
    // own value, minus 0.5 for the interpolated grid. The factors make both
    // as strong (the same RMS), so the amount looks the same on any screen.
    float n = cell <= 1.0 ? 1.1 * (hash(floor(gl_FragCoord.xy) + seed) - 0.5)
                          : 1.5 * grain((gl_FragCoord.xy - 0.5) / cell, seed);
    g += n * dvp_grain * 2.0 * (1.0 - 0.75 * abs(lum * 2.0 - 1.0));
    g = clamp(g, 0.0, 1.0);
    return vec4(pow(g, vec3(2.2)), 1.0);
}
