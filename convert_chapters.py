#!/usr/bin/env python3
import argparse
import json
import os


def get_json_path(input_path):
    """Find the appropriate JSON file to process."""
    print(f"Searching for JSON file in: {input_path}")

    if os.path.isfile(input_path):
        print(f"Found direct file: {input_path}")
        return input_path

    metadata_path = os.path.join(input_path, "metadata", "metadata.json")
    if os.path.isfile(metadata_path):
        print(f"Found metadata.json: {metadata_path}")
        return metadata_path

    root_metadata_path = os.path.join(input_path, "metadata.json")
    if os.path.isfile(root_metadata_path):
        print(f"Found metadata.json: {root_metadata_path}")
        return root_metadata_path

    chapters_path = os.path.join(input_path, "chapters.json")
    if os.path.isfile(chapters_path):
        print(f"Found chapters.json: {chapters_path}")
        return chapters_path

    raise FileNotFoundError(f"No valid JSON file found in {input_path}")


def normalize_title(title):
    return str(title).replace("&apos;", "'")


def escape_ffmetadata_value(value):
    """Escape characters that are special in FFmetadata values."""
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace("\r", "")
        .replace("=", "\\=")
        .replace(";", "\\;")
        .replace("#", "\\#")
    )


def process_metadata_json(metadata_path):
    """Process Libby/LibreGrab metadata.json into chapter start times."""
    print(f"Reading metadata file: {metadata_path}")

    with open(metadata_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    print("Processing spine durations...")
    spine_durations = {}
    for i, item in enumerate(data.get('spine', [])):
        spine_durations[i] = float(item.get('duration', 0))

    print("Processing chapters...")
    chapters = []
    for chapter in data.get('chapters', []):
        spine_index = int(chapter['spine'])
        offset = float(chapter.get('offset', 0))

        start_time = sum(spine_durations[i] for i in range(spine_index)) + offset

        chapters.append({
            "start_time": int(round(start_time)),
            "title": normalize_title(chapter['title'])
        })

    return chapters


def process_chapters_json(chapters_path):
    """Process an existing chapters.json-style file into chapter start times."""
    print(f"Reading chapters file: {chapters_path}")

    with open(chapters_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    chapters = []
    for chapter in data.get('chapters', []):
        start_time = chapter.get('start_time', 0)

        # Existing generated chapters.json files used milliseconds.
        # Treat very large values as milliseconds for backward compatibility.
        start_time = float(start_time)
        if start_time > 100000:
            start_time = start_time / 1000

        chapters.append({
            "start_time": int(round(start_time)),
            "title": normalize_title(chapter.get('title', 'Chapter'))
        })

    return chapters


def write_ffmpeg_chapters(chapters, output_path, total_duration=None):
    if not chapters:
        raise ValueError("No chapters were found in the metadata.")

    output_dir = os.path.dirname(os.path.abspath(output_path))
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    print(f"Writing FFmpeg chapter metadata to: {output_path}")

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(';FFMETADATA1\n\n')

        for i, chapter in enumerate(chapters):
            start_time = int(chapter['start_time'])

            if i < len(chapters) - 1:
                end_time = int(chapters[i + 1]['start_time'])
            elif total_duration is not None and total_duration > start_time:
                end_time = int(round(total_duration))
            else:
                # FFmpeg requires an END value. If the actual total duration is
                # unavailable, keep the previous fallback behavior.
                end_time = start_time + 30

            title = escape_ffmetadata_value(chapter['title'])

            f.write('[CHAPTER]\n')
            f.write('TIMEBASE=1/1\n')
            f.write(f'START={start_time}\n')
            f.write(f'END={end_time}\n')
            f.write(f'title={title}\n\n')

    print(f"Created {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description='Create FFmpeg chapter metadata from audiobook metadata JSON.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example usage:
python3 convert_chapters.py "/path/to/book/directory" --output "/path/to/.convert-temp/ffmpeg_chapters.txt"
python3 convert_chapters.py "/path/to/metadata.json" --output "/path/to/.convert-temp/ffmpeg_chapters.txt"
python3 convert_chapters.py "/path/to/chapters.json" --output "/path/to/.convert-temp/ffmpeg_chapters.txt"
""")
    parser.add_argument('input_path', help='Path to book directory or JSON file')
    parser.add_argument(
        '--output',
        required=True,
        help='Path to the ffmpeg_chapters.txt file to create'
    )
    parser.add_argument(
        '--total-duration',
        type=float,
        default=None,
        help='Actual total audiobook duration in seconds. Used as the END value for the final chapter.'
    )
    args = parser.parse_args()

    try:
        print(f"Processing input path: {args.input_path}")
        json_path = get_json_path(args.input_path)
        print(f"Found JSON file: {json_path}")

        with open(json_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        if 'spine' in data:
            print("Processing metadata.json format")
            chapters = process_metadata_json(json_path)
        else:
            print("Processing chapters.json format")
            chapters = process_chapters_json(json_path)

        write_ffmpeg_chapters(chapters, args.output, args.total_duration)

        print(f"\nFound {len(chapters)} chapters")
        print("First few chapters:")
        for chapter in chapters[:5]:
            print(f"{chapter['start_time']}s {chapter['title']}")

    except Exception as e:
        print(f"Error: {str(e)}")
        raise


if __name__ == "__main__":
    main()
