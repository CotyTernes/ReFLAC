# reflac.fish

Re-encode a lossless music library to maximum-compression FLAC, in parallel, without losing a tag, a picture or a sample.

`reflac.fish` is a single [fish](https://fishshell.com) script. Point it at a folder of albums and it will:

- test every track for damage before touching anything,
- re-encode what can be made smaller with `flac -8 -e -p`, verified against the source,
- convert other lossless formats (WAV, AIFF, ALAC, APE, WavPack, TTA, TAK, WMA Lossless) to FLAC with their tags and cover art,
- move each finished album out of the scan folder into `FLACed/`, albums containing lossy audio into `Lossy/`, and damaged albums into `corrupt/` with a report saying what is wrong.

Whatever is still in the scan folder afterwards is what still needs your attention. The script can be interrupted at any time and resumes where it stopped.

> [!NOTE]
> **AI disclosure:** The code in this repository was written by Claude, an AI model made by [Anthropic](https://www.anthropic.com), and so was this README. The maintainer set the requirements, tested the script on their own music library and reported the problems they found, which Claude then fixed. Treat it as you would any code from the internet, and read it before you run it.

> [!WARNING]
> This script rewrites, moves and (with `--delete-empty`) deletes files in your music library. It is careful, and it has a dry-run mode, but **have a backup before the first real run.**

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Folder layout](#folder-layout)
- [What happens to each album](#what-happens-to-each-album)
- [Options](#options)
- [Output](#output)
- [Files it writes](#files-it-writes)
- [Interrupting and resuming](#interrupting-and-resuming)
- [Good to know](#good-to-know)
- [Exit status](#exit-status)
- [License](#license)

## Requirements

Linux, with:

| Tool | Used for |
| --- | --- |
| `fish` | running the script |
| `flac`, `metaflac` | testing, encoding and tagging FLAC |
| `ffmpeg`, `ffprobe` | decoding and inspecting every other format |
| `id3v2` | stripping ID3 tags from FLAC files |
| GNU `parallel` | running albums side by side |
| `flock` (util-linux) | log locking and the one-run-at-a-time lock |
| GNU coreutils and findutils | `stat`, `find`, `sort`, `comm`, and friends |

```sh
# Arch / CachyOS
sudo pacman -S fish flac ffmpeg id3v2 parallel util-linux coreutils

# Debian / Ubuntu
sudo apt install fish flac ffmpeg id3v2 parallel util-linux coreutils
```

Tested with fish 4.9, flac 1.5 and ffmpeg 6. The script relies on GNU options and on `/dev/shm`, so macOS and the BSDs are not supported.

## Quick start

```sh
chmod +x reflac.fish

# The logs are written to the folder you run from, so pick a place for them.
mkdir -p ~/reflac-logs && cd ~/reflac-logs

# 1. See what would happen. Nothing in the library is changed.
/path/to/reflac.fish --dry-run ~/Music/Incoming

# 2. Do it.
/path/to/reflac.fish ~/Music/Incoming
```

After the run:

```
~/Music/
├── Incoming/     whatever still needs attention (ideally empty)
├── FLACed/       finished albums, all lossless
└── Lossy/        finished albums containing lossy audio
~/reflac-logs/
├── corrupt/      damaged albums, each with a CORRUPT_TRACKS.txt
└── .reflac_*     state log, run logs, quarantine list
```

## Folder layout

The script expects `ARTIST/ALBUM` folders directly inside the scan folder:

```
Incoming/
├── Artist A/
│   ├── Album One/
│   │   ├── 01 Track.flac
│   │   ├── cover.jpg
│   │   └── CD2/            everything inside an album belongs to it
│   │       └── 01 Track.flac
│   └── Loose Track.flac    a loose track: converted in place, never moved
└── Artist B/
    └── Album Two/
```

- An **album** is a folder two levels below the scan folder, together with everything inside it: disc subfolders, artwork, cue sheets, logs. It is always checked, quarantined or relocated in one piece.
- **Loose tracks**, directly in the scan folder or in an artist folder, have no album folder. They are converted where they are and never relocated. A damaged loose track is quarantined on its own.
- If your albums sit one level deeper, under a common first-level folder, name that folder with `--strip-prefix` (default: `Processed`). `Incoming/Processed/Artist/Album` is then treated as `Artist/Album`.

## What happens to each album

One worker handles one album. Albums run in parallel; the tracks inside an album run one after another.

### 1. Check

Every track gets a full integrity test.

| Source | Test |
| --- | --- |
| FLAC | `flac -t` (decodes everything and compares it with the checksum stored in the file) |
| WAV, AIFF, ALAC (`.m4a`, `.mp4`, `.caf`), Monkey's Audio (`.ape`), WavPack (`.wv`), TTA, TAK, WMA Lossless, FLAC in Matroska (`.mka`) | decoded in full by ffmpeg; any decode error, fewer samples than the header promises, or a WAV/AIFF data chunk running past the end of the file counts as damage |

Formats that can hold either kind of audio (`.m4a`, `.wma`, `.mka`, WavPack) are probed. A lossy one is not converted; it marks its album as lossy.

**ID3 tags on FLAC files.** A FLAC with an ID3 tag glued to it cannot be re-encoded. The script first copies into the FLAC's own tags any field or cover art that only the ID3 tag holds (it never overrides a field the FLAC already has), then strips the ID3 tag and tests the file again. If the file is still broken, the original is restored and the album is quarantined.

**Left untouched.** Some lossless audio cannot be converted without altering it, so it is skipped and reported, not converted:

- floating-point audio and integer audio deeper than 24 bits,
- DSD (`.dsf`, `.dff`),
- hybrid WavPack with a `.wvc` correction file (hybrid WavPack without one is lossy).

### 2. Decide

If any track is unrecoverable, the **whole album** moves to `corrupt/ARTIST/ALBUM/`, and a `CORRUPT_TRACKS.txt` inside it names each damaged track and what is wrong with it:

```
Corrupted tracks:
  01 Cut.flac
      reason: truncated — only 0:01.5 of 0:03.0 present; the end of the file
      is missing (incomplete download or copy?) [flac: LOST_SYNC after 65536 samples]
```

### 3. Convert

- Each FLAC is encoded **once**, into RAM. That one encode is both the "is it already at maximum?" test and the final output, and `flac -V` verifies it against the source while encoding.
- A FLAC that would shrink by less than 0.5 % is left alone (`SKIP (already max)`), unless you pass `--force`.
- FLAC sources keep their metadata natively. A FLAC that the encoder refuses (for example, one with no track length in its header, as written by streaming encoders) or one missing its audio checksum is rebuilt from a decode, with every metadata block copied byte for byte. It gains the missing length and checksum.
- Other sources are decoded by ffmpeg. Their tags are then mapped to the standard Vorbis names that Picard and beets read (`MusicBrainz Track Id` → `MUSICBRAINZ_TRACKID`, sort fields, and so on), `3/12` track and disc numbers are split into number and total, and container bookkeeping is dropped.
- The original is replaced by a single atomic rename, and only after the verified encode succeeded and no tag or picture was lost. A non-FLAC source is deleted only once its FLAC is in place, and never replaces a *different* FLAC that happens to have the same name.

### 4. Relocate

When every track is converted or legitimately skipped, and nothing failed, the album leaves the scan folder:

| Album contains | Goes to |
| --- | --- |
| only lossless audio | `FLACed/ARTIST/ALBUM/` |
| any lossy audio at all (`.mp3`, `.ogg`, `.opus`, `.aac`, AAC in `.m4a`, …) | `Lossy/ARTIST/ALBUM/` |

Albums that were already at maximum compression move too. Within one filesystem a move is a single rename; across filesystems it is a copy that is verified before the source is deleted. An existing destination is never overwritten (the newcomer gets a `.dup1` suffix), and artist folders left empty are removed.

## Options

```
reflac.fish [OPTIONS] [DIR]
```

`DIR` is the folder to scan and defaults to the current folder.

| Option | Meaning |
| --- | --- |
| `-n`, `--dry-run` | Show what would happen without changing the library. |
| `-f`, `--force` | Re-encode FLACs even if they are already at maximum compression. |
| `-j N`, `--jobs N` | Albums to process at once. Default: all CPU cores. |
| `--flaced-root DIR` | Where finished albums go. Default: `FLACed` beside the scan folder. |
| `--lossy-root DIR` | Where finished albums containing lossy audio go. Default: `Lossy` beside the scan folder. |
| `--corrupt-root DIR` | Where damaged albums go. Default: `corrupt` in the folder you run from. |
| `--strip-prefix NAME` | A first-level folder of the scan folder to ignore when working out `ARTIST/ALBUM`. Default: `Processed`. |
| `--delete-empty` | Delete empty (0-byte) tracks; see below. |
| `--no-strip` | Never strip ID3 tags from FLACs. An album with such a FLAC is quarantined instead. |
| `--restrip` | Re-examine FLACs finished in an earlier run that still carry an ID3 tag. |
| `--retry-corrupt` | Count earlier `CORRUPT` entries as new work in the start-of-run figures. (An album you put back into the scan folder is always re-checked, with or without this.) |
| `--reset` | Archive the state log and start from scratch. |
| `-h`, `--help` | Print a one-line usage summary. |

### `--delete-empty`

A 0-byte track holds nothing worth keeping. With this option:

- an empty track is deleted along with its same-name `.lrc` or `.txt` sidecar;
- an album that loses only *some* of its tracks this way is incomplete, so it is quarantined, and its report lists what was deleted;
- an album whose tracks were *all* empty is removed if nothing but `.txt`, `.lrc` and empty files remain. If anything else remains (artwork, logs, cue sheets), it is quarantined for review instead;
- a folder left holding only `.txt`, `.lrc` or empty files after its albums have moved out is removed too.

In a dry run these are only reported.

## Output

Each track and album gets one line. An album's final line carries a `[finished/total]` counter:

```
SKIP  (already max): …/Artist C/Album Good/02 Two.flac
OK    (pcm_s16le -> flac): …/Artist C/Album Good/01 One.flac
[5/6] ALBUM DONE -> moved (FLACed): …/Incoming/Artist C/Album Good  ->  …/FLACed/Artist C/Album Good
PRUNE empty dir    : …/Incoming/Artist C
FAIL  (name clash) : …/Album Clash/01 Song.wav — a different …/01 Song.flac already exists
[6/6] KEEP  (had FAILs)  : …/Artist A/Album Clash — not moved to FLACed; rerun to retry
```

A summary of the run follows: albums per destination, tracks converted and space saved, failures, and any worker that crashed.

On a terminal, the lines are colored:

| Color | Meaning |
| --- | --- |
| red | `FAIL` lines, errors, crashed workers, a non-zero FAIL count |
| yellow | `WARN` lines, albums held back, "Interrupted", the rerun hint |
| purple | folders pruned or removed |
| green | albums completed and moved (in a dry run: would be moved) |

Everything else is uncolored. Piped or redirected output and the run log are never colored, and `NO_COLOR=1` turns colors off entirely.

## Files it writes

Bookkeeping lives in the folder you run *from*, never inside the music tree:

| File | Contents |
| --- | --- |
| `.reflac_state.log` | One line per finished track (status, size and time stamp, path). This is what makes a rerun fast. |
| `.reflac_run_DATE.log` | The complete output of one run. |
| `.reflac_corrupt.txt` | Every quarantined track: old path, new path, reason. Tab-separated. |
| `*.lock` | Empty lock files beside the logs. |

Because the state log is found by location, **run the script from the same folder every time.**

Temporary files go to a per-run folder in `/dev/shm`, which is RAM. Inside the library the script only ever creates short-lived working files with `reflac` in their names (`.reflac_tmp_*`, `*.reflac_bak`, `.reflac_moving_*`, `.reflac_trash_*`).

## Interrupting and resuming

Ctrl-C is safe. A converted track is put in place by an atomic rename, and the one step that edits a file in place (stripping an ID3 tag) keeps a backup until it has succeeded. Run the same command again to continue: finished tracks are skipped using the state log.

The next run also cleans up after an interruption. It removes stale RAM folders and unfinished cross-filesystem moves, restores the backup of a track whose ID3 strip was cut short (`*.reflac_bak`), and deletes stray write-back files (`.reflac_tmp_*`) when the same audio already exists beside them. A stray file that holds audio found nowhere else is reported with a `WARN`, and its album is held back until you have looked at it, because that file may be the only copy of a track.

A `FAIL` is a problem with the run, not with the music (a full disk, a name clash, an encoder error). The album stays where it is, and a rerun tries again.

Only one run can be active at a time. A second one exits immediately with status 4.

## Good to know

- **A dry run is not instant.** To predict whether a FLAC would shrink, it has to test-encode it (in RAM). It writes its own logs but never modifies the library.
- **RAM.** Each worker keeps the output of the track it is encoding in `/dev/shm`. Allow for about *jobs × twice the size of your largest track*, and lower `--jobs` on a machine with little memory.
- **Albums move.** That is the point of the script, but it means the scan folder should be an inbox or a copy you intend to drain, not a library that other software expects to stay put.
- **Lossy audio is never converted or altered.** An album containing any is simply filed under `Lossy/`. Files are recognised as lossy by extension (`.mp3`, `.ogg`, `.oga`, `.opus`, `.aac`, `.mpc`, `.mp2`, `.m4b`) or by probing (`.m4a`, `.mp4`, `.wma`, `.mka`, WavPack).
- **Tags.** A FLAC source keeps its own tags exactly as they are; fields rescued from an ID3 tag are only ever added. Only tracks converted from other formats have their tag names normalised.
- **Compression settings** are `flac -8 -e -p`: the slowest, smallest setting flac offers. The gain over a typical `-5` or `-8` encode is usually a few percent at best.

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Finished without failures. |
| 1 | A track FAILed or a worker crashed. Rerun to retry. |
| 2 | Bad option, or `DIR` is not a folder. |
| 3 | A required tool is missing, or `/dev/shm` is unusable. |
| 4 | Another run is already active. |
| 130 | Interrupted. |

## License

Public domain, under [The Unlicense](https://unlicense.org). See [LICENSE](LICENSE). Do whatever you like with it; there is no warranty.
