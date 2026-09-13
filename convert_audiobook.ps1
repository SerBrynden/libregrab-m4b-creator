[CmdletBinding(DefaultParameterSetName = 'InputDir')]
param (
  [Parameter(Mandatory = $false)]
  [string]$OutputDir,

  [Parameter(Mandatory = $false)]
  [switch]$TelegramCompatible,

  [Parameter(Mandatory = $false, ParameterSetName = 'Path')]
  [Alias('LiteralPath')]
  [string[]]$Path,

  [Parameter(Mandatory = $false, ParameterSetName = 'InputDir')]
  [string[]]$InputDir,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$InputDirs
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function NormalizePathArgument {
  param (
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $normalizedPath = $Path.Trim()

  if (
    ($normalizedPath.StartsWith('"') -and $normalizedPath.EndsWith('"')) -or
    ($normalizedPath.StartsWith("'") -and $normalizedPath.EndsWith("'"))
  ) {
    $normalizedPath = $normalizedPath.Substring(1, $normalizedPath.Length - 2)
  }

  return [Environment]::ExpandEnvironmentVariables($normalizedPath)
}

$ResolvedInputDirs = @()
if ($Path) {
  $ResolvedInputDirs += $Path | ForEach-Object { NormalizePathArgument $_ }
}
if ($InputDir) {
  $ResolvedInputDirs += $InputDir | ForEach-Object { NormalizePathArgument $_ }
}
if ($InputDirs) {
  $ResolvedInputDirs += $InputDirs | ForEach-Object { NormalizePathArgument $_ }
}

$ResolvedInputDirs = @($ResolvedInputDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($OutputDir) {
  $OutputDir = NormalizePathArgument $OutputDir
}

# Function to check if a command exists
function Test-CommandExists {
  param ($Command)
  return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Write-Utf8NoBomFile {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string[]]$Content,

    [switch]$Append
  )

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  if ($Append) {
    [System.IO.File]::AppendAllLines($Path, $Content, $utf8NoBom)
  } else {
    [System.IO.File]::WriteAllLines($Path, $Content, $utf8NoBom)
  }
}

function ConvertTo-FfmpegConcatPath {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  # FFmpeg concat files are safest with forward slashes.
  $concatPath = $Path.Replace('\', '/')

  # In concat syntax, a literal apostrophe inside a single-quoted path
  # must temporarily close the quote, escape the apostrophe, then reopen it.
  $concatPath = $concatPath.Replace("'", "'\''")

  return $concatPath
}

function Get-PythonCommand {
  $venvPython = Join-Path $ScriptDir '.venv\Scripts\python.exe'

  if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
    return @{
      FilePath = $venvPython
      Args = @()
    }
  }

  if (Test-CommandExists 'python') {
    return @{
      FilePath = 'python'
      Args = @()
    }
  }

  if (Test-CommandExists 'py') {
    return @{
      FilePath = 'py'
      Args = @('-3')
    }
  }

  return $null
}

function Get-MetadataJsonPath {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Directory
  )

  $candidatePaths = @(
    (Join-Path $Directory 'metadata\metadata.json'),
    (Join-Path $Directory 'metadata.json'),
    (Join-Path $Directory 'chapters.json')
  )

  foreach ($candidatePath in $candidatePaths) {
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidatePath).Path
    }
  }

  return $null
}

