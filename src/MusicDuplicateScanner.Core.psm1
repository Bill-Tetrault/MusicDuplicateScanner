#requires -Version 5.1
<#
    MusicDuplicateScanner.Core.psm1

    Pure business-logic layer for the Music Duplicate Scanner.
    Deliberately has NO dependency on WPF / Windows Forms / Add-Type,
    so it can be imported and unit-tested on any platform (Windows,
    Linux, macOS) with PowerShell 5.1+ or PowerShell 7+.

    The GUI entry point (MusicDuplicateScanner.ps1) dot-sources / imports
    this module and layers presentation logic on top of it.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# TagLibSharp integration
# ---------------------------------------------------------------------------

$script:TagLibLoaded = $false

function Test-TagLibSharpAvailable {
    <#
        .SYNOPSIS
            Attempts to load TagLibSharp.dll from well-known locations and
            reports whether metadata reading is available.
        .PARAMETER SearchPaths
            Ordered list of candidate paths to probe. Defaults to the
            script root and a "lib" subfolder next to it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$SearchPaths = @()
    )

    if ($script:TagLibLoaded) { return $true }

    foreach ($path in $SearchPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }

        try {
            [void][Reflection.Assembly]::LoadFrom($path)
            $script:TagLibLoaded = $true
            Write-Verbose "Loaded TagLibSharp from $path"
            return $true
        } catch {
            Write-Verbose "Failed loading TagLibSharp from $path : $($_.Exception.Message)"
        }
    }

    return $false
}

function Get-AudioMetadata {
    <#
        .SYNOPSIS
            Reads audio tag metadata via TagLibSharp. Falls back to a
            filename-derived title and a MetadataStatus of 'Unavailable'
            if TagLibSharp could not be loaded, so name-based duplicate
            detection still works without the DLL.

        .NOTES
            TagLibSharp's [TagLib.File]::Create() auto-detects the concrete
            format from file content, not the extension, and already
            supports MP3, FLAC, WAV, M4A/AAC, OGG, and WMA/ASF without any
            per-format branching here - so this function needed no changes
            to support the wider default extension list in
            Get-DefaultAppSettings; only Get-MusicFile's enumeration was
            MP3-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $meta = [ordered]@{
        Title            = $null
        Album            = $null
        Artists          = $null
        Track            = $null
        Year             = $null
        DurationSeconds  = $null
        Bitrate          = $null
        SampleRate       = $null
        MetadataKey      = $null
        MetadataStatus   = 'Unavailable'
    }

    if (-not $script:TagLibLoaded) {
        $meta.Title = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        return [pscustomobject]$meta
    }

    $file = $null
    try {
        $file = [TagLib.File]::Create($Path)
        $artists = @($file.Tag.Performers | Where-Object { $_ -and $_.Trim() })
        $title = $file.Tag.Title
        if (-not $title) {
            $title = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        }

        $meta.Title = $title
        $meta.Album = $file.Tag.Album
        $meta.Artists = ($artists -join '; ')
        $meta.Track = [int]$file.Tag.Track
        $meta.Year = [int]$file.Tag.Year
        $meta.DurationSeconds = [math]::Round($file.Properties.Duration.TotalSeconds, 0)
        $meta.Bitrate = $file.Properties.AudioBitrate
        $meta.SampleRate = $file.Properties.AudioSampleRate

        $safeTitle = if ($null -ne $meta.Title) { [string]$meta.Title } else { '' }
        $safeArtists = if ($null -ne $meta.Artists) { [string]$meta.Artists } else { '' }
        $safeAlbum = if ($null -ne $meta.Album) { [string]$meta.Album } else { '' }

        $parts = @(
            $safeTitle.Trim().ToLowerInvariant(),
            $safeArtists.Trim().ToLowerInvariant(),
            $safeAlbum.Trim().ToLowerInvariant(),
            ([string]$meta.Track),
            ([string]$meta.Year),
            ([string]$meta.DurationSeconds)
        )

        $meta.MetadataKey = ($parts -join '|')
        $meta.MetadataStatus = 'OK'
    } catch {
        $meta.MetadataStatus = "Error: $($_.Exception.Message)"
        if (-not $meta.Title) {
            $meta.Title = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        }
    } finally {
        # Always dispose, even if Create()/tag reads throw partway through,
        # to avoid leaking open file handles on large libraries.
        if ($file) { $file.Dispose() }
    }

    [pscustomobject]$meta
}

# ---------------------------------------------------------------------------
# Name normalization / similarity
# ---------------------------------------------------------------------------

