# HRTF data for headphone surround

`mit_kemar_normal_pinna_dfeq.sofa`: head-related impulse responses of a
KEMAR dummy head (normal pinna), measured at the MIT Media Lab, in the SOFA
format, **diffuse-field equalized** for headphones. FFmpeg's `sofalizer`
filter uses it to render 5.1/7.1 audio for headphones (`dvp/surround.lua`).

- Original: <https://sofacoustics.org/data/database/mit/mit_kemar_normal_pinna.sofa>
  (SHA-256 `e7035994f5fd754058424c061380ee92b1d5ed58fccef2887a4266916616acdf`)
- Modification: `tools/equalize-hrtf.py` filters every response with the
  inverse of the average over all directions, which removes the ear canal
  resonance and the measurement speaker's bass roll-off (headphones add
  the former themselves). Nothing else in the file changes. Regenerate:
  `tools/equalize-hrtf.py mit_kemar_normal_pinna.sofa mit_kemar_normal_pinna_dfeq.sofa`
  (needs h5py, numpy, scipy). See docs/DECISIONS.md D48.
- SHA-256 of this file: `701644d3c1c79231c2ad77bfa501831a31883bc71553aa9e07e7061bac75a138`
- Licence (from the file's `License` attribute): "This HRTF data is
  provided without any usage restrictions. It is requested that you cite
  Gardner and Martin (1995) when using this data for research or
  commercial applications."
- Citation: W. G. Gardner and K. D. Martin, "HRTF measurements of a KEMAR",
  J. Acoust. Soc. Am. 97 (6), 1995, pp. 3907–3908.

Why this file: it is small and unrestricted. The SADIE II sets
(Apache-2.0) sound similar but are 36 MB each. See docs/DECISIONS.md D27.
