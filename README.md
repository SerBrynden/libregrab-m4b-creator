# LibreGrab M4B Creator

LibreGrab M4B Creator converts Libby/OverDrive audiobook downloads into `.m4b` audiobooks with chapter markers, 
audiobook metadata, and optional embedded cover art.

It is designed for audiobooks downloaded with LibreGrab, but it can also process any folder of `.mp3` files. 
When metadata is available, the scripts use it for accurate chapter names, title, author, and output filename. 
When metadata is not available, the scripts fall back to creating chapters from the MP3 filenames.

## Features

- Converts one or more audiobook folders from MP3 files to a single M4B file
- Supports macOS/Linux via `convert_audiobook.sh`
- Supports Windows via `convert_audiobook.ps1`
- Creates chapter markers from LibreGrab metadata when available
- Falls back to MP3 filenames for chapters when metadata is missing
- Reads metadata from:
  - `metadata/metadata.json`
  - `metadata.json`
  - `chapters.json`
- Embeds cover art when present in the metadata folder
- Uses title and author metadata for the output filename when available
- Supports processing multiple audiobook folders in one command
- Supports passing a parent folder containing multiple audiobook subfolders
- Handles paths with spaces and many special characters
- Saves output to each input folder's `converted` directory by default
- Supports a custom output directory
- Includes a Telegram-compatible output mode

## Prerequisites

### Required

Install FFmpeg:

macOS using Homebrew:
```shell
brew install ffmpeg
```

Debian/Ubuntu Linux:
```shell
sudo apt-get update sudo apt-get install ffmpeg python3
```

Windows:

