#!/usr/bin/env fish
#
# reflac.fish — re-encode a lossless music library to maximum-compression
# FLAC (flac -8 -e -p), in parallel and resumably, keeping every tag and
# picture. Damaged albums are quarantined with a report, and finished
# albums are moved out of the scan folder, so whatever is still in it
# is what still needs attention.
#
# Written by Claude, an AI model made by Anthropic (see "AI disclosure"
# in README.md). Public domain (The Unlicense); see LICENSE.
#
# Usage:
#   reflac.fish [OPTIONS] [DIR]       DIR defaults to the current folder
#
#   -n, --dry-run            show what would happen; change nothing
#   -f, --force              re-encode FLACs even if already at maximum
#                            compression
#   -j, --jobs N             albums to process at once (default: all cores)
#       --flaced-root DIR    where finished albums go
#                            (default: "FLACed" beside the scan folder)
#       --lossy-root DIR     where finished albums holding lossy audio go
#                            (default: "Lossy" beside the scan folder)
#       --corrupt-root DIR   where damaged albums go
#                            (default: "corrupt" in the folder you run from)
#       --strip-prefix NAME  a first-level folder of the scan folder to
#                            ignore when working out ARTIST/ALBUM
#                            (default: Processed)
#       --delete-empty       delete empty (0-byte) tracks and their
#                            .lrc/.txt sidecars, and remove folders left
#                            holding only .txt/.lrc/empty files (see below)
#       --no-strip           never strip ID3 tags from FLACs; a FLAC that
#                            carries one is quarantined instead
#       --restrip            re-examine FLACs finished in an earlier run
#                            that still carry an ID3 tag
#       --retry-corrupt      count earlier CORRUPT entries as new work in
#                            the start-of-run statistics (albums put back
#                            into the scan folder are always re-checked)
#       --reset              archive the state log and start from scratch
#   -h, --help               print a one-line usage summary
#
# Requirements:
#   fish, flac, metaflac, ffmpeg, ffprobe, id3v2, flock, GNU parallel
#   and GNU coreutils/findutils.
#   Arch / CachyOS:  sudo pacman -S flac ffmpeg id3v2 util-linux coreutils parallel
#
# Layout:
#   An album is an ARTIST/ALBUM folder two levels below the scan folder
#   (a leading --strip-prefix folder is ignored), together with
#   everything inside it: disc subfolders, artwork, cue sheets, logs.
#   One worker handles one album, so an album is always quarantined or
#   relocated in one piece; albums run in parallel and the tracks inside
#   an album run one after another.
#   Loose tracks (directly in the scan folder or in an ARTIST folder)
#   have no album folder: they are converted in place and never
#   relocated, and a damaged one is quarantined on its own.
#
# What happens to each album:
#   1. Check. Every track gets a full integrity test.
#      Sources: FLAC, WAV, AIFF, ALAC (.m4a/.mp4/.caf), Monkey's Audio
#      (.ape), WavPack (.wv), TTA, TAK, WMA Lossless and FLAC inside
#      Matroska (.mka). Containers that can hold either kind of audio
#      (.m4a, .wma, .mka…) are probed; lossy ones count as lossy.
#      - FLAC: `flac -t`. A FLAC carrying an ID3 tag first has any field
#        or cover art that only the ID3 tag holds copied into its own
#        tags (existing fields are never overridden); the ID3 tag is
#        then stripped and the file re-tested. If it is still broken,
#        the original is restored and the album is marked for quarantine.
#      - Everything else: decoded in full. ffmpeg errors, fewer samples
#        than the header promises, or a WAV/AIFF data chunk that runs
#        past the end of the file mark the album for quarantine.
#      - Left untouched, because converting would alter the audio:
#        floating-point and deeper-than-24-bit integer audio, DSD
#        (.dsf/.dff), and hybrid WavPack with a .wvc correction file.
#        Hybrid WavPack without one is lossy.
#   2. Decide. If any track is unrecoverable, the whole album moves to
#      <corrupt-root>/ARTIST/ALBUM/ with a CORRUPT_TRACKS.txt report
#      naming each damaged track and what is wrong with it.
#   3. Convert. Each track is encoded once: that encode is both the
#      "already at maximum?" size test and the final output, and
#      flac -V verifies it against the source while encoding.
#      FLAC sources keep their metadata natively. A FLAC the encoder
#      refuses (e.g. no track length in its header), or one lacking its
#      audio checksum, is rebuilt from a decode with every metadata
#      block copied byte for byte, and gains both.
#      Other sources are decoded by ffmpeg; their tag names are then
#      mapped to the standard Vorbis names (e.g. "MusicBrainz Track Id"
#      -> MUSICBRAINZ_TRACKID), "3/12" track and disc numbers are split
#      into number + total, and container bookkeeping is dropped.
#      The original is replaced by a single atomic rename, and only
#      after the verified encode succeeded and no tag or picture was
#      lost. A non-FLAC source is deleted only once its FLAC is in
#      place, and never replaces a different FLAC of the same name.
#   4. Relocate. When every track is converted or legitimately skipped
#      (including albums already at maximum compression) and nothing
#      failed, the album leaves the scan folder:
#        all lossless            -> <flaced-root>/ARTIST/ALBUM/
#        any lossy audio at all  -> <lossy-root>/ARTIST/ALBUM/
#      Scanning ~/Music/Incoming therefore fills ~/Music/FLACed and
#      ~/Music/Lossy. A move within one filesystem is a single rename;
#      across filesystems it is a verified copy followed by deleting
#      the source. Artist folders left empty are removed.
#
# --delete-empty:
#   An empty track is deleted along with its same-name .lrc/.txt sidecar.
#   An album that loses only some of its tracks this way is incomplete
#   and is quarantined. An album whose tracks were all empty is removed
#   if nothing but .txt/.lrc/empty files remain; if anything else
#   remains (artwork, logs…) it is quarantined for review instead.
#
# Bookkeeping:
#   Everything lives in the folder you run from, never in the music tree:
#     .reflac_state.log      one line per finished track; lets an
#                            interrupted run resume where it stopped
#     .reflac_run_DATE.log   the output of one run, without colors
#     .reflac_corrupt.txt    every quarantined track and the reason
#   Temporary files go to a per-run folder in /dev/shm (RAM).
#   Only one run may be active at a time, enforced by a per-user lock.
#
# Interruptions:
#   Ctrl-C is safe. A rerun resumes from the state log and first cleans
#   up: stale RAM folders, unfinished cross-filesystem moves, backups
#   left by a cut-short ID3 strip (*.reflac_bak, restored) and stray
#   write-back files (.reflac_tmp_*, deleted if the same audio exists
#   beside them; otherwise reported and the album held back, since the
#   file may be a track's only copy).
#
# Output:
#   Each album's outcome line carries a [finished/total] counter, and a
#   summary of the run follows at the end. On a terminal:
#     red     FAIL lines, errors, crashed workers, a non-zero FAIL count
#     yellow  WARN lines, albums held back, "Interrupted", the rerun hint
#     purple  folders pruned or removed
#     green   albums completed and moved (in a dry run: would be moved)
#   Everything else is uncolored. Piped or redirected output and the
#   run log are never colored; NO_COLOR=1 turns colors off entirely.
#
# Exit status:
#   0    finished without failures
#   1    a track FAILed or a worker crashed (rerun to retry)
#   2    bad option, or DIR is not a folder
#   3    a required tool is missing, or /dev/shm is unusable
#   4    another reflac run is already active
#   130  interrupted
#
# Internal (how GNU parallel starts one worker per album):
#   reflac.fish --folder-worker FOLDER RUNFROM SCANDIR CORRUPTROOT \
#               STRIPPREFIX STATE RUNLOG QUAR DRY FORCE STRIP \
#               FLACEDROOT LOSSYROOT RESTRIP RUNTMP JOBSEQ JOBTOTAL \
#               DELETEEMPTY

