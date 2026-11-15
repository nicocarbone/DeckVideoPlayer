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
// uneven lines shimmer. Beam widths are in lines, the same on every screen,
// so the lines look alike on a Deck, a laptop and a 4K TV (D79).
//
// Copyright 2026 nicocarbone. GPL-2.0-or-later, like the rest of the app.

//!PARAM dvp_src_h
//!DESC Visible lines of the video (set by the app)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 8192.0
480.0

//!PARAM dvp_screen_h
//!DESC Height of the screen (window) in pixels, 0 if unknown (set by the app)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 16384.0
0.0

//!PARAM dvp_scanlines
//!DESC Scanline strength: 0 light, 1 medium, 2 strong (set by the app)
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
1.0

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

// A beam's brightness at d lines from its centre; w = 1 / (2 sigma^2),
// sigma in lines, computed once per beam.
vec3 beam(float d, vec3 w) {
    return exp(-d * d * w);
}

// The average over the n screen rows of one scanline of what hook() adds
// up there (the nearest beam and the neighbour on that side), so dividing
// by it keeps the picture's average brightness: the lines move light
// around, they don't take it away. In closed form, within 1% of summing
// the rows for widths 0.18-0.46 (D79): with 2 rows, 0.5 + q + q^4 / 2;
// with more, the Gaussian's integral over -1..1 lines,
// s sqrt(2 pi) erf(1 / (s sqrt 2)), as a cubic in s (within 0.08%; no
// erf in GLSL, and a cubic is cheaper than an approximation of it).
vec3 beam_mean(vec3 s, vec3 w, float n) {
    if (n < 3.0) {
        vec3 q = exp(-0.25 * w);
        vec3 q2 = q * q;
        return 0.5 + q + 0.5 * q2 * q2;
    }
    return ((-3.619387 * s + 2.689191) * s + 1.843326) * s + 0.054162;
}

vec4 hook() {
    float h = HOOKED_size.y;
    // The video's lines on screen: the height of the source area shown
    // (input_size, after Fill's crop or Crop black bars), so each scanline
    // stays one of the video's own lines whatever the picture mode and
    // aspect ratio; the app's count if that isn't known.
    float src = input_size.y > 0.0 ? input_size.y : (dvp_src_h > 0.0 ? dvp_src_h : 480.0);
    float n = max(2.0, floor(h / src + 0.5));          // screen pixels per scanline
    float lines = h / n;
    float sw = lines * HOOKED_size.x / h;               // source pixels across (square)
    float dx = 0.6 / sw;

    // The nearest scanline and the neighbour on this side of it, d in
    // lines. Placed so that one pixel row always falls on the gap between
    // beams (d = 0.5): with an even number of rows per line the centre is
    // on a row (2 rows: the beam and the gap), with an odd number between
    // two rows. Otherwise odd counts (3 at 1440p) never sample the gap and
    // their lines look lighter than on other screens (D79).
    float centre = mod(n, 2.0) < 0.5 ? n * 0.5 - 0.5 : floor(n * 0.5);
    // (Snapped to the pixel's centre: interpolated, it can fall a hair
    // either side of a line's centre and pick the neighbour at random.)
    float row = floor(HOOKED_pos.y * h) + 0.5;
    float k = floor(row / n);
    float d = (row - k * n - centre) / n;
    float k2 = d < 0.0 ? k - 1.0 : k + 1.0;
    float d2 = d < 0.0 ? d + 1.0 : d - 1.0;
    vec3 c1 = line_color(HOOKED_pos.x, (k * n + centre) / h, dx);
    vec3 c2 = line_color(HOOKED_pos.x, (k2 * n + centre) / h, dx);

    // Gaussian beams, wider for brighter colours; sigma in lines, from the
    // darkest to the brightest colour, and the glow's share. Light lines
    // are wide beams that meet in bright areas, as on a home TV showing
    // interlaced video; strong ones are narrow, with gaps even in white
    // (which dims highlights a little, as on a real set) and less glow to
    // fill them (D79). Gaps at mid-grey, as seen: about 12%, 35%, 59%.
    vec3 sig = dvp_scanlines < 0.5 ? vec3(0.30, 0.42, 0.12)
             : (dvp_scanlines < 1.5 ? vec3(0.23, 0.31, 0.10) : vec3(0.18, 0.25, 0.06));
    vec3 s1 = mix(vec3(sig.x), vec3(sig.y), sqrt(c1));
    vec3 s2 = mix(vec3(sig.x), vec3(sig.y), sqrt(c2));
    vec3 w1 = 0.5 / (s1 * s1);
    vec3 w2 = 0.5 / (s2 * s2);
    vec3 col = c1 * beam(d, w1) / beam_mean(s1, w1, n)
             + c2 * beam(d2, w2) / beam_mean(s2, w2, n);

    // Aperture grille: red, green and blue stripes, one screen pixel wide
    // up to 1440p and two on a 4K screen, so a 4:3 picture is about 500
    // triads across, as on a CRT television (1-pixel stripes at 4K were
    // twice as fine, too fine to see from a couch); lighter on small
    // screens, where a stripe is large. Chosen by the screen, not the
    // video's area this hook gets (a cropped widescreen film, or a 4:3
    // video zoomed past the edges by Fill): the app passes the window's
    // height. Without it, a guess: at least the video's height and its
    // width x 9/16 (ISSUES.md XII 1.1, D80).
    float screen_h = dvp_screen_h > 0.0 ? dvp_screen_h : max(h, HOOKED_size.x * 0.5625);
    float dark = screen_h >= 1400.0 ? 0.70 : 0.80;
    float stripe = max(1.0, floor(screen_h / 1080.0 + 0.25));
    float px = mod(floor(gl_FragCoord.x / stripe), 3.0);
    vec3 mask = px < 1.0 ? vec3(1.0, dark, dark) : (px < 2.0 ? vec3(dark, 1.0, dark) : vec3(dark, dark, 1.0));
    col *= mask / ((1.0 + 2.0 * dark) / 3.0);

    // Glow: a wide, faint blur on top, which also gives back some of the
    // brightness lost where bright beams clip.
    vec2 g = vec2(1.5 / sw, 1.5 / lines);
    vec3 glow = 0.25 * (fetch(HOOKED_pos + g) + fetch(HOOKED_pos - g)
                      + fetch(HOOKED_pos + vec2(g.x, -g.y)) + fetch(HOOKED_pos + vec2(-g.x, g.y)));
    col = col * (1.0 - 0.67 * sig.z) + glow * sig.z;

    // Clipped to SDR white here, as an SDR screen would clip it, so the
    // output stays SDR on any screen (e.g. with SDR to HDR).
    return vec4(clamp(col, 0.0, 1.0), 1.0);
}
