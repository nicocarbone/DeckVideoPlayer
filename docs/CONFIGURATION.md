# Configuration reference

User settings live in `~/.config/deckvideoplayer/config.ini`. The launcher
creates it from `app/share/deckvideoplayer/config.ini` the first time the
app runs. Changes apply on the next start. Invalid values fall back to the
default and are logged as warnings (visible in the mpv log).

Format: `[section]` headers, `key = value`, full-line comments starting with
`#` or `;`. Keys are case-insensitive. The schema (types and defaults) lives
in `dvp/config.lua`.

## `[library]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `folder` | path, repeatable | `~/Videos` | A library folder. Repeat the line for more; a single line may also hold several separated by `;`. `~` and `$VARS` are expanded. Missing folders are skipped. Alias: `folders`. |
| `removable_media` | bool | `yes` | Also list mounted drives under `/run/media` and `/media` (microSD card, USB). |
| `show_hidden` | bool | `no` | Show dot-files and dot-folders. |
| `extensions` | csv | built-in list | File extensions treated as video. |

## `[playback]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `audio_languages` | csv | `eng` (template) | mpv `alang`; preferred audio languages in order. |
| `subtitle_languages` | csv | `eng` (template) | mpv `slang`. |
| `subtitles` | `auto` \| `always` \| `forced` \| `off` | `auto` | Subtitle auto-selection (D9). |
| `resume` | bool | `yes` | Offer to resume, and restore audio/subtitle choices per file. |
| `autoplay_next` | bool | `yes` | Queue the following videos of the same folder. |
| `seek_short` | seconds | `10` | D-pad ←/→ step. |
| `seek_long` | seconds | `60` | L1/R1 step. |
| `volume` | 0–max | `100` | Start volume. |
| `volume_max` | ≥100 | `130` | Maximum volume (above 100 amplifies). |
| `audio_passthrough` | csv | empty | mpv `audio-spdif`, e.g. `ac3,eac3,dts-hd,truehd` for AV receivers. |
| `hwdec` | string | `auto` | `auto` = `vaapi,vulkan,auto-safe`; `no`; or any mpv `--hwdec` value. |

## `[display]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `device` | `auto` \| `deck-oled` \| `deck-lcd` \| `tv` | `auto` | Detected from DMI (`Galileo` = OLED, `Jupiter` = LCD, else `tv`). Affects quality and refresh rates. |
| `quality` | `auto` \| `battery` \| `balanced` \| `high` | `auto` | Rendering profile; `auto` = `balanced` on Deck, `high` on tv. |
| `hdr` | `auto` \| `off` | `auto` | `off` forces SDR output (tone-mapped). |
| `refresh_match` | `auto` \| `off` | `auto` | Refresh-rate matching in gamescope (Deck panels). |
| `refresh_rates` | `auto` \| range \| list | `auto` | e.g. `40-60` or `48,50,60,72,90`. |
| `refresh_prefer` | `low` \| `high` | `low` | Lowest matching multiple (battery) or highest. |
| `display_resample` | bool | `no` | Experimental: mpv `video-sync=display-resample`. |
| `gpu_context` | string | `auto` | Read by the launcher. `auto` = `x11vk` under gamescope; otherwise any mpv `--gpu-context`. |

## `[interface]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ui_scale` | 0.5–3 | `1.0` | Scales the whole UI (e.g. 1.3 for a TV across the room). |
| `clean_names` | bool | `yes` | `The.Movie.2019.mkv` → `The Movie 2019`. |
| `sort` | `name` \| `date` | `name` | Initial folder sort (Y toggles). |
| `overlay_timeout` | seconds | `4` | Auto-hide delay of the playback controls. |
| `accent_color` | `RRGGBB` | `1A9FFF` | Highlight color. |

## Raw mpv options

`~/.config/deckvideoplayer/mpv.conf` is passed with `--include` after the
app's own `mpv.conf`, so anything there wins. Examples:

```ini
# Sharper scaling on a big TV
profile=high-quality
# Force software decoding for debugging
hwdec=no
```

Note that `hwdec` and other per-file options set from `config.ini` are
applied by Lua at startup and override `mpv.conf`. Use `config.ini` for
those.

## Adding a new setting (developers)

1. Add it to `SCHEMA` in `dvp/config.lua` (type, default, enum values).
2. Document it in `app/share/deckvideoplayer/config.ini` and in this file.
3. Read it as `cfg.<section>.<key>` where needed.
4. Add a parsing test to `tests/run.lua` if it has special parsing.