function Test-DirectoryContainsAudioFiles {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Directory
  )

  return [bool](Get-ChildItem -LiteralPath $Directory -Filter *.mp3 -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-AudiobookInputDirectories {
  param (
    [Parameter(Mandatory = $true)]
    [string[]]$Directories,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputDir
  )

  $audiobookDirectories = @()

  $resolvedOutputDir = $null
  if (-not [string]::IsNullOrWhiteSpace($OutputDir) -and (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    $resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
  }

  foreach ($directory in $Directories) {
    $normalizedDirectory = NormalizePathArgument $directory

    if ([string]::IsNullOrWhiteSpace($normalizedDirectory)) {
      continue
    }

    if (-not (Test-Path -LiteralPath $normalizedDirectory -PathType Container)) {
      throw "$normalizedDirectory is not a directory."
    }

    $resolvedDirectory = (Resolve-Path -LiteralPath $normalizedDirectory).Path

    if (Test-DirectoryContainsAudioFiles -Directory $resolvedDirectory) {
      $audiobookDirectories += $resolvedDirectory
      continue
    }

    $childDirectories = Get-ChildItem -LiteralPath $resolvedDirectory -Directory -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -ne 'converted' -and
        $_.Name -ne '.convert-temp' -and
        (
          -not $resolvedOutputDir -or
          [System.IO.Path]::GetFullPath($_.FullName).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($resolvedOutputDir).TrimEnd('\')
        )
      }

    foreach ($childDirectory in $childDirectories) {
      if (Test-DirectoryContainsAudioFiles -Directory $childDirectory.FullName) {
        $audiobookDirectories += $childDirectory.FullName
      }
    }
  }

  return @($audiobookDirectories | Select-Object -Unique)
}

function Get-AudiobookMetadata {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [string]$MetadataJsonPath
  )

  $metadata = @{
    Title = (Get-Item -LiteralPath $Directory).Name
    Author = 'Unknown Author'
    CoverImagePath = $null
  }

  if ($MetadataJsonPath -and (Test-Path -LiteralPath $MetadataJsonPath -PathType Leaf)) {
    try {
      $json = Get-Content -LiteralPath $MetadataJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

      if ($json.title) {
        $metadata.Title = [string]$json.title
      }

      if ($json.creator) {
        $authorCreator = $json.creator | Where-Object { $_.role -eq 'author' } | Select-Object -First 1

        if (-not $authorCreator) {
          $authorCreator = $json.creator | Select-Object -First 1
        }

        if ($authorCreator -and $authorCreator.name) {
          $metadata.Author = [string]$authorCreator.name
        }
      }
    } catch {
      Write-Warning "Could not read title/author from metadata file: $MetadataJsonPath"
      Write-Warning $_
    }
  }

  # Look for optional cover art in the metadata folder.
  $coverCandidates = @(
    (Join-Path $Directory 'metadata\cover.jpg'),
    (Join-Path $Directory 'metadata\cover.jpeg'),
    (Join-Path $Directory 'metadata\cover.png'),
    (Join-Path $Directory 'metadata\cover.webp')
  )

  foreach ($coverCandidate in $coverCandidates) {
    if (Test-Path -LiteralPath $coverCandidate -PathType Leaf) {
      $metadata.CoverImagePath = (Resolve-Path -LiteralPath $coverCandidate).Path
      break
    }
  }

  return $metadata
}

function Get-SafeFileNamePart {
  param (
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  $safeValue = $Value.Trim()
  $safeValue = $safeValue -replace '[<>:"/\\|?*]', ''
  $safeValue = $safeValue -replace '\s+', ' '
  $safeValue = $safeValue.Trim().TrimEnd('.')

  if ([string]::IsNullOrWhiteSpace($safeValue)) {
    return $null
  }

  return $safeValue
}

function Get-SafeWorkingDirectoryName {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Author,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Title
  )

  $outputFileName = Get-AudiobookOutputFileName -Directory $Directory -Author $Author -Title $Title
  $workingName = [System.IO.Path]::GetFileNameWithoutExtension($outputFileName)
  $workingName = Get-SafeFileNamePart $workingName

  if (-not $workingName) {
    $workingName = 'audiobook'
  }

  return $workingName
}

function Get-AudiobookOutputFileName {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Author,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Title
  )

  $safeAuthor = Get-SafeFileNamePart $Author
  $safeTitle = Get-SafeFileNamePart $Title

  if ($safeAuthor -and $safeTitle -and $safeAuthor -ne 'Unknown Author') {
    return "$safeAuthor - $safeTitle.m4b"
  }

  $fallbackName = Get-SafeFileNamePart ((Get-Item -LiteralPath $Directory).Name)

  if (-not $fallbackName) {
    $fallbackName = 'audiobook'
  }

  return "$fallbackName.m4b"
}

$PythonCommand = Get-PythonCommand

# Check for ffmpeg
if (-not (Test-CommandExists 'ffmpeg')) {
  Write-Error 'ffmpeg is not installed. Please install it before running this script.'
  exit 1
}

if ($PythonCommand) {
  $PythonExe = $PythonCommand['FilePath']
  $PythonArgs = @($PythonCommand['Args'])
  Write-Verbose "Using Python: $PythonExe"
} else {
  $PythonExe = $null
  $PythonArgs = @()
  Write-Verbose 'Python was not found. Metadata-based chapters will not be available.'
}

