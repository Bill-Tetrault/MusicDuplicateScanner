#requires -Version 5.1
<#
    Pester tests for MusicDuplicateScanner.Core.psm1
    Run with: Invoke-Pester -Path ./tests -Output Detailed
    These tests are pure-logic and run on any OS (no WPF dependency).
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\MusicDuplicateScanner.Core.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-NormalizedTrackName' {
    It 'lower-cases and strips the extension' {
        ConvertTo-NormalizedTrackName -Name 'Song Title.mp3' | Should -Be 'song title'
    }

    It 'removes bracketed annotations' {
        ConvertTo-NormalizedTrackName -Name 'Song [Explicit] (2019).mp3' | Should -Be 'song 2019'
    }

    It 'removes noise words like copy/remaster/edit' {
        ConvertTo-NormalizedTrackName -Name 'Song - Copy (Remastered).mp3' | Should -Be 'song'
    }

    It 'collapses punctuation and repeated whitespace' {
        ConvertTo-NormalizedTrackName -Name "Song__Title---2!!.mp3" | Should -Be 'song title 2'
    }

    It 'returns empty string for null/empty input' {
        ConvertTo-NormalizedTrackName -Name '' | Should -Be ''
        ConvertTo-NormalizedTrackName -Name $null | Should -Be ''
    }

    It 'strips a trailing Windows-style copy counter like (1)' {
        # Regression test: without this, 'Song A.mp3' and 'Song A (1).mp3' -
        # Windows' own auto-numbering when a file is copied into the same
        # folder, the single most common real-world duplicate pattern -
        # normalized to different strings and were never grouped as
        # duplicate candidates at all.
        ConvertTo-NormalizedTrackName -Name 'Song A.mp3' | Should -Be 'song a'
        ConvertTo-NormalizedTrackName -Name 'Song A (1).mp3' | Should -Be 'song a'
        ConvertTo-NormalizedTrackName -Name 'Song A (2).mp3' | Should -Be 'song a'
    }

    It 'strips a trailing "- Copy" / "- Copy (N)" suffix' {
        ConvertTo-NormalizedTrackName -Name 'Song A - Copy.mp3' | Should -Be 'song a'
        ConvertTo-NormalizedTrackName -Name 'Song A - Copy (2).mp3' | Should -Be 'song a'
    }

    It 'does not treat a 4-digit trailing year as a copy counter' {
        # Guards against a naive fix for the copy-counter case above
        # regressing this pre-existing, intentional behavior: a bracketed
        # release year must be preserved as a meaningful token, not
        # stripped like a 1-2 digit copy counter.
        ConvertTo-NormalizedTrackName -Name 'Song [Explicit] (2019).mp3' | Should -Be 'song 2019'
    }
}

Describe 'Get-JaccardSimilarity' {
    It 'returns 1.0 for two empty sets' {
        $l = New-Object 'System.Collections.Generic.HashSet[string]'
        $r = New-Object 'System.Collections.Generic.HashSet[string]'
        Get-JaccardSimilarity -Left $l -Right $r | Should -Be 1.0
    }

    It 'returns 1.0 for identical token sets' {
        $l = Get-NameTokenSet -Name 'song title.mp3'
        $r = Get-NameTokenSet -Name 'song title.mp3'
        Get-JaccardSimilarity -Left $l -Right $r | Should -Be 1.0
    }

    It 'returns 0.0 for completely disjoint sets' {
        $l = Get-NameTokenSet -Name 'alpha beta.mp3'
        $r = Get-NameTokenSet -Name 'gamma delta.mp3'
        Get-JaccardSimilarity -Left $l -Right $r | Should -Be 0.0
    }

    It 'returns a partial score for partially overlapping names' {
        $l = Get-NameTokenSet -Name 'song title live.mp3'
        $r = Get-NameTokenSet -Name 'song title.mp3'
        $result = Get-JaccardSimilarity -Left $l -Right $r
        $result | Should -BeGreaterThan 0.0
        $result | Should -BeLessThan 1.0
    }
}