function ConvertTo-NormalizedTrackName {
    <#
        .SYNOPSIS
            Lower-cases a filename, strips its extension, removes bracketed
            annotations and common "noise" words (copy, remaster, edit, ...),
            and collapses non-alphanumeric characters to single spaces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Name
    )

    if (-not $Name) { return '' }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()

    # Strip trailing OS-generated copy-counter suffixes BEFORE the generic
    # bracket-to-space collapse below, so they can be told apart from
    # meaningful bracketed content (e.g. a release year). Without this,
    # 'Song.mp3' and 'Song (1).mp3' - Windows' own auto-numbering when you
    # copy a file into the same folder, arguably the single most common
    # real-world duplicate pattern - normalized to different strings and
    # were silently never grouped as duplicate candidates at all.
    #
    # Any trailing bracketed run of 1-2 digits is treated as a copy counter
    # (rule 2). A 4-digit run like '(2019)' deliberately does NOT match,
    # since [Explicit] (2019) is an existing, intentional test case where
    # the year must be preserved as a meaningful token, not stripped as a
    # copy marker. A trailing 'copy'/'- copy'/'- copy (N)' (rule 1) matches
    # regardless of digit count, since the word itself is unambiguous.
    $base = $base -replace '(?i)\s*[-_]?\s*copy\s*[\(\[]\s*\d+\s*[\)\]]\s*$', ''
    $base = $base -replace '(?i)\s*[-_]?\s*copy\s*$', ''
    $base = $base -replace '\s*[\(\[]\s*\d{1,2}\s*[\)\]]\s*$', ''

    $base = $base -replace '[\[\]\(\)\{\}]', ' '
    $base = $base -replace '(?i)\b(copy|duplicate|dup|remaster(ed)?|version|mix|edit|explicit|clean)\b', ' '
    $base = $base -replace '[^a-z0-9]+', ' '
    return (($base -replace '\s+', ' ').Trim())
}

function Get-NameTokenSet {
    <#
        .SYNOPSIS
            Returns a HashSet[string] of normalized tokens for a filename,
            used for Jaccard similarity comparisons.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param(
        [string]$Name
    )

    $tokens = (ConvertTo-NormalizedTrackName -Name $Name) -split ' ' | Where-Object { $_ }
    return (New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$tokens))
}

function Get-JaccardSimilarity {
    <#
        .SYNOPSIS
            Jaccard similarity (intersection over union) between two token sets.
            Two empty sets are treated as identical (1.0).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [System.Collections.Generic.HashSet[string]]$Left,
        [System.Collections.Generic.HashSet[string]]$Right
    )

    if (($Left.Count -eq 0) -and ($Right.Count -eq 0)) { return 1.0 }

    $intersect = 0
    foreach ($item in $Left) {
        if ($Right.Contains($item)) { $intersect++ }
    }

    $union = $Left.Count + $Right.Count - $intersect
    if ($union -eq 0) { return 0.0 }
    return ($intersect / $union)
}

function Test-ValueMatch {
    <#
        .SYNOPSIS
            Case-insensitive, whitespace-trimmed equality check that treats
            null/empty values as non-matching (so two blank tags never
            "match" each other and inflate confidence).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $A,
        $B
    )

    if ([string]::IsNullOrWhiteSpace([string]$A) -or [string]::IsNullOrWhiteSpace([string]$B)) {
        return $false
    }

    return ([string]$A).Trim().ToLowerInvariant() -eq ([string]$B).Trim().ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Confidence scoring
# ---------------------------------------------------------------------------