# Display usage if no input directories provided
if ($ResolvedInputDirs.Count -eq 0) {
  Write-Host 'Usage:'
  Write-Host '  .\convert_audiobook.ps1 -Path <directory_path>'
  Write-Host '  .\convert_audiobook.ps1 -InputDir <directory_path> [-OutputDir <output_directory>]'
  Write-Host '  .\convert_audiobook.ps1 [-OutputDir <output_directory>] [-TelegramCompatible] <directory_path1> [directory_path2 ...]'
  Write-Host ''
  Write-Host 'Examples:'
  Write-Host '  .\convert_audiobook.ps1 -Path "C:\Users\winuser\Downloads\books\book_folder"'
  Write-Host '  .\convert_audiobook.ps1 -InputDir "C:\Users\winuser\Downloads\books\book_folder" -OutputDir "C:\Users\winuser\Downloads\books"'
  Write-Host '  .\convert_audiobook.ps1 -TelegramCompatible -Path "C:\Users\winuser\Downloads\books\book_folder"'
  Write-Host 'Notes:'
  Write-Host '- Each directory should contain MP3 files'
  Write-Host '- Metadata is optional and can be found at metadata\metadata.json, metadata.json, or chapters.json'
  Write-Host '- Default output directory: <input directory>\converted'
  Write-Host '- Use -TelegramCompatible to create lower-bitrate AAC-LC output optimized for Telegram playback'
  exit 1
}

$AudiobookInputDirs = Get-AudiobookInputDirectories -Directories $ResolvedInputDirs -OutputDir $OutputDir

if ($AudiobookInputDirs.Count -eq 0) {
  Write-Error 'No audiobook folders were found. Provide a folder containing MP3 files, or a parent folder containing audiobook subfolders with MP3 files.'
  exit 1
}

