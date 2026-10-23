# Roadmap

What comes next, in order, and why. Each release keeps the app simple:
**new features are opt-in or invisible until configured**, so someone who
only plays local files sees the same interface as in v0.1. Decisions taken
while implementing an item go to [DECISIONS.md](DECISIONS.md).

## Guiding rules

- **Simple first.** One obvious way to do each thing, reachable with the
  controller in a few presses. No settings screens: settings stay in
  `config.ini`, with a menu toggle only for things people switch often.
- **Opt-in.** A feature that needs an account, a server or a key shows no
  UI until it is configured.
- **Battery.** Nothing runs while idle; network work happens only when the
  user asks for it.
- **Direct play.** mpv plays the original file or stream. No transcoding,
  so HDR, hardware decoding and refresh-rate matching always apply.

## v0.1.0: local player (released 2026-10-23)

Local folders and removable media, resume and watched markers, refresh-rate
matching, HDR passthrough, track menus, Flatpak, SteamOS installer, Steam
artwork.

## v0.2.0: better audio and subtitles (released 2026-10-23)

| Feature | Status | Notes |
|---|---|---|
| **Headphone surround** | Released; on-device listening test pending (checklist 11) | 5.1/7.1 soundtracks rendered binaurally (FFmpeg `sofalizer` + MIT KEMAR HRTF). Toggle in the audio menu (Y) or `headphone_surround` in `config.ini`. Stereo sources unchanged. D27. |
| **Online subtitles** | Released; live search verified with a real key, on-device download pending (checklist 12) | "Download subtitles…" in the subtitle menu (X). Searches OpenSubtitles.com by file hash and by name, downloads into the app's data folder, reloads on later plays. Each user sets their own free `[opensubtitles] api_key` (no built-in key, D29); optional account for more downloads. D28–D29. |

Also in 0.2.0, from testing on a Deck OLED: refresh-rate matching through
gamescope's control protocol with a menu toggle (D31, confirmed 48 Hz on
the device), scrolling instead of overflowing text (D32), "SD Card" /
"USB drive" names (D33), About panel (D34), and the second audit's fixes
(D35).

## v0.3.0: Plex (planned)

Browse and play a Plex Media Server on the local network.

- **New source kind** in `library.lua`: the server appears next to your
  folders (Libraries → Movies / Shows → Seasons → Episodes). Browsing uses
  the Plex HTTP API with JSON responses and curl, like the subtitle client.
- **Direct play**: mpv opens the part URL (`/library/parts/…`) with the
  token, so every format, HDR and hardware decoding keep working. No
  transcoding.
- **Sign-in**: v0.3 reads `server = http://192.168.x.x:32400` and a token
  from `config.ini`. Later: a 4-letter code shown on screen and entered at
  plex.tv/link on a phone (PIN flow), plus GDM server discovery.
- **Resume**: start from Plex's `viewOffset` and report progress and
  watched state back (`/:/timeline`, `/:/scrobble`) so "On Deck" stays
  correct on other devices.
- **Subtitles** on the server load as external tracks; online search
  (v0.2) also works for Plex items.
- Plex Pass is not required for direct play.

Groundwork shared with later sources: an async HTTP helper (extracted from
`opensubtitles.lua`), a source interface with asynchronous listing and a
loading state in the browser, and resume keys that aren't file paths.

## Later (not scheduled)

- **Jellyfin / Emby** source: same shape as Plex.
- **SMB/NFS network shares**: needs mounting or a userspace client
  (FFmpeg reads `smb://` only when built with libsmbclient, which our
  build isn't).
- **Automatic headphone detection** for surround (PipeWire port type), if
  it proves reliable through the sandbox.
- **Thumbnails / posters** in the browser.
- **Touchscreen** input.
