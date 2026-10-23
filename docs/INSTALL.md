# Installation, usage and troubleshooting

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

- The library opens directly into your folder when only one source exists.
  With several (folders and/or SD card) you start at a list of sources. The
  microSD card shows as **SD Card** (or "SD Card (Label)" if you gave it a
  name) and USB drives by their label or as **USB drive**.
- Names too long for the screen scroll when you select them.
- **A** on a partly watched file asks *Resume from …* or *Start from the
  beginning*. **X** starts from the beginning directly.
- Videos after the chosen one in the same folder play automatically
  (`autoplay_next`).
- **Picture** (Fit / Fill / Stretch) in the playback menu applies to the
  current video only; the next one starts with your normal setting.
- **Opening a file from a file manager or the command line** (Desktop Mode
  "Open with", `flatpak run … file.mkv`) plays it like a normal player: it
  resumes where you left off ("Resumed at …"), and the app closes when
  playback ends or you press B.
- Inserted an SD card or USB drive while the app was open? It appears when
  you return to the library, or use *Menu → Reload library*.
- **Headphone surround** (audio menu, Y): with headphones, 5.1 and 7.1
  soundtracks sound around you instead of being folded into plain stereo.
  Stereo videos are not changed. The info panel shows
  `Audio out: … · headphone surround` while it is working. Turn it off for
  the speakers.
- **Download subtitles** (subtitle menu, X → *Download subtitles…*): lists
  OpenSubtitles results in your `subtitle_languages`; "Exact" marks
  subtitles made for this very file. A downloads and selects one, and it
  loads automatically next time. See [Online subtitles](#online-subtitles-opensubtitles).
- **Match refresh rate** (playback menu, Menu button): on by default; the
  screen switches to a multiple of the video's frame rate (48 Hz for films)
  to avoid judder. Steam's Quick Access Menu keeps showing its own rate
  (e.g. 90 Hz); the performance overlay shows the real one.
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

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| Controller does nothing, keyboard works | The mpv build lacks SDL2 gamepad support (only possible when running from source with a distro mpv). Use the Flatpak. In Steam, make sure the controller template is a gamepad layout. |
| HDR video looks washed out / badge says `HDR10 → SDR` | HDR is off in Steam display settings, or the gamescope layer extension is missing: `flatpak list --runtime \| grep VulkanLayer.gamescope`. Install it with the command above (branch must be `25.08`). |
| HDR works in other games but not here | Check that `gpu_context = auto` (it must resolve to `x11vk` in game mode). Run from Konsole inside a nested gamescope and look for `[Gamescope WSI] … hdr formats exposed to client: true`. |
| Refresh rate doesn't change | Only in game mode, only on Deck panels, not while VRR is on. Check Steam's **performance overlay** (it shows the real panel rate); the Quick Access Menu's refresh slider always shows Steam's own setting, not ours. The info panel (View) shows `48 Hz (requested)` on a Deck (gamescope's confirmation isn't visible to games there), `48 Hz (matched)` where it can confirm, `90 Hz (asked for 48 Hz)` if gamescope refused. Moving Steam's slider takes the rate back; the app asks again on the next file or when you unpause. Logs: `refresh rate: …` lines. To turn matching off: playback menu → *Match refresh rate*. |
| Software decoding (`Decoder: Software`) | Some formats have no hardware decoder (e.g. H.264 4:4:4, 10-bit H.264, MPEG-4 ASP). That's expected; it costs more battery. |
| Folder missing from the library | The path in `config.ini` must exist. Paths outside home, `/run/media`, `/media` and `/mnt` aren't visible to the Flatpak; add access with `flatpak override --user --filesystem=/path io.github.nicocarbone.DeckVideoPlayer`. |
| Need logs | Desktop Mode: `flatpak run io.github.nicocarbone.DeckVideoPlayer --msg-level=all=v --log-file=$HOME/dvp.log`. In game mode, add `--log-file=/home/deck/dvp.log` to the shortcut's launch options (after the app id). |
| No *Download subtitles…* entry | No API key yet (see [above](#online-subtitles-opensubtitles)), or the video isn't a local file. |
| "No internet connection" when searching subtitles | The Deck is offline, or the Flatpak lacks network access: `flatpak info --show-permissions io.github.nicocarbone.DeckVideoPlayer` must list `network`. |
| "OpenSubtitles rejected the API key" / "login failed" | Check `api_key`, and use your username (not e-mail) with the right password. |
| No *Headphone surround* entry in the audio menu | `audio_passthrough` is set (surround can't filter compressed audio), or the build lacks the `sofalizer` filter (log: `headphone surround: the sofalizer filter is not available`). |
| Settings ignored | Typo in a key or value: the log shows `config.ini: unknown option …` / `invalid value …`. |