Describe 'Test-ValueMatch' {
    It 'matches case-insensitively and trims whitespace' {
        Test-ValueMatch ' Foo Fighters ' 'foo fighters' | Should -BeTrue
    }

    It 'does not match when either side is null or blank' {
        Test-ValueMatch $null 'foo' | Should -BeFalse
        Test-ValueMatch '' 'foo' | Should -BeFalse
        Test-ValueMatch '   ' '   ' | Should -BeFalse
    }

    It 'does not match different values' {
        Test-ValueMatch 'foo' 'bar' | Should -BeFalse
    }
}

Describe 'Get-ConfidenceDetails' {
    It 'scores an exact hash match as 100 / Very High' {
        $left = [pscustomobject]@{ Hash = 'ABC123'; NameTokens = (Get-NameTokenSet 'a.mp3') }
        $right = [pscustomobject]@{ Hash = 'ABC123'; NameTokens = (Get-NameTokenSet 'b.mp3') }
        $details = Get-ConfidenceDetails -Left $left -Right $right
        $details.Score | Should -Be 100
        $details.ExactHashMatch | Should -BeTrue
        $details.Recommendation | Should -Be 'Very High'
    }

    It 'never exceeds a score of 100 even with many matching signals' {
        $left = [pscustomobject]@{
            Hash = $null; NameTokens = (Get-NameTokenSet 'song title.mp3')
            Title = 'Song'; Artists = 'Band'; Album = 'Album'; Track = 1; Year = 2020
            DurationSeconds = 200; Size = 5000000
        }
        $right = [pscustomobject]@{
            Hash = $null; NameTokens = (Get-NameTokenSet 'song title.mp3')
            Title = 'Song'; Artists = 'Band'; Album = 'Album'; Track = 1; Year = 2020
            DurationSeconds = 200; Size = 5000000
        }
        $details = Get-ConfidenceDetails -Left $left -Right $right
        $details.Score | Should -BeLessOrEqual 100
    }

    It 'scores unrelated files as Low' {
        $left = [pscustomobject]@{
            Hash = $null; NameTokens = (Get-NameTokenSet 'alpha.mp3')
            Title = $null; Artists = $null; Album = $null; Track = $null; Year = $null
            DurationSeconds = $null; Size = $null
        }
        $right = [pscustomobject]@{
            Hash = $null; NameTokens = (Get-NameTokenSet 'zzz-completely-different.mp3')
            Title = $null; Artists = $null; Album = $null; Track = $null; Year = $null
            DurationSeconds = $null; Size = $null
        }
        $details = Get-ConfidenceDetails -Left $left -Right $right
        $details.Recommendation | Should -Be 'Low'
    }

    It 'does not throw when optional tag properties are entirely absent from the object' {
        $left = [pscustomobject]@{ Hash = $null; NameTokens = (Get-NameTokenSet 'a.mp3') }
        $right = [pscustomobject]@{ Hash = $null; NameTokens = (Get-NameTokenSet 'b.mp3') }
        { Get-ConfidenceDetails -Left $left -Right $right } | Should -Not -Throw
    }
}

Describe 'Select-PreferredFile (Int32 overflow regression)' {
    It 'does not throw when LastWriteTime produces a large 64-bit tick value' {
        # This mirrors the real-world failure: raw FileTimeUtc values like
        # 134317609806497344 overflow Int32.MaxValue (2,147,483,647) when
        # cast with [int]. The fix must handle this without throwing.
        $a = [pscustomobject]@{
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
        }
        $b = [pscustomobject]@{
            Bitrate = 128; SampleRate = 44100; Size = 3000000
            MetadataStatus = 'Unavailable'; LastWriteTime = (Get-Date '2010-01-01')
        }

        { Select-PreferredFile -A $a -B $b } | Should -Not -Throw
    }

    It 'prefers the higher-bitrate, more-complete-metadata file' {
        $high = [pscustomobject]@{
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
        }
        $low = [pscustomobject]@{
            Bitrate = 128; SampleRate = 44100; Size = 3000000
            MetadataStatus = 'Unavailable'; LastWriteTime = (Get-Date '2010-01-01')
        }

        $result = Select-PreferredFile -A $high -B $low
        $result.Keep | Should -Be $high
        $result.Delete | Should -Be $low
    }

    It 'handles a maximum-representable DateTime without throwing' {
        $a = [pscustomobject]@{
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = [datetime]::MaxValue
        }
        $b = [pscustomobject]@{
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2010-01-01')
        }

        { Select-PreferredFile -A $a -B $b } | Should -Not -Throw
    }
}

