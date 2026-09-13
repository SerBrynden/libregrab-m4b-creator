#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR=""
TELEGRAM_COMPATIBLE=false
INPUT_DIRS=()

usage() {
    echo "Usage:"
    echo "  $0 [--output-dir <output_directory>] [--telegram-compatible] <directory_path1> [directory_path2 ...]"
    echo ""
    echo "Examples:"
    echo "  $0 ~/Downloads/books/book_folder"
    echo "  $0 --output-dir ~/Downloads/books ~/Downloads/books/book_folder"
    echo "  $0 --telegram-compatible ~/Downloads/books/book_folder"
    echo ""
    echo "Notes:"
    echo "- Each audiobook directory should contain MP3 files"
    echo "- A parent directory containing audiobook subfolders may also be supplied"
    echo "- Metadata is optional and can be found at metadata/metadata.json, metadata.json, or chapters.json"
    echo "- Default output directory: <input directory>/converted"
    echo "- Use --telegram-compatible to create lower-bitrate AAC-LC output optimized for Telegram playback"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_python_command() {
    local venv_python="$SCRIPT_DIR/.venv/bin/python"

    if [[ -x "$venv_python" ]]; then
        printf '%s\n' "$venv_python"
        return 0
    fi

    if command_exists python3; then
        printf '%s\n' "python3"
        return 0
    fi

    if command_exists python; then
        printf '%s\n' "python"
        return 0
    fi

    return 1
}

normalize_path_argument() {
    local value="$1"

    if [[ -z "${value//[[:space:]]/}" ]]; then
        return 1
    fi

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s\n' "$value"
}

absolute_path() {
    local path="$1"

    if [[ -d "$path" ]]; then
        cd "$path" && pwd
    else
        local dir
        local file
        dir="$(dirname "$path")"
        file="$(basename "$path")"
        cd "$dir" && printf '%s/%s\n' "$(pwd)" "$file"
    fi
}

contains_audio_files() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f -iname "*.mp3" -print -quit | grep -q .
}

safe_file_name_part() {
    local value="$1"

    if [[ -z "${value//[[:space:]]/}" ]]; then
        return 1
    fi

    value="$(printf '%s' "$value" | tr -d '<>:"/\|?*')"
    value="$(printf '%s' "$value" | tr '\n\t\r' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/\.+$//')"

    if [[ -z "${value//[[:space:]]/}" ]]; then
        return 1
    fi

    printf '%s\n' "$value"
}

get_metadata_json_path() {
    local dir="$1"
    local candidate

    for candidate in \
        "$dir/metadata/metadata.json" \
        "$dir/metadata.json" \
        "$dir/chapters.json"
    do
        if [[ -f "$candidate" ]]; then
            absolute_path "$candidate"
            return 0
        fi
    done

    return 1
}

get_cover_image_path() {
    local dir="$1"
    local candidate

    for candidate in \
        "$dir/metadata/cover.jpg" \
        "$dir/metadata/cover.jpeg" \
        "$dir/metadata/cover.png" \
        "$dir/metadata/cover.webp"
    do
        if [[ -f "$candidate" ]]; then
            absolute_path "$candidate"
            return 0
        fi
    done

    return 1
}

