# Third-party notices

Deck Video Player's own code (everything in this repository unless noted
below) is licensed under the **GNU General Public License v2.0 or later**
(`LICENSE`), © 2026 nicocarbone.

The Flatpak bundle published with each release also contains the
components below, built from source at the exact versions pinned in
`packaging/flatpak/io.github.nicocarbone.DeckVideoPlayer.yml`. Each
component's licence text is installed in the bundle under
`/app/share/licenses/io.github.nicocarbone.DeckVideoPlayer/<module>/`, and
the complete corresponding source of every release is published next to it
as `DeckVideoPlayer-<version>-sources.tar.gz`
(`scripts/make-source-archive.py`).

| Component | Version | Licence | Notes |
|---|---|---|---|
| [mpv](https://mpv.io) | 0.41.0 | GPL-2.0-or-later | playback engine |
| [FFmpeg](https://ffmpeg.org) | n9.0.1 | **GPL-3.0-or-later** (built with `--enable-gpl --enable-version3`) | decoders, demuxers, filters; with libmysofa from the runtime |
| [libplacebo](https://code.videolan.org/videolan/libplacebo) | 7.360.1 | LGPL-2.1-or-later | GPU rendering; its bundled submodules (Vulkan-Headers, glad, fast_float, jinja, markupsafe) keep their own permissive licences |
| [libass](https://github.com/libass/libass) | 0.17.5 | ISC | subtitle and UI rendering |
| [LuaJIT](https://github.com/openresty/luajit2) (OpenResty branch) | 2.1-20260724 | MIT | scripting |
| [libXpresent](https://gitlab.freedesktop.org/xorg/lib/libxpresent) | 1.0.2 | MIT/X11 | |
| [uchardet](https://www.freedesktop.org/wiki/Software/uchardet/) | 0.0.8 | MPL-1.1 / GPL-2.0-or-later / LGPL-2.1-or-later | subtitle encoding detection |
| [zimg](https://github.com/sekrit-twc/zimg) | 3.0.6 | WTFPL | scaling |
| [Inter](https://rsms.me/inter/) font | 4.1 | SIL Open Font License 1.1 | UI font |

Included in this repository:

| File | Licence |
|---|---|
| `app/share/deckvideoplayer/hrtf/mit_kemar_normal_pinna.sofa` (MIT KEMAR HRTF, W. G. Gardner and K. D. Martin, 1995) | "Provided without any usage restrictions"; citation requested (see `hrtf/README.md`) |
| `helper/gamescope-control.xml` (gamescope protocol definition) | MIT, © 2023 Valve Corporation (notice kept in the file) |

Screenshots in `docs/screenshots/` show frames of the *Sintel* trailer,
© Blender Foundation (durian.blender.org), licensed CC BY 3.0.

**Combined work.** Because FFmpeg is built as GPL-3.0-or-later, the Flatpak
bundle as a whole is distributed under the terms of the GPL version 3 (or
later). All other components, including this app's GPL-2.0-or-later code,
are compatible with that.

The Freedesktop runtime (`org.freedesktop.Platform`) and the gamescope
Vulkan layer extension are not part of our bundle; they are installed from
Flathub under their own licences.

**Trademarks.** Steam, Steam Deck and SteamOS are trademarks of Valve
Corporation. This project is not affiliated with or endorsed by Valve.
OpenSubtitles is a trademark of its owners; the subtitle feature uses their
public API with each user's own key.