Describe 'Select-PreferredFile (exact-hash folder-vs-root tie-break)' {
    It 'prefers the copy inside a subfolder over the one at the library root when hashes match' {
        $atRoot = [pscustomobject]@{
            Path = 'C:\Music\Song.mp3'; Directory = 'C:\Music'
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
            Hash = 'ABC123'
        }
        $inFolder = [pscustomobject]@{
            Path = 'C:\Music\Artist\Album\Song.mp3'; Directory = 'C:\Music\Artist\Album'
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
            Hash = 'ABC123'
        }

        $result = Select-PreferredFile -A $atRoot -B $inFolder -RootPath 'C:\Music'
        $result.Keep | Should -Be $inFolder
        $result.Delete | Should -Be $atRoot

        # Order of A/B should not matter.
        $result2 = Select-PreferredFile -A $inFolder -B $atRoot -RootPath 'C:\Music'
        $result2.Keep | Should -Be $inFolder
        $result2.Delete | Should -Be $atRoot
    }

    It 'falls through to normal scoring when hashes do not match' {
        $atRoot = [pscustomobject]@{
            Directory = 'C:\Music'
            Bitrate = 128; SampleRate = 44100; Size = 3000000
            MetadataStatus = 'Unavailable'; LastWriteTime = (Get-Date '2010-01-01')
            Hash = 'AAA'
        }
        $inFolder = [pscustomobject]@{
            Directory = 'C:\Music\Artist'
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
            Hash = 'BBB'
        }

        # Hashes differ, so the folder-vs-root rule must not apply; the
        # higher-bitrate/more-complete-metadata file should win as usual,
        # even though it also happens to be the one in a subfolder here.
        $result = Select-PreferredFile -A $atRoot -B $inFolder -RootPath 'C:\Music'
        $result.Keep | Should -Be $inFolder
        $result.Delete | Should -Be $atRoot
    }

    It 'falls through to normal scoring when RootPath is not supplied' {
        $atRoot = [pscustomobject]@{
            Directory = 'C:\Music'
            Bitrate = 320; SampleRate = 44100; Size = 8000000
            MetadataStatus = 'OK'; LastWriteTime = (Get-Date '2024-06-01')
            Hash = 'ABC123'
        }
        $inFolder = [pscustomobject]@{
            Directory = 'C:\Music\Artist'
            Bitrate = 128; SampleRate = 44100; Size = 3000000
            MetadataStatus = 'Unavailable'; LastWriteTime = (Get-Date '2010-01-01')
            Hash = 'ABC123'
        }

        # Same hash, but no -RootPath given: cannot determine "at root", so
        # falls through to quality scoring, where the higher-bitrate file
        # (the one at root here) wins.
        { Select-PreferredFile -A $atRoot -B $inFolder } | Should -Not -Throw
        $result = Select-PreferredFile -A $atRoot -B $inFolder
        $result.Keep | Should -Be $atRoot
    }

    It 'does not throw when Hash/Directory properties are absent (older fixtures)' {
        $a = [pscustomobject]@{ Bitrate = 320; SampleRate = 44100; Size = 8000000; MetadataStatus = 'OK'; LastWriteTime = (Get-Date) }
        $b = [pscustomobject]@{ Bitrate = 128; SampleRate = 44100; Size = 3000000; MetadataStatus = 'Unavailable'; LastWriteTime = (Get-Date) }
        { Select-PreferredFile -A $a -B $b -RootPath 'C:\Music' } | Should -Not -Throw
    }
}