function Get-PropertyValue {
    <#
        .SYNOPSIS
            Safely reads a property from an object under Set-StrictMode,
            returning $null instead of throwing when the property is
            absent (e.g. a partially-populated test double or a hash-
            matched record that skips optional tag fields).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string]$Name
    )

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ConfidenceDetails {
    <#
        .SYNOPSIS
            Scores how confident we are that two file records are duplicates.
            An exact SHA-256 hash match always scores 100. Otherwise the
            score is a weighted sum of filename similarity, tag matches,
            duration closeness, and file-size closeness, capped at 100.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )

    $score = 0
    $reasons = New-Object System.Collections.Generic.List[string]
    $hashMatched = $false

    $leftHash = Get-PropertyValue -InputObject $Left -Name 'Hash'
    $rightHash = Get-PropertyValue -InputObject $Right -Name 'Hash'

    if ($leftHash -and $rightHash -and $leftHash -eq $rightHash) {
        $score += 100
        $hashMatched = $true
        $reasons.Add('Exact file hash match')
    } else {
        $leftTitle = Get-PropertyValue $Left 'Title'; $rightTitle = Get-PropertyValue $Right 'Title'
        $leftArtists = Get-PropertyValue $Left 'Artists'; $rightArtists = Get-PropertyValue $Right 'Artists'
        $leftAlbum = Get-PropertyValue $Left 'Album'; $rightAlbum = Get-PropertyValue $Right 'Album'
        $leftTrack = Get-PropertyValue $Left 'Track'; $rightTrack = Get-PropertyValue $Right 'Track'
        $leftYear = Get-PropertyValue $Left 'Year'; $rightYear = Get-PropertyValue $Right 'Year'
        $leftDuration = Get-PropertyValue $Left 'DurationSeconds'; $rightDuration = Get-PropertyValue $Right 'DurationSeconds'
        $leftSize = Get-PropertyValue $Left 'Size'; $rightSize = Get-PropertyValue $Right 'Size'

        $nameSimilarity = Get-JaccardSimilarity -Left $Left.NameTokens -Right $Right.NameTokens
        $namePoints = [math]::Round($nameSimilarity * 35, 0)

        if ($namePoints -gt 0) {
            $score += $namePoints
            $reasons.Add("Name similarity $([math]::Round($nameSimilarity * 100, 0))%")
        }

        if (Test-ValueMatch $leftTitle $rightTitle) {
            $score += 20
            $reasons.Add('Title match')
        }

        if (Test-ValueMatch $leftArtists $rightArtists) {
            $score += 15
            $reasons.Add('Artist match')
        }

        if (Test-ValueMatch $leftAlbum $rightAlbum) {
            $score += 10
            $reasons.Add('Album match')
        }

        if ($leftTrack -and $rightTrack -and $leftTrack -eq $rightTrack) {
            $score += 5
            $reasons.Add('Track match')
        }

        if ($leftYear -and $rightYear -and $leftYear -eq $rightYear) {
            $score += 5
            $reasons.Add('Year match')
        }

        if ($leftDuration -and $rightDuration) {
            $delta = [math]::Abs($leftDuration - $rightDuration)
            if ($delta -eq 0) {
                $score += 12
                $reasons.Add('Exact duration match')
            } elseif ($delta -le 2) {
                $score += 8
                $reasons.Add('Near duration match')
            }
        }

        if ($leftSize -and $rightSize) {
            $sizeDelta = [math]::Abs($leftSize - $rightSize)
            $larger = [math]::Max($leftSize, $rightSize)

            if ($larger -gt 0) {
                $ratio = 1 - ($sizeDelta / $larger)
                if ($ratio -ge 0.98) {
                    $score += 8
                    $reasons.Add('Very similar file size')
                } elseif ($ratio -ge 0.90) {
                    $score += 4
                    $reasons.Add('Similar file size')
                }
            }
        }
    }

    if ($score -gt 100) { $score = 100 }

    $recommendation = if ($hashMatched -or $score -ge 90) {
        'Very High'
    } elseif ($score -ge 75) {
        'High'
    } elseif ($score -ge 55) {
        'Medium'
    } else {
        'Low'
    }

    return [pscustomobject]@{
        Score           = [int]$score
        Reasons         = ($reasons -join '; ')
        Recommendation  = $recommendation
        ExactHashMatch  = $hashMatched
    }
}

