# lib/

Drop `TagLibSharp.dll` here (or next to `MusicDuplicateScanner.ps1`) to enable
tag-based duplicate matching (title/artist/album/track/year/duration).

The scanner works without it too - it falls back to filename similarity,
file size, and SHA-256 hash comparisons - but tag metadata meaningfully
improves confidence scoring, especially for files with inconsistent names.

## Get it

1. Download the official NuGet package: https://www.nuget.org/packages/TagLibSharp/
2. Rename the downloaded `.nupkg` to `.zip` and extract it (NuGet packages
   are zip archives; `Expand-Archive` requires a `.zip` extension).
3. Copy `lib/net462/TagLibSharp.dll` from the extracted package into this
   folder.

Project source: https://github.com/mono/taglib-sharp

TagLibSharp is MIT-licensed and safe to redistribute, but this repository
does not bundle the binary directly so contributors always get the current
signed build straight from NuGet.