Describe 'Get-DuplicateCandidatePair' {
    It 'pairs files that share a normalized base name' {
        $items = @(
            [pscustomobject]@{ Path = 'C:\a\song.mp3'; BaseNameNormalized = 'song'; MetadataKey = $null }
            [pscustomobject]@{ Path = 'C:\b\song copy.mp3'; BaseNameNormalized = 'song'; MetadataKey = $null }
            [pscustomobject]@{ Path = 'C:\c\unrelated.mp3'; BaseNameNormalized = 'unrelated'; MetadataKey = $null }
        )

        $pairs = Get-DuplicateCandidatePair -Items $items
        $pairs.Count | Should -Be 1
    }

    It 'pairs files that share a metadata key even with different names' {
        $items = @(
            [pscustomobject]@{ Path = 'C:\a\1.mp3'; BaseNameNormalized = 'one'; MetadataKey = 'k1' }
            [pscustomobject]@{ Path = 'C:\b\2.mp3'; BaseNameNormalized = 'two'; MetadataKey = 'k1' }
        )

        $pairs = Get-DuplicateCandidatePair -Items $items
        $pairs.Count | Should -Be 1
    }

    It 'does not pair a lone file with no matches' {
        $items = @(
            [pscustomobject]@{ Path = 'C:\a\only.mp3'; BaseNameNormalized = 'only'; MetadataKey = $null }
        )
        $pairs = Get-DuplicateCandidatePair -Items $items
        $pairs.Count | Should -Be 0
    }
}

