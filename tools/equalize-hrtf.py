#!/usr/bin/env python3
"""Makes the headphone-surround HRTF (app/share/deckvideoplayer/hrtf/) from
the original MIT KEMAR file: diffuse-field equalization (D48).

    tools/equalize-hrtf.py mit_kemar_normal_pinna.sofa OUT.sofa
    tools/equalize-hrtf.py --fit mit_kemar_normal_pinna.sofa   # refit EQ

The MIT measurements are taken at the dummy head's eardrum with a small
loudspeaker, so they contain the ear canal resonance (+20 dB around
2.5 kHz) and the speaker's bass roll-off (-23 dB below 40 Hz). Headphones
already produce the ear canal response, so played as is the result is
thin and quiet. This filters every impulse response with the inverse of
the average over all directions (EQ below: a fit of that inverse, bass
boost capped), which keeps the differences between directions (the 3D
cues) and makes the average flat. Only Data.IR changes; the file keeps
its structure, so libmysofa reads it as before.

Needs h5py, numpy and scipy (development only; the app ships the output).
"""
import sys
import numpy as np

FS = 44100.0
# (type, Hz, dB, Q): fitted by --fit; low shelf capped at +18 dB.
EQ = [
    ("low", 76, 17.6, 0.96),
    ("peak", 2265, -12.7, 1.54),
    ("peak", 1647, -2.8, 1.00),
    ("peak", 3295, -8.9, 0.90),
    ("peak", 8003, -10.7, 1.24),
    ("peak", 12724, -5.8, 2.28),
]
MAX_BASS = 18.0
FADE = 32  # samples of fade-out at the end of each 512-tap response


def biquad(kind, f0, g, q):
    """RBJ cookbook coefficients (b, a) of a peaking filter or low shelf."""
    A = 10 ** (g / 40)
    w0 = 2 * np.pi * f0 / FS
    al = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    if kind == "peak":
        b = [1 + al * A, -2 * c, 1 - al * A]
        a = [1 + al / A, -2 * c, 1 - al / A]
    else:  # low shelf
        s = 2 * np.sqrt(A) * al
        b = [A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s)]
        a = [(A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s]
    return np.array(b) / a[0], np.array(a) / a[0]


def eq_db(params, f):
    z = np.exp(-1j * 2 * np.pi * f / FS)
    out = 0
    for kind, f0, g, q in params:
        b, a = biquad(kind, f0, g, q)
        out = out + 20 * np.log10(np.abs((b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)))
    return out


def diffuse(ir, nfft=8192):
    """Power average over all directions and both ears, 1/3-octave smoothed."""
    f = np.fft.rfftfreq(nfft, 1 / FS)
    p = (np.abs(np.fft.rfft(ir, nfft, axis=-1)) ** 2).reshape(-1, len(f)).mean(0)
    cs = np.concatenate([[0], np.cumsum(p)])
    lo = np.searchsorted(f, f * 2 ** -(1 / 6))
    hi = np.maximum(np.searchsorted(f, f * 2 ** (1 / 6), side="right"), lo + 1)
    return f, 10 * np.log10((cs[hi] - cs[lo]) / (hi - lo))


def apply(ir, params):
    from scipy.signal import lfilter
    n = ir.shape[-1]
    x = np.concatenate([ir, np.zeros(ir.shape[:-1] + (4096,))], axis=-1)
    for kind, f0, g, q in params:
        b, a = biquad(kind, f0, g, q)
        x = lfilter(b, a, x, axis=-1)
    x = x[..., :n]
    x[..., n - FADE:] *= np.cos(np.linspace(0, np.pi / 2, FADE)) ** 2
    # 24-bit steps: inaudible, and the file compresses like the 16-bit original.
    return np.round(x * 2 ** 23) / 2 ** 23


def fit(ir):
    """Fits EQ to the inverse diffuse-field response (bass boost capped)."""
    from scipy.optimize import least_squares
    f, df = diffuse(ir)
    fg = np.geomspace(25, 20000, 220)
    plateau = np.interp(np.geomspace(200, 500, 20), f, df).mean()
    target = np.minimum(-(np.interp(fg, f, df) - plateau), MAX_BASS)
    target = np.where(fg > 12500, np.minimum(target, 0), target)
    kinds = [e[0] for e in EQ]
    to = lambda x: [(k, x[3 * i], x[3 * i + 1], x[3 * i + 2]) for i, k in enumerate(kinds)]
    x0 = np.ravel([e[1:] for e in EQ])
    lo = np.ravel([(max(20, e[1] * 0.6), -30, 0.3) for e in EQ])
    hi = np.ravel([(min(18000, e[1] * 1.6), 25, 6) for e in EQ])
    x = least_squares(lambda x: eq_db(to(x), fg) - target, np.clip(x0, lo + 1e-6, hi - 1e-6),
                      bounds=(lo, hi)).x
    err = eq_db(to(x), fg) - target
    print(f"fit error: rms {np.sqrt((err ** 2).mean()):.2f} dB, max {np.abs(err).max():.2f} dB")
    print("EQ = [")
    for kind, f0, g, q in to(x):
        print(f'    ("{kind}", {f0:.0f}, {g:.1f}, {q:.2f}),')
    print("]")
    report("result (dB re 200-500 Hz)", apply(ir, to(x)))


def report(label, ir):
    f, df = diffuse(ir)
    ref = np.interp(np.geomspace(200, 500, 20), f, df).mean()
    pts = [31.5, 40, 50, 63, 100, 250, 1000, 2500, 4000, 8000, 12500, 16000]
    print(label + ": " + "  ".join(f"{p:g}:{np.interp(p, f, df) - ref:+.1f}" for p in pts))


def main(argv):
    import h5py
    if argv[0] == "--fit":
        with h5py.File(argv[1], "r") as h:
            fit(h["Data.IR"][()])
        return
    src, dst = argv
    import shutil
    shutil.copyfile(src, dst)
    with h5py.File(dst, "r+") as h:
        if float(h["Data.SamplingRate"][0]) != FS:
            sys.exit("expected a 44.1 kHz file")
        ir = h["Data.IR"][()]
        report("diffuse field before (dB re 200-500 Hz)", ir)
        out = apply(ir, EQ)
        report("diffuse field after                    ", out)
        h["Data.IR"][...] = out
    print("wrote", dst)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1:])
