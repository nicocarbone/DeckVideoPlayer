# Installation, usage and troubleshooting

> **Beta software**, lightly tested so far on a Steam Deck OLED, a Steam
> Deck LCD and a DIY Steam Machine with official SteamOS. See the
> warning in the [README](../README.md); please report problems on the
> [issue tracker](https://github.com/nicocarbone/DeckVideoPlayer/issues).

## Requirements

- SteamOS 3.x (Steam Deck LCD/OLED) or any Linux with Flatpak, gamescope and
  Steam (DIY Steam Machine, Bazzite, ChimeraOS, …).
- Internet access during installation (Flathub runtime and the gamescope
  layer extension).

## Install on SteamOS (recommended)

1. Switch to **Desktop Mode** (Steam button → Power → Switch to Desktop).
2. Get the release archive `DeckVideoPlayer-vX.Y.Z.tar.gz` (or build it, see
   below) and extract it, e.g. into `~/Downloads/DeckVideoPlayer`.
3. Open **Konsole** in that folder and run:

   ```sh
   ./scripts/install-steamos.sh
   ```

   The script, all per-user with no `sudo`:
   1. adds the Flathub remote for the user (`flatpak remote-add --user`),
   2. installs `dist/DeckVideoPlayer.flatpak` (Flatpak pulls the Freedesktop
      25.08 runtime from Flathub),
   3. installs `org.freedesktop.Platform.VulkanLayer.gamescope//25.08`
      (required for HDR),
   4. creates `~/.config/deckvideoplayer/config.ini` if missing,
   5. adds a **Non-Steam game** "Deck Video Player" with artwork:
      - Steam running: uses `steamos-add-to-steam` on the exported
        `.desktop` file, then waits for the shortcut to appear and copies the
        artwork,
      - Steam closed: writes the shortcut into `shortcuts.vdf` itself
        (`scripts/steam_shortcut.py add`, keeps a `.bak`).
4. Edit `~/.config/deckvideoplayer/config.ini` (Kate works) and set your
   folders:

   ```ini
   [library]
   folder = ~/Videos
   folder = /run/media/deck/SDCARD/Movies
   ```

   The app can read `~/Videos`, `~/Downloads`, the microSD card, USB
   drives and `/mnt`. For a folder elsewhere, see
   [Troubleshooting](#troubleshooting) (*Folder missing*).

5. Return to **Gaming Mode** and launch *Deck Video Player* (Library →
   Non-Steam).

### Recommended Steam settings

- **HDR** (OLED or HDR TV): *Settings → Display → Enable HDR*. HDR videos
  then play as real HDR; the overlay shows an `HDR10` badge, or `HDR10 →
  SDR` if HDR isn't active.
- **External 4K / Steam Machine**: in the shortcut's *Properties → Game
  Resolution* choose **Native**. Otherwise gamescope renders the app at
  1280×800 and upscales.
- **VRR TVs**: enable VRR in Steam's display settings; refresh-rate matching
  is then unnecessary and gamescope ignores it.
- **Controller layout**: the default "Gamepad" template works. If you
  changed it, make sure the template sends a gamepad (not keyboard/mouse).

### Other ways to install

```sh
# Just the Flatpak, without the Steam shortcut:
flatpak install --user dist/DeckVideoPlayer.flatpak
flatpak install --user flathub org.freedesktop.Platform.VulkanLayer.gamescope//25.08
flatpak run io.github.nicocarbone.DeckVideoPlayer

# Shortcut and artwork later (Steam closed):
python3 scripts/steam_shortcut.py add
# Artwork for a shortcut you added by hand:
./scripts/install-steamos.sh --artwork
```

### Update

Run `./scripts/install-steamos.sh` again with the newer archive. The
Flatpak is reinstalled; settings, resume data and the Steam shortcut are
kept.

### Uninstall

```sh
./scripts/install-steamos.sh --uninstall   # close Steam first to remove the shortcut
rm -rf ~/.config/deckvideoplayer ~/.var/app/io.github.nicocarbone.DeckVideoPlayer   # optional: settings + resume data
```

## Using the app

See the controls table in the [README](../README.md#controls). Notes:

- The library opens directly into your folder when only one source exists
  and you haven't played anything yet. Otherwise you start at a list of
  sources, followed by **Recently played** (the last 5 videos, local,
  Plex or Jellyfin, each tagged with where it is;
  `recently_played` in `config.ini`, *Menu → Remove from recently played*
  hides one). The
  microSD card shows as **SD Card** (or "SD Card (Label)" if you gave it a
  name) and USB drives by their label or as **USB drive**.
- Names too long for the screen scroll when you select them.
- **View** on a video (or *Menu → Video info*) shows what it is: size,
  bitrate, codec, resolution, frame rate, HDR type, audio and subtitle
  tracks, and where the file is (folder or drive, or the server).
- **A** on a partly watched file asks *Resume from …* or *Start from the
  beginning*. **X** starts from the beginning directly.
- Videos after the chosen one in the same folder play automatically
  (`autoplay_next`).
- **Video menu** (*Menu → Video*) holds *Picture*, *Match refresh rate*,
  *Decoding* and, on HDR screens, the HDR settings below.
- **Decoding** (Video menu): hardware (default, saves battery) or
  software for the current video. On a Steam Deck, 4K AV1 videos can
  stutter with the hardware decoder; software plays them smoother at
  about twice the power. The choice is remembered for that video only. When
  a video keeps dropping frames with hardware decoding, the player
  suggests this once.
- **Picture** (Fit / Crop black bars / Fill / Stretch) in the Video menu
  applies to the current video only; the next one starts with your normal
  setting. **Crop black bars** is for bars that are part of the video file
  (a 4:3 show stored as 16:9, a widescreen film with bars above and below):
  Fit and Fill treat them as picture. It looks at the current frame, so
  use it in a bright scene. Fill crops the edges of the picture instead.
- **B** during playback first hides the controls (and then the info panel);
  with nothing on screen it stops and returns to the library.
- **Opening a file from a file manager or the command line** (Desktop Mode
  "Open with", `flatpak run … file.mkv`) plays it like a normal player: it
  resumes where you left off ("Resumed at …"), and the app closes when
  playback ends or you stop it (B with the controls hidden).
- Inserted an SD card or USB drive while the app was open? It appears when
  you return to the library, or use *Menu → Reload library*.
- **Night mode** (audio menu, Y): evens out loud and quiet passages, so
  dialogue stays clear at low volume and explosions don't jump out. Works
  on the Deck's speakers, headphones and TVs (5.1 keeps its channels).
  The info panel shows `Audio out: … · night mode`. `night_mode = yes` in
  `config.ini` starts with it on.
- **Skip intro / credits (Plex, Jellyfin):** while an intro or the end credits play,
  *R2 Skip intro* or *R2 Next episode* appears at the bottom right; R2
  does it. `skip_intro = auto` skips intros by themselves; `off` hides the
  prompts (`skip_credits = off` for the credits). Plex detects intros on
  the server (a Plex Pass feature) and credits; Jellyfin needs a plugin
  that detects them (e.g. Intro Skipper). Without markers nothing
  appears.
- **Headphone surround** (audio menu, Y): with headphones, 5.1 and 7.1
  soundtracks sound around you instead of being folded into plain stereo.
  Stereo videos are not changed. The info panel shows
  `Audio out: … · headphone surround` while it is working. Turn it off for
  the speakers.
- **Download subtitles** (subtitle menu, X → *Download subtitles…*): lists
  OpenSubtitles results in your `subtitle_languages`; "Exact" marks
  subtitles made for this very file. A downloads and selects one, and it
  loads automatically next time. See [Online subtitles](#online-subtitles-opensubtitles).
- **Match refresh rate** (Video menu): on by default; the
  screen switches to a multiple of the video's frame rate (48 Hz for films)
  to avoid judder. Steam's Quick Access Menu keeps showing its own rate
  (e.g. 90 Hz); the performance overlay shows the real one.
- **HDR settings** (Video menu, on a Deck OLED or an HDR TV with HDR on
  in SteamOS): *HDR* off shows HDR videos in SDR. *HDR mapping* for HDR
  videos: *Display* (default: the screen fits the picture to its
  brightness), *Display, per scene* (it also gets the scene-by-scene
  information; offered only for Dolby Vision / HDR10+ videos, which have it), *App* (the player does it
  for the *Peak brightness* you pick). *SDR to HDR* shows SDR videos in
  HDR. Which looks best is a matter of taste; menu changes last until the
  app closes, `config.ini` sets your defaults (`hdr_mapping`, `hdr_peak`,
  `sdr_to_hdr`, `hdr`).
- **About** (library menu or playback menu): version, build date, project
  page, licence and credits. Please include the version and build line in
  bug reports.
- **View** during playback shows the info panel: use it to confirm hardware
  decoding (`Hardware (vaapi)`), HDR (`HDR passthrough`) and the matched
  refresh rate.

## Online subtitles (OpenSubtitles)

The *Download subtitles…* entry appears once you give the app **your own
OpenSubtitles API key**. The app doesn't ship with one (its source code is
public, and a shared key would be abused and blocked), so every user
creates a personal key. It's free and takes a couple of minutes, and can be
done from a phone or a PC:

1. Make a free account at <https://www.opensubtitles.com> (confirm the
   e-mail they send).
2. Open <https://www.opensubtitles.com/consumers> while logged in, click
   **New consumer**, give it any name (e.g. "DeckVideoPlayer") and save.
   Copy the **API key** shown for it.
3. On the Deck, in Desktop Mode, edit
   `~/.config/deckvideoplayer/config.ini` (Kate works) and fill in the
   `[opensubtitles]` section:

   ```ini
   [opensubtitles]
   api_key = <your key>
   # optional, for more downloads per day:
   username = <your username>
   password = <your password>
   ```

4. Restart the app. *Download subtitles…* now appears in the subtitle
   menu (X) during playback.

Treat the key like a password: don't post it or commit it anywhere. If it
leaks, delete the consumer on the same page and create a new one.

Searches are free. Downloads count against a daily limit (a few per day
without logging in, more with your username and password); the toast after
a download shows how many are left.

## Plex

Deck Video Player can browse and play the movies and shows of your Plex
Media Server.

1. Library → **Menu** → **Sign in to Plex…**. A QR code and a 4-character
   code appear.
2. Scan the QR code with your phone and approve the sign-in, or open
   **plex.tv/link** on a phone or PC and enter the code. The dialog closes
   by itself and your servers appear in the library, next to your folders.
3. Open a server: **Continue watching**, then your movie and TV libraries.
   Progress bars and checkmarks come from Plex, and what you watch here
   updates Plex for your other devices. In *Continue watching*, *Menu →
   Remove from Continue watching* hides a video there (in every Plex
   app) without changing its progress.

Notes:
- Videos play in their original quality (direct play), so HDR and the
  48 Hz refresh match work just like for local files. There is no
  transcoding: away from home, your server's upload speed must exceed the
  video's bitrate (4K remuxes can need 20–80 Mbit/s).
- *Download subtitles…* (subtitle menu, X) also works for Plex videos; the
  search uses Plex's title, year, season and episode, and downloads are
  kept on the Deck.
- Remote play needs Remote Access enabled on the server. The info panel
  (View) shows `Stream: Plex · <server> · local` or `remote`.
- Connections to the server are always encrypted (https), at home and
  away; see Troubleshooting if Plex can't reach your server at home.
- Your Plex sign-in is stored in the app's data folder (`plex.json`,
  readable only by you). **Menu → Plex account → Sign out** removes it;
  you can also revoke "Deck Video Player" under Plex → Settings →
  Authorized Devices.

## Jellyfin

Deck Video Player can browse and play the movies and shows of your
Jellyfin server.

1. Library → **Menu** → **Add a Jellyfin server…**. The servers on your
   home network are listed; choose yours.
2. A QR code and a 6-digit code appear. In Jellyfin on your phone or PC,
   signed in as you, open your profile → **Quick Connect** and enter the
   code (the QR code opens that page). The dialog closes by itself and the
   server appears in the library, next to your folders.
3. Open the server: **Continue watching**, **Next up**, then your
   libraries. Progress bars and checkmarks come from Jellyfin, and what
   you watch here updates Jellyfin for your other devices.

Notes:
- Server not listed? Jellyfin in Docker without host networking, or on
  another network, doesn't answer the search. Add it to `config.ini`
  (`server = http://192.168.1.20:8096` under `[jellyfin]`, your address)
  and it appears in the list. Plain `http://` works only for home
  network addresses; a server reached over the internet needs `https://`.
- Quick Connect must be on in the server (Dashboard → General → Quick
  Connect; it is by default).
- Videos play in their original quality (direct play), like Plex: HDR and
  the refresh match work as for local files, and there is no transcoding.
- Subtitle files stored next to a video on the server are offered in the
  subtitle menu, and *Download subtitles…* works too.
- *Skip intro* / *Skip credits* need a server plugin that detects them
  (e.g. Intro Skipper).
- The info panel (View) shows `Stream: Jellyfin · <server> · local` or
  `remote`.
- *Remove from Continue watching* is Plex-only: Jellyfin can't hide a
  video there and keep its progress. *Mark as unwatched* removes it (and
  its progress).
- The sign-in is stored in the app's data folder (`jellyfin.json`,
  readable only by you). **Menu → Jellyfin servers → server → Sign out**
  removes it and ends the session on the server; it is also listed under
  Dashboard → Devices in Jellyfin.