function Convert-AudiobookDirectory {
  param (
    [string]$Directory
  )

  $Directory = NormalizePathArgument $Directory

  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    throw "$Directory is not a directory."
  }

  $Directory = (Resolve-Path -LiteralPath $Directory).Path

  if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $ResolvedOutputDir = Join-Path $Directory 'converted'
  } else {
    $ResolvedOutputDir = NormalizePathArgument $OutputDir
  }

  if (-not (Test-Path -LiteralPath $ResolvedOutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null
    Write-Verbose "Created output directory: $ResolvedOutputDir"
  }

  $ResolvedOutputDir = (Resolve-Path -LiteralPath $ResolvedOutputDir).Path

  Push-Location -LiteralPath $Directory
  try {
    $MetadataJsonPath = Get-MetadataJsonPath -Directory $Directory
    $AudiobookMetadata = Get-AudiobookMetadata -Directory $Directory -MetadataJsonPath $MetadataJsonPath

    $bookTitle = $AudiobookMetadata.Title
    $author = $AudiobookMetadata.Author
    $CoverImagePath = $AudiobookMetadata.CoverImagePath

    $OutputFile = Get-AudiobookOutputFileName -Directory $Directory -Author $author -Title $bookTitle
    $FinalOutputPath = Join-Path $ResolvedOutputDir $OutputFile

    $WorkingDirectoryName = Get-SafeWorkingDirectoryName -Directory $Directory -Author $author -Title $bookTitle
    $TempRoot = Join-Path $ResolvedOutputDir '.convert-temp'
    $TempDirectory = Join-Path $TempRoot "$WorkingDirectoryName-$([guid]::NewGuid().ToString('N'))"

    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null

    Write-Verbose "Processing audiobook: $bookTitle"
    Write-Verbose "Author: $author"
    Write-Verbose "Input directory: $Directory"
    Write-Verbose "Output directory: $ResolvedOutputDir"
    Write-Verbose "Final output file: $FinalOutputPath"
    Write-Verbose "Temporary working directory: $TempDirectory"
    Write-Verbose "Telegram compatibility mode: $([bool]$TelegramCompatible)"

    if (Test-Path -LiteralPath $FinalOutputPath -PathType Leaf) {
      Write-Warning "Final output file already exists and will be overwritten: $FinalOutputPath"
    }

    if ($CoverImagePath) {
      Write-Verbose "Cover image: $CoverImagePath"
    }

    # Find all MP3 files
    $AudioFiles = Get-ChildItem -LiteralPath $Directory -Filter *.mp3 -File | Sort-Object Name

    if ($AudioFiles.Count -eq 0) {
      throw "No MP3 files found in $Directory."
    }

    # Create audio files list for FFmpeg concat demuxer.
    # Paths are escaped so spaces, periods, and apostrophes work correctly.
    $AudioFilesList = Join-Path $TempDirectory 'audiofiles.txt'
    $AudioFileLines = $AudioFiles | ForEach-Object {
      $concatPath = ConvertTo-FfmpegConcatPath $_.FullName
      "file '$concatPath'"
    }

    Write-Utf8NoBomFile -Path $AudioFilesList -Content $AudioFileLines

    Write-Verbose 'Audio files list created:'
    Get-Content -LiteralPath $AudioFilesList

    # Get bitrate from first file
    $firstFile = $AudioFiles[0].FullName
    $bitrateInfo = & ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$firstFile" 2>$null

    if ($bitrateInfo -and $bitrateInfo -ne 'N/A') {
      $bitrateArgs = @('-b:a', $bitrateInfo.Trim())
      Write-Verbose "Detected bitrate: $($bitrateInfo.Trim())"
    } else {
      Write-Warning "Could not detect input bitrate, FFmpeg will use its default AAC bitrate."
      $bitrateArgs = @()
    }

    $TotalDuration = 0.0
    foreach ($file in $AudioFiles) {
      $durationText = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)" 2>$null

      $durationValue = 0.0
      if (-not [double]::TryParse($durationText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$durationValue)) {
        throw "Could not determine duration for audio file: $($file.FullName)"
      }

      $TotalDuration += $durationValue
    }

    Write-Verbose "Total audiobook duration: $TotalDuration seconds"

    # Create chapter metadata file in this book's temporary working directory.
    $ChaptersFile = Join-Path $TempDirectory 'ffmpeg_chapters.txt'

    if ($MetadataJsonPath) {
      if (-not $PythonExe) {
        throw "Metadata file was found, but Python is not available to process it: $MetadataJsonPath"
      }

      Write-Verbose "Found metadata file: $MetadataJsonPath"
      Write-Verbose 'Using metadata for chapter information...'

      $ConvertChaptersScript = Join-Path $ScriptDir 'convert_chapters.py'

      if (-not (Test-Path -LiteralPath $ConvertChaptersScript -PathType Leaf)) {
        throw "Required helper script was not found: $ConvertChaptersScript"
      }

      & $PythonExe @PythonArgs $ConvertChaptersScript $MetadataJsonPath --output $ChaptersFile --total-duration $TotalDuration
      if ($LASTEXITCODE -ne 0) {
        throw "convert_chapters.py failed with exit code $LASTEXITCODE"
      }

      if (-not (Test-Path -LiteralPath $ChaptersFile -PathType Leaf)) {
        throw "Expected temporary chapter metadata file was not created: $ChaptersFile"
      }
    } else {
      Write-Verbose 'No metadata.json or chapters.json found, using MP3 filenames for chapters...'

      $ChapterLines = @(';FFMETADATA1', '')

      $currentTime = 0
      foreach ($file in $AudioFiles) {
        # Get duration
        $durationText = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$($file.FullName)" 2>$null

        $durationValue = 0.0
        if (-not [double]::TryParse($durationText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$durationValue)) {
          throw "Could not determine duration for audio file: $($file.FullName)"
        }

        $duration = [Math]::Floor($durationValue)

        # Write chapter metadata
        $nextTime = $currentTime + $duration

        $ChapterLines += @(
          '[CHAPTER]',
          'TIMEBASE=1/1',
          "START=$currentTime",
          "END=$nextTime",
          "title=$($file.BaseName)",
          ''
        )

        $currentTime = $nextTime
      }

      Write-Utf8NoBomFile -Path $ChaptersFile -Content $ChapterLines
    }

    # Get number of logical processors for threading
    $threads = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

    # Construct FFmpeg command.
    # The final M4B is written directly to the resolved output directory.
    $OutputFilePath = $FinalOutputPath

    $ffmpegArgs = @(
      '-hwaccel', 'auto',
      '-threads', $threads,
      '-y',
      '-f', 'concat',
      '-safe', '0',
      '-i', $AudioFilesList,
      '-i', $ChaptersFile
    )

    if ($CoverImagePath) {
      $ffmpegArgs += @(
        '-i', $CoverImagePath,
        '-map', '0:a',
        '-map', '2:v',
        '-map_metadata', '1',
        '-map_chapters', '1',
        '-disposition:v', 'attached_pic'
      )
    } else {
      $ffmpegArgs += @(
        '-map', '0:a',
        '-map_metadata', '1',
        '-map_chapters', '1'
      )
    }

    $ffmpegArgs += @(
      '-metadata', "album=$bookTitle",
      '-metadata', "title=$bookTitle",
      '-metadata', "artist=$author",
      '-metadata', "album_artist=$author",
      '-metadata', "author=$author",
      '-metadata', 'genre=Audiobook'
    )

    if ($TelegramCompatible) {
      $ffmpegArgs += @(
        '-metadata', 'media_type=1',
        '-c:a', 'aac',
        '-profile:a', 'aac_low',
        '-b:a', '64k',
        '-ac', '2',
        '-ar', '44100',
        '-avoid_negative_ts', 'make_zero',
        '-fflags', '+genpts',
        '-movflags', '+faststart'
      )
    } else {
      $ffmpegArgs += @(
        '-c:a', 'aac',
        '-aac_coder', 'twoloop',
        '-ac', '2',
        '-ar', '44100',
        '-movflags', '+faststart'
      )

      if ($bitrateArgs.Count -gt 0) {
        $ffmpegArgs += $bitrateArgs
      }
    }

    if ($CoverImagePath) {
      $ffmpegArgs += @(
        '-c:v', 'mjpeg',
        '-metadata:s:v', 'title=Cover',
        '-metadata:s:v', 'comment=Cover (front)'
      )
    }

    $ffmpegArgs += $OutputFilePath

    Write-Verbose 'Converting to M4B format...'
    Write-Verbose "FFmpeg output file: $OutputFilePath"

    & ffmpeg @ffmpegArgs

    $ffmpegExitCode = $LASTEXITCODE

    if ($ffmpegExitCode -eq 0) {
      Write-Verbose "`rConversion complete!     "
      Write-Verbose "Final output file: $FinalOutputPath"

      if ($TelegramCompatible) {
        $extradataSize = & ffprobe -v quiet -select_streams a:0 -show_entries stream=extradata_size -of csv=p=0 "$FinalOutputPath" 2>$null

        if ($extradataSize -eq '2') {
          Write-Host "Telegram compatibility check passed: extradata_size = 2"
        } else {
          Write-Warning "Telegram compatibility check warning: extradata_size = $extradataSize. This file may not work correctly in Telegram."
        }
      }

      Write-Verbose 'You can now test the audiobook in your preferred player.'
    } else {
      Write-Error "`rConversion failed!     "
      throw "FFmpeg exited with code $ffmpegExitCode"
    }

    return $FinalOutputPath

  } finally {
    if ($TempRoot -and (Test-Path -LiteralPath $TempRoot -PathType Container)) {
      Write-Verbose "Cleaning up temporary files directory: $TempRoot"
      Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Pop-Location
  }
}

# Process each provided directory
$HadErrors = $false
$ProcessedCount = 0
$FailedCount = 0
$FinalOutputPaths = @()

foreach ($dir in $AudiobookInputDirs) {
  try {
    $FinalOutputPath = Convert-AudiobookDirectory -Directory $dir

    if ($FinalOutputPath) {
      $FinalOutputPaths += $FinalOutputPath
    }

    $ProcessedCount++
    Write-Verbose "Completed processing: $dir"
    Write-Verbose '----------------------------------------'
  } catch {
    $HadErrors = $true
    $FailedCount++
    Write-Error "Failed processing: $dir"
    Write-Error $_
    Write-Verbose '----------------------------------------'
  }
}

if ($FinalOutputPaths.Count -gt 0) {
  Write-Host ''
  Write-Host 'Processed files saved to:'
  foreach ($path in $FinalOutputPaths) {
    Write-Host "  $path"
  }
}

if ($HadErrors) {
  Write-Error "Finished with errors. Successful: $ProcessedCount. Failed: $FailedCount."
  exit 1
}

Write-Host "All audiobooks processed successfully! Successful: $ProcessedCount."
