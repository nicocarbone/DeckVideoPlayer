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

## v0.7.0: network shares and DLNA (released 2026-10-29)

Scope chosen to keep the new attack surface small: no new native
library, no credentials in the app, no listening socket, no sandbox
change. In-app SMB/NFS clients come later (see below).

| Feature | Status | Notes |
|---|---|---|
| **Folders that don't block** | Done (D64) | Folder listings and file checks move off mpv's main thread (a subprocess with a timeout), so a sleeping or vanished network share shows "Not responding" instead of freezing the app. Touches the browser's core: regression-test local folders, SD card, USB drives, *Recently played*, Downloads. |
| **Network folders** | Done (D64): recognised from the mount table, never stat'ed, *Network* icon and tag | Shares mounted by SteamOS (SMB or NFS, e.g. a systemd automount under `/mnt`) used as `folder =` in `config.ini`: recognised from the mount table (as delete already does, D60), shown with a *Network* icon and tag; no sidecar or hash work before the listing arrives; never deletable. The app never handles the share's password. |
| **Mount guide** | Done for SMB (D65); NFS not covered (SteamOS lacks `nfs-utils`) | `docs/INSTALL.md`: mounting an SMB or NFS share on SteamOS (systemd automount, credentials file readable by root only, SMB version notes for old NAS units), and adding it to `config.ini`. |
| **DLNA servers** | Done (D66); tested with a mock server and in the Flatpak; the owner's NAS server hangs on browsing (the timeout path) | A third server type behind `dvp/servers.lua`. Discovery: SSDP `M-SEARCH` for `MediaServer:1` (extend `dvp-discover`). Browsing: `ContentDirectory` `Browse` (SOAP over the async `dvp/http.lua`), DIDL-Lite parsed by a small Lua parser (no DTDs or entities, size caps). Playback: the item's http(s) URL in mpv, only if it points at the host that answered. Resume, watched marks and *Recently played* kept locally (DLNA has no standard progress sync). Target servers: minidlna/ReadyMedia, Jellyfin and Plex DLNA, a NAS's built-in server; claim only what was tested. |

Not in v0.7.0: in-app SMB/NFS, downloads from shares or DLNA, DLNA
subtitles (vendor-specific), DLNA progress sync.

## v0.7.1: DLNA downloads (released 2026-10-29)

| Feature | Status | Notes |
|---|---|---|
| **DLNA downloads** | Done (D67) | *Download* on DLNA videos, through D60's queue: stop, resume (also after closing), cancel; the URL asked again from the server at start. |

## v0.7.2: ninth audit fixes (released 2026-10-30)

Fixes from ISSUES.md Part IX (D68): network shares automounted inside a
library folder protected from deletion, *Show in the library* with the
whole folder path, download folder clean-up, DLNA parsing (empty tags,
embedded media servers, `UUID:`), subtitle search for DLNA titles, a
timeout for Video info on DLNA.

## v0.8.0: old SD video (released 2026-11-03)

| Feature | Status | Notes |
|---|---|---|
| **Deinterlacing** | Released (D69) | `deinterlace=auto`: interlaced video (480i/576i TV and DVDs) shown at a frame per field; refresh matching follows the doubled rate. |
| **Looks** | Released (D69); battery cost of Clean-up on a Deck not measured | Video menu, SDR videos: *Look* (Off / CRT, with light, medium or strong lines since v0.8.5, D79), *Grain* (Off / Light / Medium / Strong), *Clean-up* (Off / Light / Strong, SD only: debanding, `fspp` deblocking, `hqdn3d` when strong), remembered together per folder or show. Sharp and Film dropped after the owner's tests; CRT made stronger on the Deck. Test builds tried by the owner on a Deck. |

Fixes from ISSUES.md Part X (D70): Clean-up with hardware decoding,
grain strength on 16:9 video, CRT shader cost, screen updates while
paused.

v0.8.1 (released 2026-11-03): HDR10+ phone videos no longer flicker with
the Display HDR mapping (D71).

v0.8.2 (released 2026-11-05): subtitle track, size, brightness and position remembered per movie
or season, delay per video (D72); Picture and HDR choices too, and
`remember_settings` to turn all such memory off (D73).

