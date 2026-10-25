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

## v0.3.0: Plex (released 2026-10-24)

| Feature | Status | Notes |
|---|---|---|
| **Sign-in with a code or QR** | Done | QR code (scan with a phone) or a code for plex.tv/link, from the library menu; servers and their addresses saved in `plex.json`. D37, D38. |
| **Subtitle downloads** | Done | *Download subtitles…* works for Plex videos too (Plex metadata for the search, hash via HTTP range requests). D38. |
| **Browse** | Done | Servers as library sources: *Continue watching*, movie and show libraries, seasons, episodes, Plex's progress and watched marks, sort by name/date. |
| **Direct play** | Done | Original file over HTTP: HDR10, hardware decoding, 48 Hz matching, Plex's external subtitles. Verified with 4K HDR10 HEVC on the LAN. |
| **Progress sync** | Done | Position and watched state reported back, so other Plex apps continue where you left off. |
| **Remote access** | Released, partly tested | Remote addresses are used when the LAN ones don't answer; tested only through the router's public address from inside the LAN. Needs upload bandwidth above the file's bitrate (no transcoding). |

Tested by the owner on a Deck OLED before release; remote play from
outside the home network is still to be confirmed. Third and fourth audits
resolved (D39, D40). Release notes: [CHANGELOG.md](../CHANGELOG.md).

Possible follow-ups: transcoded streams for slow remote connections
(Plex's universal transcoder, HLS), next-episode for *Continue watching*,
Plex Home users, server discovery without an account (GDM).

## v0.3.1: polish from Deck testing

Crop black bars encoded in the video, B hides the playback controls before
stopping, recently played videos on the start screen (D42).

## v0.3.2: keep the screen awake

The screen no longer dims and the Deck no longer sleeps while a video
plays: a screensaver inhibition, held only while playing (D43).

## Next, in this order

1. **Night mode (volume leveling)**: compress the dynamic range so
   dialogue is audible on the Deck's speakers and loud scenes don't blast.
   An audio filter (FFmpeg `dynaudnorm`/`acompressor`, already in the
   build) behind a toggle in the audio menu (Y) and a `config.ini` default.
   Small.
2. **Plex niceties**: a *Skip intro* button from the intro (and credits)
   markers Plex already detects; the next episode in *Continue watching*
   after finishing one. Uses data the Plex API already returns.
3. **Jellyfin / Emby** source: same shape as Plex (reuse `dvp/http.lua`
   and the asynchronous listing in the browser). A whole new source to
   maintain.
4. **SMB/NFS network shares**: many people keep video on a NAS. Needs
   mounting or a userspace client: FFmpeg reads `smb://` only when built
   with libsmbclient (GPLv3, which would move the bundle to GPLv3), or the
   share has to be mounted outside the sandbox.

## Floating (any time)

- **Publish on Flathub**: install from Discover in Desktop Mode, automatic
  updates, much wider reach. Reuses the existing Flatpak; the cost is
  Flathub's review (justify the filesystem and network permissions, build
  the refresh helper in their CI) and maintaining the listing. The Steam
  shortcut and artwork still need `install-steamos.sh` or manual steps.
  Publishing on Steam itself is possible later but needs a second build
  for the Steam Linux Runtime.

## Later (not scheduled)

- **Automatic headphone detection** for surround (PipeWire port type), if
  it proves reliable through the sandbox.
- **Thumbnails / posters** in the browser.
- **Touchscreen** input.