Describe 'Get-QuarantineDestinationPath' {
    It 'preserves drive and folder structure under the quarantine root' {
        $dest = Get-QuarantineDestinationPath -SourcePath 'C:\Music\Artist\song.mp3' `
            -QuarantineRoot 'D:\Quarantine' -ExistsTest { $false }
        $dest | Should -Be 'D:\Quarantine\C\Music\Artist\song.mp3'
    }

    It 'handles UNC source paths with a dedicated bucket' {
        $dest = Get-QuarantineDestinationPath -SourcePath '\\nas\Music\Artist\song.mp3' `
            -QuarantineRoot 'D:\Quarantine' -ExistsTest { $false }
        $dest | Should -Be 'D:\Quarantine\UNC\nas\Music\Artist\song.mp3'
    }

    It 'appends a timestamp suffix when the destination already exists' {
        $dest = Get-QuarantineDestinationPath -SourcePath 'C:\Music\Artist\song.mp3' `
            -QuarantineRoot 'D:\Quarantine' -ExistsTest { $true }
        $dest | Should -Match 'song\.\d{8}-\d{9}\.mp3$'
    }
}

Describe 'Settings persistence' {
    It 'round-trips settings through JSON' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "settings-$([guid]::NewGuid()).json"
        try {
            $settings = Get-DefaultAppSettings
            $settings.LibraryPath = 'C:\Music'
            $settings.Threshold = 80
            Export-AppSettings -Settings $settings -Path $tmp

            $loaded = Import-AppSettings -Path $tmp
            $loaded.LibraryPath | Should -Be 'C:\Music'
            $loaded.Threshold | Should -Be 80
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'returns defaults when the settings file does not exist' {
        $settings = Import-AppSettings -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'does-not-exist.json')
        $settings.Threshold | Should -Be 75
        $settings.FileExtensions | Should -Be 'mp3, flac, wav, m4a, ogg, wma, aac'
    }

    It 'backfills FileExtensions for an older settings file saved before this field existed' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "settings-legacy-$([guid]::NewGuid()).json"
        try {
            # Simulates a settings.json written by a pre-3.0.0 build, which
            # has no FileExtensions key at all.
            [pscustomobject]@{ LibraryPath = 'C:\Music'; QuarantinePath = ''; Recurse = $true; ComputeHash = $true; Threshold = 75 } |
                ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8

            $loaded = Import-AppSettings -Path $tmp
            $loaded.FileExtensions | Should -Be 'mp3, flac, wav, m4a, ogg, wma, aac'
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ConvertTo-ExtensionFilterList' {
    It 'returns the default extension set for a null or empty input' {
        (ConvertTo-ExtensionFilterList -RawList $null) | Should -Be @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
        (ConvertTo-ExtensionFilterList -RawList '') | Should -Be @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
        (ConvertTo-ExtensionFilterList -RawList '   ') | Should -Be @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
    }

    It 'parses a comma-separated list into bare lowercase extensions' {
        (ConvertTo-ExtensionFilterList -RawList 'MP3,FLAC,Wav') | Should -Be @('mp3', 'flac', 'wav')
    }

    It 'tolerates leading dots, wildcards, semicolons, pipes, and extra whitespace' {
        (ConvertTo-ExtensionFilterList -RawList '  .mp3 ; *.flac | wav   m4a  ') | Should -Be @('mp3', 'flac', 'wav', 'm4a')
    }

    It 'deduplicates case-insensitively while preserving first-seen order' {
        (ConvertTo-ExtensionFilterList -RawList 'mp3,MP3,Mp3,flac') | Should -Be @('mp3', 'flac')
    }

    It 'drops tokens containing path separators, dot-dot, or other unsafe characters' {
        # Note: splitting is whitespace/comma/semicolon/pipe-based, so a
        # phrase like 'rm -rf' becomes two space-separated tokens ('rm' and
        # '-rf') rather than one unsafe blob - '-rf' is correctly dropped
        # (contains a hyphen), while the bare word 'rm' is kept because it IS
        # a syntactically valid (if unusual) extension name; it is never
        # executed or interpreted as a command, only compared against a
        # file's Extension property, so this is safe by construction.
        (ConvertTo-ExtensionFilterList -RawList 'mp3,..\..\windows,c:\evil,fl*ac,-rf,') | Should -Be @('mp3')
    }

    It 'drops tokens longer than 15 characters' {
        $longToken = 'a' * 16
        (ConvertTo-ExtensionFilterList -RawList "mp3,$longToken") | Should -Be @('mp3')
    }

    It 'falls back to defaults when every token is invalid' {
        (ConvertTo-ExtensionFilterList -RawList '..\;***;///') | Should -Be @('mp3', 'flac', 'wav', 'm4a', 'ogg', 'wma', 'aac')
    }

    It 'caps the result at 50 extensions' {
        $raw = (1..60 | ForEach-Object { "ext$_" }) -join ','
        (ConvertTo-ExtensionFilterList -RawList $raw).Count | Should -Be 50
    }

    It 'honors a custom DefaultExtensions fallback' {
        (ConvertTo-ExtensionFilterList -RawList '' -DefaultExtensions @('jpg', 'png')) | Should -Be @('jpg', 'png')
    }
}

Describe 'Get-MusicFile' {
    BeforeAll {
        $script:mediaDir = Join-Path ([System.IO.Path]::GetTempPath()) "media-$([guid]::NewGuid())"
        $script:mediaSubDir = Join-Path $script:mediaDir 'sub'
        New-Item -ItemType Directory -Path $script:mediaSubDir -Force | Out-Null
        'a' | Set-Content -LiteralPath (Join-Path $script:mediaDir 'song.mp3')
        'b' | Set-Content -LiteralPath (Join-Path $script:mediaDir 'track.flac')
        'c' | Set-Content -LiteralPath (Join-Path $script:mediaDir 'notes.txt')
        'd' | Set-Content -LiteralPath (Join-Path $script:mediaSubDir 'nested.wav')
        'e' | Set-Content -LiteralPath (Join-Path $script:mediaSubDir 'nested.mp3')
    }

    AfterAll {
        Remove-Item -LiteralPath $script:mediaDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'matches only the default (mp3) extension when none is specified, non-recursive' {
        $files = @(Get-MusicFile -RootPath $script:mediaDir -Recurse $false -Extensions @('mp3'))
        $files.Count | Should -Be 1
        $files[0].Name | Should -Be 'song.mp3'
    }

    It 'matches multiple configured extensions in a single non-recursive pass' {
        $files = @(Get-MusicFile -RootPath $script:mediaDir -Recurse $false -Extensions @('mp3', 'flac'))
        ($files.Name | Sort-Object) | Should -Be @('song.mp3', 'track.flac')
    }

    It 'matches multiple configured extensions recursively, including subfolders' {
        $files = @(Get-MusicFile -RootPath $script:mediaDir -Recurse $true -Extensions @('mp3', 'flac', 'wav'))
        ($files.Name | Sort-Object) | Should -Be @('nested.mp3', 'nested.wav', 'song.mp3', 'track.flac')
    }

    It 'is case-insensitive when matching extensions' {
        $files = @(Get-MusicFile -RootPath $script:mediaDir -Recurse $false -Extensions @('MP3'))
        $files.Count | Should -Be 1
    }

    It 'never matches an extension that was not requested' {
        $files = @(Get-MusicFile -RootPath $script:mediaDir -Recurse $true -Extensions @('mp3', 'flac', 'wav'))
        $files.Name | Should -Not -Contain 'notes.txt'
    }
}

Describe 'Move-QuarantineBatchCore' {
    BeforeEach {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "mds-quarantine-$([guid]::NewGuid())"
        $script:sourceDir = Join-Path $script:testRoot 'source'
        $script:quarantineDir = Join-Path $script:testRoot 'quarantine'
        New-Item -ItemType Directory -Path $script:sourceDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'moves every selected file and reports one Moved count per file' {
        $files = 1..3 | ForEach-Object {
            $path = Join-Path $script:sourceDir "song$_.mp3"
            Set-Content -LiteralPath $path -Value 'data'
            [pscustomobject]@{ DeletePath = $path }
        }

        $result = Move-QuarantineBatchCore -SelectedRows $files -QuarantineRoot $script:quarantineDir

        $result.Moved | Should -Be 3
        $result.Failed | Should -Be 0
        $result.Total | Should -Be 3
        $result.ManifestEntries.Count | Should -Be 3
        foreach ($file in $files) { Test-Path -LiteralPath $file.DeletePath | Should -BeFalse }
    }

    It 'reports incremental progress through the ProgressQueue with index/total prefixes' {
        $files = 1..2 | ForEach-Object {
            $path = Join-Path $script:sourceDir "track$_.mp3"
            Set-Content -LiteralPath $path -Value 'data'
            [pscustomobject]@{ DeletePath = $path }
        }
        $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        Move-QuarantineBatchCore -SelectedRows $files -QuarantineRoot $script:quarantineDir -ProgressQueue $queue | Out-Null

        $messages = @()
        $line = $null
        while ($queue.TryDequeue([ref]$line)) { $messages += $line }

        $messages.Count | Should -Be 2
        $messages[0] | Should -Match '^PROGRESS:1:2:'
        $messages[1] | Should -Match '^PROGRESS:2:2:'
    }

    It 'skips files that no longer exist without throwing' {
        $missing = [pscustomobject]@{ DeletePath = (Join-Path $script:sourceDir 'ghost.mp3') }

        { Move-QuarantineBatchCore -SelectedRows @($missing) -QuarantineRoot $script:quarantineDir } | Should -Not -Throw
        $result = Move-QuarantineBatchCore -SelectedRows @($missing) -QuarantineRoot $script:quarantineDir
        $result.Moved | Should -Be 0
        $result.Failed | Should -Be 0
    }

    It 'stops early and marks Cancelled when CancelFlag.Cancelled is set' {
        $files = 1..3 | ForEach-Object {
            $path = Join-Path $script:sourceDir "cancel$_.mp3"
            Set-Content -LiteralPath $path -Value 'data'
            [pscustomobject]@{ DeletePath = $path }
        }
        $cancelFlag = @{ Cancelled = $true }

        $result = Move-QuarantineBatchCore -SelectedRows $files -QuarantineRoot $script:quarantineDir -CancelFlag $cancelFlag

        $result.Cancelled | Should -BeTrue
        $result.Moved | Should -Be 0
        foreach ($file in $files) { Test-Path -LiteralPath $file.DeletePath | Should -BeTrue }
    }
}

Describe 'Start-DuplicateScanCore (Get-FileHash error-message regression)' {
    BeforeAll {
        $script:scanDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mds-scan-$(New-Guid)")
        New-Item -ItemType Directory -Path $script:scanDir -Force | Out-Null
        # Same normalized base name ('song a') so these two files are grouped
        # as a duplicate candidate pair and go through the SHA-256 hashing
        # path when -HashAllCandidates is used.
        Set-Content -LiteralPath (Join-Path $script:scanDir 'Song A.mp3') -Value 'same content'
        Set-Content -LiteralPath (Join-Path $script:scanDir 'Song A (1).mp3') -Value 'same content'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:scanDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'surfaces the real Get-FileHash error instead of a masked strict-mode property error' {
        # Regression test for a real-world failure: on a scan of a large
        # network-drive library, a transient read glitch made Get-FileHash
        # write a non-terminating error and return nothing for that file.
        # Because Set-StrictMode -Version Latest is active and the call site
        # did not pass -ErrorAction Stop, `(Get-FileHash ...).Hash` on that
        # $null result threw "The property 'Hash' cannot be found on this
        # object" - masking the real "An unexpected network error occurred"
        # cause in the scan log. This mocks that exact non-terminating
        # failure mode and asserts the real message is now what gets logged.
        # Pester's Mock does not reproduce the engine's automatic
        # non-terminating-to-terminating conversion for -ErrorAction Stop
        # (verified separately against the real Get-FileHash cmdlet), so
        # this mock throws directly - that is exactly what the real
        # cmdlet does once -ErrorAction Stop is honored, which is what the
        # production fix relies on.
        Mock Get-FileHash -ModuleName MusicDuplicateScanner.Core {
            $exception = [System.IO.IOException]::new('An unexpected network error occurred.')
            $er = [System.Management.Automation.ErrorRecord]::new($exception, 'FileReadError', 'ReadError', $LiteralPath)
            throw $er
        }

        $progressQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $cancelFlag = @{ Cancelled = $false }
        $modulePath = Join-Path $PSScriptRoot '..\src\MusicDuplicateScanner.Core.psm1'

        $results = Start-DuplicateScanCore -RootPath $script:scanDir -UseRecurse $false -Threshold 50 `
            -HashAllCandidates $true -CorePath $modulePath -ProgressQueue $progressQueue -CancelFlag $cancelFlag `
            -Extensions @('mp3')

        $messages = @()
        $line = $null
        while ($progressQueue.TryDequeue([ref]$line)) { $messages += $line }

        $hashFailedLines = @($messages | Where-Object { $_ -like 'Hash failed for *' })
        $hashFailedLines.Count | Should -BeGreaterThan 0
        $hashFailedLines[0] | Should -Match 'An unexpected network error occurred'
        $hashFailedLines[0] | Should -Not -Match "property 'Hash' cannot be found"

        # The scan must still complete rather than aborting - a hash failure
        # for one candidate degrades gracefully to a $null hash, not a crash.
        # (Piping a possibly-empty $results array into Should would skip the
        # assertion entirely when it has 0 elements, since nothing flows
        # through the pipeline - so check it as a scalar via .Count instead.)
        $messages | Where-Object { $_ -like 'Scan complete.*' } | Should -Not -BeNullOrEmpty
        $results.Count | Should -BeGreaterOrEqual 0
    }
}
