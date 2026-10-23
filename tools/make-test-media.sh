#!/bin/sh
# Generate a small synthetic video library for testing (needs ffmpeg with
# libx264 and libx265). Output: .dev/test-media/Videos (or $1).
#
#   Videos/
#     The.Test.Movie.2024.1080p.BluRay.x264.mkv  40 s, 23.976 fps, 2 audio
#         tracks (eng AAC stereo, spa AC-3 5.1 "Castellano"), 2 SRT subtitle
#         tracks (eng, spa), 3 chapters  -> track menus, chapters, name cleanup
#     HDR10 Sample 2160p.mkv                      12 s HEVC 10-bit PQ/BT.2020 with
#         HDR10 metadata (1000 nits)        -> HDR passthrough / badges
#     A Long Film (2023).mkv                      5 min, 25 fps -> resume dialog,
#         50 Hz refresh matching
#     Series/Season 1/Show S01E01..03.mp4         6 s each -> auto-play next,
#         watched markers, breadcrumbs
#     Documentaries/Nature_Documentary_Part_1..14.mp4 -> scrolling, natural sort
#     This.Is.A.Very.Long.Movie.Title…-GROUPNAME.mkv  symlink to the long film
#         (sorts last) -> truncation and scrolling of long names
#
# Note: the series/documentary clips are H.264 4:4:4 (from the RGB test
# source), which GPUs cannot decode in hardware; mpv falls back to software
# for them. That is expected.

set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-$root/.dev/test-media/Videos}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out/Series/Season 1" "$out/Documentaries"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

printf '1\n00:00:01,000 --> 00:00:20,000\nHello, this is an English subtitle.\n\n2\n00:00:21,000 --> 00:00:39,000\nSecond English line.\n' > "$tmp/en.srt"
printf '1\n00:00:01,000 --> 00:00:20,000\nHola, este es un subtítulo en español.\n\n2\n00:00:21,000 --> 00:00:39,000\nSegunda línea en español.\n' > "$tmp/es.srt"
printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=15000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=15000\nEND=30000\ntitle=Middle part\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=30000\nEND=40000\ntitle=Credits\n' > "$tmp/chapters.txt"

echo "movie with tracks and chapters..."
ff -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001:duration=40" \
   -f lavfi -i "sine=frequency=440:duration=40" -f lavfi -i "sine=frequency=660:duration=40" \
   -i "$tmp/en.srt" -i "$tmp/es.srt" -i "$tmp/chapters.txt" \
   -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map_metadata 5 \
   -c:v libx264 -preset veryfast -crf 28 -c:a:0 aac -ac:a:0 2 -c:a:1 ac3 -ac:a:1 6 -c:s srt \
   -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:a:1 title=Castellano \
   -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa \
   "$out/The.Test.Movie.2024.1080p.BluRay.x264.mkv"

echo "HDR10 sample..."
ff -f lavfi -i "testsrc2=size=1920x1080:rate=24:duration=12" -f lavfi -i "sine=frequency=330:duration=12" \
   -vf format=yuv420p10le -c:v libx265 -preset ultrafast \
   -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
   -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a aac \
   "$out/HDR10 Sample 2160p.mkv"

echo "long film..."
ff -f lavfi -i "testsrc2=size=640x360:rate=25:duration=300" -f lavfi -i "sine=frequency=500:duration=300" \
   -c:v libx264 -preset ultrafast -crf 35 -c:a aac "$out/A Long Film (2023).mkv"

echo "series and documentaries..."
for i in 1 2 3; do
    ff -f lavfi -i "testsrc=size=1280x720:rate=25:duration=6" -f lavfi -i "sine=frequency=$((300 + i * 100)):duration=6" \
       -c:v libx264 -preset ultrafast -c:a aac "$out/Series/Season 1/Show S01E0$i.mp4"
done
for i in $(seq 1 14); do
    cp "$out/Series/Season 1/Show S01E01.mp4" "$out/Documentaries/Nature_Documentary_Part_$i.mp4"
done
ln -sf "A Long Film (2023).mkv" \
    "$out/This.Is.A.Very.Long.Movie.Title.With.Many.Words.WWMM.2024.2160p.UHD.BluRay.REMUX.HDR10.HEVC.TrueHD.Atmos.7.1-GROUPNAME.mkv"
echo "Test library ready in $out"
