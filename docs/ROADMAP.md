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
| **Headphone surround** | Released; on-device listening test pending (checklist 11) | 5.1/7.1 soundtracks rendered binaurally (FFmpeg `sofalizer` + MIT KEMAR HRTF, diffuse-field equalized in v0.4, D48). Toggle in the audio menu (Y) or `headphone_surround` in `config.ini`. Stereo sources unchanged. D27. |
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

## v0.4.0: night mode, skip intro/credits, better headphone surround

Night mode for any output (D46), R2 to skip intros and credits or go to
the next episode on Plex (D47), headphone surround with a diffuse-field
equalized HRTF and dialogue-matched level (D48), sixth audit (D49).

## v0.4.1: video info, HDR settings, Plex in Recently played

Video info for local and Plex videos (View in the library), Plex videos in
*Recently played*, *Remove from Continue watching*, and a Picture-mode fix
(D50). A Video menu with HDR choices: HDR off, who maps HDR to the screen,
SDR to HDR (D51 test, D52).

## v0.4.2: per-scene HDR mapping only where it applies

*Display, per scene* is offered only for Dolby Vision and HDR10+ videos
(D54).

## v0.5.0: Jellyfin (released 2026-10-27)

| Feature | Status | Notes |
|---|---|---|
| **Jellyfin servers** | Done; on-device test pending (checklist 14) | Found on the LAN (UDP discovery) or in config.ini, Quick Connect sign-in with a QR code, Continue watching, Next up, libraries, direct play, progress and watched sync, server subtitles, Recently played, Video info, subtitle downloads, intro/credits from media segments (D55). Plex now goes through the same interface. |

Also: where each video is, in *Recently played* and Video info (D56); 5.1
headphone surrounds behind the listener (D57); subtitle brightness (D58);
eighth audit fixed (D59).

## v0.6.0: downloads for offline playback (released 2026-10-28)

| Feature | Status | Notes |
|---|---|---|
| **Downloads** | Done; on-device test pending (checklist 15) | Plex and Jellyfin videos and seasons to `download_folder`, with subtitles; stop, resume (also after closing), cancel; a *Downloaded* source (D60). Network shares later, once they exist. |
| **Delete from this device** | Done | Local videos only, never server or network-share files (D60). |
| **Decoding per video** | Done | Hardware / software in the Video menu, remembered per video, suggested when frames keep dropping; 4K AV1 stutters with the Deck's hardware decoder (D62). |

Also: a bug hunt (D61), and B closes toasts and the skip prompt before
stopping (D63).

## v0.7.0: network shares and DLNA (planned)

Scope chosen to keep the new attack surface small: no new native
library, no credentials in the app, no listening socket, no sandbox
change. In-app SMB/NFS clients come later (see below).

| Feature | Status | Notes |
|---|---|---|
| **Folders that don't block** | Done (D64) | Folder listings and file checks move off mpv's main thread (a subprocess with a timeout), so a sleeping or vanished network share shows "Not responding" instead of freezing the app. Touches the browser's core: regression-test local folders, SD card, USB drives, *Recently played*, Downloads. |
| **Network folders** | Partly done (D64): recognised from the mount table, never stat'ed, *Network* tag; icon pending | Shares mounted by SteamOS (SMB or NFS, e.g. a systemd automount under `/mnt`) used as `folder =` in `config.ini`: recognised from the mount table (as delete already does, D60), shown with a *Network* icon and tag; no sidecar or hash work before the listing arrives; never deletable. The app never handles the share's password. |
| **Mount guide** | Planned | `docs/INSTALL.md`: mounting an SMB or NFS share on SteamOS (systemd automount, credentials file readable by root only, SMB version notes for old NAS units), and adding it to `config.ini`. |
| **DLNA servers** | Planned | A third server type behind `dvp/servers.lua`. Discovery: SSDP `M-SEARCH` for `MediaServer:1` (extend `dvp-discover`). Browsing: `ContentDirectory` `Browse` (SOAP over the async `dvp/http.lua`), DIDL-Lite parsed by a small Lua parser (no DTDs or entities, size caps). Playback: the item's http(s) URL in mpv, only if it points at the host that answered. Resume, watched marks and *Recently played* kept locally (DLNA has no standard progress sync). Target servers: minidlna/ReadyMedia, Jellyfin and Plex DLNA, a NAS's built-in server; claim only what was tested. |

Not in v0.7.0: in-app SMB/NFS, downloads from shares or DLNA, DLNA
subtitles (vendor-specific), DLNA progress sync.

## Next, in this order

1. **In-app SMB** (no system mount): a helper built on libsmb2
   (LGPL-2.1, SMB2/3) that lists folders and streams files to mpv
   through a local HTTP endpoint (`127.0.0.1`, random port and per-session
   token, only files the app asked for); the password goes to the helper
   on stdin, never to mpv. Starts with a spike: build it in the Flatpak
   and measure a high-bitrate 4K remux through it on a Deck (CPU,
   battery). Not Samba's libsmbclient in FFmpeg: huge dependency tree, in
   the player process, password in the URL (logs), and no folder
   listing. (Licensing is not the obstacle: the bundle is already
   GPL-3.0-or-later because FFmpeg is built with `--enable-version3`.)
2. **In-app NFS** with libnfs (LGPL-2.1) in the same helper, if worth it:
   most NFS exports only accept privileged source ports, which a
   sandboxed app can't use, so many would need `insecure` on the server;
   a system mount (v0.7.0) may be the better answer for NFS users.
3. **Downloads from shares and DLNA** through the same paths (D60's
   queue, curl).
4. **Next episode from *Continue watching*** (Plex, Jellyfin): finishing
   an episode started there should offer the next one (today *Continue
   watching* plays one item at a time).

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