function Select-PreferredFile {
    <#
        .SYNOPSIS
            Decides which of two candidate duplicate files to keep, based on
            bitrate, sample rate, size, metadata completeness, and recency.

        .NOTES
            REGRESSION FIX: earlier versions cast [datetime]::ToFileTimeUtc()
            (a 64-bit tick count, e.g. 134317609806497344) to [int], which
            overflows Int32.MaxValue (2,147,483,647) and throws
            "Value was either too large or too small for an Int32."
            All accumulator variables here are explicitly [long] (Int64),
            and recency is scored using Ticks/1e9 (still monotonic, always
            fits comfortably in Int64) rather than a raw file-time cast to
            Int32. See tests/MusicDuplicateScanner.Core.Tests.ps1 for a
            regression test using a real-world large file time.

            EXACT-HASH TIE-BREAK: when both files carry a SHA256 Hash (i.e.
            -HashAllCandidates was used on the scan) and the hashes are
            equal, the files are byte-for-byte identical, so bitrate/sample
            rate/size scoring is moot - they are the same quality by
            definition. In that case, prefer keeping the copy that lives in
            a subfolder of the scanned library over one sitting directly in
            the library root, since a stray copy dropped at the top level is
            more likely the accidental duplicate than the one filed away
            into an album/artist folder. This only applies when both A and B
            carry a Directory and the caller passes -RootPath; otherwise it
            is skipped and scoring falls through to the rules below
            unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $A,
        [Parameter(Mandatory)] $B,
        [string]$RootPath
    )

    $hashA = Get-PropertyValue -InputObject $A -Name 'Hash'
    $hashB = Get-PropertyValue -InputObject $B -Name 'Hash'

    if ($hashA -and $hashB -and $hashA -eq $hashB -and $RootPath) {
        $normRoot = $RootPath.TrimEnd('\', '/')
        $dirA = (Get-PropertyValue -InputObject $A -Name 'Directory')
        $dirB = (Get-PropertyValue -InputObject $B -Name 'Directory')
        $aAtRoot = $dirA -and $dirA.TrimEnd('\', '/').Equals($normRoot, [System.StringComparison]::OrdinalIgnoreCase)
        $bAtRoot = $dirB -and $dirB.TrimEnd('\', '/').Equals($normRoot, [System.StringComparison]::OrdinalIgnoreCase)

        if ($aAtRoot -and -not $bAtRoot) {
            return @{ Keep = $B; Delete = $A; Basis = 'Exact hash match - kept the copy in a subfolder over the one at the library root' }
        }
        if ($bAtRoot -and -not $aAtRoot) {
            return @{ Keep = $A; Delete = $B; Basis = 'Exact hash match - kept the copy in a subfolder over the one at the library root' }
        }
        # Both (or neither) at root - fall through to the scoring below
        # (e.g. recency) as a further tie-break.
    }

    [long]$scoreA = 0
    [long]$scoreB = 0

    foreach ($candidate in @(@{ Item = $A; Ref = 'A' }, @{ Item = $B; Ref = 'B' })) {
        $item = $candidate.Item
        [long]$score = 0

        if ($item.Bitrate) { $score += [long]$item.Bitrate }
        if ($item.SampleRate) { $score += [long]($item.SampleRate / 100) }
        if ($item.Size) { $score += [long]($item.Size / 1MB) }
        if ($item.MetadataStatus -eq 'OK') { $score += 25 }
        if ($item.LastWriteTime) {
            # Ticks (100ns units) scaled down; stays well within Int64 range
            # for any real filesystem timestamp and is monotonic with time.
            $score += [long]([datetime]$item.LastWriteTime).ToUniversalTime().Ticks / 1000000000
        }

        if ($candidate.Ref -eq 'A') { $scoreA = $score } else { $scoreB = $score }
    }

    if ($scoreA -ge $scoreB) {
        return @{ Keep = $A; Delete = $B; Basis = 'Preferred by bitrate/sample rate/size/metadata/date scoring' }
    }

    return @{ Keep = $B; Delete = $A; Basis = 'Preferred by bitrate/sample rate/size/metadata/date scoring' }
}

# ---------------------------------------------------------------------------
# File enumeration & candidate pairing
# ---------------------------------------------------------------------------

function ConvertTo-ExtensionFilterList {
    <#
        .SYNOPSIS
            Parses and sanitizes a user-supplied, free-text extension list
            (comma/semicolon/space/pipe separated, with or without leading
            dots or wildcards, any casing) into a clean, deduplicated array
            of lowercase bare extensions (no dot) safe to use for file
            enumeration.

        .DESCRIPTION
            SECURITY: this is the only place raw, user-controlled text from
            the GUI's "File types" box (or a settings.json a user could hand
            -edit) enters the file-enumeration path. Every token is matched
            against a strict `^[A-Za-z0-9]{1,15}$` allow-list AFTER stripping
            leading dots/wildcards/whitespace, so it is impossible to smuggle
            path separators, `..`, wildcards, or PowerShell/regex metacharacters
            through into a filesystem filter. Tokens that do not match are
            silently dropped rather than throwing, so one bad token (e.g. a
            stray comma) doesn't block an entire scan. The result is capped
            at 50 extensions as a defense-in-depth bound against a pathological
            input causing excessive enumeration passes. If every token is
            invalid/empty, the caller's DefaultExtensions are returned so a
            scan never silently matches zero files nor falls back to "all
            files" (which would be a surprising, potentially destructive
            behavior change for quarantine actions).

        .OUTPUTS
            string[] of lowercase bare extensions, e.g. @('mp3','flac').
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$RawList,
        [string[]]$DefaultExtensions = @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
    )

    if ([string]::IsNullOrWhiteSpace($RawList)) { return $DefaultExtensions }

    $tokens = $RawList -split '[,;|\s]+'
    $clean = New-Object System.Collections.Generic.List[string]
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($token in $tokens) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        $candidate = $token.Trim().TrimStart('.', '*').ToLowerInvariant()
        if ($candidate -notmatch '^[a-z0-9]{1,15}$') { continue }
        if ($clean.Count -ge 50) { break }
        if ($seen.Add($candidate)) { $clean.Add($candidate) }
    }

    if ($clean.Count -eq 0) { return $DefaultExtensions }
    return $clean.ToArray()
}