1. Download and install [FFmpeg](https://ffmpeg.org/download.html)
2. Ensure `ffmpeg` is available in your `PATH`

[Python 3](https://www.python.org/) is also required.

The scripts use Python to inspect audio duration and process metadata. On Windows, either `python` or the 
Python launcher `py` can be used. On macOS/Linux, either `python3` or `python` can be used.

### Optional

On Unix-like systems, if this repository contains a `.venv/bin/python`, the shell script will use it automatically.

On Windows, if this repository contains `.venv\Scripts\python.exe`, the PowerShell script will use it automatically.

## Getting Audiobook Files

This tool is optimized for audiobooks downloaded from Libby/OverDrive using 
[LibreGrab](https://greasyfork.org/en/scripts/498782-libregrab).

LibreGrab downloads usually include MP3 files and a metadata folder in the structure expected by these scripts.

## Installation

### macOS/Linux

1. Clone or download this repository.
2. Open Terminal.
3. Navigate to the repository folder.
4. Make the shell script executable:
```shell
chmod +x convert_audiobook.sh
```
5. Confirm prerequisites are installed:
```shell
ffmpeg -version ffprobe -version python3 --version
```

### Windows

1. Clone or download this repository.
2. Install FFmpeg and make sure `ffmpeg` is in your `PATH`.
3. Install [Python 3](https://www.python.org/) if it is not already installed.
4. If PowerShell blocks local scripts, allow locally created scripts for your user:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
5. Confirm prerequisites are installed:
```powershell
ffmpeg -version ffprobe -version python --version
```

If `python --version` does not work but the Python launcher is installed, try:
```powershell
py -3 --version
```

## Expected Input Structure

Each audiobook folder should contain MP3 files directly inside the folder.

Recommended LibreGrab-style structure:
```text
your-audiobook-folder/ 
├── part001.mp3 
├── part002.mp3 
├── part003.mp3 
└── metadata/ 
    ├── metadata.json 
    └── cover.jpg
```

Metadata is optional. The scripts look for metadata in this order:
```text
your-audiobook-folder/ 
├── metadata/ 
│   └── metadata.json 
├── metadata.json 
└── chapters.json
```

Cover art is optional. The scripts look for cover images in:
```text
metadata/cover.jpg 
metadata/cover.jpeg 
metadata/cover.png 
metadata/cover.webp
```

## Quick Start

### macOS/Linux

Convert a single audiobook folder:
```shell
./convert_audiobook.sh "/path/to/audiobook folder"
```

Convert multiple audiobook folders:
```shell
./convert_audiobook.sh "/path/to/book one" "/path/to/book two"
```

Convert all audiobook subfolders inside a parent folder:
```shell
./convert_audiobook.sh "/path/to/downloaded audiobooks"
```

Save output files to a custom directory:
```shell
./convert_audiobook.sh "/path/to/audiobook folder" --output-dir "/path/to/output folder"
```

Create Telegram-compatible output:
```shell
./convert_audiobook.sh --telegram-compatible "/path/to/audiobook folder"
```

### Windows PowerShell

Convert a single audiobook folder:
```powershell
.\convert_audiobook.ps1 "C:\Path\To\Audiobook Folder"
```

Convert multiple audiobook folders:
```powershell
.\convert_audiobook.ps1 "C:\Path\To\Book One" "C:\Path\To\Book Two"
```

Convert all audiobook subfolders inside a parent folder:
```powershell
.\convert_audiobook.ps1 "C:\Path\To\Downloaded Audiobooks"
```

Save output files to a custom directory:
```powershell
.\convert_audiobook.ps1 "C:\Path\To\Audiobook Folder" -OutputDir "C:\Path\To\Output Folder"
```

Create Telegram-compatible output:
```powershell
.\convert_audiobook.ps1 -TelegramCompatible "C:\Path\To\Audiobook Folder"
```

## Usage Details

The scripts accept either:

1. One audiobook folder containing `.mp3` files directly inside it
2. Multiple audiobook folders
3. A parent folder containing audiobook subfolders

When a parent folder is supplied, the scripts scan only its immediate child folders and process child folders that 
contain `.mp3` files.

The scripts skip generated folders named:
```text
converted .convert-temp
```

## Output

By default, each converted audiobook is saved to:
```text
/converted/
```

If a custom output directory is provided, all converted files are saved there.

When title and author metadata are available, output files are named like:
```text
Author Name - Book Title.m4b
```

If metadata is missing or does not include an author/title, the output file falls back to the input folder name:
```text
Audiobook Folder Name.m4b
```

Existing output files with the same name are overwritten.

Temporary working files are created under `.convert-temp` inside the output directory and cleaned up automatically.

## Chapter Handling

If metadata is available, chapters are generated from the metadata file.

Supported metadata files:
```text
metadata/metadata.json 
metadata.json 
chapters.json
```

If no metadata file is available, the scripts create one chapter per MP3 file using the MP3 filename as the 
chapter title.

MP3 files are processed in filename sort order, so make sure files are named in playback order, for example:
```text
001.mp3 
002.mp3 
003.mp3
```

or:
```text
Book Title - Part 01.mp3 
Book Title - Part 02.mp3 
Book Title - Part 03.mp3
```

## Cover Art

If a supported cover image is found in the `metadata` folder, it is embedded as the audiobook cover.

Supported cover filenames:
```text
metadata/cover.jpg 
metadata/cover.jpeg 
metadata/cover.png 
metadata/cover.webp
```

## Telegram-Compatible Mode

Telegram-compatible mode creates lower-bitrate AAC-LC output intended to improve playback compatibility in Telegram.

macOS/Linux:
```shell
./convert_audiobook.sh --telegram-compatible "/path/to/audiobook folder"
```

Windows:
```powershell
.\convert_audiobook.ps1 -TelegramCompatible "C:\Path\To\Audiobook Folder"
```

This mode uses:
```text
AAC-LC 64k audio bitrate 2 channels 44.1 kHz sample rate faststart metadata
```

After conversion, the script checks the output with `ffprobe` and warns if the file may not be fully 
Telegram-compatible.

## Helper Script

`convert_chapters.py` is used by the conversion scripts to convert supported JSON metadata into FFmpeg chapter 
metadata.

It can also be run directly:
```shell
python3 convert_chapters.py "/path/to/audiobook folder" --output "/path/to/ffmpeg_chapters.txt"
```

Or with a direct metadata file path:
```shell
python3 convert_chapters.py "/path/to/metadata.json" --output "/path/to/ffmpeg_chapters.txt"
```

You usually do not need to run this helper manually.

## Troubleshooting

### `ffmpeg` or `ffprobe` is not found

Install FFmpeg and make sure both commands are available in your terminal:
```shell
ffmpeg -version ffprobe -version
```

On Windows, confirm FFmpeg's `bin` directory is in your `PATH`.

### Python is not found

Install Python 3 and confirm it is available:
```shell
python3 --version
```

On Windows:
```powershell
python --version
```

or:
```powershell
py -3 --version
```

### No audiobook folders were found

Make sure the folder you pass either:

- Contains `.mp3` files directly, or
- Contains immediate child folders that contain `.mp3` files

The scripts do not recursively scan deeply nested folder structures.

### Chapters are out of order

MP3 files are processed in filename sort order. Rename files so they sort in playback order.

### Metadata chapters are missing

Check that one of these files exists:
```text
metadata/metadata.json 
metadata.json 
chapters.json
```

Also make sure Python is installed and available.

### Cover art is not embedded

Check that the cover image is inside the `metadata` folder and uses one of the supported filenames:
```text
cover.jpg 
cover.jpeg 
cover.png 
cover.webp
```

## Related Projects

- [LibbyRip/LibreGrab](https://github.com/PsychedelicPalimpsest/LibbyRip) - A userscript that enables downloading 
- Libby/OverDrive audiobooks in a format compatible with this tool. Also available on 
[GreasyFork](https://greasyfork.org/en/scripts/498782-libregrab).