v0.8.3 (released 2026-11-14): Freedesktop 26.08 runtime, as a release of
its own (D74).

v0.8.4 (released 2026-11-14): **TV speakers** in the audio menu, a stereo mix
of 5.1/7.1 with dialogue 3 dB louder and the rest 3 dB quieter than the usual
downmix, for a TV's own speakers (D75). Tested in headless gamescope and the
Flatpak; the owner tried the test build (TV listening: checklist 17). Also: DLNA videos listed on
another home-network address of the server are no longer dropped, and a
folder whose videos can't be played says why (D76, user report with
minidlna). And a crash of the Flatpak while quitting after a menu was open,
there since at least v0.8.2, is fixed (D77).

v0.8.5 (released 2026-11-15): CRT look with *light*, *medium* and *strong*
lines, the same on every screen size (they were much fainter on a 4K TV than
on a 1080p screen) and in every picture mode and aspect ratio, and a
phosphor mask scaled to the screen (D79, D80). Tested in headless gamescope
and the Flatpak; the owner tried the test builds.

v0.9.0 (released 2026-11-19): **online videos** (D84, D85): a `.m3u` file in a
library folder is a list of links (YouTube videos, playlists and channels
as folders, other sites, video files), played through mpv's yt-dlp hook
(confined to the app's own `ytdl://` addresses) with QuickJS-NG for
YouTube's challenges; resume, watched marks, *Recently played*; downloads
with curl or yt-dlp (joined by the bundled `ffmpeg`), 1080p on a Deck and
2160p elsewhere, HDR and surround kept; an optional cookies file for
connections where YouTube wants a sign-in (the owner's is one). yt-dlp is
kept current by a weekly pull request (`scripts/update-yt-dlp.py`); until
v0.10.0's repository, a fix reaches users as a release they install.
Tested in headless gamescope and the Flatpak with `tools/mock-online.py`
and, for titles, playlists and channels, real YouTube; the owner tried the
test builds before release. Not measured on a Deck: QuickJS-NG's start-up
time, battery with VP9 and AV1 streams, and 5.1 audio from YouTube (the
mock can't say how many channels a stream has). Not in v0.9.0: search,
thumbnails, sign-in other than cookies, more than 200 videos of a
playlist, Google Photos links (yt-dlp has no extractor for them).

v0.9.1 (released 2026-11-20): YouTube HDR videos with several audio
languages played in SDR at 1080p, because streams with sound won the
language sort; a video-only stream is now chosen first (D86). Checked in
headless gamescope; the owner tried the test build on a Deck.

mpv 0.42 and libplacebo 7.387 (planned, moved out of v0.9.0): once mpv
0.42.1 is out, with streaming tests for mpv's new libcurl backend
(`--curl-enabled=no` as the fallback), as a release of its own.

**CI actions on Node.js 24** (done, in v0.9.2, D87): every pinned
action moved to a release built for Node 24, and `flatpak-builder` back to
`flatpak/flatpak-github-actions` (the flathub-infra fork is archived). The
release job's new versions published v0.9.2, its first tag, with no
warnings on any job.

v0.9.2 (released 2026-11-21): quality of online videos. `[online]
stream_quality` caps their resolution (`auto` = the screen's, as before:
1080p on a Deck, D88), and *Quality* in the Video menu changes it for one
list, remembered (D89). Checked in headless gamescope and the Flatpak
with real YouTube; the owner tried the test build on a Deck. Still to
measure on a Deck: battery at 1440p against 1080p; and whether AV1 1440p
plays smoothly on the Deck's decoder (today avoided above 1080p, D62),
which would allow it at 1440p (the owner: later).

v0.9.3 (released 2026-11-22): L2 / R2 jumped several chapters per pull
on a Deck, because mpv turns the analog triggers into key presses with
no hysteresis; a trigger press now counts only after its events settle
(D90). Checked in headless gamescope and the Flatpak with key events
milliseconds apart; the owner confirmed the test build on a Deck.

v0.9.4 (released 2026-11-23): YouTube playlists and channels are kept
in memory for 30 minutes, so coming back to one after a video is
instant (D91; *Reload library* asks again). Fourteenth audit fixed in
D92: online videos with no audio stream play, Video info from
*Recently played* uses the list's Quality, no Quality row while a video
opens. Checked in headless gamescope and the Flatpak with real YouTube;
the owner tried the test builds on a Deck.

v0.9.5 (released 2026-11-24): yt-dlp 2026.11.23 (YouTube workarounds:
a temporary signature fix, YouTube's `web` client out of the defaults),
the first release made from the update pull request; the weekly run had
missed it by hours, so it was started by hand. The bundle CI built for
the pull request listed a playlist and played a video in headless
gamescope with real YouTube before merging (2026.10.26 still worked
here too).

v0.10.0 (planned): the first version published in the app's own Flatpak
repository on GitHub Pages (D81), so installs update themselves (moved
from v0.9.0 by the owner):

- **CI:** on a tag, the build CI already makes goes into an OSTree
  repository, signed with the app's GPG key (private key only in a GitHub
  Actions secret, public key in the repo), with static deltas, pruned to
  the last few versions, and deployed to GitHub Pages next to a
  `.flatpakrepo` and a `.flatpakref`. Branch `stable`, as today (D44).
  To settle first: how the repository carries over between releases (a
  Pages deploy replaces the whole site), e.g. pulled back from the live
  site before adding the new build.
- **Installer:** `install-steamos.sh` adds the remote and installs from
  it; Steam shortcut and artwork as today. The release `.flatpak` keeps
  working offline and is built with `--repo-url`, so bundle installs also
  update from the repository. Existing installs move over on their next
  run of the installer.
- **Docs:** README and INSTALL say how to add the remote by hand and that
  updates come through Discover or `flatpak update`.
- **Tests:** a deploy to a test path first, installed into an isolated
  `FLATPAK_USER_DIR`: fresh install, update from the previous version,
  signature refused when tampered with, bundle install switching to the
  remote.

## Next, in this order

1. **Rename library sources**: *Rename…* in the start screen's menu for
   any source (folders, network shares, SD card, USB drives, Plex,
   Jellyfin and DLNA servers), shown on the start screen, in *Recently
   played* tags and in Video info; names kept in the data folder by path
   or server id, an empty name restores the original. Needs the UI's
   first **text field** (typed with the Steam keyboard, STEAM + X, or a
   keyboard; mpv's `ANY_UNICODE` key; Backspace and Enter handled while it
   is open), reusable for the SMB password below. Until then a network
   share is named after its mount folder (the SMB guide says how).
2. **In-app SMB** (no system mount): a helper built on libsmb2
   (LGPL-2.1, SMB2/3) that lists folders and streams files to mpv
   through a local HTTP endpoint (`127.0.0.1`, random port and per-session
   token, only files the app asked for); the password goes to the helper
   on stdin, never to mpv. Starts with a spike: build it in the Flatpak
   and measure a high-bitrate 4K remux through it on a Deck (CPU,
   battery). Not Samba's libsmbclient in FFmpeg: huge dependency tree, in
   the player process, password in the URL (logs), and no folder
   listing. (Licensing is not the obstacle: the bundle is already
   GPL-3.0-or-later because FFmpeg is built with `--enable-version3`.)
3. **In-app NFS** with libnfs (LGPL-2.1) in the same helper, if worth it:
   most NFS exports only accept privileged source ports, which a
   sandboxed app can't use, so many would need `insecure` on the server;
   a system mount (v0.7.0) may be the better answer for NFS users.
4. **Downloads from network shares**: a background copy (e.g. `dd`,
   resumable) in D60's queue, with progress, stop, resume and cancel,
   sidecar subtitles, only from configured network sources; on-device
   tests for sleep and a share disappearing mid-copy. (DLNA downloads:
   v0.7.1.)
5. **Next episode from *Continue watching*** (Plex, Jellyfin): finishing
   an episode started there should offer the next one (today *Continue
   watching* plays one item at a time).

## Floating (any time)

- **Flathub or FlatPark**: not planned (D81). Flathub's rules on
  AI-generated apps, and a manifest, PR text and replies written by a
  person for every change, are too much to maintain; FlatPark only wraps a
  release download, not an app built from source like this one. Either
  could be a second channel later, next to the app's own repository.
  Publishing on Steam itself is possible later but needs a second build
  for the Steam Linux Runtime.

## Later (not scheduled)

- **Automatic headphone detection**: *Auto* for headphone surround and the
  TV speaker mix, choosing by the output. `pactl` is in the runtime and
  works through the sandbox's PulseAudio socket; `pactl -f json` gives the
  default sink's channels, active port type (Headphones, Speaker, HDMI) and
  form factor (Bluetooth headsets). Open: what a Deck reports for its jack,
  Bluetooth and a dock's HDMI (to be logged on a Deck first), and how to
  notice a change mid-film without polling (D75).
- **Frame pacing with `VK_EXT_present_timing`** (waiting on mpv): SteamOS
  3.10 (Preview, November 2026) supports the Vulkan extension in Game
  Mode. It tells a program when each frame actually reached the screen and
  lets it ask for a frame to be shown at a set time. Nothing in the app can
  use it: mpv / libplacebo would have to (no sign of it in their code or
  issues so far). What it could fix:
  - *A repeated frame every ~42 s on the Deck*: 23.976 fps on a 48 Hz
    panel is 2.002 refreshes per frame, so with `video-sync=audio` (D7) a
    frame is held for 3 refreshes about every 42 s (calculated, not
    measured). `display-resample` avoids it but stays optional because mpv
    can't measure the refresh exactly under gamescope; the extension's
    feedback would give it that, and it could become the default.
  - *VRR on a TV*: frames shown at their own time instead of whenever
    they are handed over, so uneven render times don't become uneven frames.

  Needs an mpv with support, then the gamescope Vulkan layer and Mesa in
  the Flatpak recent enough to pass it through. Can be checked now on a
  Deck: a 23.976 fps film for a few minutes with mpv's stats page (frame
  timing), default against `display_resample = yes`.
- **Thumbnails / posters** in the browser.
- **Touchscreen** input.
- **arm64 build** (low priority; only once there is an arm64 device to
  test on). For arm64 SteamOS devices (Valve's Steam Frame) and for
  DroidDeck below.
  - *Build:* nothing in the Flatpak is tied to x86 (LuaJIT, FFmpeg,
    libplacebo, mpv, QuickJS-NG and the helpers are built from source,
    yt-dlp is a Python zipapp, the Freedesktop runtime has aarch64). CI
    would build a second bundle on GitHub's arm64 Linux runners, the
    release would carry both, and the installer would pick one by
    `uname -m`. A day or two.
  - *Playing well:* the open part. Hardware decoding is VA-API today
    (`hwdec=auto-safe`); Qualcomm's decoder is behind V4L2 on Linux, which
    mpv only uses by copying frames back (`v4l2m2m-copy`), and without it
    4K HEVC and AV1 are software decoding (battery, maybe dropped frames).
    Device detection reads the Deck's DMI names (`display.lua`), so an ARM
    device is a generic screen; HDR and refresh switching depend on its
    gamescope and screen.
  - *DroidDeck* ([github.com/Droid-Deck/DroidDeck](https://github.com/Droid-Deck/DroidDeck),
    GPL-3.0, started in September 2026, 0.7.1 in November): an Android app
    that runs a Linux runtime under proot with Steam's arm64 client in
    gamescope, on Adreno GPUs through Mesa's Turnip (Adreno 730 or newer,
    or 8xx; others experimental), with PulseAudio/PipeWire sound. Its
    store installs arm64 Flatpaks from Flathub through its own bubblewrap
    shim, and it can add AppImages, also the latest arm64 AppImage of a
    GitHub repository. For this app, to check on a device:
    - how to install it: the app isn't on Flathub (D81). A `.flatpak`
      bundle, the v0.10.0 repository as a remote, or an arm64 AppImage
      (a second package format, only if nothing else works);
    - decoding: Android keeps the hardware decoder behind MediaCodec, so
      inside the runtime mpv most likely decodes in software (fine for
      1080p H.264 on a Snapdragon 8-class CPU; 4K HEVC, AV1 and battery
      to measure);
    - whether the screen stays on during a film (D43 asks the desktop's
      ScreenSaver service, which may not reach Android), where the
      library folders and SD cards appear inside the runtime, and how
      much proot slows the subprocesses (curl, ffprobe, yt-dlp, listings);
    - controller input through Steam as on a Deck, Vulkan output
      (`gpu-next`) on Turnip, no HDR.