function Get-MusicFile {
    <#
        .SYNOPSIS
            Enumerates library files under a root path matching the given
            extensions, optionally recursing.

        .DESCRIPTION
            Takes a single Get-ChildItem pass (not one call per extension,
            and not -Include, which silently no-ops unless combined with
            -Recurse or a trailing '\*' on -Path - a real PowerShell
            surprise that would otherwise make non-recursive multi-extension
            scans quietly return zero files) and filters by extension
            in-memory via a case-insensitive HashSet lookup, so adding more
            extensions costs O(1) per file rather than another full
            directory walk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RootPath,
        [bool]$Recurse = $true,
        [string[]]$Extensions = @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
    )

    $extSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Extensions, [System.StringComparer]::OrdinalIgnoreCase)

    $params = @{
        Path         = $RootPath
        File         = $true
        ErrorAction  = 'SilentlyContinue'
    }
    if ($Recurse) { $params.Recurse = $true }

    Get-ChildItem @params | Where-Object { $extSet.Contains($_.Extension.TrimStart('.')) }
}

function Get-DuplicateCandidatePair {
    <#
        .SYNOPSIS
            Groups file records by normalized filename and by metadata key,
            and returns the set of unique candidate pairs to score. Kept
            separate from Get-ConfidenceDetails so the pairing strategy can
            be unit-tested independently of scoring.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Items
    )

    $byName = @($Items | Group-Object BaseNameNormalized | Where-Object { $_.Count -gt 1 -and $_.Name })
    $byMetadata = @($Items | Where-Object { $_.MetadataKey } | Group-Object MetadataKey | Where-Object { $_.Count -gt 1 })

    $candidateMap = [ordered]@{}

    # NOTE: earlier versions used "@($byName + $byMetadata)" which throws
    # "does not contain a method named 'op_Addition'" whenever Group-Object
    # returns exactly one group, because PowerShell unwraps single-element
    # results to a scalar [GroupInfo] instead of an array, and GroupInfo
    # has no '+' operator. Forcing both sides to arrays with @(...) before
    # concatenating avoids that. Covered by a regression test.
    foreach ($group in (@($byName) + @($byMetadata))) {
        if ($null -eq $group) { continue }
        $groupItems = @($group.Group)

        for ($i = 0; $i -lt $groupItems.Count; $i++) {
            for ($j = $i + 1; $j -lt $groupItems.Count; $j++) {
                $left = $groupItems[$i]
                $right = $groupItems[$j]
                $pairKey = (@($left.Path, $right.Path) | Sort-Object) -join '||'
                $candidateMap[$pairKey] = @($left, $right)
            }
        }
    }

    return $candidateMap
}

# ---------------------------------------------------------------------------
# Quarantine path mapping
# ---------------------------------------------------------------------------