# =====================================================================
#  WORKER MODE
#  One process per album (or per folder of loose tracks), started by
#  GNU parallel from the controller at the bottom of this file.
# =====================================================================
if test (count $argv) -ge 1; and test "$argv[1]" = --folder-worker
    set -l FOLDER      "$argv[2]"
    set -l RUNFROM     "$argv[3]"
    set -l SCANDIR     "$argv[4]"
    set -l CORRUPTROOT "$argv[5]"
    set -l STRIPPREFIX "$argv[6]"
    set -l STATE       "$argv[7]"
    set -l RUNLOG      "$argv[8]"
    set -l QUAR        "$argv[9]"
    set -l DRY         "$argv[10]"
    set -l FORCE       "$argv[11]"
    set -l STRIP       "$argv[12]"
    set -l FLACEDROOT  "$argv[13]"
    set -l LOSSYROOT   "$argv[14]"
    set -l RESTRIP     "$argv[15]"
    set -l RUNTMP      "$argv[16]"   # this run's RAM dir (/dev/shm/reflac.run.*)
    set -l JOBSEQ      "$argv[17]"   # this album's job number (parallel's {#})
    set -l JOBTOTAL    "$argv[18]"   # albums queued this run
    set -l DELETEEMPTY "$argv[19]"   # 1 = --delete-empty
    test -n "$DELETEEMPTY"; or set DELETEEMPTY 0

    # ----- shared files -----
    # All workers append to the same files, so every write is one short
    # /bin/sh command run under flock (much cheaper than starting
    # another fish for each line).
    # w_log: one line to the run log and to the terminal.
    function w_log --inherit-variable RUNLOG
        flock "$RUNLOG.lock" sh -c 'printf "%s\n" "$1" >> "$2"' sh "$argv[1]" "$RUNLOG"
        w_paint "$argv[1]"
    end
    # Print a log line on the terminal, colored by its kind. The
    # controller decides whether colors are on (REFLAC_COLOR=1): this
    # worker's stdout is GNU parallel's pipe, so it cannot tell. The
    # run log always gets the plain line, because the summary greps it.
    function w_paint --argument-names line
        set -l c
        if test "$REFLAC_COLOR" = 1
            # kind = the line without its "[n/N] " progress prefix
            set -l kind (string replace -r '^\[ *[0-9]+/[0-9]+\] ' '' -- "$line")
            switch "$kind"
                case 'FAIL *'
                    set c 31     # red: an error
                case 'WARN *' 'KEEP  (had FAILs)*' 'KEEP  (stray temp)*' 'KEEP  (no audio)*'
                    set c 33     # yellow: a warning / album held back
                case 'PRUNE *' 'DELETED folder*' 'WOULD DELETE folder*'
                    set c 35     # purple: a folder pruned or removed
                case 'ALBUM DONE *' 'WOULD MOVE (*'
                    set c 32     # green: an album completed and moved
            end
        end
        if test -n "$c"
            printf '\e[%sm%s\e[0m\n' $c "$line"
        else
            printf '%s\n' "$line"
        end
    end
    # w_state: a track's STATUS, size:mtime key and path to the state log.
    function w_state --inherit-variable STATE
        flock "$STATE.lock" sh -c 'printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$4"' \
            sh "$argv[1]" "$argv[2]" "$argv[3]" "$STATE"
    end
    # w_quar: a quarantined track's old path, new path and reason.
    function w_quar --inherit-variable QUAR
        flock "$QUAR.lock" sh -c 'printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$4"' \
            sh "$argv[1]" "$argv[2]" "$argv[3]" "$QUAR"
    end
    # w_bytes: a converted track's size before and after (for the summary).
    function w_bytes --inherit-variable RUNTMP
        flock "$RUNTMP/bytes.lock" sh -c 'printf "%s %s\n" "$1" "$2" >> "$3"' \
            sh "$argv[1]" "$argv[2]" "$RUNTMP/bytes"
    end
    # w_final: the single line reporting how this album ended, prefixed
    # with a "[finished/total]" counter shared by all workers.
    set -g W_FINAL_DONE 0
    function w_final --inherit-variable RUNTMP --inherit-variable JOBTOTAL
        set -l n (flock "$RUNTMP/progress.lock" sh -c \
            'n=$(cat "$1" 2>/dev/null); n=$(( ${n:-0} + 1 )); echo "$n" > "$1"; echo "$n"' \
            sh "$RUNTMP/progress")
        set -g W_FINAL_DONE 1
        w_log "["(string pad -w (string length -- "$JOBTOTAL") -- "$n")"/$JOBTOTAL] $argv[1]"
    end
    # ----- exit handling -----
    # On every normal exit, remove this worker's RAM workspace and leave
    # a "done" marker. A worker that is killed, crashes or never starts
    # leaves no marker, and the controller reports its album as crashed.
    set -g W_KILLED 0
    set -g W_RAMDIR ""
    function _w_exit --inherit-variable RUNTMP --inherit-variable JOBSEQ --inherit-variable FOLDER --on-event fish_exit
        test -n "$W_RAMDIR"; and rm -rf -- "$W_RAMDIR"
        test "$W_KILLED" -eq 1; and return
        test "$W_FINAL_DONE" -eq 0; and w_final "DONE  (no change)  : $FOLDER"
        touch -- "$RUNTMP/done/$JOBSEQ" 2>/dev/null
    end
    # Ctrl-C: GNU parallel terminates every worker. Remove the RAM
    # workspace on the way out and leave no "done" marker.
    function _w_sig --on-signal INT --on-signal TERM
        set -g W_KILLED 1
        test -n "$W_RAMDIR"; and rm -rf -- "$W_RAMDIR"
        exit 143
    end
    # ----- helpers -----
    # Prints a file's "size:mtime", the key by which the state log tells
    # whether a track has changed. Prints ":" on failure, never nothing,
    # so a caller cannot lose an argument to an empty substitution.
    function w_key
        set -l k (stat -c '%s:%Y' -- "$argv[1]" 2>/dev/null)
        test -n "$k"; or set k :
        echo "$k"
    end
    # If the source's only embedded picture is an APEv2 "Cover Art (Front)"
    # item that reached the FLAC as picture type 0 (Other), make it
    # type 3 (front cover).
    function w_fix_cover_type --argument-names src out work
        set -l tags (ffprobe -v error -select_streams v -show_entries stream_tags \
            -of default=nw=1 -- "$src" 2>/dev/null)
        string match -qi '*Cover Art (Front)*' -- $tags; or return 0
        set -l ptypes (metaflac --list --block-type=PICTURE -- "$out" 2>/dev/null \
            | string match -r '^  type: [0-9]+ \(.*' | string match -v '*(PICTURE)')
        test (count $ptypes) -eq 1; or return 0
        string match -q '  type: 0 (*' -- $ptypes[1]; or return 0
        set -l mime (metaflac --list --block-type=PICTURE -- "$out" 2>/dev/null \
            | string match -r '^  MIME type: (.*)$')[2]
        metaflac --export-picture-to="$work/cover.bin" -- "$out" 2>/dev/null; or return 1
        metaflac --remove --block-type=PICTURE --dont-use-padding -- "$out" 2>/dev/null; or return 1
        metaflac --import-picture-from="3|$mime|||$work/cover.bin" -- "$out" 2>/dev/null; or return 1
        rm -f -- "$work/cover.bin"
    end

    # Prints "<tag count> <picture count>" for a FLAC. A re-encode must
    # keep both.
    function w_meta_counts --argument-names f
        set -l nc (metaflac --list --block-type=VORBIS_COMMENT -- "$f" 2>/dev/null | grep -c 'comment\[')
        set -l np (metaflac --list --block-type=PICTURE -- "$f" 2>/dev/null | grep -c 'type: 6 (PICTURE)')
        echo "$nc $np"
    end

    # Re-encode a FLAC from a decode of itself, then copy every metadata
    # block (tags, pictures, cue sheet, application data) over byte for
    # byte and add a seek table. Used for valid FLACs the encoder refuses
    # directly (e.g. no track length in the header) and as a fallback if
    # a native encode doesn't keep all tags and pictures.
    function w_flac_via_decode --argument-names src out work
        set -l fmt (metaflac --show-channels --show-bps --show-sample-rate -- "$src" 2>/dev/null)
        test (count $fmt) -eq 3; or return 1
        flac -d -c --silent --force-raw-format --endian=little --sign=signed -- "$src" 2>/dev/null \
            | flac --silent --totally-silent -V -8 -e -p --force-raw-format --endian=little \
                --sign=signed --channels=$fmt[1] --bps=$fmt[2] --sample-rate=$fmt[3] -o "$out" - 2>/dev/null
        test "$pipestatus[1]" -eq 0 -a "$pipestatus[2]" -eq 0; or return 1
        # the encoder's own tag block is empty: replace it with the source's
        metaflac --remove --block-type=VORBIS_COMMENT -- "$out" 2>/dev/null; or return 1
        metaflac --list --data-format=binary --except-block-type=STREAMINFO,SEEKTABLE,PADDING \
            -- "$src" > "$work/blocks.bin" 2>/dev/null; or return 1
        if test -s "$work/blocks.bin"
            metaflac --append -- "$out" < "$work/blocks.bin" 2>/dev/null; or return 1
        end
        rm -f -- "$work/blocks.bin"
        metaflac --add-seekpoint=10s -- "$out" 2>/dev/null
        return 0
    end

    # WavPack block header: "wvpk" + sizes, then a 32-bit flags word at
    # byte 24; flag 0x8 = hybrid (lossy) mode. Prints lossless|hybrid|unknown.
    function w_wv_mode --argument-names f
        set -l b (head -c 28 -- "$f" 2>/dev/null | od -An -tu1 | string split -n ' ')
        if test (count $b) -ne 28; or not test "$b[1]" = 119 -a "$b[2]" = 118 -a "$b[3]" = 112 -a "$b[4]" = 107
            echo unknown
        else if test (math "bitand($b[25], 8)") -ne 0
            echo hybrid
        else
            echo lossless
        end
    end

    # Integrity check for non-FLAC lossless sources (ALAC, WAV, AIFF…),
    # which, unlike FLAC, carry no checksum of their own. ffmpeg does
    # not exit non-zero on decode errors (not even with -xerror), so
    # the verdict rests on what it prints at error level and on how
    # much audio decodes compared with what the header promises.
    # ffmpeg also trusts whatever bytes a truncated WAV still has, so
    # WAV and AIFF are read once more by flac, whose reader notices a
    # data chunk that runs past the end of the file.
    # Prints a reason if the file is damaged, nothing if it is fine.
    function w_decode_check --argument-names f errfile
        # Decode everything and count the samples that come out. The
        # count is exact: a healthy file matches its header to the
        # sample. (ffmpeg's progress time is no substitute: it marks
        # where the last frame starts, which for APE and TTA can be
        # seconds before the end.)
        set -l bytes (ffmpeg -hide_banner -nostdin -v error -i "$f" -map 0:a:0 \
            -c:a pcm_s16le -f s16le - 2>"$errfile" | wc -c | string trim)
        set -l err (head -n 1 "$errfile" 2>/dev/null | string replace -r '^\[[^]]*\] *' '' | string trim)
        if test -n "$err"
            echo "damaged audio — ffmpeg reports: $err"
            return
        end
        set -l info (ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels,duration \
            -of default=nw=1 -- "$f" 2>/dev/null)
        set -l rate (string match -r '^sample_rate=([0-9]+)$' -- $info)[2]
        set -l ch (string match -r '^channels=([0-9]+)$' -- $info)[2]
        set -l dur (string match -r '^duration=([0-9.]+)$' -- $info)[2]
        if test -n "$rate" -a -n "$ch" -a -n "$dur"; and string match -qr '^[0-9]+$' -- "$bytes"
            set -l got (math -s0 "$bytes / (2 * $ch)")
            set -l want (math -s0 "$dur * $rate")
            # tolerance: 0.25 s or 0.1 % of the track, whichever is more
            set -l allow (math -s0 "max(0.25 * $rate, $want / 1000)")
            if test (math -s0 "$want - $got") -gt $allow
                echo "truncated — only "(w_mmss $got $rate)" of "(w_mmss $want $rate)" decodes; the end of the file is missing (incomplete download or copy?)"
                return
            end
        end
        switch (string lower (string replace -r '.*\.' '' -- "$f"))
            case wav wave aif aiff aifc
                set -l ferr (flac -0 --silent -c -- "$f" 2>&1 >/dev/null \
                    | string match -r -e 'overruns the end of the file|unexpected EOF')
                if test -n "$ferr[1]"
                    echo "truncated — the file ends before its audio data does (incomplete download or copy?) [flac: "(string replace -r '^.*WARNING: ' '' -- "$ferr[1]" | string replace -r '\. Please consult.*$' '')"]"
                end
        end
    end

    # Formats a sample count as "m:ss.s".
    function w_mmss --argument-names samples rate
        set -l s (math "$samples / $rate")
        set -l m (math "floor($s / 60)")
        printf '%d:%04.1f' $m (math "$s - $m * 60")
    end
    # Turns flac's terse decoder errors ("LOST_SYNC after processing N
    # samples") into a plain description of what is wrong and where in
    # the track, keeping flac's own wording in brackets.
    # Usage: w_flac_reason FILE FLAC_OUTPUT_LINES...
    function w_flac_reason
        set -l f $argv[1]
        set -l out $argv[2..-1]
        set -l info (metaflac --show-total-samples --show-sample-rate -- "$f" 2>/dev/null)
        set -l total "$info[1]"
        set -l rate "$info[2]"
        set -l n (string match -r 'after processing ([0-9]+) samples' -- $out)[2]
        set -l code (string match -r 'ERROR_STATUS_([A-Z_]+)' -- $out)[2]
        set -l raw (printf '%s\n' $out | grep -m1 -E '\*\*\*|ERROR' | string replace -r '^.*?: (\*\*\* )?' '' | string trim)
        test -n "$code"; and test -n "$n"; and set raw "$code after $n samples"
        set -l known 0
        string match -qr '^[0-9]+$' -- "$total"; and string match -qr '^[1-9][0-9]*$' -- "$rate"
        and test "$total" -gt 0; and set known 1
        set -l eos 0
        string match -q '*END_OF_STREAM*' -- $out; and set eos 1
        set -l what
        if string match -q '*MD5 signature mismatch*' -- $out
            set what "audio does not match its own checksum (MD5) — the data is damaged"
        else if string match -q '*decoded number of samples is smaller*' -- $out
            set what "truncated — the file ends before the length its header declares (incomplete download or copy?)"
            if test $known -eq 1
                set what "truncated — shorter than the "(w_mmss $total $rate)" its header declares (incomplete download or copy?)"
            end
        else if test $eos -eq 1; and test -n "$n"; and test $known -eq 1; and test "$n" -gt 0; and test "$n" -lt "$total"
            set what "truncated — only "(w_mmss $n $rate)" of "(w_mmss $total $rate)" present; the end of the file is missing (incomplete download or copy?)"
        else if test "$n" = 0; and test $known -eq 0
            set what "not a readable FLAC stream — the header is damaged or missing"
        else if test -n "$n"; and test $known -eq 1
            switch "$code"
                case FRAME_CRC_MISMATCH
                    set what "damaged audio at "(w_mmss $n $rate)" (frame checksum error)"
                case LOST_SYNC UNPARSEABLE_STREAM
                    set what "damaged audio at "(w_mmss $n $rate)" (unreadable frames)"
                case BAD_METADATA
                    set what "damaged metadata"
            end
        end
        if test -z "$what"
            set what "FLAC decode test failed"
        end
        if test -n "$raw"
            echo "$what [flac: $raw]"
        else
            echo "$what"
        end
    end

    # ----- tags -----
    # ffmpeg carries tags over from MP4 (iTunes), RIFF INFO and ID3
    # under its own key names. This list ("ffmpeg key|VORBIS NAME") maps
    # them to the Vorbis names that taggers such as Picard and beets read.
    set -g W_TAGMAP \
        'musicbrainz track id|MUSICBRAINZ_TRACKID' \
        'musicbrainz release track id|MUSICBRAINZ_RELEASETRACKID' \
        'musicbrainz album id|MUSICBRAINZ_ALBUMID' \
        'musicbrainz artist id|MUSICBRAINZ_ARTISTID' \
        'musicbrainz album artist id|MUSICBRAINZ_ALBUMARTISTID' \
        'musicbrainz release group id|MUSICBRAINZ_RELEASEGROUPID' \
        'musicbrainz work id|MUSICBRAINZ_WORKID' \
        'musicbrainz disc id|MUSICBRAINZ_DISCID' \
        'musicbrainz original album id|MUSICBRAINZ_ORIGINALALBUMID' \
        'musicbrainz original artist id|MUSICBRAINZ_ORIGINALARTISTID' \
        'musicbrainz trm id|MUSICBRAINZ_TRMID' \
        'musicbrainz album status|RELEASESTATUS' \
        'musicbrainz album type|RELEASETYPE' \
        'musicbrainz album release country|RELEASECOUNTRY' \
        'musicip puid|MUSICIP_PUID' \
        'acoustid id|ACOUSTID_ID' \
        'acoustid fingerprint|ACOUSTID_FINGERPRINT' \
        'sort_name|TITLESORT' 'title-sort|TITLESORT' \
        'sort_artist|ARTISTSORT' 'artist-sort|ARTISTSORT' \
        'sort_album|ALBUMSORT' 'album-sort|ALBUMSORT' \
        'sort_album_artist|ALBUMARTISTSORT' 'album_artist-sort|ALBUMARTISTSORT' \
        'sort_composer|COMPOSERSORT' 'composer-sort|COMPOSERSORT' \
        'album_artist|ALBUMARTIST' 'encoded_by|ENCODEDBY' 'publisher|LABEL' \
        'album artist|ALBUMARTIST' 'year|DATE' \
        'musicbrainz_albumstatus|RELEASESTATUS' 'musicbrainz_albumtype|RELEASETYPE'
    # Container bookkeeping that ffmpeg exposes as metadata but that is
    # not a music tag.
    set -g W_TAGJUNK major_brand minor_version compatible_brands creation_time \
        media_type gapless_playback itunsmpb itunnorm itunpgap handler_name vendor_id

    # Clean up the tags of a FLAC that ffmpeg made from a non-FLAC
    # source: rename them to the standard Vorbis names, split "3/12"
    # track and disc numbers into number + total, and drop container
    # junk. Prints a short summary of what changed, or nothing.
    function w_fix_tags --argument-names out srcext
        set -l present (metaflac --no-utf8-convert --export-tags-to=- -- "$out" 2>/dev/null \
            | string match -r '^[^=]+(?==)' | string lower)
        set -l map $W_TAGMAP
        switch $srcext
            case m4a mp4 caf
                # iTunes "encoded by" (©too) arrives as "encoder"
                set -a map 'encoder|ENCODEDBY'
        end
        set -l args
        set -l n_ren 0
        set -l n_split 0
        set -l n_junk 0
        for pair in $map
            set -l kv (string split '|' -- $pair)
            contains -- $kv[1] $present; or continue
            set -l vals (metaflac --no-utf8-convert --show-tag="$kv[1]" -- "$out" 2>/dev/null | string replace -r '^[^=]*=' '')
            set -l have (metaflac --no-utf8-convert --show-tag="$kv[2]" -- "$out" 2>/dev/null | string replace -r '^[^=]*=' '')
            set -a args --remove-tag="$kv[1]"
            for v in $vals
                contains -- "$v" $have; or set -a args --set-tag="$kv[2]=$v"
            end
            set n_ren (math $n_ren + 1)
        end
        for spec in 'tracknumber|TRACKNUMBER|TRACKTOTAL|totaltracks' 'discnumber|DISCNUMBER|DISCTOTAL|totaldiscs'
            set -l p (string split '|' -- $spec)
            contains -- $p[1] $present; or continue
            set -l v (metaflac --no-utf8-convert --show-tag=$p[2] -- "$out" 2>/dev/null | string replace -r '^[^=]*=' '')
            set -l m (string match -r '^\s*(\d+)\s*/\s*(\d+)\s*$' -- "$v[1]")
            test (count $m) -eq 3; or continue
            set -a args --remove-tag=$p[2] --set-tag="$p[2]=$m[2]"
            if not contains -- (string lower $p[3]) $present; and not contains -- $p[4] $present
                set -a args --set-tag="$p[3]=$m[3]"
            end
            set n_split (math $n_split + 1)
        end
        for j in $W_TAGJUNK
            if contains -- $j $present
                set -a args --remove-tag=$j
                set n_junk (math $n_junk + 1)
            end
        end
        test (count $args) -eq 0; and return 0
        metaflac --no-utf8-convert $args -- "$out" 2>/dev/null; or return 1
        set -l parts
        test $n_ren -gt 0;   and set -a parts "$n_ren renamed"
        test $n_split -gt 0; and set -a parts "$n_split split"
        test $n_junk -gt 0;  and set -a parts "$n_junk junk removed"
        # `string join` exits 1 for a single item, hence the explicit return
        string join ', ' -- $parts
        return 0
    end

    # ----- ID3 tags on FLAC files -----
    # ffmpeg ignores an ID3 tag stuck in front of FLAC data but reads
    # one perfectly well in an MP3. So build a tiny MP3 ($probe): the
    # track's ID3v2 block, a few silent MP3 frames, and the track's
    # trailing ID3v1 block if it has one.
    function w_id3_probe --inherit-variable RUNTMP --argument-names f probe
        set -l total 0
        set -l b (head -c 10 -- "$f" | od -An -tu1 | string split -n ' ')
        if test (count $b) -eq 10; and test "$b[1]" = 73 -a "$b[2]" = 68 -a "$b[3]" = 51
            # "ID3" + version(2) + flags(1) + syncsafe size(4)
            set total (math "10 + bitand($b[7],127)*2097152 + bitand($b[8],127)*16384 + bitand($b[9],127)*128 + bitand($b[10],127)")
            test (math "bitand($b[6],16)") -ne 0; and set total (math "$total + 10")
        end
        begin
            test $total -gt 0; and head -c $total -- "$f"
            cat "$RUNTMP/frames.mp3"
            set -l t3 (tail -c 128 -- "$f" 2>/dev/null | head -c 3 | string collect)
            test "$t3" = TAG; and tail -c 128 -- "$f"
        end > "$probe" 2>/dev/null
    end

    # Copy from that probe into the (already stripped) FLAC $flacf every
    # field, and the cover art, that the FLAC's own tags lack. A field
    # the FLAC already has is never overridden. Prints what was added,
    # comma-separated.
    function w_id3_rescue --argument-names probe flacf work
        set -l meta "$work/id3meta.txt"
        ffmpeg -hide_banner -v error -nostdin -y -i "$probe" -f ffmetadata "$meta" 2>/dev/null; or return 0
        set -l have (metaflac --no-utf8-convert --export-tags-to=- -- "$flacf" 2>/dev/null \
            | string match -r '^[^=]+(?==)' | string upper)
        # ffmetadata: key=value lines; '=', ';', '#', '\' and newlines in
        # values are backslash-escaped (an escaped newline continues the
        # value on the next line).
        set -l lines (string split \n -- (cat "$meta" | string collect))
        set -l keys
        set -l vals
        set -l cur ""
        set -l cont 0
        for idx in (seq 2 (count $lines))
            set -l line $lines[$idx]
            if test $cont -eq 0
                string match -q -- '[*' "$line"; and break
                string match -q -- ';*' "$line"; and continue
                test -z "$line"; and continue
                set cur "$line"
            else
                set cur "$cur"\n"$line"
            end
            set -l tb (string length -- (string match -r '\\\\*$' -- "$line"))
            if test (math "$tb % 2") -eq 1
                set cur (string sub -e -1 -- "$cur")
                set cont 1
                continue
            end
            set cont 0
            # Key and value are split without capture groups: command
            # substitution would break a multi-line value into several
            # list items.
            string match -q -- '*=*' "$cur"; or continue
            set -a keys (string replace -r '(?s)=.*' '' -- "$cur" | string replace -ra '\\\\(.)' '$1')
            set -a vals (string replace -r '^[^=]*=' '' -- "$cur" | string replace -ra '\\\\(.)' '$1' | string collect --allow-empty)
        end
        set -l stdmap 'title|TITLE' 'artist|ARTIST' 'album|ALBUM' 'composer|COMPOSER' \
            'genre|GENRE' 'date|DATE' 'comment|COMMENT' 'id3v1 comment|COMMENT' \
            'copyright|COPYRIGHT' 'performer|PERFORMER' 'language|LANGUAGE' \
            'compilation|COMPILATION' 'grouping|GROUPING' $W_TAGMAP
        set -l args
        set -l added
        set -l n 0
        for i in (seq (count $keys))
            set -l k (string lower -- "$keys[$i]")
            set -l v "$vals[$i]"
            test -n "$v"; or continue
            contains -- $k $W_TAGJUNK encoder tlen length; and continue
            set -l name ""
            for pair in $stdmap
                set -l kv (string split '|' -- $pair)
                if test "$kv[1]" = "$k"
                    set name $kv[2]
                    break
                end
            end
            if test -z "$name"
                switch $k
                    case 'lyrics' 'lyrics-*'
                        set name LYRICS
                    case track disc
                        set -l num TRACKNUMBER
                        set -l tot TRACKTOTAL
                        test $k = disc; and set num DISCNUMBER; and set tot DISCTOTAL
                        set -l mm (string match -r '^\s*(\d+)\s*(?:/\s*(\d+))?\s*$' -- "$v")
                        test (count $mm) -ge 2; or continue
                        if not contains -- $num $have $added
                            set n (math $n + 1)
                            printf '%s' "$mm[2]" > "$work/rescue_$n"
                            set -a args --set-tag-from-file="$num=$work/rescue_$n"
                            set -a added $num
                        end
                        if test -n "$mm[3]"; and not contains -- $tot $have $added
                            set n (math $n + 1)
                            printf '%s' "$mm[3]" > "$work/rescue_$n"
                            set -a args --set-tag-from-file="$tot=$work/rescue_$n"
                            set -a added $tot
                        end
                        continue
                    case '*'
                        # custom TXXX field: keep its own name if it's a
                        # legal Vorbis field name
                        string match -qr '^[\x20-\x3c\x3e-\x7d]+$' -- "$k"; or continue
                        set name (string upper -- "$k")
                end
            end
            contains -- $name $have $added; and continue
            set n (math $n + 1)
            printf '%s' "$v" > "$work/rescue_$n"
            set -a args --set-tag-from-file="$name=$work/rescue_$n"
            set -a added $name
        end
        # Cover art: only if the FLAC has no picture of its own.
        set -l npics (metaflac --list --block-type=PICTURE -- "$flacf" 2>/dev/null | grep -c 'type: 6')
        if test "$npics" -eq 0
            set -l vc (ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                -of default=nw=1:nk=1 -- "$probe" 2>/dev/null)
            set -l pext ""
            switch "$vc[1]"
                case mjpeg
                    set pext jpg
                case png
                    set pext png
            end
            if test -n "$pext"
                set -l pic "$work/id3pic.$pext"
                if ffmpeg -hide_banner -v error -nostdin -y -i "$probe" -map 0:v:0 -c copy -f image2 "$pic" 2>/dev/null
                    set -a args --import-picture-from="3||||$pic"
                    set -a added "cover art"
                end
            end
        end
        test (count $args) -eq 0; and return 0
        metaflac --no-utf8-convert $args -- "$flacf" 2>/dev/null; or return 1
        string join ', ' -- $added
        return 0
    end

    # ----- paths and moves -----
    # Prints FOLDER's path relative to SCANDIR, without a leading
    # STRIPPREFIX component (e.g. "Artist/Album"). Prints "" for the
    # scan root or the bare prefix folder.
    function w_reldir --inherit-variable FOLDER --inherit-variable SCANDIR --inherit-variable STRIPPREFIX
        set -l abs (realpath -m -- "$FOLDER")
        set -l base (realpath -- "$SCANDIR")
        if test "$abs" = "$base"
            echo ""
            return 0
        end
        set -l rel (string sub -s (math (string length -- "$base") + 2) -- "$abs")
        if test -n "$STRIPPREFIX"
            set rel (string replace -r '^'(string escape --style=regex -- "$STRIPPREFIX")'(/|$)' '' -- "$rel")
        end
        echo "$rel"
    end
    # Prints this album's destination under the root in $argv[1],
    # keeping its ARTIST/ALBUM position. Returns 1 and prints nothing
    # if FOLDER is the scan root, which is never moved.
    function w_dest_for
        set -l root "$argv[1]"
        set -l rel (w_reldir)
        if test -z "$rel"
            return 1
        end
        set -l dest "$root/$rel"
        # never overwrite an existing destination: add a ".dupN" suffix
        if test -e "$dest"
            set -l k 1
            while test -e "$dest.dup$k"
                set k (math $k + 1)
            end
            set dest "$dest.dup$k"
        end
        echo "$dest"
    end
    # Move the whole album folder to the destination in $argv[1]
    # (parent folders are created as needed).
    #  * Same filesystem: a single rename. Instant and atomic, with
    #    nothing to copy or verify.
    #  * Different filesystem: copy to a hidden .reflac_moving_* folder
    #    beside the destination, verify it (file count and total
    #    bytes), rename it into place, then delete the source under a
    #    hidden .reflac_trash_* name, so that an interrupted delete
    #    never leaves half an album behind. Leftovers of either kind
    #    are removed at the start of the next run.
    # Returns 0 if moved, 1 if the copy did not verify (copy removed,
    # source untouched), 2 if the copy failed.
    function w_move_album --inherit-variable FOLDER
        set -l dest "$argv[1]"
        set -l parent (dirname -- "$dest")
        mkdir -p -- "$parent"; or return 2
        if test (stat -c %d -- "$FOLDER") = (stat -c %d -- "$parent")
            if mv -T -- "$FOLDER" "$dest" 2>/dev/null
                return 0
            end
            # rename refused (e.g. bind mount): fall back to copying
        end
        set -l stage "$parent/.reflac_moving_"(random)
        if not cp -a -- "$FOLDER" "$stage"
            rm -rf -- "$stage"
            return 2
        end
        set -l src_sig (find "$FOLDER" -type f -printf '%s\n' | awk '{n++; s += $1} END {printf "%d %.0f", n, s}')
        set -l dst_sig (find "$stage"  -type f -printf '%s\n' | awk '{n++; s += $1} END {printf "%d %.0f", n, s}')
        if test "$src_sig" != "$dst_sig"
            rm -rf -- "$stage"
            return 1
        end
        if not mv -T -- "$stage" "$dest"
            rm -rf -- "$stage"
            return 2
        end
        set -l trash (dirname -- "$FOLDER")"/.reflac_trash_"(random)
        if mv -T -- "$FOLDER" "$trash"
            rm -rf -- "$trash"
        else
            rm -rf -- "$FOLDER"
        end
        return 0
    end
    # True for a file that is worthless once its folder holds no music
    # (used by --delete-empty): an empty (0-byte) file, a .txt or .lrc
    # sidecar, or OS clutter (.DS_Store, Thumbs.db, desktop.ini, ._*).
    function w_is_disposable --argument-names f
        test -f "$f"; or return 1
        test -s "$f"; or return 0
        switch (string lower -- (basename -- "$f"))
            case '*.txt' '*.lrc' .ds_store thumbs.db desktop.ini '._*'
                return 0
        end
        return 1
    end
    # True if folder $d has no subfolders and holds only disposable
    # files, or nothing at all.
    function w_dir_disposable --argument-names d
        set -l sub (find "$d" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)
        test -z "$sub"; or return 1
        for f in (find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | string split0)
            w_is_disposable "$f"; or return 1
        end
        return 0
    end
    # After an album has left, remove its now-empty parent folders
    # (e.g. the ARTIST folder), walking up toward the scan root without
    # ever removing it. rmdir only removes empty folders, so a parent
    # that still holds other albums or files is left alone and the walk
    # stops there. This is safe with parallel workers: rmdir is atomic
    # and simply fails while a sibling album exists.
    # With --delete-empty, a folder holding nothing but disposable
    # files (e.g. an artist folder with a leftover .txt) is emptied
    # first. Optional $argv[1]: the folder to start at (default:
    # FOLDER's parent).
    function w_prune_empty_parents --inherit-variable FOLDER --inherit-variable SCANDIR --inherit-variable DELETEEMPTY --inherit-variable DRY
        set -l base (realpath -- "$SCANDIR")
        set -l d (dirname -- (realpath -m -- "$FOLDER"))
        test -n "$argv[1]"; and set d (realpath -m -- "$argv[1]")
        while test "$d" != "$base"; and test "$d" != /
            # never touch anything outside the scan tree
            string match -q -- "$base/*" "$d"; or break
            if test "$DELETEEMPTY" = 1; and test "$DRY" != 1; and w_dir_disposable "$d"
                for f in (find "$d" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | string split0)
                    rm -f -- "$f"
                    w_log "DELETED            : $f (leftover in an emptied folder)"
                end
            end
            rmdir -- "$d" 2>/dev/null; or break
            w_log "PRUNE empty dir    : $d"
            set d (dirname -- "$d")
        end
    end
    # Record a transient FAIL for a track and remember that this album
    # had one, so that it is not relocated during this run.
    set -g W_ANYFAIL 0
    function w_fail
        set -g W_ANYFAIL 1
        w_state FAIL "$argv[1]" "$argv[2]"
    end

    # ----- album or loose tracks? -----
    # ALBUM mode: FOLDER is an ARTIST/ALBUM folder (two levels below
    #   the scan root, ignoring STRIPPREFIX). Every file beneath it,
    #   including disc subfolders (CD1, Disc 2…), Bonus/ and Scans/,
    #   belongs to the album: this one worker processes all of it, and
    #   the folder is quarantined or relocated as a unit.
    # LOOSE mode: FOLDER is the scan root or an ARTIST folder holding
    #   loose tracks. Only the files directly in it are processed, in
    #   place; there is no album folder to relocate, and damaged tracks
    #   are quarantined one by one.
    set -l ALBUMMODE 0
    set -l unitrel (w_reldir)
    if test -n "$unitrel"; and test (count (string split / -- "$unitrel")) -ge 2
        set ALBUMMODE 1
    end

    # ----- recover from an interrupted earlier run -----
    # A *.reflac_bak is the untouched original of a track whose ID3
    # strip was cut short. Putting it back is always safe (the strip
    # either never happened, was half-written, or will simply be
    # redone), and keeps the backup from being moved along as clutter.
    set -l depth
    test $ALBUMMODE -eq 0; and set depth -maxdepth 1
    set -l dry_restored
    set -l baks (find "$FOLDER" $depth -name '*.reflac_bak' -xtype f -print0 2>/dev/null | sort -z | string split0)
    for b in $baks
        test -f "$b"; or continue
        set -l orig (string replace -r '\.reflac_bak$' '' -- "$b")
        if test "$DRY" -eq 1
            w_log "WOULD RESTORE      : $orig (original kept from an interrupted ID3 strip)"
            set -a dry_restored "$orig"
        else if mv -f -- "$b" "$orig"
            w_log "RESTORE            : $orig (original kept from an interrupted ID3 strip)"
        end
    end

    # ----- gather the files of this album -----
    # Uses find rather than a fish glob, which would skip tracks whose
    # names start with a dot. Left out: this script's own .reflac_*
    # temp files and macOS "._*" / .AppleDouble resource forks.
    set -l entries (find "$FOLDER" $depth \( -name '.reflac_*' -o -name '._*' -o -name .AppleDouble \) -prune \
        -o -xtype f -print0 2>/dev/null | sort -z | string split0)
    set -l files
    set -l has_lossy 0
    for f in $entries
        test -f "$f"; or continue
        set -l ext (string lower (string replace -r '.*\.' '' -- "$f"))
        switch $ext
            # Possibly-lossless files are probed later (.m4a, .wma and
            # .mka can hold either kind); the rest are lossy by name.
            case flac wav wave aif aiff aifc m4a mp4 caf ape wv tta tak wma mka dsf dff
                set files $files "$f"
            case mp3 ogg oga opus aac mpc mp2 m4b
                set has_lossy 1
        end
    end
    # ----- --delete-empty: remove zero-byte tracks -----
    # An empty track holds nothing worth keeping, so it is deleted along
    # with its same-name .lrc/.txt sidecar. An album that loses only
    # some of its tracks this way is incomplete and is still
    # quarantined (phase 2). A dry run only reports.
    set -l deleted_empty
    set -l deleted_side
    if test "$DELETEEMPTY" = 1
        for f in $entries
            test -f "$f"; and not test -s "$f"; or continue
            switch (string lower (string replace -r '.*\.' '' -- "$f"))
                case flac wav wave aif aiff aifc m4a mp4 caf ape wv tta tak wma mka dsf dff mp3 ogg oga opus aac mpc mp2 m4b
                case '*'
                    continue
            end
            set -a deleted_empty "$f"
            set -l side
            for s in (string replace -r '\.[^.]*$' '' -- "$f").{lrc,LRC,txt,TXT}
                test -f "$s"; and set -a side "$s"
            end
            set -a deleted_side $side
            if test "$DRY" = 1
                w_log "WOULD DELETE       : $f (empty, 0 bytes)"
                for s in $side
                    w_log "WOULD DELETE       : $s (sidecar of an empty track)"
                end
            else
                rm -f -- "$f" $side
                w_log "DELETED            : $f (empty, 0 bytes)"
                for s in $side
                    w_log "DELETED            : $s (sidecar of an empty track)"
                end
            end
        end
        # Take the deleted tracks off the work list, and look again for
        # lossy files among what is left.
        if test (count $deleted_empty) -gt 0
            set -l keep
            for f in $files
                contains -- "$f" $deleted_empty; or set -a keep "$f"
            end
            set files $keep
            set has_lossy 0
            for f in $entries
                test -f "$f"; or continue
                contains -- "$f" $deleted_empty; and continue
                switch (string lower (string replace -r '.*\.' '' -- "$f"))
                    case mp3 ogg oga opus aac mpc mp2 m4b
                        set has_lossy 1
                        break
                end
            end
        end
    end

    if test (count $files) -eq 0; and test $has_lossy -eq 0; and test (count $deleted_empty) -gt 0
        # Every track was an empty file, so no music is left here.
        # Remove the folder if all that remains is disposable (.txt,
        # .lrc, empty files, OS clutter). If anything else remains
        # (artwork, logs, cue sheets…), an album is quarantined with a
        # report instead (phase 2), so that nothing of value is
        # deleted, and a loose folder is left alone.
        set -l rest
        set -l subdirs
        if test $ALBUMMODE -eq 1
            set rest (find "$FOLDER" -type f -print0 2>/dev/null | string split0)
        else
            set rest (find "$FOLDER" -maxdepth 1 -type f -print0 2>/dev/null | string split0)
            set subdirs (find "$FOLDER" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)
        end
        set -l junk
        set -l keepers
        for f in $rest
            contains -- "$f" $deleted_empty $deleted_side; and continue
            if w_is_disposable "$f"
                set -a junk "$f"
            else
                set -a keepers "$f"
            end
        end
        if test (count $keepers) -eq 0; and test -z "$subdirs"
            if test "$DRY" = 1
                w_final "WOULD DELETE folder: $FOLDER (no audio left — every track was empty; "(count $junk)" leftover .txt/.lrc/empty files)"
                exit 0
            end
            for f in $junk
                rm -f -- "$f"
                w_log "DELETED            : $f (leftover, no audio left)"
            end
            if test $ALBUMMODE -eq 1
                find "$FOLDER" -depth -type d -empty -delete 2>/dev/null
            else if test (realpath -- "$FOLDER") != (realpath -- "$SCANDIR")
                rmdir -- "$FOLDER" 2>/dev/null
            end
            if test -e "$FOLDER"
                w_final "KEEP  (no audio)   : $FOLDER — empty tracks deleted, but the folder could not be removed"
            else
                w_final "DELETED folder     : $FOLDER (no audio left — every track was empty)"
                w_prune_empty_parents
            end
            exit 0
        end
        if test $ALBUMMODE -eq 0
            w_final "KEEP  (loose)      : $FOLDER — empty tracks deleted; other files remain"
            exit 0
        end
        w_log "NO AUDIO LEFT      : $FOLDER — every track was empty; kept for review: "(string join ', ' -- (string replace -- "$FOLDER/" '' $keepers))
    end

    if test (count $files) -eq 0
        # Nothing here can be converted. An album of purely lossy audio
        # (.mp3, .ogg…) still has to go to the Lossy tree, so carry on
        # with an empty work list: phases 1–3 have nothing to do and
        # phase 4 makes the move. With no audio at all, stop here.
        if test $has_lossy -eq 0; and test (count $deleted_empty) -eq 0
            w_final "EMPTY folder: $FOLDER"
            exit 0
        end
        if test $ALBUMMODE -eq 0
            w_final "SKIP  (loose lossy): $FOLDER — lossy tracks outside an ARTIST/ALBUM folder are left in place"
            exit 0
        end
        test $has_lossy -eq 1; and w_log "LOSSY-ONLY album   : $FOLDER"
    end

    # RAM workspace for this album (dry-run strip tests in phase 1,
    # encoder output in phase 3). Removed on every exit path.
    set -l ramdir (mktemp -d "$RUNTMP/w.XXXXXX")
    if test -z "$ramdir"; or not test -d "$ramdir"
        w_final "FAIL  (ramdir)     : $FOLDER"
        exit 1
    end
    set -g W_RAMDIR "$ramdir"

    # ----- per-track state, one slot per file -----
    # fstatus[i]  new | ok | stripped | lossy | asis | notaudio |
    #             unrecoverable | quarantined | pending (dry run) |
    #             prior | prior_lossy | prior_asis
    #             asis   = lossless audio that would not survive the
    #                      conversion intact; left untouched
    #             prior* = finished in an earlier run (state log)
    # freason[i]  why a track is unrecoverable, in plain words, for
    #             CORRUPT_TRACKS.txt and the quarantine list
    # fasis[i]    why a track is left as it is
    # fcodec[i]   codec found in phase 1, reused in phase 3 so that
    #             ffprobe never runs twice on the same file
    # fsrc[i]     the file the phase-3 encoder reads: the track itself,
    #             or in a dry run the stripped RAM copy of a track that
    #             carries an ID3 tag (a dry run never touches the library)
    set -l fcount (count $files)
    set -l fstatus
    set -l freason
    set -l fcodec
    set -l fsrc
    set -l fasis
    for i in (seq $fcount)
        set fstatus[$i] new
        set freason[$i] ""
        set fcodec[$i] ""
        set fsrc[$i] $files[$i]
        set fasis[$i] ""
    end

    # ----- what the state log already knows -----
    # An album still in the scan tree has not been relocated yet, so
    # the controller queues it even if all of its tracks are finished.
    # To keep that cheap, look up each track's latest state entry
    # once: finished tracks skip the integrity checks and the encoder
    # and go straight to the relocation decision.
    set -l prior_lines
    if test -s "$STATE"
        # Lines are STATUS<TAB>size:mtime<TAB>path. Take every line
        # whose path lies inside this folder.
        set prior_lines (grep -F -- \t"$FOLDER"/ "$STATE" 2>/dev/null)
        # A loose folder owns only the files directly in it (the scan
        # root would otherwise match the whole log).
        if test $ALBUMMODE -eq 0; and test (count $prior_lines) -gt 0
            set prior_lines (string match -r -e -- \t(string escape --style=regex -- "$FOLDER")'/[^/]*$' $prior_lines)
        end
    end
    set -l fkeys
    set -l fprior
    for i in (seq $fcount)
        set fkeys[$i] (w_key "$files[$i]")
        set fprior[$i] ""
    end
    if test (count $prior_lines) -gt 0
        for i in (seq $fcount)
            set -l f $files[$i]
            set -l k $fkeys[$i]
            for line in $prior_lines
                set -l parts (string split \t -- $line)
                test (count $parts) -ge 3; or continue
                set -l lpath (string join \t -- $parts[3..-1])
                if test "$parts[2]" = "$k"; and test "$lpath" = "$f"
                    # keep scanning: the log is append-only, so the
                    # last matching entry is the current one
                    set fprior[$i] $parts[1]
                end
            end
        end
    end

    # ============================================================
    #  PHASE 1 — CHECK every track (and strip ID3 tags from FLACs)
    # ============================================================
    set -l unrecoverable 0
    for i in (seq $fcount)
        set -l f $files[$i]
        # Dry run: this track's .reflac_bak would be restored first, so
        # the half-written file on disk says nothing about the outcome.
        if contains -- "$f" $dry_restored
            set fstatus[$i] pending
            continue
        end
        set -l ext (string lower (string replace -r '.*\.' '' -- "$f"))
        # Finished in an earlier run and unchanged since (same
        # size:mtime key): nothing to check again. --restrip turns
        # this off for FLACs, so that the ID3 strip can re-examine them.
        switch "$fprior[$i]"
            case DONE SKIPMAX
                if test "$RESTRIP" -eq 1; and test "$ext" = flac
                    # --restrip: fall through and re-examine this FLAC
                else
                    set fstatus[$i] prior
                    set fcodec[$i] flac
                    continue
                end
            case SKIPLOSSY
                set fstatus[$i] prior_lossy
                continue
            case SKIPASIS SKIPFLOAT
                set fstatus[$i] prior_asis
                continue
        end
        set -l codec ""
        # Shortcut: a .flac file that starts with the FLAC magic "fLaC"
        # is a FLAC, no ffprobe needed. Anything else (other extensions,
        # a .flac with an ID3 tag in front, odd files) gets the full
        # ffprobe inspection below.
        if test "$ext" = flac
            # Captured into a variable and compared quoted: for a
            # damaged file that starts with NUL bytes the substitution
            # is empty, and an unquoted empty expansion would make
            # `test` lose an argument.
            set -l magic (head -c 4 -- "$f" 2>/dev/null | string collect)
            if test "$magic" = fLaC
                set codec flac
            end
        end
        if test -z "$codec"
            # Which audio streams does ffprobe find? None at all means
            # the file is unreadable (damaged or truncated), not lossy,
            # and sends the album to quarantine. The one exception is a
            # video-only .mp4 (e.g. animated cover art), which simply is
            # not a track and is ignored.
            set -l acodecs (ffprobe -v error -select_streams a -show_entries stream=codec_name \
                -of default=nw=1:nk=1 -- "$f" 2>/dev/null | string replace -ra '[^A-Za-z0-9_]' '' \
                | string match -r -- '.+')
            if test (count $acodecs) -eq 0
                if test "$ext" = mp4
                    set fstatus[$i] notaudio
                else
                    set fstatus[$i] unrecoverable
                    set freason[$i] "unreadable: no audio stream found (damaged or truncated file)"
                    set unrecoverable 1
                end
                continue
            end
            # Lossless if any audio stream is; the first stream is the
            # one that gets converted.
            set -l lossless 0
            for c in $acodecs
                switch $c
                    case flac alac 'pcm_*' ape tak tta wavpack wmalossless shorten 'dsd_*'
                        set lossless 1
                end
            end
            if test $lossless -eq 0
                set fstatus[$i] lossy
                continue
            end
            set codec $acodecs[1]
        end
        # FLAC inside another container (.mka, .m4a…) is converted like
        # any other non-FLAC source; only a real .flac file takes the
        # native FLAC path (flac -t, ID3 strip, metadata kept as-is).
        if test "$codec" = flac; and test "$ext" != flac
            set codec "flac-in-$ext"
        end
        set fcodec[$i] "$codec"
        # Lossless audio that FLAC cannot hold exactly is left as it is:
        # converting would alter the audio and then delete the original.
        switch "$codec"
            case 'pcm_f*' 'pcm_s64*' 'pcm_u64*'
                set fstatus[$i] asis
                set fasis[$i] "floating-point audio; FLAC stores whole-number samples only"
                continue
            case 'dsd_*'
                set fstatus[$i] asis
                set fasis[$i] "DSD audio; FLAC stores PCM, so converting would resample it"
                continue
            case wavpack
                # WavPack "hybrid" mode is lossy unless its .wvc correction
                # file is applied, which ffmpeg cannot do.
                if test -e (string replace -r '\.[^.]*$' '' -- "$f").wvc
                    set fstatus[$i] asis
                    set fasis[$i] "WavPack hybrid with a .wvc correction file; only WavPack's own tools can restore it losslessly"
                    continue
                end
                switch (w_wv_mode "$f")
                    case hybrid
                        set fstatus[$i] lossy
                        continue
                    case unknown
                        set fstatus[$i] asis
                        set fasis[$i] "unrecognised WavPack header; can't confirm it is lossless"
                        continue
                end
        end
        # ffmpeg writes FLAC with at most 24-bit integer samples, so a
        # deeper integer source, or float audio in any codec (e.g. float
        # WavPack), would silently lose precision. Leave those untouched.
        if test "$codec" != flac
            set -l sinfo (ffprobe -v error -select_streams a:0 \
                -show_entries stream=sample_fmt,bits_per_raw_sample \
                -of default=nw=1 -- "$f" 2>/dev/null)
            set -l sfmt (string match -r '^sample_fmt=(.+)$' -- $sinfo)[2]
            set -l sbits (string match -r '^bits_per_raw_sample=([0-9]+)$' -- $sinfo)[2]
            if string match -qr '^(flt|dbl)' -- "$sfmt"
                set fstatus[$i] asis
                set fasis[$i] "floating-point audio; FLAC stores whole-number samples only"
                continue
            else if test -n "$sbits"; and test "$sbits" -gt 24
                set fstatus[$i] asis
                set fasis[$i] "$sbits-bit integer audio; converting would cut it down to 24-bit"
                continue
            end
        end
        # Non-FLAC lossless sources (ALAC, WAV, AIFF…) get a full decode
        # test; a damaged one quarantines the album just like a bad FLAC.
        # (Only FLAC inputs get the ID3 strip path.)
        if test "$codec" != flac
            set -l bad (w_decode_check "$f" "$ramdir/decode_err")
            if test -n "$bad"
                set fstatus[$i] unrecoverable
                set freason[$i] "$bad"
                set unrecoverable 1
            else
                set fstatus[$i] ok
            end
            continue
        end

        # From here on the file is a real FLAC. Look for an ID3 tag:
        # v2 at the very start ("ID3") or v1 in the last 128 bytes
        # ("TAG"). flac's decoder tolerates one (the test passes with
        # a warning), but its encoder refuses a file with an ID3v2
        # tag. ID3v1 does not always block encoding, but it does not
        # belong in a FLAC and would otherwise survive untouched in a
        # track that is already at maximum compression. (Compared
        # quoted, for the same reason as the "fLaC" check above.)
        set -l has_id3 0
        set -l head3 (head -c 3 -- "$f" 2>/dev/null | string collect)
        if test "$head3" = ID3
            set has_id3 1
        else
            set -l tail3 (tail -c 128 -- "$f" 2>/dev/null | head -c 3 | string collect)
            if test "$tail3" = TAG
                set has_id3 1
            end
        end

        # Decode test. flac's messages are kept so that the report can
        # say exactly what is wrong with the file.
        set -l flacmsg (flac -ts -- "$f" 2>&1)
        set -l decode_ok 0
        test $status -eq 0; and set decode_ok 1
        set -l flacerr (printf '%s\n' $flacmsg | grep -i -m1 error | string trim)
        test -z "$flacerr"
        and set flacerr (printf '%s\n' $flacmsg | grep -v '^ *$' | tail -n 1 | string trim)

        if test $decode_ok -eq 1; and test $has_id3 -eq 0
            # Decodes cleanly and has no ID3 tag: the file is good.
            set fstatus[$i] ok
            continue
        end

        # Decode failed and there is no ID3 tag: nothing to strip, so
        # the damage is in the FLAC data itself.
        if test $has_id3 -eq 0
            set fstatus[$i] unrecoverable
            if test (stat -c %s -- "$f" 2>/dev/null; or echo 0) -eq 0
                set freason[$i] "file is empty (0 bytes) — nothing was ever written to it (incomplete download or copy?)"
            else
                set freason[$i] (w_flac_reason "$f" $flacmsg)
            end
            set unrecoverable 1
            continue
        end

        # There is an ID3 tag (and the decode test may have failed too).
        if test "$STRIP" -eq 0
            # --no-strip: the tag has to stay, yet the encoder would
            # refuse the file on every run. Mark it unrecoverable, so
            # that the album is quarantined instead of failing forever.
            set fstatus[$i] unrecoverable
            if test $decode_ok -eq 0
                set freason[$i] (w_flac_reason "$f" $flacmsg)
            else
                set freason[$i] "ID3 tag present (would block re-encode); repair disabled by --no-strip"
            end
            set unrecoverable 1
            continue
        end

        # Real run: strip the track in place, keeping a .reflac_bak to
        # restore if the strip does not fix it. Dry run: strip a RAM
        # copy instead, so that the prediction is exact but nothing in
        # the library changes; phase 3's test encode reads that copy.
        set -l target "$f"
        set -l bak "$f.reflac_bak"
        if test "$DRY" -eq 1
            set target "$ramdir/dry_$i.flac"
            if not cp -- "$f" "$target"
                w_log "FAIL  (dry copy)   : $f"
                set fstatus[$i] unrecoverable
                set freason[$i] "could not copy track to RAM for a dry-run strip test"
                set unrecoverable 1
                continue
            end
        else if not cp -p -- "$f" "$bak"
            w_log "FAIL  (bak copy)   : $f"
            set fstatus[$i] unrecoverable
            set freason[$i] "could not create backup copy before ID3 strip attempt"
            set unrecoverable 1
            continue
        end

        # Before the strip discards it, capture what the ID3 tag holds
        # (read back after the strip, below, by w_id3_rescue).
        set -l id3probe "$ramdir/id3probe_$i.mp3"
        w_id3_probe "$f" "$id3probe"

        # id3v2 doesn't accept '--' end-of-options; pass the path bare.
        id3v2 --delete-all "$target" >/dev/null 2>&1
        set -l rc $status

        set -l strip_ok 0
        set -l post_reason ""
        if test $rc -eq 0
            set -l flacmsg2 (flac -ts -- "$target" 2>&1)
            if test $status -eq 0
                set strip_ok 1
            else
                # Describe the damage that remains without the ID3 tag
                # (now, while the stripped file still exists).
                set post_reason (w_flac_reason "$target" $flacmsg2)
            end
        end
        if test $strip_ok -eq 1
            # The strip worked (or removed a redundant tag from a file
            # that already decoded cleanly). Before the backup goes,
            # rescue anything the ID3 tag held that the FLAC's own tags
            # lack. In a dry run this touches the RAM copy only.
            set -l rescued (w_id3_rescue "$id3probe" "$target" "$ramdir")
            if test $status -ne 0
                w_log "WARN  ID3 rescue could not write tags (stripped file kept as is): $f"
            else if test -n "$rescued"
                if test "$DRY" -eq 1
                    w_log "WOULD RESCUE (ID3 -> FLAC tags): $f — $rescued"
                else
                    w_log "RESCUE (ID3 -> FLAC tags): $f — added $rescued"
                end
            end
            rm -f -- "$id3probe"
            if test "$DRY" -eq 1
                set fsrc[$i] "$target"
            else
                rm -f -- "$bak"
            end
            set fstatus[$i] stripped
        else
            # Still broken: restore the original and mark the track
            # unrecoverable.
            if test "$DRY" -eq 1
                rm -f -- "$target"
            else
                mv -f -- "$bak" "$f"
            end
            set fstatus[$i] unrecoverable
            if test $rc -ne 0
                set freason[$i] "id3v2 tag strip failed (exit status $rc); original restored"
            else
                set freason[$i] "even without its ID3 tag: $post_reason"
            end
            set unrecoverable 1
        end
    end

    # ============================================================
    #  PHASE 2 — DECIDE: quarantine, or go on to convert
    # ============================================================
    # An album that lost tracks to --delete-empty is incomplete:
    # quarantine it, listing what was deleted.
    if test $ALBUMMODE -eq 1; and test (count $deleted_empty) -gt 0
        set unrecoverable 1
    end

    if test $unrecoverable -eq 1; and test $ALBUMMODE -eq 0
        # Loose tracks are independent of each other: quarantine only
        # the damaged ones (mirroring their folder under the corrupt
        # root) and carry on converting the rest in place.
        set -l qdir "$CORRUPTROOT"
        set -l reldir (w_reldir)
        test -n "$reldir"; and set qdir "$CORRUPTROOT/$reldir"
        for i in (seq $fcount)
            test "$fstatus[$i]" = unrecoverable; or continue
            set -l p $files[$i]
            set -l name (basename -- "$p")
            set -l qdest "$qdir/$name"
            if test -e "$qdest"
                set -l stem (string replace -r '\.[^.]*$' '' -- "$name")
                set -l sfx (string match -r '\.[^.]*$' -- "$name")
                set -l k 1
                while test -e "$qdir/$stem.dup$k$sfx"
                    set k (math $k + 1)
                end
                set qdest "$qdir/$stem.dup$k$sfx"
            end
            set fstatus[$i] quarantined
            if test "$DRY" -eq 1
                w_log "WOULD QUARANTINE   : $p  ->  $qdest — $freason[$i]"
                continue
            end
            mkdir -p "$qdir"
            if not mv -- "$p" "$qdest"
                w_log "FAIL  (track quarantine): $p"
                w_fail $fkeys[$i] "$p"
                continue
            end
            begin
                echo "$name  (from $FOLDER, "(date '+%Y-%m-%d %H:%M:%S')")"
                echo "      reason: $freason[$i]"
            end >> "$qdir/CORRUPT_TRACKS.txt" 2>/dev/null
            w_log "TRACK CORRUPT -> moved: $p  ->  $qdest"
            w_state CORRUPT (w_key "$qdest") "$p"
            w_quar "$p" "$qdest" (string replace -a \t ' ' -- "$freason[$i]")
        end
        set unrecoverable 0
    end

    if test $unrecoverable -eq 1
        # Album: move all of it (every disc, artwork, logs) to the
        # corrupt root, recreating ARTIST/ALBUM under it.
        set -l dest (w_dest_for "$CORRUPTROOT")
        if test $status -ne 0
            w_final "FAIL  (corrupt move): refusing to relocate the scan root itself: $FOLDER"
            exit 0
        end

        if test "$DRY" -eq 1
            w_final "WOULD MOVE ALBUM   : $FOLDER  ->  $dest"
            for i in (seq $fcount)
                test "$fstatus[$i]" = unrecoverable; and \
                    w_log "  corrupt track: "(string replace -- "$FOLDER/" '' "$files[$i]")" — $freason[$i]"
            end
            for f in $deleted_empty
                w_log "  empty track (would be deleted): "(string replace -- "$FOLDER/" '' "$f")
            end
            exit 0
        end

        w_move_album "$dest"
        switch $status
            case 0
                w_final "ALBUM CORRUPT -> moved: $FOLDER  ->  $dest"
                # Write a report inside the quarantined album saying
                # which tracks are damaged and in what way. Tracks are
                # named by their path inside the album, so a multi-disc
                # album reads "CD2/03. Track.flac".
                set -l report "$dest/CORRUPT_TRACKS.txt"
                begin
                    echo "Corrupt album report — written by reflac.fish"
                    echo "Date     : "(date '+%Y-%m-%d %H:%M:%S')
                    echo "Original : $FOLDER"
                    echo "Moved to : $dest"
                    echo ""
                    set -l nbad 0
                    for i in (seq $fcount)
                        test "$fstatus[$i]" = unrecoverable; and set nbad (math $nbad + 1)
                    end
                    if test $nbad -gt 0
                        echo "Corrupted tracks:"
                        for i in (seq $fcount)
                            test "$fstatus[$i]" = unrecoverable; or continue
                            echo "  "(string replace -- "$FOLDER/" '' "$files[$i]")
                            echo "      reason: $freason[$i]"
                        end
                        echo ""
                    end
                    if test (count $deleted_empty) -gt 0
                        echo "Empty tracks (0 bytes) — deleted by --delete-empty; this album is"
                        echo "missing them (incomplete download or copy?):"
                        for f in $deleted_empty
                            echo "  "(string replace -- "$FOLDER/" '' "$f")
                        end
                        echo ""
                    end
                    if test $fcount -eq 0; and test $has_lossy -eq 0
                        echo "No audio is left in this album; the remaining files were kept"
                        echo "for review."
                    else
                        echo "All other files in this album passed their integrity"
                        echo "checks and were moved along with it untouched."
                    end
                end > "$report" 2>/dev/null
                # Record every track of the album as CORRUPT in the
                # state log and the quarantine list, as a complete
                # inventory of what was moved.
                for i in (seq $fcount)
                    set -l p $files[$i]
                    set -l moved "$dest/"(string replace -- "$FOLDER/" '' "$p")
                    set -l reason $fstatus[$i]
                    if test "$fstatus[$i]" = unrecoverable; and test -n "$freason[$i]"
                        # the quarantine list is tab-separated, so
                        # flatten any tab in the reason
                        set reason (string replace -a \t ' ' -- "$freason[$i]")
                    end
                    w_state CORRUPT (w_key "$moved") "$p"
                    w_quar "$p" "$moved" "$reason"
                end
                w_prune_empty_parents
            case 1
                w_final "FAIL  (album move verify): $FOLDER — copy mismatch, destination removed, source untouched"
            case 2
                w_final "FAIL  (album move copy): $FOLDER"
        end
        exit 0
    end

    # ============================================================
    #  PHASE 3 — CONVERT
    #  Every track passed its integrity check. Encode what needs it.
    # ============================================================
    for i in (seq $fcount)
        set -l f $files[$i]
        set -l st $fstatus[$i]
        set -l key $fkeys[$i]
        # The ID3 strip in phase 1 rewrote the file, so its key changed.
        test "$st" = stripped; and set key (w_key "$f")

        # Finished in an earlier run: nothing to redo, the album is
        # only here to be relocated.
        if test "$st" = prior
            w_log "SKIP  (prior)      : $f"
            continue
        end
        if test "$st" = prior_lossy
            w_log "SKIP  (lossy,prior): $f"
            continue
        end
        if test "$st" = prior_asis
            w_log "SKIP  (as-is,prior): $f"
            continue
        end
        if test "$st" = asis
            w_log "SKIP  (kept as is) : $f — $fasis[$i]; left untouched"
            w_state SKIPASIS "$key" "$f"
            continue
        end
        # A damaged loose track, already moved to the corrupt root.
        if test "$st" = quarantined
            continue
        end
        if test "$st" = pending
            w_log "WOULD RE-CHECK     : $f (after restoring its .reflac_bak)"
            continue
        end
        if test "$st" = notaudio
            w_log "SKIP  (no audio)   : $f — no audio stream (video/art only); left as is"
            continue
        end

        if test "$st" = lossy
            w_log "SKIP  (lossy)      : $f"
            w_state SKIPLOSSY "$key" "$f"
            continue
        end
        set -l codec $fcodec[$i]

        # Dry-run answers that need no encoding:
        if test "$codec" != flac
            # A non-FLAC source always converts; no test encode needed.
            if test "$DRY" -eq 1
                w_log "WOULD CONVERT      : $f  [codec=$codec, pre=$st]"
                continue
            end
        else if test "$DRY" -eq 1; and test "$FORCE" -eq 1
            # A FLAC with --force always converts.
            w_log "WOULD CONVERT      : $f  [codec=$codec, pre=$st]"
            continue
        end

        # ----- encode into RAM -----
        # The encoder reads the track straight from the library; only
        # its output lives in the RAM workspace.
        set -l work "$ramdir/w_"(random)
        mkdir -p "$work"
        set -l out "$work/out.flac"
        set -l tagnote ""
        set -l repairnote ""

        if test "$codec" = flac
            # ===== FLAC -> FLAC (flac keeps the metadata itself) =====
            # One encode is both the "already at maximum?" size test
            # and, if the track is worth converting, the final output.
            # -V makes flac verify the result against the source while
            # encoding, so no separate `flac -t` pass is needed.
            # Some valid FLACs cannot be re-encoded directly: flac
            # refuses input whose header lacks the track length (as
            # written by streaming encoders). Those are rebuilt from a
            # decode, with every metadata block copied byte for byte.
            set -l how native
            set -l note ""
            if not flac --silent -V -8 -e -p \
                    -o "$out" -- "$fsrc[$i]" 2>"$work/enc_err"
                set -l why (head -n 1 "$work/enc_err" 2>/dev/null | string replace -r '^.*?ERROR: ' '' | string trim)
                rm -f -- "$out"
                if w_flac_via_decode "$fsrc[$i]" "$out" "$work"
                    set how decode
                    if string match -qi '*unknown total samples*' -- "$why"
                        set note "header repaired: adds the missing track length + checksum"
                    else
                        set note "re-encoded from a decode (flac refused it directly: $why)"
                    end
                else
                    w_log "FAIL  (encode)     : $f — $why"
                    test "$DRY" -eq 0; and w_fail "$key" "$f"
                    rm -rf "$work"
                    continue
                end
            end
            # A header without the audio's checksum (MD5) means the track
            # can never be verified later. Rewrite it so that it gains
            # one, even if it is already at maximum compression.
            set -l src_md5 (metaflac --show-md5sum -- "$fsrc[$i]" 2>/dev/null)
            if test -z "$note"; and test "$src_md5" = 00000000000000000000000000000000
                set note "header repaired: adds the missing checksum"
            end

            # Already at maximum? Skip the track if the new file is not
            # at least 0.5 % smaller (unless --force is set or the
            # header needs repairing).
            if test "$FORCE" -eq 0; and test -z "$note"
                set -l old (stat -c %s -- "$fsrc[$i]")
                set -l new (stat -c %s -- "$out")
                if test (math -s0 "$new * 1000") -ge (math -s0 "$old * 995")
                    w_log "SKIP  (already max): $f"
                    # A dry run must not record SKIPMAX for a track it
                    # stripped only in RAM: the real run still has to
                    # strip it, and a matching SKIPMAX entry would make
                    # it skip the track untouched.
                    if test "$DRY" -eq 0; or test "$st" != stripped
                        w_state SKIPMAX "$key" "$f"
                    end
                    rm -rf "$work"
                    continue
                end
            end

            if test "$DRY" -eq 1
                set -l extra ""
                test -n "$note"; and set extra ", $note"
                w_log "WOULD CONVERT      : $f  [codec=$codec, pre=$st$extra]"
                rm -rf "$work"
                continue
            end

            # Every tag and picture must survive. If the direct encode
            # lost one, redo it from a decode, which copies the metadata
            # blocks verbatim.
            set -l src_counts (w_meta_counts "$f")
            set -l out_counts (w_meta_counts "$out")
            if test "$src_counts" != "$out_counts"; and test $how = native
                rm -f -- "$out"
                if w_flac_via_decode "$f" "$out" "$work"
                    set how decode
                    set out_counts (w_meta_counts "$out")
                    test -z "$note"; and set note "metadata copied block-for-block"
                end
            end
            if test "$src_counts" != "$out_counts"
                w_log "FAIL  (metadata)   : $f  (tags pictures: source=$src_counts output=$out_counts)"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
            test -n "$note"; and set repairnote "$note"
        else
            # ===== any other lossless source -> FLAC (via ffmpeg) =====
            if not ffmpeg -hide_banner -loglevel error -nostdin \
                    -i "$f" -map 0:a:0 -map 0:v? \
                    -c:a flac -compression_level 12 \
                    -c:v copy -disposition:v attached_pic \
                    -map_metadata 0 -fflags +bitexact -flags:a +bitexact \
                    "$out" 2>/dev/null
                w_log "FAIL  (encode)     : $f"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
            # Re-encode ffmpeg's output with flac itself at maximum
            # settings; -V verifies it while encoding. Should that
            # fail, ffmpeg's own FLAC is used instead, provided it
            # passes `flac -t`.
            set -l out2 "$work/out2.flac"
            if flac --silent --totally-silent -V -8 -e -p \
                    -o "$out2" -- "$out" 2>/dev/null
                mv -f "$out2" "$out"
            else if not flac -t --totally-silent -- "$out" 2>/dev/null
                w_log "FAIL  (flac -t)    : $f"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
            # Standard Vorbis names for ffmpeg's tag keys (MusicBrainz IDs,
            # sort fields), number/total split, container junk dropped.
            set tagnote (w_fix_tags "$out" (string lower (string replace -r '.*\.' '' -- "$f")))
            if test $status -ne 0
                w_log "FAIL  (tag cleanup): $f"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
            # APEv2 cover art (APE, WavPack…) reaches FLAC as picture type
            # 0 "Other": mark the front cover as the front cover.
            if not w_fix_cover_type "$f" "$out" "$work"
                w_log "FAIL  (cover type) : $f"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
        end

        # ----- put the new file in place -----
        set -l dir (dirname -- "$f")
        set -l base (basename -- "$f")
        set -l stem (string replace -r '\.[^.]*$' '' -- "$base")
        set -l final "$dir/$stem.flac"
        # Converting x.wav or x.m4a to x.flac while an x.flac already
        # sits beside it: overwrite that one only if it holds the same
        # audio (left by an interrupted earlier conversion of this very
        # file). A different recording that merely shares the name is
        # never overwritten.
        if test "$final" != "$f"; and test -e "$final"
            set -l md5_new (metaflac --show-md5sum -- "$out" 2>/dev/null)
            set -l md5_old (metaflac --show-md5sum -- "$final" 2>/dev/null)
            if test -z "$md5_new"; or test "$md5_new" != "$md5_old"; or test "$md5_new" = 00000000000000000000000000000000
                w_log "FAIL  (name clash) : $f — a different $final already exists"
                w_fail "$key" "$f"
                rm -rf "$work"
                continue
            end
        end
        set -l tmpf "$dir/.reflac_tmp_"(random)".flac"
        if not cp -- "$out" "$tmpf"
            w_log "FAIL  (writeback)  : $f"
            w_fail "$key" "$f"
            rm -f "$tmpf"
            rm -rf "$work"
            continue
        end
        touch -r "$f" "$tmpf" 2>/dev/null
        # rename() replaces the destination atomically, so there is no
        # moment at which the track exists only as the hidden temp file.
        if not mv -f -- "$tmpf" "$final"
            w_log "FAIL  (writeback rename): $f"
            w_fail "$key" "$f"
            rm -f "$tmpf"
            rm -rf "$work"
            continue
        end
        # Non-FLAC source: delete it only now that its FLAC is in place.
        if test "$final" != "$f"
            rm -f -- "$f"
        end

        set -l newkey (w_key "$final")
        # original size (before any ID3 strip) -> converted size
        w_bytes (string split -f1 : -- $fkeys[$i]) (string split -f1 : -- $newkey)
        set -l notes "$codec -> flac"
        test "$st" = stripped; and set notes "$notes, ID3 stripped"
        test -n "$repairnote"; and set notes "$notes, $repairnote"
        test -n "$tagnote"; and set notes "$notes, tags: $tagnote"
        w_log "OK    ($notes): $final"
        w_state DONE "$newkey" "$final"
        rm -rf "$work"
    end


    # ----- stray temp files from an interrupted write-back -----
    # A hidden .reflac_tmp_* is a converted track that was never renamed
    # into place. If a FLAC beside it holds the same audio (same MD5),
    # or it is an unreadable partial copy, it is junk. Otherwise it may
    # be the only copy of a track: keep it, warn, and hold the album
    # back.
    set -l stray_keep 0
    set -l tmps
    if test $ALBUMMODE -eq 1
        set tmps (find "$FOLDER" -type f -name '.reflac_tmp_*' 2>/dev/null)
    else
        set tmps (find "$FOLDER" -maxdepth 1 -type f -name '.reflac_tmp_*' 2>/dev/null)
    end
    for t in $tmps
        set -l tmd5 (metaflac --show-md5sum -- "$t" 2>/dev/null)
        set -l junk 0
        if test -z "$tmd5"; or test "$tmd5" = 00000000000000000000000000000000
            set junk 1
        else
            for g in (dirname -- "$t")/*.flac
                set -l gmd5 (metaflac --show-md5sum -- "$g" 2>/dev/null)
                if test "$gmd5" = "$tmd5"
                    set junk 1
                    break
                end
            end
        end
        if test $junk -eq 1
            if test "$DRY" -eq 1
                w_log "WOULD DELETE       : $t (stray temp: duplicate or partial copy)"
            else
                rm -f -- "$t"
                w_log "CLEANUP            : $t (stray temp: duplicate or partial copy)"
            end
        else
            set stray_keep 1
            w_log "WARN  stray temp file holds audio found nowhere else — it may be the only copy of a track; inspect it: $t"
        end
    end

    # ============================================================
    #  PHASE 4 — RELOCATE the finished album out of the scan tree
    #  Only if every track was converted or legitimately skipped
    #  (already at maximum compression counts) and nothing FAILed.
    #    any lossy audio at all  ->  <LOSSYROOT>/ARTIST/ALBUM/
    #    all lossless            ->  <FLACEDROOT>/ARTIST/ALBUM/
    #  Lossy audio is recognised two ways: a probed file whose
    #  streams are lossy (e.g. AAC in an .m4a), or any file in the
    #  album with a lossy extension (.mp3, .ogg…), noted while
    #  gathering. Loose tracks have no album folder and stay put.
    # ============================================================
    if test $ALBUMMODE -eq 0
        w_final "KEEP  (loose)      : $FOLDER — tracks outside an ARTIST/ALBUM folder are converted in place, not relocated"
        exit 0
    end
    for i in (seq $fcount)
        if test "$fstatus[$i]" = lossy; or test "$fstatus[$i]" = prior_lossy
            set has_lossy 1
            break
        end
    end
    set -l destroot "$FLACEDROOT"
    set -l destlabel FLACed
    if test $has_lossy -eq 1
        set destroot "$LOSSYROOT"
        set destlabel Lossy
    end

    set -l dest (w_dest_for "$destroot")
    if test $status -ne 0
        # the files sit in the scan root itself, which is never moved
        exit 0
    end
    if test $stray_keep -eq 1
        w_final "KEEP  (stray temp) : $FOLDER — not moved to $destlabel until the WARN above is resolved"
        exit 0
    end
    if test "$DRY" -eq 1
        w_final "WOULD MOVE ($destlabel): $FOLDER  ->  $dest"
        exit 0
    end
    if test "$W_ANYFAIL" -ne 0
        w_final "KEEP  (had FAILs)  : $FOLDER — not moved to $destlabel; rerun to retry"
        exit 0
    end
    w_move_album "$dest"
    switch $status
        case 0
            w_final "ALBUM DONE -> moved ($destlabel): $FOLDER  ->  $dest"
            w_prune_empty_parents
        case 1
            w_final "FAIL  ($destlabel move verify): $FOLDER — copy mismatch, destination removed, source untouched"
        case 2
            w_final "FAIL  ($destlabel move copy): $FOLDER"
    end
    exit 0
end

# =====================================================================
#  CONTROLLER MODE
#  Parses the options, takes the run lock, finds every album, starts
#  the workers and prints the summary.
# =====================================================================
set -g SELF (realpath (status filename))

# ----- terminal colors -----
# Only on a real terminal: never when output is piped or redirected,
# with NO_COLOR set (no-color.org), or on TERM=dumb. Workers print
# through GNU parallel's pipe and can't test for a terminal
# themselves, so the decision reaches them in REFLAC_COLOR. The run
# log is always plain text (the summary is counted from it with grep).
set -gx REFLAC_COLOR 0
set -g COLOR_ERR 0
if test -z "$NO_COLOR"; and test "$TERM" != dumb
    test -t 1; and set REFLAC_COLOR 1
    test -t 2; and set COLOR_ERR 1
end
# Print a line in ANSI color $code: 31 red (errors), 33 yellow
# (warnings), 35 purple (folders removed) or 32 green (albums done,
# used by the workers). An empty code prints the line plain.
function _paint --argument-names code line
    if test "$REFLAC_COLOR" = 1; and test -n "$code"
        printf '\e[%sm%s\e[0m\n' $code "$line"
    else
        printf '%s\n' "$line"
    end
end
# A summary line: colored on the terminal, plain in the run log.
function _say --argument-names code line
    printf '%s\n' "$line" >> "$RUN_LOG"
    _paint "$code" "$line"
end
# An error or warning message on stderr.
function _err --argument-names code line
    if test "$COLOR_ERR" = 1
        printf '\e[%sm%s\e[0m\n' $code "$line" >&2
    else
        printf '%s\n' "$line" >&2
    end
end

set -g DRY_RUN 0
set -g FORCE 0
set -g RESET 0
set -g RETRY_CORRUPT 0
set -g RESTRIP 0
set -g STRIP 1
set -g DELETE_EMPTY 0
set -g JOBS 0    # 0 = auto: use all cores (nproc)
set -g TARGET_DIR .
set -g CORRUPT_ROOT ""
set -g FLACED_ROOT ""
set -g LOSSY_ROOT ""
set -g STRIP_PREFIX Processed

set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case --dry-run -n
            set DRY_RUN 1
        case --force -f
            set FORCE 1
        case --reset
            set RESET 1
        case --retry-corrupt
            set RETRY_CORRUPT 1
        case --restrip
            set RESTRIP 1
        case --delete-empty
            set DELETE_EMPTY 1
        case --no-strip
            set STRIP 0
        case --jobs -j
            set i (math $i + 1); set JOBS $argv[$i]
        case --corrupt-root
            set i (math $i + 1); set CORRUPT_ROOT $argv[$i]
        case --flaced-root
            set i (math $i + 1); set FLACED_ROOT $argv[$i]
        case --lossy-root
            set i (math $i + 1); set LOSSY_ROOT $argv[$i]
        case --strip-prefix
            set i (math $i + 1); set STRIP_PREFIX $argv[$i]
        case --help -h
            echo "Usage: "(status filename)" [--dry-run] [--force] [--reset] [--retry-corrupt] [--restrip] [--no-strip] [--delete-empty] [--jobs N] [--corrupt-root DIR] [--flaced-root DIR] [--lossy-root DIR] [--strip-prefix NAME] [DIR]"
            exit 0
        case '--*'
            _err 31 "Unknown option: $argv[$i]"; exit 2
        case '*'
            set TARGET_DIR $argv[$i]
    end
    set i (math $i + 1)
end

test -d "$TARGET_DIR"; or begin
    _err 31 "Error: '$TARGET_DIR' is not a directory."; exit 2
end
set TARGET_DIR (realpath "$TARGET_DIR")

set -g RUNFROM (pwd)
set -g STATE_FILE "$RUNFROM/.reflac_state.log"
set -g QUAR_LIST "$RUNFROM/.reflac_corrupt.txt"
set -g RUN_LOG "$RUNFROM/.reflac_run_"(date +%Y%m%d_%H%M%S)".log"
test -z "$CORRUPT_ROOT"; and set CORRUPT_ROOT "$RUNFROM/corrupt"
set CORRUPT_ROOT (string replace -r '/$' '' -- "$CORRUPT_ROOT")
# Finished albums go beside the scan folder, into "FLACed":
# scanning ~/Music/Incoming  ->  ~/Music/FLACed
test -z "$FLACED_ROOT"; and set FLACED_ROOT (dirname -- "$TARGET_DIR")"/FLACed"
set FLACED_ROOT (string replace -r '/$' '' -- "$FLACED_ROOT")
# Finished albums that contain lossy audio go into "Lossy" instead,
# also beside the scan folder.
test -z "$LOSSY_ROOT"; and set LOSSY_ROOT (dirname -- "$TARGET_DIR")"/Lossy"
set LOSSY_ROOT (string replace -r '/$' '' -- "$LOSSY_ROOT")

if not string match -qr '^[0-9]+$' -- "$JOBS"; or test "$JOBS" -lt 1
    command -q nproc; and set JOBS (nproc); or set JOBS 4
end

for tool in flac metaflac ffmpeg ffprobe flock parallel id3v2
    if not command -q $tool
        _err 31 "Error: required tool '$tool' not found."
        echo "On CachyOS: sudo pacman -S flac ffmpeg id3v2 util-linux coreutils parallel" >&2
        exit 3
    end
end

# ----- single-instance lock -----
# Two runs over the same library race each other: one run's worker can
# move an album out while the other is mid-write-back. Only one reflac
# run may be active at a time (per user). The controller re-executes
# itself under flock; the lock fd is inherited by every worker, so the
# lock is released only when the last process of the run has exited.
if not set -q REFLAC_LOCKED
    set -l lockdir "$XDG_RUNTIME_DIR"
    if test -z "$lockdir"; or not test -d "$lockdir"
        set lockdir /tmp
    end
    set -l lock "$lockdir/reflac-"(id -u)".lock"
    if not flock -n "$lock" true
        _err 31 "Error: another reflac run is already active (lock: $lock)."
        echo "Wait for it to finish — two runs over one library would race." >&2
        exit 4
    end
    set -gx REFLAC_LOCKED 1
    # --no-fork (util-linux 2.38+): flock takes the lock and then turns
    # into the run rather than waiting on it as a separate parent. A
    # forking flock dies at once on Ctrl-C, handing your prompt back
    # while the run is still cleaning up; this way the run finishes its
    # cleanup and prints "Interrupted" before the prompt returns.
    set -l nofork
    flock --help 2>&1 | string match -q -- '*--no-fork*'; and set nofork --no-fork
    exec flock $nofork -n -E 4 "$lock" fish --no-config "$SELF" $argv
end

function _sig --on-signal INT --on-signal TERM
    # GNU parallel has already terminated the workers by the time fish
    # runs this handler; drop this run's RAM dir with them.
    set -q RUNTMP; and test -n "$RUNTMP"; and rm -rf -- "$RUNTMP"
    # never leave the terminal stuck in a color if output was cut short
    test "$REFLAC_COLOR" = 1; and printf '\e[0m'
    echo "" >&2
    _err 33 "Interrupted — state log intact, rerun to resume."
    # fish restores $status after an event handler, so a plain
    # `exit 130` here would exit with parallel's status instead.
    exec sh -c 'exit 130'
end

if test $RESET -eq 1; and test -e "$STATE_FILE"
    mv -f "$STATE_FILE" "$STATE_FILE.bak."(date +%s)
end
touch "$STATE_FILE"
touch "$QUAR_LIST"

echo "Run-from dir : $RUNFROM"        | tee -a "$RUN_LOG"
echo "Scan dir     : $TARGET_DIR"     | tee -a "$RUN_LOG"
echo "Corrupt root : $CORRUPT_ROOT"   | tee -a "$RUN_LOG"
echo "FLACed root  : $FLACED_ROOT"    | tee -a "$RUN_LOG"
echo "Lossy root   : $LOSSY_ROOT"     | tee -a "$RUN_LOG"
echo "Strip prefix : '$STRIP_PREFIX'" | tee -a "$RUN_LOG"
echo "State log    : $STATE_FILE"     | tee -a "$RUN_LOG"
echo "Quarantine   : $QUAR_LIST"      | tee -a "$RUN_LOG"
echo "Run log      : $RUN_LOG"        | tee -a "$RUN_LOG"
echo "Parallel jobs: $JOBS (albums in flight; tracks sequential within)" | tee -a "$RUN_LOG"
echo "ID3 strip    : "(test $STRIP -eq 1; and echo on; or echo off) | tee -a "$RUN_LOG"
echo "Delete empty : "(test $DELETE_EMPTY -eq 1; and echo "on (0-byte tracks deleted; folders left with only .txt/.lrc removed)"; or echo off) | tee -a "$RUN_LOG"
test $DRY_RUN -eq 1;       and echo "Mode         : DRY RUN"       | tee -a "$RUN_LOG"
test $FORCE   -eq 1;       and echo "Mode         : FORCE"         | tee -a "$RUN_LOG"
test $RESET   -eq 1;       and echo "Mode         : RESET"         | tee -a "$RUN_LOG"
test $RETRY_CORRUPT -eq 1; and echo "Mode         : RETRY-CORRUPT" | tee -a "$RUN_LOG"
echo "" | tee -a "$RUN_LOG"

# ----- leftovers from an interrupted earlier run -----
# All safe to remove: the run lock guarantees that no other reflac run,
# and none of its workers, is still alive.
#  * RAM dirs in /dev/shm (temp lists, encoder output).
#  * .reflac_moving_* beside a destination album: an unfinished
#    cross-drive copy; its source album is still intact.
#  * .reflac_trash_* in the scan tree: the source of a finished
#    cross-drive move, interrupted while being deleted.
for d in /dev/shm/reflac.* /dev/shm/reflac_*
    test -O "$d"; and rm -rf -- "$d"
end
set -l dest_roots
for r in "$FLACED_ROOT" "$LOSSY_ROOT" "$CORRUPT_ROOT"
    test -d "$r"; and set -a dest_roots "$r"
end
set -l leftovers
if test (count $dest_roots) -gt 0
    set -a leftovers (find $dest_roots -mindepth 2 -maxdepth 2 -type d -name '.reflac_moving_*' -print0 2>/dev/null | string split0)
end
set -a leftovers (find "$TARGET_DIR" -mindepth 2 -maxdepth 3 -type d -name '.reflac_trash_*' -print0 2>/dev/null | string split0)
for d in $leftovers
    if test $DRY_RUN -eq 1
        echo "WOULD CLEAN UP     : $d (left by an interrupted move)" | tee -a "$RUN_LOG"
    else
        rm -rf -- "$d"
        echo "CLEANUP            : $d (left by an interrupted move)" | tee -a "$RUN_LOG"
    end
end

# This run's RAM dir: temp lists, worker workspaces, progress counter,
# crash markers and byte totals. Removed at the end of the run.
set -g RUNTMP (mktemp -d /dev/shm/reflac.run.XXXXXX)
if test -z "$RUNTMP"; or not mkdir -p "$RUNTMP/done"
    _err 31 "Error: cannot create a working directory in /dev/shm."
    exit 3
end
# Silent MPEG-1 Layer III frames (128 kbps, 44.1 kHz): workers wrap
# an ID3 tag found in front of FLAC data around these so that ffmpeg
# can read it (see w_id3_probe).
for k in (seq 8)
    printf '\xff\xfb\x90\x64'
    head -c 413 /dev/zero
end > "$RUNTMP/frames.mp3"

# ----- which album does a file belong to? -----
# Work is queued per album: the folder two levels below the scan root
# (ARTIST/ALBUM), ignoring a leading STRIP_PREFIX component. Any file
# deeper inside it (CD1/, Disc 2/, Bonus/…) belongs to that album.
# A file that sits shallower (in the scan root or directly in an
# ARTIST folder) has no album: its own folder is queued instead, and
# its tracks are processed in place as loose tracks.
function unit_of --argument-names path
    set -l rel (string sub -s (math (string length -- "$TARGET_DIR") + 2) -- "$path")
    set -l comps (string split / -- "$rel")
    set -l pre ""
    if test -n "$STRIP_PREFIX"; and test (count $comps) -gt 1; and test "$comps[1]" = "$STRIP_PREFIX"
        set pre "$comps[1]/"
        set -e comps[1]
    end
    if test (count $comps) -ge 3
        echo "$TARGET_DIR/$pre$comps[1]/$comps[2]"
    else
        string replace -r '/[^/]*$' '' -- "$path"
    end
end

# ----- find every album that holds audio -----
# A single find pass prints size:mtime:path for each audio file,
# NUL-delimited, so no process is started per file. Files already
# finished are then subtracted with a sorted `comm` against the state
# log. LC_ALL=C keeps sort and comm byte-ordered whatever the locale
# and however odd the file names.
set -g FOLDERLIST        "$RUNTMP/folders"
set -g FOLDERLIST_QUEUED "$RUNTMP/queue"
set -l CAND_RAW    "$RUNTMP/cand_raw"
set -l CAND        "$RUNTMP/cand"
set -l FINAL       "$RUNTMP/final"
set -l NEWREC      "$RUNTMP/newrec"
set -l TMP_FOLDERS "$RUNTMP/folders_raw"
set -l QRAW        "$RUNTMP/newwork_raw"

set -l CR_ABS (realpath -m -- "$CORRUPT_ROOT")
set -l FL_ABS (realpath -m -- "$FLACED_ROOT")
set -l LO_ABS (realpath -m -- "$LOSSY_ROOT")
# Only a destination tree that lies inside the scan folder can show up
# in find's output, so only those need excluding path by path.
set -l inside_roots
for r in "$CR_ABS" "$FL_ABS" "$LO_ABS"
    string match -q -- "$TARGET_DIR/*" "$r"; and set inside_roots $inside_roots "$r"
end

# %s:%Ts gives the same key as the workers' `stat -c %s:%Y`.
# The lossy extensions are listed only so that purely lossy albums are
# found and queued: a worker never converts them, it just moves the
# album to the Lossy tree. Anything named .reflac_* (temp files,
# leftovers of an interrupted move) is skipped.
find "$TARGET_DIR" \( -name '.reflac_*' -o -name '._*' -o -name .AppleDouble \) -prune -o -type f \( \
        -iname '*.flac' -o -iname '*.wav' -o -iname '*.wave' \
        -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.aifc' \
        -o -iname '*.m4a' -o -iname '*.mp4' -o -iname '*.caf' \
        -o -iname '*.ape' -o -iname '*.wv' -o -iname '*.tta' \
        -o -iname '*.tak' -o -iname '*.wma' -o -iname '*.mka' \
        -o -iname '*.dsf' -o -iname '*.dff' \
        -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.oga' \
        -o -iname '*.opus' -o -iname '*.aac' -o -iname '*.mpc' \
        -o -iname '*.mp2' -o -iname '*.m4b' \
    \) -printf '%s:%Ts:%p\0' > "$CAND_RAW"

set -g n_files 0
: > "$CAND"
: > "$TMP_FOLDERS"
while read -lz rec
    test -z "$rec"; and continue
    set n_files (math $n_files + 1)
    set -l path (string replace -r '^[^:]*:[^:]*:' '' -- "$rec")
    # skip anything already inside the corrupt, FLACed, or Lossy trees
    set -l skip 0
    for r in $inside_roots
        if string match -q -- "$r/*" "$path"
            set skip 1
            break
        end
    end
    test $skip -eq 1; and continue
    printf '%s\0' "$rec" >> "$CAND"
    printf '%s\0' (unit_of "$path") >> "$TMP_FOLDERS"
end < "$CAND_RAW"
rm -f "$CAND_RAW"

env LC_ALL=C sort -uz < "$TMP_FOLDERS" > "$FOLDERLIST"
rm -f "$TMP_FOLDERS"
set -g n_folders_seen (tr -cd '\0' < "$FOLDERLIST" | wc -c | string trim)

# Finished records from the state log, reshaped into the same
# size:mtime:path form as find's output. They feed only the "with
# conversion work" figure below. (State-log lines end in a newline,
# so turning newlines into NULs is safe.)
awk -F'\t' -v rc=$RETRY_CORRUPT '
    NF >= 3 {
        st = $1
        if (st=="DONE" || st=="SKIPLOSSY" || st=="SKIPMAX" || st=="SKIPFLOAT" || st=="SKIPASIS" || (st=="CORRUPT" && rc==0)) {
            i = index($0, "\t"); rest = substr($0, i+1)
            j = index(rest, "\t")
            print substr(rest, 1, j-1) ":" substr(rest, j+1)
        }
    }' "$STATE_FILE" | tr '\n' '\0' | env LC_ALL=C sort -uz > "$FINAL"

env LC_ALL=C sort -z < "$CAND" > "$CAND.sorted"
rm -f "$CAND"
env LC_ALL=C comm -z -23 "$CAND.sorted" "$FINAL" > "$NEWREC"
rm -f "$CAND.sorted" "$FINAL"

# Albums with at least one new or changed file have conversion work to
# do. This only feeds the figures printed below.
: > "$QRAW"
while read -lz rec
    test -z "$rec"; and continue
    set -l path (string replace -r '^[^:]*:[^:]*:' '' -- "$rec")
    printf '%s\0' (unit_of "$path") >> "$QRAW"
end < "$NEWREC"
rm -f "$NEWREC"
set -l n_newwork (env LC_ALL=C sort -uz < "$QRAW" | tr -cd '\0' | wc -c | string trim)
rm -f "$QRAW"

# Queue every album still in the scan tree. An album that is still
# here has not been relocated yet, even if all of its tracks are
# finished in the state log (after a dry run, say, or a move that
# failed). Workers skip finished tracks with a cheap state-log lookup,
# so queueing them again costs almost nothing and makes sure the album
# still reaches FLACed, Lossy or corrupt. --restrip is handled in the
# worker, which re-examines finished FLACs.
mv -f -- "$FOLDERLIST" "$FOLDERLIST_QUEUED"
set -g n_queued_folders $n_folders_seen

echo "Files discovered        : $n_files"          | tee -a "$RUN_LOG"
echo "Albums queued this run  : $n_queued_folders" | tee -a "$RUN_LOG"
echo "  with conversion work  : $n_newwork"        | tee -a "$RUN_LOG"
echo "  relocate/verify only  : "(math $n_queued_folders - $n_newwork) | tee -a "$RUN_LOG"
echo "" | tee -a "$RUN_LOG"

if test "$n_queued_folders" -eq 0
    echo "Nothing to do — no candidate audio left in the scan tree." | tee -a "$RUN_LOG"
    rm -rf -- "$RUNTMP"
    exit 0
end

# ----- start one worker per album -----
# Jobs go through /bin/sh (PARALLEL_SHELL) rather than parallel's own
# fish quoting, which some parallel versions get wrong for accented
# paths. Workers start with --no-config, so that nothing in config.fish
# (an alias such as `cp -i`, say) can change how they behave.
# {#} is parallel's job number.
set -gx PARALLEL_SHELL /bin/sh
parallel -q --null --jobs "$JOBS" --line-buffer \
    fish --no-config "$SELF" --folder-worker {} "$RUNFROM" "$TARGET_DIR" "$CORRUPT_ROOT" \
        "$STRIP_PREFIX" "$STATE_FILE" "$RUN_LOG" "$QUAR_LIST" \
        "$DRY_RUN" "$FORCE" "$STRIP" "$FLACED_ROOT" "$LOSSY_ROOT" "$RESTRIP" \
        "$RUNTMP" {#} "$n_queued_folders" "$DELETE_EMPTY" \
    :::: "$FOLDERLIST_QUEUED"

# ----- workers that never finished -----
# Every worker that exits normally leaves $RUNTMP/done/<job number>.
# A missing marker means the worker crashed, was killed, or never
# started: that album was not processed in this run.
set -l queued (string split0 < "$FOLDERLIST_QUEUED")
set -l crashed
for i in (seq (count $queued))
    test -e "$RUNTMP/done/$i"; or set -a crashed "$queued[$i]"
end

# ----- summary of this run (counted from its own log) -----
function _cnt --argument-names re
    set -l c (grep -cE -- "$re" "$RUN_LOG" 2>/dev/null)
    test -n "$c"; and echo $c; or echo 0
end
function _size --argument-names b
    if test "$b" -ge 1073741824
        echo (math -s2 "$b / 1073741824")" GB"
    else
        echo (math -s1 "$b / 1048576")" MB"
    end
end
set -l pfx '^(\[ *[0-9]+/[0-9]+\] )?'
set -l c_fail    (_cnt "$pfx"'FAIL ')
set -l c_conv    (_cnt '^OK    \(')
set -l c_max     (_cnt '^SKIP  \(already max\)')
set -l c_prior   (_cnt '^SKIP  \((prior|lossy,prior|as-is,prior)\)')
set -l c_float   (_cnt '^SKIP  \(kept as is\)')
set -l c_rescue  (_cnt '^(WOULD )?RESCUE')
set -l c_restore (_cnt '^(WOULD )?RESTORE')
set -l bytes_in 0
set -l bytes_out 0
if test -s "$RUNTMP/bytes"
    set -l sums (awk '{o += $1; n += $2} END {printf "%.0f %.0f\n", o, n}' "$RUNTMP/bytes" | string split ' ')
    set bytes_in $sums[1]
    set bytes_out $sums[2]
end

set -l L "$RUN_LOG"
echo "" | tee -a $L
echo "──────────────────────────────────────────" | tee -a $L
if test $DRY_RUN -eq 1
    echo "This dry run would:" | tee -a $L
    echo "  move albums to FLACed        : "(_cnt 'WOULD MOVE \(FLACed\)')  | tee -a $L
    echo "  move albums to Lossy         : "(_cnt 'WOULD MOVE \(Lossy\)')   | tee -a $L
    echo "  quarantine albums (corrupt)  : "(_cnt 'WOULD MOVE ALBUM')       | tee -a $L
    echo "  quarantine loose tracks      : "(_cnt '^WOULD QUARANTINE')      | tee -a $L
    echo "  convert tracks               : "(_cnt '^WOULD CONVERT')         | tee -a $L
    echo "  skip tracks already at max   : $c_max"                          | tee -a $L
    echo "  rescue ID3 tags into FLACs   : $c_rescue"                       | tee -a $L
    if test $DELETE_EMPTY -eq 1
        echo "  delete empty (0-byte) tracks : "(_cnt '^WOULD DELETE +: .*\(empty, 0 bytes\)$') | tee -a $L
        echo "  remove folders (no audio)    : "(_cnt 'WOULD DELETE folder')  | tee -a $L
    end
else
    echo "This run:" | tee -a $L
    echo "  Albums → FLACed              : "(_cnt 'ALBUM DONE -> moved \(FLACed\)') | tee -a $L
    echo "  Albums → Lossy               : "(_cnt 'ALBUM DONE -> moved \(Lossy\)')  | tee -a $L
    echo "  Albums → corrupt             : "(_cnt 'ALBUM CORRUPT -> moved')         | tee -a $L
    echo "  Loose tracks → corrupt       : "(_cnt '^TRACK CORRUPT -> moved')        | tee -a $L
    set -l c_kept (_cnt "$pfx"'KEEP  \((had FAILs|stray temp)')
    set -l col ''
    test $c_kept -gt 0; and set col 33
    _say "$col" "  Albums kept back             : $c_kept"
    if test $c_conv -gt 0; and test $bytes_in -gt 0
        set -l saved (math "$bytes_in - $bytes_out")
        echo "  Tracks converted             : $c_conv  ("(_size $bytes_in)" → "(_size $bytes_out)", saved "(_size $saved)", "(math -s1 "$saved * 100 / $bytes_in")"%)" | tee -a $L
    else
        echo "  Tracks converted             : $c_conv" | tee -a $L
    end
    echo "  Tracks already at max        : $c_max"     | tee -a $L
    echo "  Tracks done in earlier runs  : $c_prior"   | tee -a $L
    test $c_float -gt 0;   and echo "  Tracks kept as is (float/DSD): $c_float"   | tee -a $L
    test $c_rescue -gt 0;  and echo "  ID3 tags rescued into FLACs  : $c_rescue"  | tee -a $L
    test $c_restore -gt 0; and echo "  Interrupted strips restored  : $c_restore" | tee -a $L
    if test $DELETE_EMPTY -eq 1
        echo "  Empty (0-byte) tracks deleted: "(_cnt '^DELETED +: .*\(empty, 0 bytes\)$') | tee -a $L
        echo "  Folders removed (no audio)   : "(_cnt 'DELETED folder')       | tee -a $L
    end
end
set -l col ''
test $c_fail -gt 0; and set col 31
_say "$col" "  Transient FAILs              : $c_fail"
set col ''
test (count $crashed) -gt 0; and set col 31
_say "$col" "  Workers that crashed         : "(count $crashed)
for c in $crashed
    _say 31 "    CRASHED (not processed — rerun): $c"
end
echo "" | tee -a $L
echo "Corrupt albums are in  : $CORRUPT_ROOT/<ARTIST>/<ALBUM>/ (see CORRUPT_TRACKS.txt)" | tee -a $L
echo "Finished albums are in : $FLACED_ROOT/<ARTIST>/<ALBUM>/" | tee -a $L
echo "Lossy albums are in    : $LOSSY_ROOT/<ARTIST>/<ALBUM>/" | tee -a $L
echo "Quarantine list        : $QUAR_LIST" | tee -a $L
if test $c_fail -gt 0; or test (count $crashed) -gt 0
    echo "" | tee -a $L
    _say 33 "Rerun the same command to retry the FAILs / crashed albums."
end

rm -rf -- "$RUNTMP"
if test $c_fail -gt 0; or test (count $crashed) -gt 0
    exit 1
end
exit 0