## DLNA servers

Many NAS units, PCs and routers share videos over DLNA (often called a
"media server" in their settings).

1. Library → **Menu** → **Add a DLNA server…**. The media servers on
   your home network are listed; choose one. It appears next to your
   folders.
2. Open it and browse its folders (each server organizes them its own
   way, e.g. *Video → Folders*).

Notes:
- There is no sign-in: anyone on your home network can browse a DLNA
  server, and so can the app.
- Progress, watched marks and *Recently played* are kept on this device
  (DLNA has no shared progress), tagged *DLNA*.
- Videos play in their original form: when a server also offers a
  converted copy, the app picks the original.
- A server that is busy (e.g. indexing new files) may not answer for a
  while: the library says so after 20 s, and B goes back at any time.
- Not listed? The server must be on the same network, with its media
  server (DLNA) turned on; some routers block the search between Wi-Fi
  and wired devices.
- **Menu → DLNA servers → server → Remove from the library** forgets it.

## Network shares (SMB)

Videos on a NAS or a shared folder of a PC play once SteamOS mounts the
share as a folder. The app reads it like any other folder; a share that is
asleep or off only makes that folder slow to open, never the whole app.
The setup is done once, in Desktop Mode, in Konsole, and needs your
`sudo` password (run `passwd` first if you never set one).