function Get-QuarantineDestinationPath {
    <#
        .SYNOPSIS
            Computes a collision-free destination path under a quarantine
            root for a given source file, preserving the original drive and
            folder structure (e.g. C:\Music\A\song.mp3 ->
            <quarantine>\C\Music\A\song.mp3). If the destination already
            exists, a timestamp suffix is appended instead of overwriting.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$QuarantineRoot,
        [scriptblock]$ExistsTest = { Test-Path -LiteralPath $args[0] }
    )

    # NOTE: deliberately does NOT use [System.IO.Path]::GetFullPath/GetPathRoot
    # or Join-Path here. Both are platform- and PSDrive-dependent: on a
    # non-Windows host (or a Windows host without 'D:' mapped), resolving a
    # literal Windows path like 'D:\Quarantine' throws or behaves
    # differently than on the target Windows environment. Since this tool's
    # inputs are always Windows-style paths regardless of which OS runs the
    # unit tests, we parse the drive/UNC prefix ourselves with a fixed
    # regex so behavior is 100% deterministic on every platform.
    if ($SourcePath -match '^(?<drive>[A-Za-z]):[\\/](?<rest>.*)$') {
        $driveLetter = $Matches['drive'].ToUpperInvariant()
        $relative = $Matches['rest']
    } elseif ($SourcePath -match '^[\\/]{2}(?<rest>.+)$') {
        $driveLetter = 'UNC'
        $relative = $Matches['rest']
    } else {
        $driveLetter = 'UNC'
        $relative = $SourcePath.TrimStart('\', '/')
    }

    $relative = ($relative -replace '/', '\').TrimStart('\')

    # Plain backslash string-joining (not [IO.Path]::Combine) keeps the
    # separator consistently '\' regardless of the host OS, since the
    # destination is always a Windows path in production.
    $root = $QuarantineRoot.TrimEnd('\', '/')
    $destination = "$root\$driveLetter\$relative"

    if (& $ExistsTest $destination) {
        $lastSlash = $destination.LastIndexOf('\')
        $dir = $destination.Substring(0, $lastSlash)
        $leafName = $destination.Substring($lastSlash + 1)
        $extIndex = $leafName.LastIndexOf('.')
        if ($extIndex -gt 0) {
            $name = $leafName.Substring(0, $extIndex)
            $ext = $leafName.Substring($extIndex)
        } else {
            $name = $leafName
            $ext = ''
        }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmssfff')
        $destination = "$dir\$name.$stamp$ext"
    }

    return $destination
}

function Move-QuarantineBatchCore {
    <#
        .SYNOPSIS
            Moves a batch of selected duplicate-scan rows into a quarantine
            folder, reporting per-file progress through a thread-safe queue
            so a caller running this on a background runspace can drive a
            UI progress bar without blocking the UI thread.

        .DESCRIPTION
            Pure logic, no WPF/UI dependency, so it can run inside a
            background [System.Management.Automation.PowerShell] runspace
            exactly like Start-DuplicateScanCore does for scanning, and can
            be unit tested directly. Each processed row enqueues a
            'PROGRESS:<index>:<total>:<message>' string onto ProgressQueue
            (when supplied) so the UI thread can parse the index/total to
            update a determinate progress bar and show the message text.

        .OUTPUTS
            A pscustomobject with ManifestEntries (for the undo CSV), Moved,
            Failed, Total, and Cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$SelectedRows,
        [Parameter(Mandatory)] [string]$QuarantineRoot,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$ProgressQueue,
        [hashtable]$CancelFlag
    )

    New-Item -ItemType Directory -Path $QuarantineRoot -Force -ErrorAction SilentlyContinue | Out-Null

    $manifestEntries = New-Object System.Collections.Generic.List[object]
    $moved = 0
    $failed = 0
    $total = $SelectedRows.Count
    $index = 0
    $cancelled = $false

    foreach ($row in $SelectedRows) {
        $index++

        if ($CancelFlag -and $CancelFlag.Cancelled) {
            $cancelled = $true
            if ($ProgressQueue) { $ProgressQueue.Enqueue("PROGRESS:$($index - 1):${total}:Quarantine cancelled.") }
            break
        }

        try {
            if (-not (Test-Path -LiteralPath $row.DeletePath)) {
                if ($ProgressQueue) { $ProgressQueue.Enqueue("PROGRESS:${index}:${total}:Skipped (already gone): $($row.DeletePath)") }
                continue
            }

            $destination = Get-QuarantineDestinationPath -SourcePath $row.DeletePath -QuarantineRoot $QuarantineRoot
            $destDir = Split-Path -Path $destination -Parent
            New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null

            Move-Item -LiteralPath $row.DeletePath -Destination $destination -Force
            $manifestEntries.Add([pscustomobject]@{
                OriginalPath   = $row.DeletePath
                QuarantinePath = $destination
                MovedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
            })
            $moved++
            if ($ProgressQueue) { $ProgressQueue.Enqueue("PROGRESS:${index}:${total}:Quarantined $($row.DeletePath) -> $destination") }
        } catch {
            $failed++
            if ($ProgressQueue) { $ProgressQueue.Enqueue("PROGRESS:${index}:${total}:Quarantine failed for $($row.DeletePath): $($_.Exception.Message)") }
        }
    }

    [pscustomobject]@{
        ManifestEntries = $manifestEntries
        Moved           = $moved
        Failed          = $failed
        Total           = $total
        Cancelled       = $cancelled
    }
}

# ---------------------------------------------------------------------------
# Settings persistence (JSON, cross-platform)
# ---------------------------------------------------------------------------

function Get-DefaultAppSettings {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        LibraryPath      = ''
        QuarantinePath   = ''
        Recurse          = $true
        ComputeHash      = $true
        Threshold        = 75
        FileExtensions   = 'mp3, flac, wav, m4a, ogg, wma, aac'
    }
}

function Import-AppSettings {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return Get-DefaultAppSettings
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
        $defaults = Get-DefaultAppSettings
        foreach ($prop in $defaults.PSObject.Properties.Name) {
            if (-not (Get-Member -InputObject $loaded -Name $prop -ErrorAction SilentlyContinue)) {
                $loaded | Add-Member -NotePropertyName $prop -NotePropertyValue $defaults.$prop
            }
        }
        return $loaded
    } catch {
        Write-Verbose "Failed to read settings from $Path : $($_.Exception.Message)"
        return Get-DefaultAppSettings
    }
}

