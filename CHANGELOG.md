# Changelog

User-visible changes in each release. The section for a tag becomes the
text of its GitHub release (CI extracts it, see `docs/DEVELOPMENT.md` §7),
so write it for people installing the app, and add one for every release.
Design details behind each change are in [docs/DECISIONS.md](docs/DECISIONS.md).

## v0.9.4 (unreleased)

### Changed

- **YouTube playlists and channels open faster the second time**: coming
  back to one after a video, or going back to it from a playlist inside
  it, shows it at once instead of waiting a few seconds for YouTube. The
  app asks YouTube again after 30 minutes, or right away with *Menu →
  Reload library*, so a new upload can take up to 30 minutes to appear.

### Fixed

- **Online videos with no sound at all didn't play** ("No playable
  format"). They play now.
- **Video info from *Recently played*** showed the quality the screen
  gets, not the one chosen in the Video menu for the video's list.
- **Quality chosen while a video was still opening** was saved but not
  applied until the next video. *Quality* now appears in the Video menu
  once the video has opened.

## v0.9.3 (2026-11-22)

### Fixed

- **L2 / R2 jumped several chapters at once** on a Steam Deck (seen with
  a Plex film): the triggers are analog, and one pull could count as
  several presses. One pull now moves one chapter.

## v0.9.2 (2026-11-21)

### New

- **Streaming quality for online videos**: `[online] stream_quality` in
  `config.ini` sets the highest resolution they play at. The default
  stays the screen's (1080p on a Steam Deck); `1440` gives a little more
  detail and colour on a Deck's screen, for about 2.5 times the data and
  more battery.
