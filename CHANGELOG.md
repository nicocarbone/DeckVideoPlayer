# Changelog

User-visible changes in each release. The section for a tag becomes the
text of its GitHub release (CI extracts it, see `docs/DEVELOPMENT.md` §7),
so write it for people installing the app, and add one for every release.
Design details behind each change are in [docs/DECISIONS.md](docs/DECISIONS.md).

## v0.3.6 (2026-10-25)

Fixes from a fifth code audit: Plex auto-play, black-bar cropping,
keep-awake and the installer.

### Fixed

- **Plex auto-play:** when one episode failed to open, the following ones
  failed too. Now only that one is skipped; if the server can't be
  reached, playback stops at once with "Can't reach the Plex server"
  instead of trying every remaining episode.
- *Crop black bars* no longer mistakes a dark sky or a shadow on one side
  for a bar; after "No black bars found" pressing again retries.
- Episodes started from *Recently played* continue in episode order.
- The Plex sign-in dialog notices when the code expires.
- **B** closes *Advanced statistics*, which no longer stays over the
  library after stopping.
- The Subtitles menu shows a downloaded subtitle right away.
- Keep-awake is sturdier: it can't get stuck or use CPU if the system
  session changes, and the info panel says if it stopped.
- The installer keeps the current version installed until the new one is
  in, and adds the shortcut to every Steam account on the device.

### Changed

- Paused playback uses less battery (no periodic redraws).
- Changing the sort order of a Plex library is instant.

## v0.3.5 (2026-10-25)

A clearer installer message when the Steam shortcut still needs fixing.

### Changed

- If the installer can't repair the Steam shortcut because Steam is open,
  it no longer ends with "Done!": it says the shortcut needs one more step
  and how to do it (close Steam and run it again, or edit the launch
  options).

## v0.3.4 (2026-10-25)

Fixes the Steam shortcut after the v0.3.3 update.

### Fixed

- **After updating to v0.3.3 the app could return to Steam immediately**
  when its Steam shortcut was added from the app menu (*Add a Non-Steam
  Game*, or by the installer while Steam was running): that shortcut named
  the old Flatpak branch. The installer now repairs the shortcut (close
  Steam first). To fix it by hand, remove `--branch=master` from the
  shortcut's *Properties → Launch options*.

## v0.3.3 (2026-10-25)

Fixes updates that left the previous version running.

### Fixed

- **Updating could leave the old version running.** Release bundles and
  test builds used different Flatpak branches, so installing one next to
  the other kept two copies, and Steam started the older one. Releases now
  use the same branch, and the installer removes any other installed copy
  first (settings are kept).

## v0.3.2 (2026-10-24)

Keeps the Steam Deck awake during videos.

### Fixed

- **The screen no longer dims, and the Deck no longer goes to sleep,
  while a video plays** in game mode. Paused or in the library, Steam's
  usual timers apply. `keep_awake = no` in `config.ini` turns this off.

## v0.3.1 (2026-10-24)

Small additions and fixes from testing v0.3.0 on a Steam Deck.

### New

- **Recently played** on the start screen, below your folders and SD card:
  the last 5 local videos with their progress. A plays one and continues
  with the rest of its folder. *Menu → Remove from recently played* hides
  an entry; `recently_played` in `config.ini` changes the number (0 turns
  the list off).
- **Crop black bars** in the playback menu's *Picture* setting: for videos
  with the bars stored in the file (a 4:3 show saved as 16:9, a widescreen
  film with bars above and below). The picture then fills as much of the
  screen as it can. Use it in a bright scene; it applies to the current
  video only.

### Changed

- **B during playback** first hides the controls (and the info panel); it
  stops the video only when nothing is on screen.
- With a single library folder, the app now opens at the start screen once
  you have played something, so *Recently played* is reachable.
- A partly watched video (Plex or local) offers both *Mark as watched* and
  *Mark as unwatched* in the library menu; before, only *Mark as unwatched*.
- *Sort by* is in the library menu only where the list can be sorted.

## v0.3.0 (2026-10-24)

Plex streaming, and a security review of everything that touches accounts
and the network.

### New

- **Plex.** Menu → *Sign in to Plex…* in the library shows a QR code (scan
  it with a phone) or a code for plex.tv/link. Your servers then appear as
  library sources: *Continue watching*, movie and TV libraries, seasons
  and episodes, with Plex's progress and watched marks.
- **Direct play from Plex**: the original file is streamed, so HDR10,
  hardware decoding and refresh-rate matching work as with local files
  (no transcoding).
- **Progress sync**: the position and watched state go back to the
  server, so other Plex apps continue where you left off.
- **Remote access**: when the server isn't on the local network, its
  remote addresses are tried. Needs upload bandwidth above the video's
  bitrate. Only lightly tested so far.
- **Subtitle downloads for Plex videos** (*Download subtitles…* in the
  subtitle menu), like for local files.

### Changed

- **Narrower sandbox.** The app no longer reads your whole home folder:
  only `~/Videos`, `~/Downloads`, the microSD card / USB drives
  (`/run/media`, `/media`) and `/mnt`. If a folder in your `config.ini` is
  elsewhere, allow it once in Konsole:
  `flatpak override --user --filesystem=/home/deck/Movies:ro io.github.nicocarbone.DeckVideoPlayer`
  (with your path).
- Plex uses only encrypted (https, `*.plex.direct`) connections. If your
  router blocks those names, `allow_insecure_lan = yes` under `[plex]` in
  `config.ini` allows plain http on a home network you trust.
- Files the app creates (settings, Plex sign-in, resume points) are
  readable only by your user.

### Fixed

- The hint bar shows L1 as −60 s and now also shows R1 +60 s.
- A full disk no longer empties the saved resume points.
- Hardened network code: no redirects that could carry the Plex token to
  another host, size limits on downloads, validation of what servers and
  OpenSubtitles send back.

## v0.2.0 (2026-10-23)

Better audio and subtitles, and fixes from the first tests on a Steam Deck.

- Headphone surround for 5.1 and 7.1 audio (audio menu, Y).
- Download subtitles from OpenSubtitles.com (subtitle menu, X). Needs your
  own free API key in `config.ini`.
- Refresh-rate matching works on current SteamOS, with an on/off toggle in
  the playback menu.
- SD card and USB drives shown by name, with icons.
- Long names scroll instead of overflowing; About panel.
- Audio/subtitle choices and delays no longer carry over to the next video.

## v0.1.0 (2026-10-23)

First version: local folders and removable media, resume and watched
markers, refresh-rate matching, HDR passthrough, audio and subtitle track
menus, Flatpak bundle, SteamOS installer with Steam artwork.