You need the server's **IP address** (give it a fixed one in your
router), the **share name**, and a **user name and password** that can
read it. A user that can only read the videos is the safest choice.

1. Folders for the share (the share itself goes one level down, in
   `~/NAS/share`, so starting the app doesn't wake the NAS):

   ```sh
   mkdir -p ~/NAS/share
   ```

2. How to mount it (your address, share, user and password):

   ```sh
   sudo tee /etc/systemd/system/home-deck-NAS-share.mount >/dev/null <<'EOF'
   [Unit]
   Description=NAS share for Deck Video Player
   Wants=network-online.target
   After=network-online.target

   [Mount]
   What=//192.168.1.50/Videos
   Where=/home/deck/NAS/share
   Type=cifs
   Options=ro,username=USER,password=PASSWORD,uid=1000,gid=1000,iocharset=utf8
   TimeoutSec=30
   EOF
   sudo chmod 600 /etc/systemd/system/home-deck-NAS-share.mount
   ```

3. Mount it when it is opened, and let go of it after 10 idle minutes (so
   a NAS can sleep):

   ```sh
   sudo tee /etc/systemd/system/home-deck-NAS-share.automount >/dev/null <<'EOF'
   [Unit]
   Description=Mount the NAS share when it is opened

   [Automount]
   Where=/home/deck/NAS/share
   TimeoutIdleSec=10min

   [Install]
   WantedBy=multi-user.target
   EOF
   sudo systemctl daemon-reload
   sudo systemctl enable --now home-deck-NAS-share.automount
   ```

4. Keep both files through SteamOS updates (since SteamOS 3.6 an update
   discards files added to `/etc` unless they are listed like this):

   ```sh
   sudo tee /etc/atomic-update.conf.d/deckvideoplayer-nas.conf >/dev/null <<'EOF'
   /etc/systemd/system/home-deck-NAS-share.mount
   /etc/systemd/system/home-deck-NAS-share.automount
   EOF
   ```

5. Check: `ls ~/NAS/share` should list the share (the first access
   mounts it, which can take a few seconds). If it doesn't, `journalctl
   -u home-deck-NAS-share.mount -n 20` says why.

6. Let the app read it, and add it to the library:

   ```sh
   flatpak override --user --filesystem=/home/deck/NAS:ro io.github.nicocarbone.DeckVideoPlayer
   ```

   and in `~/.config/deckvideoplayer/config.ini`, under `[library]`:

   ```ini
   folder = ~/NAS/share
   ```

   (or a folder inside it, e.g. `~/NAS/share/Movies`). The permission is
   for `~/NAS`, not the share itself: the app gets access to it when it
   starts, and the share would be mounted then.

The share appears on the start screen with a network icon, and its
videos show a *Network* tag in *Recently played*.

Notes:
- **Old NAS units** that only speak SMB 2.0 (the mount fails with
  "Operation not supported"): add `vers=2.0` to the `Options=` line.
  Newer servers need nothing: the best version is chosen by itself.
- **A share without a password:** use `username=guest,password=` in
  `Options=`.
- **Why an IP address and the password in the file:** the usual helper
  (`mount.cifs`, which looks up names and reads separate password files)
  isn't always part of SteamOS, and installing it doesn't survive updates.
  The file is readable only by root, but programs running as you can see
  the mount options through `systemctl`, so use an account that can only
  read the videos. A password with a comma can't be written this way.
- **The name in the library** is the folder's: this guide's share shows
  as "share". To see another name, use another folder in every step,
  e.g. `~/NAS/Movies` (units `home-deck-NAS-Movies.mount` /
  `.automount`, `folder = ~/NAS/Movies`); the permission for `~/NAS`
  stays the same.
- **Another folder name:** unit files are named after the folder they
  mount: `/home/deck/NAS/share` → `home-deck-NAS-share.mount` /
  `.automount`. For another path, `systemd-escape -p --suffix=mount
  "/home/deck/NAS/My Share"` prints the name to use. A second share: a
  second folder in `~/NAS` with its own pair of units.
- **To remove it:** `sudo systemctl disable --now
  home-deck-NAS-share.automount`, then delete the three files above and
  run `sudo systemctl daemon-reload`.
- The app never writes to the share: it is mounted read-only (`ro`),
  and downloads and *Delete* refuse network folders anyway.
- **Desktop file search** (KDE's file indexer in Desktop Mode) may keep
  reading `~/NAS/share`, so the share is never released and the NAS doesn't
  sleep: exclude that folder from file search in Desktop Mode's settings.
- NFS shares aren't covered yet: SteamOS lacks the tools to mount them.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| Controller does nothing, keyboard works | The mpv build lacks SDL2 gamepad support (only possible when running from source with a distro mpv). Use the Flatpak. In Steam, make sure the controller template is a gamepad layout. |
| HDR video looks washed out / badge says `HDR10 → SDR` | HDR is off in Steam display settings, or the gamescope layer extension is missing: `flatpak list --runtime \| grep VulkanLayer.gamescope`. Install it with the command above (branch must be `25.08`). |
| HDR works in other games but not here | Check that `gpu_context = auto` (it must resolve to `x11vk` in game mode). Run from Konsole inside a nested gamescope and look for `[Gamescope WSI] … hdr formats exposed to client: true`. |
| Refresh rate doesn't change | Only in game mode, only on Deck panels, not while VRR is on. Check Steam's **performance overlay** (it shows the real panel rate); the Quick Access Menu's refresh slider always shows Steam's own setting, not ours. The info panel (View) shows `48 Hz (requested)` on a Deck (gamescope's confirmation isn't visible to games there), `48 Hz (matched)` where it can confirm, `90 Hz (asked for 48 Hz)` if gamescope refused. Moving Steam's slider takes the rate back; the app asks again on the next file or when you unpause. Logs: `refresh rate: …` lines. To turn matching off: playback menu → *Match refresh rate*. |
| 4K AV1 video stutters on a Steam Deck (*Dropped* in the info panel keeps rising) | The Deck's hardware decoder can't keep up with some 4K AV1 videos. *Menu → Video → Decoding: Software* plays them smoother, at about twice the power. HEVC and 1080p AV1 are fine in hardware. |
| Software decoding (`Decoder: Software`) | Some formats have no hardware decoder (e.g. H.264 4:4:4, 10-bit H.264, MPEG-4 ASP). That's expected; it costs more battery. |
| Folder missing from the library | The path in `config.ini` must exist. The Flatpak can only see `~/Videos`, `~/Downloads`, the microSD card / USB drives (`/run/media`, `/media`) and `/mnt` (since v0.3, so a malicious video can't read the rest of your files). For another folder, run once in Konsole: `flatpak override --user --filesystem=/home/deck/Movies io.github.nicocarbone.DeckVideoPlayer` (your path; add `:ro` at the end of the path to keep the app from downloading to or deleting there). |
| *Download* fails with "Can't create …" | `download_folder` in `config.ini` must be inside one of the folders above. |
| No *Download* entry | Only on Plex and Jellyfin videos. Plex: a shared server must allow downloads (the owner's setting); Jellyfin: the user needs download permission. |
| No *Delete from this device…* entry | Only for video files in a library folder or on a drive of this device; never for server videos or network shares. |
| Need logs | Desktop Mode: `flatpak run io.github.nicocarbone.DeckVideoPlayer --msg-level=all=v --log-file=$HOME/Downloads/dvp.log`. In game mode, add `--msg-level=all=v --log-file=/home/deck/Downloads/dvp.log` to the end of the shortcut's launch options (after the app id). The log must go in Downloads or Videos: the app can't write to the home folder itself. |
| No *Download subtitles…* entry | No API key yet (see [above](#online-subtitles-opensubtitles)), or the video isn't a local file. |
| "No internet connection" when searching subtitles | The Deck is offline, or the Flatpak lacks network access: `flatpak info --show-permissions io.github.nicocarbone.DeckVideoPlayer` must list `network`. |
| "OpenSubtitles rejected the API key" / "login failed" | Check `api_key`, and use your username (not e-mail) with the right password. |
| No *Headphone surround* entry in the audio menu | `audio_passthrough` is set (surround can't filter compressed audio), or the build lacks the `sofalizer` filter (log: `headphone surround: the sofalizer filter is not available`). |
| Plex server missing or "Can't reach …" | Menu → Plex account → Refresh server list. At home the Deck must reach the server on the LAN; away from home the server needs Remote Access. The app only uses encrypted `*.plex.direct` connections; some routers block those names (DNS rebinding protection). Allow `plex.direct` in the router, or set `allow_insecure_lan = yes` under `[plex]` in `config.ini` (plain http, home networks only). |
| Jellyfin server not listed in *Add a Jellyfin server…* | The search only reaches servers on the same network that answer Jellyfin's discovery (UDP port 7359; not Docker bridge networking). Add the server's address to `config.ini` (`server = http://…:8096` under `[jellyfin]`). |
| "Quick Connect is off on this server" | Turn it on in Jellyfin: Dashboard → General → Quick Connect. |
| "Use https for a server outside your home network" | Only home network addresses may use plain `http://`; give the server's `https://` address. |
| Plex video stutters away from home | No transcoding yet: the server's upload speed must exceed the file's bitrate. Try a lower-bitrate version of the video. |
| Returns to Steam immediately after updating to v0.3.3 (works in Desktop Mode) | The Steam shortcut names the old Flatpak branch (`--branch=master` in *Properties → Launch options*), typical when it was added with *Add a Non-Steam Game* or while Steam was running. Remove the `--branch=…` part, or close Steam and run the installer again: since v0.3.4 it repairs the shortcut. |
| About shows an older version after updating | Two copies are installed on different Flatpak branches (releases up to v0.3.2 used `master`, later ones and test builds `stable`) and Steam starts the old one. Run the v0.3.3+ installer again (it removes other copies), or in Konsole: `flatpak list --user --app --columns=ref,version` and `flatpak uninstall --user io.github.nicocarbone.DeckVideoPlayer//BRANCH` for the old one. Settings are kept. |
| Settings ignored | Typo in a key or value: the log shows `config.ini: unknown option …` / `invalid value …`. |
