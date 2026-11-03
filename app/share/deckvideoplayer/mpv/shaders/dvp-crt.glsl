// Deck Video Player: "CRT" look (docs/DECISIONS.md D69).
//
// Scanlines, an aperture-grille mask and a little glow, for old SD video
// made for CRT televisions. Runs on the scaled image in linear light
// (SCALED), so only the video area is touched, never the black bars,
// subtitles or the app's interface. The beam shape (brighter lines are
// wider) follows the ideas of Timothy Lottes' public-domain CRT shader;
// this is a new implementation.
//
// Every scanline covers a whole number of screen pixels (2 on the Steam
// Deck's 800 lines, 4-5 on a 4K TV), the nearest to the video's own line
// count: 480 or 576 lines can't be spread evenly over 800 pixels, and
// uneven lines shimmer.
//
// Copyright 2026 nicocarbone. GPL-2.0-or-later, like the rest of the app.

//!PARAM dvp_src_h
//!DESC Visible lines of the video (set by the app)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 8192.0
480.0

//!HOOK SCALED
//!BIND HOOKED
//!DESC Deck Video Player: CRT

vec3 fetch(vec2 pos) {
    return max(HOOKED_tex(pos).rgb, vec3(0.0));
}

// The scanline's colour at x, softened over about a source pixel, as a
// beam is.
vec3 line_color(float x, float y, float dx) {
    return 0.25 * fetch(vec2(x - dx, y)) + 0.5 * fetch(vec2(x, y)) + 0.25 * fetch(vec2(x + dx, y));
}

// A beam's brightness at d lines from its centre (sigma s, in lines).
vec3 beam(float d, vec3 s) {
    return exp(-0.5 * d * d / (s * s));
}

// The beam's average over the n screen rows of one scanline (with its
// neighbours' tails), so dividing by it keeps the picture's average
// brightness: the lines move light around, they don't take it away. In
// closed form (the same as summing the rows to within 0.05%): with 2 rows
// the sum is 0.5 + q + q^4; with 3 or more rows and these widths, the
// Gaussian's integral, s * sqrt(2 pi).
vec3 beam_mean(vec3 s, float n) {
    if (n < 3.0) {
        vec3 q = exp(-0.125 / (s * s));
        vec3 q2 = q * q;
        return 0.5 + q + q2 * q2;
    }
    return s * 2.5066283;
}

vec4 hook() {
    float h = HOOKED_size.y;
    float src = dvp_src_h > 0.0 ? dvp_src_h : 480.0;
    float n = max(2.0, floor(h / src + 0.5));          // screen pixels per scanline
    float lines = h / n;
    float sw = lines * HOOKED_size.x / h;               // source pixels across (square)
    float dx = 0.6 / sw;

    // The nearest scanline and the neighbour on this side of it. A line's
    // centre is on a pixel row (with 2 pixels per line, one row is the
    // beam and the other the gap between beams), and d is in lines.
    float centre = floor((n - 1.0) / 2.0) + 0.5;
    // (Snapped to the pixel's centre: interpolated, it can fall a hair
    // either side of a line's centre and pick the neighbour at random.)
    float row = floor(HOOKED_pos.y * h) + 0.5;
    float k = floor(row / n);
    float d = (row - k * n - centre) / n;
    float k2 = d < 0.0 ? k - 1.0 : k + 1.0;
    float d2 = d < 0.0 ? d + 1.0 : d - 1.0;
    vec3 c1 = line_color(HOOKED_pos.x, (k * n + centre) / h, dx);
    vec3 c2 = line_color(HOOKED_pos.x, (k2 * n + centre) / h, dx);

    // Gaussian beams, wider for brighter colours. Narrower with 2 pixels
    // per line (Steam Deck), where the gap is a single pixel row and wide
    // beams would fill it.
    vec2 sig = n < 3.0 ? vec2(0.20, 0.34) : vec2(0.24, 0.42);
    vec3 s1 = mix(vec3(sig.x), vec3(sig.y), sqrt(c1));
    vec3 s2 = mix(vec3(sig.x), vec3(sig.y), sqrt(c2));
    vec3 col = c1 * beam(d, s1) / beam_mean(s1, n)
             + c2 * beam(d2, s2) / beam_mean(s2, n);

    // Aperture grille: red, green and blue stripes one screen pixel wide;
    // lighter on small screens, where a stripe is large.
    float dark = h >= 1400.0 ? 0.70 : 0.80;
    float px = mod(floor(gl_FragCoord.x), 3.0);
    vec3 mask = px < 1.0 ? vec3(1.0, dark, dark) : (px < 2.0 ? vec3(dark, 1.0, dark) : vec3(dark, dark, 1.0));
    col *= mask / ((1.0 + 2.0 * dark) / 3.0);

    // Glow: a wide, faint blur on top, which also gives back some of the
    // brightness lost where bright beams clip.
    vec2 g = vec2(1.5 / sw, 1.5 / lines);
    vec3 glow = 0.25 * (fetch(HOOKED_pos + g) + fetch(HOOKED_pos - g)
                      + fetch(HOOKED_pos + vec2(g.x, -g.y)) + fetch(HOOKED_pos + vec2(-g.x, g.y)));
    col = col * 0.92 + glow * 0.12;

    // Clipped to SDR white here, as an SDR screen would clip it, so the
    // output stays SDR on any screen (e.g. with SDR to HDR).
    return vec4(clamp(col, 0.0, 1.0), 1.0);
}
