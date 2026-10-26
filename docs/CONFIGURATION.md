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
| `folder` | path, repeatable | `~/Videos` | A library folder. Repeat the line for more; a single line may also hold several separated by `;`. `~` and `$VARS` are expanded. Missing folders are skipped. Alias: `folders`. The Flatpak reads only `~/Videos`, `~/Downloads`, `/run/media`, `/media` and `/mnt`; other folders need a `flatpak override` ([INSTALL](INSTALL.md#troubleshooting)). |
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
| `headphone_surround` | bool | `no` | Start with headphone surround on: 5.1/7.1 audio rendered binaurally for headphones (D27). Stereo sources are unchanged. Also toggled in the audio menu (Y). Ignored when `audio_passthrough` is set. |
| `night_mode` | bool | `no` | Start with night mode on: a compressor and limiter even out loud and quiet passages (+5 dB for quiet ones, up to −8 dB for loud ones), for low volume or the Deck's speakers; any channel layout (D46). Also toggled in the audio menu (Y). Ignored when `audio_passthrough` is set. |
| `skip_intro` | `ask` \| `auto` \| `off` | `ask` | Intro markers (Plex): show *R2 Skip intro* while an intro plays, skip it by itself, or nothing (D47). |
| `skip_credits` | `ask` \| `off` | `ask` | Credits markers (Plex): show *R2 Next episode* / *Skip credits* during the credits, or nothing. |

## `[display]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `device` | `auto` \| `deck-oled` \| `deck-lcd` \| `tv` | `auto` | Detected from DMI (`Galileo` = OLED, `Jupiter` = LCD, else `tv`). Affects the default quality. |
| `quality` | `auto` \| `battery` \| `balanced` \| `high` | `auto` | Rendering profile; `auto` = `balanced` on Deck, `high` on tv. |
| `hdr` | `auto` \| `off` | `auto` | `off` forces SDR output (tone-mapped). *HDR* in the Video menu changes it for the session (D52). |
| `hdr_mapping` | `static` \| `dynamic` \| `app` | `static` | Who fits HDR video to the screen: the display with the film's metadata (`static`), the display with per-scene metadata (`dynamic`), or the player, tone-mapping to `hdr_peak` (`app`). Video menu: *HDR mapping* (D52). |
| `hdr_peak` | nits | `1000` | Peak brightness for `hdr_mapping = app` (300–2000, in steps of 100). |
| `sdr_to_hdr` | `off` \| `300` \| `400` \| `600` \| `1000` | `off` | Shows SDR video in HDR with highlights up to this many nits. Only on a screen in HDR mode; switches itself off elsewhere. Video menu: *SDR to HDR*. |
| `refresh_match` | `auto` \| `off` | `auto` | Refresh-rate matching in gamescope (Deck panels), D31. Default for the session; *Match refresh rate* in the Video menu toggles it. |
| `refresh_rates` | `auto` \| range \| list | `auto` | `auto` = the rates gamescope reports for the active display; or e.g. `40-60`, `48,50,60,72,90`. |
| `refresh_prefer` | `low` \| `high` | `low` | Lowest matching multiple (battery) or highest. |
| `display_resample` | bool | `no` | Experimental: mpv `video-sync=display-resample`. |
| `keep_awake` | bool | `yes` | Keeps the screen from dimming and the system from sleeping while a video plays, not while paused (D43). The info panel shows whether the system accepted. |
| `gpu_context` | string | `auto` | Read by the launcher. `auto` = `x11vk` under gamescope; otherwise any mpv `--gpu-context`. |

## `[plex]`

Plex servers are added from the library (*Menu → Sign in to Plex…*), not
here.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `allow_insecure_lan` | bool | `no` | Also try plain `http://` on the server's local addresses. Only for routers that block Plex's `*.plex.direct` names (DNS rebinding protection) when Plex fails at home. The Plex token then travels unencrypted, so only enable it if the Deck stays on networks you trust (D39). |

## `[opensubtitles]`

"Download subtitles…" in the subtitle menu (X). The menu entry only
appears once you set your own API key (D29). Searches use
`[playback] subtitle_languages` (English if empty).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `api_key` | string | empty | Your personal OpenSubtitles.com API key; required for the feature (the app has no built-in key). Create one at <https://www.opensubtitles.com/consumers>: step by step in [INSTALL.md](INSTALL.md#online-subtitles-opensubtitles). Keep it private. |
| `username` | string | empty | Optional free account (the username, not the e-mail). Without it OpenSubtitles allows only a few downloads per day. |
| `password` | string | empty | Password of that account. Stored in plain text in this file; only sent to OpenSubtitles when logging in before the first download of a session. |

Downloaded files are kept in the app's data folder (Flatpak:
`~/.var/app/io.github.nicocarbone.DeckVideoPlayer/data/deckvideoplayer/subtitles/`),
one folder per video, and load automatically the next time that video
plays. Delete a folder to forget its downloads.

## `[interface]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ui_scale` | 0.5–3 | `1.0` | Scales the whole UI (e.g. 1.3 for a TV across the room). |
| `clean_names` | bool | `yes` | `The.Movie.2019.mkv` → `The Movie 2019`. |
| `sort` | `name` \| `date` | `name` | Initial folder sort (Y toggles). |
| `overlay_timeout` | seconds | `4` | Auto-hide delay of the playback controls. |
| `recently_played` | number | `5` | Recently played videos (local and Plex) listed on the start screen, below the sources (`0` hides the list). Menu → *Remove from recently played* hides one. |
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