function Export-AppSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject]$Settings,
        [Parameter(Mandatory)] [string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Start-DuplicateScanCore {
    <#
        .SYNOPSIS
            Pure orchestration wrapper around this module's building blocks;
            designed to run inside a background PowerShell instance/runspace.
            Reports progress via $ProgressQueue.Enqueue(...) so the caller
            can drain it on a UI timer without cross-thread control access.

            Lives in the Core module (not the GUI script) specifically so a
            background runspace can reach it with a plain
            Import-Module $CorePath -Force, instead of the previous approach
            of extracting the function body as text via
            (Get-Item Function:...).ScriptBlock.ToString() and dot-sourcing it
            as an anonymous scriptblock. That extraction only captured the
            scriptblock body (param block + statements), not a
            'function Name { ... }' wrapper - dot-sourcing it therefore
            executed the body immediately, once, with every parameter
            unbound (empty/default), instead of defining a callable
            function. That produced a premature 'Library path is empty.'
            failure even when a valid, non-empty path was passed from the
            GUI.
    #>
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [bool]$UseRecurse,
        [int]$Threshold,
        [bool]$HashAllCandidates,
        [string]$CorePath,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$ProgressQueue,
        [hashtable]$CancelFlag,
        [string[]]$Extensions
    )

    if ([string]::IsNullOrWhiteSpace($RootPath)) { throw 'Library path is empty.' }
    if (-not (Test-Path -LiteralPath $RootPath)) { throw "Path does not exist: $RootPath" }

    # Defense in depth: re-validate extensions here too, since this function
    # is a public module entry point that other callers (scripts, future
    # UIs) may invoke directly with unsanitized input, not only the GUI
    # (which already sanitizes via ConvertTo-ExtensionFilterList before
    # calling in). An empty/omitted array falls back to the module default.
    $safeExtensions = ConvertTo-ExtensionFilterList -RawList ($Extensions -join ',')

    $ProgressQueue.Enqueue("Scanning $RootPath")
    $files = @(Get-MusicFile -RootPath $RootPath -Recurse $UseRecurse -Extensions $safeExtensions)
    $ProgressQueue.Enqueue("Found $($files.Count) candidate file(s) matching: $($safeExtensions -join ', ')")

    $tagLibCandidates = @(
        (Join-Path (Split-Path $CorePath -Parent) 'TagLibSharp.dll'),
        (Join-Path (Split-Path $CorePath -Parent) 'lib\TagLibSharp.dll')
    )
    $tagLibReady = Test-TagLibSharpAvailable -SearchPaths $tagLibCandidates
    if ($tagLibReady) {
        $ProgressQueue.Enqueue('TagLibSharp loaded - tag metadata matching enabled.')
    } else {
        $ProgressQueue.Enqueue('TagLibSharp.dll not found - continuing with filename/size/hash matching only.')
    }

    $items = New-Object System.Collections.Generic.List[object]
    $processed = 0

    foreach ($file in $files) {
        if ($CancelFlag.Cancelled) { $ProgressQueue.Enqueue('Scan cancelled during metadata read.'); return @() }

        $meta = Get-AudioMetadata -Path $file.FullName

        $items.Add([pscustomobject]@{
            Path                = $file.FullName
            Directory           = $file.DirectoryName
            FileName            = $file.Name
            BaseNameNormalized  = ConvertTo-NormalizedTrackName -Name $file.Name
            NameTokens          = Get-NameTokenSet -Name $file.Name
            Size                = $file.Length
            SizeMB              = [math]::Round($file.Length / 1MB, 2)
            LastWriteTime       = $file.LastWriteTime
            Hash                = $null
            Title               = $meta.Title
            Album               = $meta.Album
            Artists             = $meta.Artists
            Track               = $meta.Track
            Year                = $meta.Year
            DurationSeconds     = $meta.DurationSeconds
            Bitrate             = $meta.Bitrate
            SampleRate          = $meta.SampleRate
            MetadataKey         = $meta.MetadataKey
            MetadataStatus      = $meta.MetadataStatus
        })

        $processed++
        if ($processed % 250 -eq 0) {
            $ProgressQueue.Enqueue("Read metadata for $processed / $($files.Count) files")
        }
    }

    $candidateMap = Get-DuplicateCandidatePair -Items $items
    $ProgressQueue.Enqueue("Built $($candidateMap.Count) candidate pairs from name and metadata grouping")

    if ($HashAllCandidates -and $candidateMap.Count -gt 0) {
        $uniquePaths = @($candidateMap.Values | ForEach-Object { $_ } | Select-Object -ExpandProperty Path -Unique)
        $lookup = @{}
        $hashDone = 0

        foreach ($path in $uniquePaths) {
            if ($CancelFlag.Cancelled) { $ProgressQueue.Enqueue('Scan cancelled during hashing.'); return @() }

            try {
                # -ErrorAction Stop is required here: Get-FileHash writes
                # transient I/O failures (e.g. a network-drive read glitch)
                # as a NON-terminating error and returns nothing for that
                # item. Without -Stop, the catch block below never runs for
                # that real failure - instead $() is $null, and under this
                # module's Set-StrictMode -Version Latest, the subsequent
                # ".Hash" property access on $null itself throws "The
                # property 'Hash' cannot be found on this object", which
                # masks the actual underlying error in the log.
                $lookup[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch {
                $lookup[$path] = $null
                $ProgressQueue.Enqueue("Hash failed for $path : $($_.Exception.Message)")
            }

            $hashDone++
            if ($hashDone % 100 -eq 0) {
                $ProgressQueue.Enqueue("Hashed $hashDone / $($uniquePaths.Count) candidate files")
            }
        }

        foreach ($item in $items) {
            if ($lookup.ContainsKey($item.Path)) { $item.Hash = $lookup[$item.Path] }
        }

        $ProgressQueue.Enqueue('SHA256 hashing complete for candidate files')
    }

    $results = foreach ($entry in $candidateMap.GetEnumerator()) {
        $left = $entry.Value[0]
        $right = $entry.Value[1]
        $details = Get-ConfidenceDetails -Left $left -Right $right

        if ($details.Score -lt $Threshold) { continue }

        $preference = Select-PreferredFile -A $left -B $right -RootPath $RootPath

        [pscustomobject]@{
            Selected        = $false
            Confidence      = $details.Score
            Recommendation  = $details.Recommendation
            KeepPath        = $preference.Keep.Path
            DeletePath      = $preference.Delete.Path
            KeepFileName    = $preference.Keep.FileName
            DeleteFileName  = $preference.Delete.FileName
            KeepSizeMB      = $preference.Keep.SizeMB
            DeleteSizeMB    = $preference.Delete.SizeMB
            KeepBitrate     = $preference.Keep.Bitrate
            DeleteBitrate   = $preference.Delete.Bitrate
            KeepDuration    = $preference.Keep.DurationSeconds
            DeleteDuration  = $preference.Delete.DurationSeconds
            ExactHashMatch  = $details.ExactHashMatch
            Basis           = $preference.Basis
            Reason          = $details.Reasons
            KeepMetadata    = "Title=$($preference.Keep.Title); Artist=$($preference.Keep.Artists); Album=$($preference.Keep.Album)"
            DeleteMetadata  = "Title=$($preference.Delete.Title); Artist=$($preference.Delete.Artists); Album=$($preference.Delete.Album)"
        }
    }

    $sorted = @(
        $results | Sort-Object -Property `
            @{Expression = 'Confidence'; Descending = $true}, `
            @{Expression = 'DeletePath'; Descending = $false}
    )

    $ProgressQueue.Enqueue("Scan complete. $($sorted.Count) matches met threshold $Threshold")
    return $sorted
}

Export-ModuleMember -Function `
    Test-TagLibSharpAvailable, `
    Get-AudioMetadata, `
    Get-PropertyValue, `
    ConvertTo-NormalizedTrackName, `
    Get-NameTokenSet, `
    Get-JaccardSimilarity, `
    Test-ValueMatch, `
    Get-ConfidenceDetails, `
    Select-PreferredFile, `
    Get-MusicFile, `
    ConvertTo-ExtensionFilterList, `
    Get-DuplicateCandidatePair, `
    Get-QuarantineDestinationPath, `
    Move-QuarantineBatchCore, `
    Get-DefaultAppSettings, `
    Import-AppSettings, `
    Export-AppSettings, `
    Start-DuplicateScanCore