get_metadata_value() {
    local metadata_path="$1"
    local field="$2"

    "${PYTHON_CMD[@]}" - "$metadata_path" "$field" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
field = sys.argv[2]

try:
    with open(metadata_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if field == "title":
        print(data.get("title") or "")
    elif field == "author":
        creators = data.get("creator") or []
        author = None

        if isinstance(creators, list):
            for creator in creators:
                if isinstance(creator, dict) and creator.get("role") == "author":
                    author = creator
                    break

            if author is None and creators:
                author = creators[0]

        if isinstance(author, dict):
            print(author.get("name") or "")
        else:
            print("")
except Exception:
    print("")
PY
}

get_audiobook_output_file_name() {
    local dir="$1"
    local author="$2"
    local title="$3"

    local safe_author=""
    local safe_title=""
    local fallback_name=""

    safe_author="$(safe_file_name_part "$author" 2>/dev/null || true)"
    safe_title="$(safe_file_name_part "$title" 2>/dev/null || true)"

    if [[ -n "$safe_author" && -n "$safe_title" && "$safe_author" != "Unknown Author" ]]; then
        printf '%s - %s.m4b\n' "$safe_author" "$safe_title"
        return 0
    fi

    fallback_name="$(safe_file_name_part "$(basename "$dir")" 2>/dev/null || true)"

    if [[ -z "$fallback_name" ]]; then
        fallback_name="audiobook"
    fi

    printf '%s.m4b\n' "$fallback_name"
}

get_audiobook_input_directories() {
    local resolved_output_dir=""
    local input
    local dir
    local child
    local result=()

    if [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
        resolved_output_dir="$(absolute_path "$OUTPUT_DIR")"
    fi

    for input in "${INPUT_DIRS[@]}"; do
        dir="$(normalize_path_argument "$input")" || continue

        if [[ ! -d "$dir" ]]; then
            echo "Error: $dir is not a directory." >&2
            return 1
        fi

        dir="$(absolute_path "$dir")"

        if contains_audio_files "$dir"; then
            result+=("$dir")
            continue
        fi

        while IFS= read -r -d '' child; do
            local child_name
            local child_abs

            child_name="$(basename "$child")"
            child_abs="$(absolute_path "$child")"

            if [[ "$child_name" == "converted" || "$child_name" == ".convert-temp" ]]; then
                continue
            fi

            if [[ -n "$resolved_output_dir" && "$child_abs" == "$resolved_output_dir" ]]; then
                continue
            fi

            if contains_audio_files "$child_abs"; then
                result+=("$child_abs")
            fi
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done

    printf '%s\n' "${result[@]}" | awk '!seen[$0]++'
}

write_concat_file() {
    local output_file="$1"
    shift

    : > "$output_file"

    local audio_file
    for audio_file in "$@"; do
        local concat_path
        concat_path="${audio_file//\\/\/}"
        concat_path="${concat_path//\'/\'\\\'\'}"
        printf "file '%s'\n" "$concat_path" >> "$output_file"
    done
}

process_directory() {
    local dir="$1"
    local workdir
    local metadata_json_path=""
    local cover_image_path=""
    local book_title
    local author="Unknown Author"
    local output_file
    local resolved_output_dir
    local final_output_path
    local working_name
    local temp_root
    local temp_dir
    local audiofiles_list
    local chapters_file
    local bitrate=""
    local bitrate_args=()
    local threads
    local audio_files=()

    LAST_FINAL_OUTPUT_PATH=""

    workdir="$(absolute_path "$dir")"

    if [[ -n "$OUTPUT_DIR" ]]; then
        resolved_output_dir="$(normalize_path_argument "$OUTPUT_DIR")"
        mkdir -p "$resolved_output_dir"
        resolved_output_dir="$(absolute_path "$resolved_output_dir")"
    else
        resolved_output_dir="$workdir/converted"
        mkdir -p "$resolved_output_dir"
    fi

    if [[ ! -w "$resolved_output_dir" ]]; then
        echo "Error: Output directory is not writable: $resolved_output_dir" >&2
        return 1
    fi

    book_title="$(basename "$workdir")"

    if metadata_json_path="$(get_metadata_json_path "$workdir")"; then
        local metadata_title
        local metadata_author

        metadata_title="$(get_metadata_value "$metadata_json_path" "title")"
        metadata_author="$(get_metadata_value "$metadata_json_path" "author")"

        if [[ -n "$metadata_title" ]]; then
            book_title="$metadata_title"
        fi

        if [[ -n "$metadata_author" ]]; then
            author="$metadata_author"
        fi
    fi

    cover_image_path="$(get_cover_image_path "$workdir" 2>/dev/null || true)"

    output_file="$(get_audiobook_output_file_name "$workdir" "$author" "$book_title")"
    final_output_path="$resolved_output_dir/$output_file"

    working_name="$(safe_file_name_part "${output_file%.m4b}" 2>/dev/null || true)"
    if [[ -z "$working_name" ]]; then
        working_name="audiobook"
    fi

    temp_root="$resolved_output_dir/.convert-temp"
    mkdir -p "$temp_root"
    temp_dir="$(mktemp -d "$temp_root/${working_name}-XXXXXXXX")"

    audiofiles_list="$temp_dir/audiofiles.txt"
    chapters_file="$temp_dir/ffmpeg_chapters.txt"

    cleanup() {
        rm -rf "$temp_root"
    }
    trap cleanup RETURN

    echo "Processing audiobook: $book_title"
    echo "Author: $author"
    echo "Input directory: $workdir"
    echo "Output directory: $resolved_output_dir"
    echo "Final output file: $final_output_path"
    echo "Temporary working directory: $temp_dir"
    echo "Telegram compatibility mode: $TELEGRAM_COMPATIBLE"

    if [[ -f "$final_output_path" ]]; then
        echo "Warning: Final output file already exists and will be overwritten: $final_output_path"
    fi

    if [[ -n "$cover_image_path" ]]; then
        echo "Cover image: $cover_image_path"
    fi

    while IFS= read -r -d '' audio_file; do
        audio_files+=("$audio_file")
    done < <(find "$workdir" -maxdepth 1 -type f -iname "*.mp3" -print0 | sort -z)

    if [[ ${#audio_files[@]} -eq 0 ]]; then
        echo "Error: No MP3 files found in $workdir." >&2
        return 1
    fi

    write_concat_file "$audiofiles_list" "${audio_files[@]}"

    echo "Audio files list created:"
    cat "$audiofiles_list"

    bitrate="$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "${audio_files[0]}" 2>/dev/null || true)"

    if [[ -n "$bitrate" && "$bitrate" != "N/A" ]]; then
        bitrate_args=(-b:a "$bitrate")
        echo "Detected bitrate: $bitrate"
    else
        echo "Warning: Could not detect input bitrate, FFmpeg will use its default AAC bitrate."
    fi

    local total_duration
    total_duration="$(
        "${PYTHON_CMD[@]}" - "${audio_files[@]}" <<'PY'
import subprocess
import sys

total = 0.0

for audio_file in sys.argv[1:]:
    result = subprocess.run(
        [
            "ffprobe",
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            audio_file,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    duration_text = result.stdout.strip()

    if result.returncode != 0 or not duration_text:
        raise RuntimeError(f"Could not determine duration for audio file: {audio_file}")

    total += float(duration_text)

print(total)
PY
    )"

    if [[ -z "$total_duration" ]]; then
        echo "Error: Could not determine total audiobook duration." >&2
        return 1
    fi

    echo "Total audiobook duration: $total_duration seconds"

    if [[ -n "$metadata_json_path" ]]; then
        if [[ ${#PYTHON_CMD[@]} -eq 0 ]]; then
            echo "Error: Metadata file was found, but Python is not available to process it: $metadata_json_path" >&2
            return 1
        fi

        echo "Found metadata file: $metadata_json_path"
        echo "Using metadata for chapter information..."

        if [[ ! -f "$SCRIPT_DIR/convert_chapters.py" ]]; then
            echo "Error: Required helper script was not found: $SCRIPT_DIR/convert_chapters.py" >&2
            return 1
        fi

        "${PYTHON_CMD[@]}" "$SCRIPT_DIR/convert_chapters.py" "$metadata_json_path" --output "$chapters_file" --total-duration "$total_duration" || return 1

        if [[ ! -f "$chapters_file" ]]; then
            echo "Error: Expected temporary chapter metadata file was not created: $chapters_file"
            return 1
        fi
    else
        echo "No metadata.json or chapters.json found, using MP3 filenames for chapters..."

        {
            echo ";FFMETADATA1"
            echo ""
        } > "$chapters_file"

        local current_time=0
        local audio_file
        for audio_file in "${audio_files[@]}"; do
            local duration_text
            local duration
            local next_time
            local chapter_title

            duration_text="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$audio_file" 2>/dev/null || true)"

            if [[ -z "$duration_text" ]]; then
                echo "Error: Could not determine duration for audio file: $audio_file" >&2
                return 1
            fi

            duration="${duration_text%.*}"

            if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
                echo "Error: Could not parse duration for audio file: $audio_file" >&2
                return 1
            fi

            next_time=$((current_time + duration))
            chapter_title="$(basename "$audio_file" .mp3)"

            {
                echo "[CHAPTER]"
                echo "TIMEBASE=1/1"
                echo "START=$current_time"
                echo "END=$next_time"
                echo "title=$chapter_title"
                echo ""
            } >> "$chapters_file"

            current_time="$next_time"
        done
    fi

    if command_exists nproc; then
        threads="$(nproc)"
    elif command_exists sysctl; then
        threads="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    else
        threads="1"
    fi

    local ffmpeg_args=(
        -hwaccel auto
        -threads "$threads"
        -y
        -f concat
        -safe 0
        -i "$audiofiles_list"
        -i "$chapters_file"
    )

    if [[ -n "$cover_image_path" ]]; then
        ffmpeg_args+=(
            -i "$cover_image_path"
            -map 0:a
            -map 2:v
            -map_metadata 1
            -map_chapters 1
            -disposition:v attached_pic
        )
    else
        ffmpeg_args+=(
            -map 0:a
            -map_metadata 1
            -map_chapters 1
        )
    fi

    ffmpeg_args+=(
        -metadata "album=$book_title"
        -metadata "title=$book_title"
        -metadata "artist=$author"
        -metadata "album_artist=$author"
        -metadata "author=$author"
        -metadata "genre=Audiobook"
    )

    if [[ "$TELEGRAM_COMPATIBLE" == true ]]; then
        ffmpeg_args+=(
            -metadata media_type=1
            -c:a aac
            -profile:a aac_low
            -b:a 64k
            -ac 2
            -ar 44100
            -avoid_negative_ts make_zero
            -fflags +genpts
            -movflags +faststart
        )
    else
        ffmpeg_args+=(
            -c:a aac
            -aac_coder twoloop
            -ac 2
            -ar 44100
            -movflags +faststart
        )

        if [[ ${#bitrate_args[@]} -gt 0 ]]; then
            ffmpeg_args+=("${bitrate_args[@]}")
        fi
    fi

    if [[ -n "$cover_image_path" ]]; then
        ffmpeg_args+=(
            -c:v mjpeg
            -metadata:s:v title=Cover
            -metadata:s:v "comment=Cover (front)"
        )
    fi

    ffmpeg_args+=("$final_output_path")

    echo "Converting to M4B format..."
    echo "FFmpeg output file: $final_output_path"

    ffmpeg "${ffmpeg_args[@]}"
    local ffmpeg_exit_code=$?

    if [[ $ffmpeg_exit_code -ne 0 ]]; then
        echo "Conversion failed!"
        echo "Error: FFmpeg exited with code $ffmpeg_exit_code" >&2
        return "$ffmpeg_exit_code"
    fi

    echo "Conversion complete!"
    echo "Final output file: $final_output_path"

    xattr -d com.apple.quarantine "$final_output_path" 2>/dev/null || true

    if [[ "$TELEGRAM_COMPATIBLE" == true ]]; then
        local extradata_size
        extradata_size="$(ffprobe -v quiet -select_streams a:0 -show_entries stream=extradata_size -of csv=p=0 "$final_output_path" 2>/dev/null || true)"

        if [[ "$extradata_size" == "2" ]]; then
            echo "Telegram compatibility check passed: extradata_size = 2"
        else
            echo "Warning: Telegram compatibility check warning: extradata_size = $extradata_size. This file may not work correctly in Telegram."
        fi
    fi

    echo "You can now test the audiobook in your preferred player."
    LAST_FINAL_OUTPUT_PATH="$final_output_path"

    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            if [[ -n "${2:-}" ]]; then
                OUTPUT_DIR="$2"
                shift 2
            else
                echo "Error: --output-dir requires a directory path" >&2
                exit 1
            fi
            ;;
        --telegram-compatible)
            TELEGRAM_COMPATIBLE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            INPUT_DIRS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#INPUT_DIRS[@]} -eq 0 ]]; then
    usage
    exit 1
fi

if ! command_exists ffprobe; then
    echo "Error: ffprobe is not installed. Please install ffmpeg/ffprobe before running this script." >&2
    exit 1
fi

PYTHON_CMD=()
if python_exe="$(get_python_command)"; then
    PYTHON_CMD=("$python_exe")
    echo "Using Python: $python_exe"
else
    echo "Warning: Python was not found. Metadata-based chapters will not be available."
fi

if [[ -n "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(normalize_path_argument "$OUTPUT_DIR")"

    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR" || {
            echo "Error: Failed to create output directory: $OUTPUT_DIR" >&2
            exit 1
        }
    fi

    if [[ ! -w "$OUTPUT_DIR" ]]; then
        echo "Error: Output directory is not writable: $OUTPUT_DIR" >&2
        exit 1
    fi
fi

mapfile -t AUDIOBOOK_INPUT_DIRS < <(get_audiobook_input_directories)

if [[ ${#AUDIOBOOK_INPUT_DIRS[@]} -eq 0 ]]; then
    echo "Error: No audiobook folders were found. Provide a folder containing MP3 files, or a parent folder containing audiobook subfolders with MP3 files." >&2
    exit 1
fi

HAD_ERRORS=false
PROCESSED_COUNT=0
FAILED_COUNT=0
FINAL_OUTPUT_PATHS=()

for dir in "${AUDIOBOOK_INPUT_DIRS[@]}"; do
    if process_directory "$dir"; then
        if [[ -n "$LAST_FINAL_OUTPUT_PATH" ]]; then
            FINAL_OUTPUT_PATHS+=("$LAST_FINAL_OUTPUT_PATH")
        fi

        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        echo "Completed processing: $dir"
        echo "----------------------------------------"
    else
        HAD_ERRORS=true
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "Failed processing: $dir" >&2
        echo "----------------------------------------"
    fi
done

if [[ ${#FINAL_OUTPUT_PATHS[@]} -gt 0 ]]; then
    echo ""
    echo "Processed files saved to:"
    for path in "${FINAL_OUTPUT_PATHS[@]}"; do
        echo "  $path"
    done
fi

echo ""

if [[ "$HAD_ERRORS" == true ]]; then
    echo "Finished with errors. Successful: $PROCESSED_COUNT. Failed: $FAILED_COUNT." >&2
    exit 1
fi

echo "All audiobooks processed successfully! Successful: $PROCESSED_COUNT."