- **Quality in the Video menu** for online videos: *Auto* (the screen's),
  720p, 1080p, 1440p or 2160p, remembered for the list the video plays
  from (its `.m3u` file, playlist or channel). The video reopens where it
  was, at the new quality, after a few seconds.

## v0.9.1 (2026-11-20)

### Fixed

- **Some YouTube HDR videos played without HDR**, at 1080p even on a 4K
  TV: those with several audio languages (dubbed tracks). They now play
  in HDR at the screen's resolution, with the original soundtrack;
  downloads too.

## v0.9.0 (2026-11-19)

### New

- **Online videos.** Put links in a list file (`.m3u`, one link per line)
  in a library folder and it shows as a folder of videos: YouTube videos,
  other sites' videos, or links to video files. A YouTube playlist or
  channel in the list is a folder of its own, with its latest videos.
  Videos resume, get watched marks and appear in *Recently played*; they
  play in HDR and with surround sound when the video has them, in its
  original language. How to make a list: [docs/INSTALL.md](docs/INSTALL.md#online-videos).
- **Download online videos** for offline viewing (*Menu → Download*, or
  *Download all videos* on a list or playlist): 1080p on a Steam Deck,
  4K elsewhere, keeping HDR and surround sound, with its subtitles. A
  downloaded video plays from the file, also from its list, and keeps one
  position and watched mark whether it is opened from the list or from
  the download folder.
- **YouTube sign-in with a cookies file.** Some internet connections get
  "YouTube asks to sign in" (and age-restricted videos always need it):
  the app can use cookies exported from a browser where you are signed in.
  The guide says how, and why a spare account is safer.

### Changed

- **"Opening…"** shows in the middle of the screen while a video opens
  (an online video, or a server that takes a moment to answer).
- **Subtitle and audio languages with a region** have names: *Spanish
  (Latin America)* instead of *ES-419*, *English (US)*.

### Fixed

- **Positions and watched marks stopped being kept** after deleting the
  only video that had them (*Delete from this device…*): from then on
  they were lost whenever the app closed.
- **The installer on a PC shared by several people** no longer takes
  another person's Steam for yours: it could ask you to close Steam when
  only theirs was running.

## v0.8.5 (2026-11-15)

### New

- **CRT look strength.** *Menu → Video → Look* now offers *CRT, light lines*,
  *CRT* and *CRT, strong lines*. Light is close to how a home TV showed
  broadcast or DVD video, with faint lines; strong has clear gaps between
  lines even in white, like a studio monitor or an old games console, and
  makes highlights a little dimmer. Your current CRT choice becomes the
  middle one, which looks about as the CRT look did on the Steam Deck.

### Changed

- **The CRT look is the same on every screen.** Its scanlines were much
  fainter on a 4K TV than on a laptop or the Steam Deck; they now look alike
  everywhere. On a 4K screen the red, green and blue mask is coarser, about
  as fine as on a real CRT television, so it can be seen from the couch.

## v0.8.4 (2026-11-14)

### New

- **TV speakers** (audio menu, Y): for films with 5.1 or 7.1 sound played on
  a TV's own speakers or other stereo speakers. Dialogue comes out 3 dB
  louder and music and effects 3 dB quieter than in the usual stereo mix,
  so you don't have to turn the volume up for voices and down for
  explosions. Stereo videos are not changed. It can't be on together with
  *Headphone surround*: switching one on switches the other off. *Night
  mode* works with it. Leave it off with an AV receiver or a surround
  soundbar. `tv_speakers = yes` in `config.ini` starts with it on.

### Fixed

- **DLNA folders showing "No videos here"** with some servers (reported with
  minidlna). A server with more than one network address can list its videos
  under a different address than the one the app found it at, and the app
  left those videos out. Any address on your home network is now accepted;
  addresses outside it still aren't. If a folder's videos still can't be
  played, it now says *No playable videos here* and why, and the log names
  each one.
- **A crash while quitting** after a menu had been open during playback.
  It happened as the app closed, so it was mostly invisible, but it could
  leave a crash report behind. The first start after updating can take about a
  second longer while the app indexes the system's fonts for itself.

## v0.8.3 (2026-11-14)

### Changed

- **Updated to the Freedesktop 26.08 runtime**, the base system the app runs
  on. Nothing in the app is meant to look or work differently. The installer
  downloads the new runtime and a newer version of the gamescope layer used
  for HDR. Your settings, resume points and sign-ins are kept. The previous
  runtime stays on disk until nothing needs it; `flatpak uninstall --unused`
  lists what it would remove before asking.

## v0.8.2 (2026-11-05)

### New

- **Subtitle settings are remembered.** The subtitle track you choose (or
  *Off*), and its size, brightness and position, come back when you play
  the movie again. For a series they apply to the whole season, so the
  next episode starts with the same choice, even if its tracks are in
  another order. The subtitle delay is remembered for each video. Works
  for local files, Plex, Jellyfin and DLNA, and for downloaded subtitles.
  If an episode has no track in the language you chose, the player
  selects subtitles as usual for that episode.
- **Picture and HDR choices are remembered** the same way, per movie or
  season: *Picture* (Fit, Crop black bars, Fill, Stretch) and *HDR*, *HDR
  mapping*, *Peak brightness* and *SDR to HDR* in the Video menu. A crop
  found in one episode applies to the season's videos of the same size.
- **New setting, `remember_settings`** in `config.ini` (`[playback]`, on by
  default): turn it off and all these choices, as well as Look, Grain,
  Clean-up and Decoding, are forgotten when the app closes. What was
  already saved is kept for when you turn it on again.

## v0.8.1 (2026-11-03)

### Fixed

- **HDR videos filmed with a phone no longer flicker** in brightness on
  an HDR screen (seen with a Samsung Galaxy S24 Ultra video on a Steam
  Deck OLED). Such videos carry per-frame HDR10+ brightness data that
  jumps every few frames; with *HDR mapping: Display* (the default) the
  player now uses the video's overall brightness data instead, so the
  picture is steady and as bright as recorded. Other HDR videos look
  the same as before.

## v0.8.0 (2026-11-03)

Better playback of old, low-resolution video: DVDs, TV recordings and SD
series made for CRT televisions.

### New

- **Deinterlacing**: interlaced video (480i/576i from TV and DVDs) is
  shown at a frame per field, as smooth as on a CRT, instead of with
  comb lines on motion. Other video is untouched. The refresh rate
  follows the doubled frame rate (e.g. 60 Hz for 29.97i).
- In *Menu → Video*, for SDR videos, three settings that can be combined:
  - **Look: CRT**: scanlines, an aperture-grille mask and a faint glow,
    sized for the screen (2 pixels per line on the Deck, 4–5 on a 4K
    TV), with the picture's brightness kept.
  - **Grain**: Light / Medium / Strong. Fine, moving film grain, about
    the same size relative to the picture on the Deck and on a TV.
  - **Clean-up** (SD videos only): Light / Strong. Smooths the colour
    banding and the square blocks of low-bitrate files (XviD, old TV
    rips); Strong also reduces noise (VHS, TV recordings) and is a
    little softer. It runs on the CPU, so it uses some battery.
- The choices are remembered per folder, or per show for Plex and
  Jellyfin episodes; *Playback info* lists what is on.
- Your own shaders and filters from `mpv.conf` stay on; these run after
  them.

### Changed

- *Video → Decoding* says *Software (GPU can't)* for videos the GPU
  doesn't decode (MPEG-4 Part 2, as in XviD/DivX AVI files, and MPEG-2),
  instead of *Hardware (unavailable)*, which read like a fault. These
  videos were software-decoded before too, and that is cheap at SD.
- *Playback info* and the HW badge update right away while paused when a
  Video menu setting or the decoder changes.

## v0.7.2 (2026-10-30)

Fixes from a code review of the download, network and DLNA features.

### Fixed

- **Files on a network share can't be deleted** even when the share is
  mounted inside a library folder by a systemd automount (as in the SMB
  guide). KDE network folders (Desktop Mode) also count as network
  shares now.
- *Menu → Downloads → Show in the library* opens the whole folder path
  (e.g. *downloads › Show › Season 01*), so B goes up one level at a
  time instead of straight to the start screen.
- Cancelling a download (or one stopped for lack of free space) no
  longer leaves empty show and season folders behind.
- Deleting a download from *Menu → Downloads* works even when it was the
  first one in the download folder, and the library leaves a folder
  emptied by the deletion.
- A download that finishes while a menu is open shows up in the library
  when the menu closes.
- DLNA: servers built into a router or NAS, and servers that write their
  id in capitals, are found correctly; videos are no longer hidden by an
  empty resource entry before them; the subtitle search reads the year,
  season and episode from DLNA titles; *Video info* gives up after 15 s
  when the server stops answering.

## v0.7.1 (2026-10-29)

Download DLNA videos.

### New

- **Download DLNA videos** for offline playback: *Menu → Download* on a
  video of a DLNA server, like Plex and Jellyfin videos. Downloads can be
  stopped, resumed (also after closing the app) and cancelled from
  *Menu → Downloads*.

### Changed

- A download that has to try again now says why (e.g. "The server did
  not answer (timeout)") instead of always "Connection lost".

## v0.7.0 (2026-10-29)

Network shares and DLNA servers.

### New

- **DLNA servers:** *Menu → Add a DLNA server…* finds the media servers
  on your network (NAS units, PCs, routers); added servers appear next to
  your folders. Their videos play like any other, with resume, watched
  marks and *Recently played* kept on the device (DLNA servers don't keep
  progress). Video info works too.
- **Guide for network shares (SMB):** the install guide shows how to
  have SteamOS mount a NAS or PC share (once, in Desktop Mode, kept
  through SteamOS updates) and add it to the library.

### Changed

- **Folders on a network share no longer freeze the app.** Folders are
  read in the background: if a share is asleep or gone, the library says
  the folder is slow to answer and B goes back, instead of the whole app
  hanging. Shares mounted on the system (SMB, NFS) have their own icon on
  the start screen and a *Network* tag in *Recently played*.
- A `download_folder` on a network share is no longer used (downloads
  are for this device, and a share that stopped answering could freeze
  them).

## v0.6.0 (2026-10-28)

Downloads for offline playback, and a decoding choice for demanding
videos.

### New

- **Downloads for offline playback**: *Menu → Download* on a Plex or
  Jellyfin video (or *Download season* on a season) saves the original
  file, with the server's subtitle files, in `~/Videos/Downloaded`
  (`download_folder` in `config.ini`, e.g. a folder on the microSD card).
  It shows up as a source on the start screen and plays like any local
  video, without the server. *Menu → Downloads* shows progress; downloads
  can be stopped, resumed (also after closing the app) and cancelled.
  Only where the server's owner allows downloads.
- **Delete from this device…** in the library menu removes a local video
  (and its subtitle files) after asking. Only files on the Deck, the
  microSD card or a USB drive: never anything on Plex, Jellyfin or a
  network share.
- **Decoding** in the Video menu switches the current video between
  hardware and software decoding, and remembers the choice for that
  video. On a Steam Deck, 4K AV1 videos can stutter with the hardware
  decoder; software decoding plays them smoother but uses about twice the
  power. When a video keeps dropping frames with hardware decoding, the
  player suggests trying it.

### Fixed

- Jellyfin servers listed in `config.ini` after one that doesn't answer
  are found again.
- With `show_hidden = yes`, the library no longer lists `.` and `..`.
- *Speed* in the playback menu shows 1.25× and 1.75× correctly.
- *Playback info* labelled all dropped frames as "decoder" drops; the
  *Dropped* row now shows what mpv actually counts.
- Starting a local video no longer reads part of the file for online
  subtitles when none were ever downloaded.

### Changed

- **B** during playback first closes a message (like "Resumed at …") or
  the *Skip intro* / *Skip credits* prompt, instead of stopping the video.
- The app can now write to the library folders (`~/Videos`,
  `~/Downloads`, removable drives), which downloads and deleting need. It
  still can't see the rest of your home folder.

## v0.5.0 (2026-10-27)

### New

- **Jellyfin**: *Menu → Add a Jellyfin server…* finds the Jellyfin
  servers on your home network (servers it can't find can be listed in
  `config.ini`). Sign in with Quick Connect: approve the code shown (or
  scan the QR code) in Jellyfin on your phone or PC. Then browse
  *Continue watching*, *Next up* and your libraries, and play the original
  files with HDR, hardware decoding and refresh-rate matching. Progress
  and watched marks stay in sync with your other Jellyfin apps; subtitle
  files from the server, *Download subtitles…*, *Recently played*, Video
  info and *Skip intro* / *Skip credits* (with a server plugin that
  detects them) work as with Plex.
- Plex and Jellyfin servers are labelled on the start screen.
- *Recently played* shows where each video is (Local, SD Card, USB, Plex,
  Jellyfin), so the same film played from two places is easy to tell
  apart; each keeps its own progress.
- Video info starts with a *Source* row: the folder or drive, or the
  service, server and connection (local network or remote).
- **Subtitle brightness** in the playback menu (30–100 %), for subtitles
  that glare in dark scenes, above all on HDR screens. Picture-based
  subtitles (Blu-ray PGS, DVD) dim on HDR screens only.

### Fixed

- Signing in to Plex when the app had opened straight into your only
  folder now shows the start screen with the new server.

### Changed

- Headphone surround: the surround channels of 5.1 audio now sound behind
  you (at 120°, as in a 5.1 room) instead of beside your ears, for a
  clearer front/back separation.

## v0.4.2 (2026-10-26)

A smaller HDR menu for videos without scene-by-scene information.

### Changed

- **HDR mapping → *Display, per scene*** is only offered for videos that
  have scene-by-scene HDR information (Dolby Vision, HDR10+). With plain
  HDR10 it changed nothing, so those videos now offer *Display* and *App*
  only. If you set it in `config.ini`, it still applies to the videos
  that have the information.

## v0.4.1 (2026-10-26)

Video info in the library, a Video menu with HDR settings, and Plex
videos in *Recently played*.

### New

- **Video info** in the library: select a video and press **View** (or
  *Menu → Video info*) to see its file name and folder, size, duration,
  bitrate, video codec, resolution, frame rate, bit depth, HDR type
  (HDR10, HDR10+, Dolby Vision, HLG), mastering brightness, and the audio
  and subtitle tracks. Works for local files and Plex videos (for Plex,
  the path is the file's location on the server).
- **Plex videos in *Recently played*** on the start screen, next to
  local ones. Opening one checks the server for the latest position, and
  an episode continues with the rest of its season.
- **Remove from Continue watching** (Plex) in the library menu: hides a
  video from *Continue watching*, also in other Plex apps, without
  changing its progress. Useful for "next up" episodes of shows you
  stopped watching.
- **Video menu** (*Menu → Video*): *Picture* and *Match refresh rate*
  moved here, next to new HDR settings for HDR screens (Deck OLED, HDR
  TVs). HDR looks are a matter of taste, so you can now choose:
  - **HDR**: on, or off to show HDR videos in SDR even on an HDR screen.
  - **HDR mapping** (HDR videos): *Display* (the screen fits the picture
    to its brightness, as before), *Display, per scene* (the screen also
    gets Dolby Vision / HDR10+ scene-by-scene information), or *App* (the
    player does it, for a chosen peak brightness).
  - **SDR to HDR** (SDR videos): shows normal videos in HDR, with
    highlights up to 300–1000 nits.

  The defaults are the same as in v0.4.0. Menu changes last until you
  close the app; to keep a choice, set `hdr`, `hdr_mapping`, `hdr_peak`
  or `sdr_to_hdr` in `config.ini`. On a screen that isn't in HDR mode,
  *SDR to HDR* and *App* switch themselves off.

### Fixed

- **Picture → Crop black bars:** when no bars were found, pressing right
  went back to *Crop black bars* again and never reached *Fill* and
  *Stretch*. The setting now shows "No black bars found" and moves on.

## v0.4.0 (2026-10-25)

Better sound: night mode and fuller headphone surround. Plex skips intros
and credits.

### New

- **Night mode** (audio menu, Y): evens out loud and quiet passages, so
  dialogue stays clear at low volume and explosions don't jump out. Works
  on the Deck's speakers, headphones and TVs; `night_mode = yes` in
  `config.ini` turns it on at start.
- **Skip intro and credits on Plex:** while an intro or the end credits
  play, *R2 Skip intro* / *R2 Next episode* appears; press R2.
  `skip_intro = auto` skips intros by themselves. Uses the markers your
  Plex server detects (intros need Plex Pass).

### Fixed

- **Headphone surround sounds fuller and as loud as normal playback.** It
  was quieter (by 6 dB on 5.1 and 12 dB on 7.1) and thin: the dummy-head
  data emphasized the upper mids and lacked bass. Voices and music now
  keep their natural tone with the same 3D placement, and the
  subwoofer (LFE) channel is included. Very loud scenes no longer clip.
- The keep-awake status in the info panel appears right away even when a
  system service is slow to answer.
- Holding L2 or R2 during playback no longer skips several chapters.

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
