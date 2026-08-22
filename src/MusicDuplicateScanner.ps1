#requires -Version 5.1
<#
    .SYNOPSIS
        Music Duplicate Scanner - finds likely-duplicate MP3 files by
        filename similarity and tag metadata, scores confidence, and moves
        chosen duplicates to a reversible quarantine folder.

    .DESCRIPTION
        WPF desktop GUI for Windows PowerShell 5.1+ / PowerShell 7+ on
        Windows. Business logic lives in MusicDuplicateScanner.Core.psm1
        (imported below) so it can be unit-tested independently of the UI.

        Scanning and hashing run on a background runspace so the window
        stays responsive during large libraries; progress is reported back
        to the UI thread via the Dispatcher.

    .PARAMETER LibraryPath
        Pre-fills the library path field. Optional.

    .PARAMETER QuarantinePath
        Pre-fills the quarantine folder field. Optional.

    .PARAMETER Threshold
        Pre-fills the confidence threshold slider (0-100). Optional.

    .EXAMPLE
        .\MusicDuplicateScanner.ps1
        Launches the GUI with previously saved settings (or defaults).

    .EXAMPLE
        .\MusicDuplicateScanner.ps1 -LibraryPath 'D:\Music' -Threshold 80
        Launches the GUI pre-filled for a specific library and threshold.

    .NOTES
        Requires TagLibSharp.dll next to this script or in a "lib"
        subfolder for tag-based matching. Without it, the scanner still
        works using filename similarity, size, and hash comparisons alone.
        Get it from: https://www.nuget.org/packages/TagLibSharp/
#>

[CmdletBinding()]
param(
    [string]$LibraryPath,
    [string]$QuarantinePath,
    [ValidateRange(0, 100)]
    [int]$Threshold
)

# ---------------------------------------------------------------------------
# Platform guard - this is a Windows-only WPF application.
# ---------------------------------------------------------------------------
$isWindowsHost = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }
if (-not $isWindowsHost) {
    throw 'MusicDuplicateScanner.ps1 uses WPF and requires Windows PowerShell 5.1+ or PowerShell 7+ on Windows.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Import-Module (Join-Path $PSScriptRoot 'MusicDuplicateScanner.Core.psm1') -Force

# ---------------------------------------------------------------------------
# App paths / settings / logging
# ---------------------------------------------------------------------------

$script:AppDataDir = Join-Path $env:LOCALAPPDATA 'MusicDuplicateScanner'
$script:SettingsPath = Join-Path $script:AppDataDir 'settings.json'
$script:LogDir = Join-Path $script:AppDataDir 'logs'
$script:LogPath = Join-Path $script:LogDir "scan-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:ManifestDir = Join-Path $script:AppDataDir 'quarantine-manifests'

New-Item -ItemType Directory -Path $script:AppDataDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $script:LogDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $script:ManifestDir -Force -ErrorAction SilentlyContinue | Out-Null

$script:Settings = Import-AppSettings -Path $script:SettingsPath
if ($LibraryPath) { $script:Settings.LibraryPath = $LibraryPath }
if ($QuarantinePath) { $script:Settings.QuarantinePath = $QuarantinePath }
if ($PSBoundParameters.ContainsKey('Threshold')) { $script:Settings.Threshold = $Threshold }

$script:LastScanResults = @()
$script:CurrentSortColumn = 'Confidence'
$script:CurrentSortDirection = 'Descending'
$script:ActiveJob = $null
$script:ActivePowerShell = $null
$script:ProgressQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:LastManifestPath = $null
$script:ActiveQuarantineJob = $null
$script:ActiveQuarantinePowerShell = $null
$script:QuarantineProgressQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

function Write-UiLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    $line = "$(Get-Date -Format 'HH:mm:ss')  $Message"
    if ($script:txtLog) {
        $script:txtLog.AppendText("$line`r`n")
        $script:txtLog.ScrollToEnd()
    }
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Logging to disk is best-effort; never let it break the UI.
        Write-Verbose "Failed to write log file: $($_.Exception.Message)"
    }
}

function Save-CurrentSettings {
    $script:Settings.LibraryPath = $script:txtPath.Text
    $script:Settings.QuarantinePath = $script:txtQuarantine.Text
    $script:Settings.Recurse = [bool]$script:chkRecurse.IsChecked
    $script:Settings.ComputeHash = [bool]$script:chkHash.IsChecked
    $script:Settings.Threshold = [int]$script:sldThreshold.Value
    Export-AppSettings -Settings $script:Settings -Path $script:SettingsPath
}

# ---------------------------------------------------------------------------
# Scan orchestration (runs on a background runspace)
# ---------------------------------------------------------------------------
#
# Start-DuplicateScanCore itself lives in MusicDuplicateScanner.Core.psm1 -
# see Start-BackgroundScan below for why (a background runspace imports the
# module directly rather than transplanting a function body as a string).

function Start-BackgroundScan {
    param(
        [string]$RootPath,
        [bool]$UseRecurse,
        [int]$Threshold,
        [bool]$HashAllCandidates
    )

    $corePath = Join-Path $PSScriptRoot 'MusicDuplicateScanner.Core.psm1'

    # A synchronized hashtable is a reference type, so the SAME instance is
    # visible inside the background runspace after AddArgument - this is
    # what makes live Cancel-button polling possible without [ref], which
    # cannot usefully cross a runspace boundary.
    $script:CancelState = [hashtable]::Synchronized(@{ Cancelled = $false })

    # Start-DuplicateScanCore is defined in the Core module, so the background
    # runspace can reach it with a plain Import-Module - no need to smuggle a
    # function body across the runspace boundary as text (that approach is
    # broken: ScriptBlock.ToString() on a function only returns the param
    # block + statements, not a 'function Name { ... }' wrapper, so
    # dot-sourcing it just executes the body once with every parameter
    # unbound instead of defining a callable function).
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript({
        param($RootPath, $UseRecurse, $Threshold, $HashAllCandidates, $CorePath, $ProgressQueue, $CancelState)
        Import-Module $CorePath -Force
        Start-DuplicateScanCore -RootPath $RootPath -UseRecurse $UseRecurse -Threshold $Threshold `
            -HashAllCandidates $HashAllCandidates -CorePath $CorePath -ProgressQueue $ProgressQueue `
            -CancelFlag $CancelState
    }) | Out-Null

    $ps.AddArgument($RootPath).AddArgument($UseRecurse).AddArgument($Threshold).AddArgument($HashAllCandidates).AddArgument($corePath).AddArgument($script:ProgressQueue).AddArgument($script:CancelState) | Out-Null

    $script:ActivePowerShell = $ps
    $script:ActiveJob = $ps.BeginInvoke()
}

# ---------------------------------------------------------------------------
# Grid / export
# ---------------------------------------------------------------------------

function Update-ResultsGrid {
    param([object[]]$Data)

    if (-not $script:dataGrid) { return }

    $sorted = if ($script:CurrentSortDirection -eq 'Descending') {
        $Data | Sort-Object -Property $script:CurrentSortColumn -Descending
    } else {
        $Data | Sort-Object -Property $script:CurrentSortColumn
    }

    $script:dataGrid.ItemsSource = $null
    $script:dataGrid.ItemsSource = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]' (, [object[]]$sorted)
    $script:lblResultCount.Text = "Matches: $($sorted.Count)"
}

function Export-DeletionList {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Export path is empty.' }

    $selected = @($script:LastScanResults | Where-Object { $_.Selected })
    if (-not $selected.Count) { throw 'No rows are selected for export.' }

    $selected |
        Select-Object Confidence, Recommendation, ExactHashMatch, KeepPath, DeletePath, Reason, Basis, KeepBitrate, DeleteBitrate, KeepDuration, DeleteDuration |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Quarantine (reversible "delete") with an undoable manifest
# ---------------------------------------------------------------------------

function Move-SelectedDuplicatesToQuarantine {
    param([string]$QuarantineRoot)

    $selected = @($script:LastScanResults | Where-Object { $_.Selected })
    if (-not $selected.Count) {
        [System.Windows.MessageBox]::Show('No rows are selected.', 'Nothing Selected', 'OK', 'Information') | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($QuarantineRoot)) {
        [System.Windows.MessageBox]::Show('Choose a quarantine folder first.', 'Quarantine Folder Required', 'OK', 'Warning') | Out-Null
        return
    }

    $libraryFull = try { [System.IO.Path]::GetFullPath($script:txtPath.Text) } catch { $script:txtPath.Text }
    $quarantineFull = try { [System.IO.Path]::GetFullPath($QuarantineRoot) } catch { $QuarantineRoot }
    if ($quarantineFull.StartsWith($libraryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $warn = [System.Windows.MessageBox]::Show(
            "The quarantine folder is inside the library path being scanned.`nRe-scanning could pick up already-quarantined files. Continue anyway?",
            'Quarantine Inside Library', 'YesNo', 'Warning')
        if ($warn -ne 'Yes') { return }
    }

    $preview = ($selected | Select-Object -First 10 | ForEach-Object { $_.DeletePath }) -join "`n"
    $more = if ($selected.Count -gt 10) { "`n...and $($selected.Count - 10) more" } else { '' }
    $message = "Move $($selected.Count) file(s) to quarantine?`n(This does not permanently delete anything - use Undo Last Quarantine to restore.)`n`n$preview$more"
    $confirm = [System.Windows.MessageBox]::Show($message, 'Confirm Quarantine', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    # Run the actual file moves on a background runspace (same pattern as
    # Start-BackgroundScan) so the WPF UI thread stays responsive and a
    # determinate progress bar can update per file, instead of a silent,
    # blocking loop on the UI thread.
    $script:pbScan.IsIndeterminate = $false
    $script:pbScan.Minimum = 0
    $script:pbScan.Maximum = $selected.Count
    $script:pbScan.Value = 0
    $script:pbScan.Visibility = 'Visible'
    $script:lblStatus.Text = "Quarantining 0/$($selected.Count)..."
    $btnQuarantine.IsEnabled = $false
    $btnUndo.IsEnabled = $false
    $btnScan.IsEnabled = $false

    $corePath = Join-Path $PSScriptRoot 'MusicDuplicateScanner.Core.psm1'
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript({
        param($SelectedRows, $QuarantineRoot, $CorePath, $ProgressQueue)
        Import-Module $CorePath -Force
        Move-QuarantineBatchCore -SelectedRows $SelectedRows -QuarantineRoot $QuarantineRoot -ProgressQueue $ProgressQueue
    }) | Out-Null
    $ps.AddArgument(@($selected)).AddArgument($QuarantineRoot).AddArgument($corePath).AddArgument($script:QuarantineProgressQueue) | Out-Null

    $script:ActiveQuarantinePowerShell = $ps
    $script:ActiveQuarantineJob = $ps.BeginInvoke()
    $script:quarantineTimer.Start()
}

function Undo-LastQuarantine {
    if (-not $script:LastManifestPath -or -not (Test-Path -LiteralPath $script:LastManifestPath)) {
        [System.Windows.MessageBox]::Show('No quarantine manifest available to undo in this session.', 'Nothing to Undo', 'OK', 'Information') | Out-Null
        return
    }

    $entries = Import-Csv -Path $script:LastManifestPath
    $confirm = [System.Windows.MessageBox]::Show(
        "Restore $($entries.Count) file(s) to their original location?", 'Confirm Undo', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    $restored = 0
    $failed = 0

    foreach ($entry in $entries) {
        try {
            if (-not (Test-Path -LiteralPath $entry.QuarantinePath)) { continue }
            $originalDir = Split-Path -Path $entry.OriginalPath -Parent
            New-Item -ItemType Directory -Path $originalDir -Force -ErrorAction SilentlyContinue | Out-Null
            Move-Item -LiteralPath $entry.QuarantinePath -Destination $entry.OriginalPath -Force
            $restored++
            Write-UiLog "Restored $($entry.QuarantinePath) -> $($entry.OriginalPath)"
        } catch {
            $failed++
            Write-UiLog "Restore failed for $($entry.QuarantinePath): $($_.Exception.Message)"
        }
    }

    [System.Windows.MessageBox]::Show("Restored: $restored`nFailed: $failed", 'Undo Complete', 'OK', 'Information') | Out-Null
}

# ---------------------------------------------------------------------------
# XAML / UI
# ---------------------------------------------------------------------------

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Music Duplicate Scanner"
        Height="860" Width="1520"
        WindowStartupLocation="CenterScreen"
        Background="#F5F7FA"
        Foreground="#1F2937">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="170"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Padding="12" CornerRadius="8" Background="#FFFFFF" BorderBrush="#D0D7DE" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="Music Duplicate Scanner" FontSize="24" FontWeight="Bold" Foreground="#111827"/>
                    <TextBlock Margin="0,6,0,0" Foreground="#4B5563" Text="Scans MP3 files by normalized file name and metadata, scores duplicate confidence, and moves selected duplicates to a reversible quarantine folder." TextWrapping="Wrap"/>
                </StackPanel>
                <TextBlock Grid.Column="1" VerticalAlignment="Top" Foreground="#2563EB" Text="PowerShell + WPF" FontWeight="SemiBold"/>
            </Grid>
        </Border>

        <Border Grid.Row="1" Margin="0,12,0,0" Padding="12" CornerRadius="8" Background="#FFFFFF" BorderBrush="#D0D7DE" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,8,0" Text="Library Path:" Foreground="#111827"/>
                <TextBox x:Name="txtPath" Grid.Row="0" Grid.Column="1" MinWidth="650" Height="30" Padding="6,4" Background="#FFFFFF" Foreground="#111827" BorderBrush="#94A3B8"/>
                <Button x:Name="btnBrowse" Grid.Row="0" Grid.Column="2" Margin="8,0,0,0" Padding="14,6" Content="Browse" Background="#E5E7EB" Foreground="#111827"/>
                <TextBlock Grid.Row="0" Grid.Column="3" VerticalAlignment="Center" Margin="18,0,8,0" Text="Threshold:" Foreground="#111827"/>
                <Slider x:Name="sldThreshold" Grid.Row="0" Grid.Column="4" Width="140" Minimum="0" Maximum="100" Value="75" TickFrequency="5" IsSnapToTickEnabled="True"/>
                <TextBlock x:Name="txtThresholdValue" Grid.Row="0" Grid.Column="5" VerticalAlignment="Center" Margin="8,0,0,0" Width="40" Text="75" Foreground="#111827"/>
                <Button x:Name="btnScan" Grid.Row="0" Grid.Column="6" Margin="18,0,0,0" Padding="18,6" Content="Scan" Background="#2563EB" Foreground="White"/>

                <TextBlock Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Margin="0,10,8,0" Text="Quarantine Path:" Foreground="#111827"/>
                <TextBox x:Name="txtQuarantine" Grid.Row="1" Grid.Column="1" MinWidth="650" Height="30" Margin="0,10,0,0" Padding="6,4" Background="#FFFFFF" Foreground="#111827" BorderBrush="#94A3B8"/>
                <Button x:Name="btnBrowseQuarantine" Grid.Row="1" Grid.Column="2" Margin="8,10,0,0" Padding="14,6" Content="Browse" Background="#E5E7EB" Foreground="#111827"/>
                <Button x:Name="btnCancelScan" Grid.Row="1" Grid.Column="6" Margin="18,10,0,0" Padding="18,6" Content="Cancel Scan" Background="#9CA3AF" Foreground="White" IsEnabled="False"/>

                <WrapPanel Grid.Row="2" Grid.ColumnSpan="7" Margin="0,12,0,0">
                    <CheckBox x:Name="chkRecurse" Margin="0,0,20,0" Content="Recurse subfolders" IsChecked="True" Foreground="#111827"/>
                    <CheckBox x:Name="chkHash" Margin="0,0,20,0" Content="Compute SHA256 for candidate matches" IsChecked="True" Foreground="#111827"/>
                    <Button x:Name="btnSelectHigh" Margin="0,0,12,0" Padding="12,6" Content="Select confidence &#8805; threshold" Background="#E5E7EB" Foreground="#111827"/>
                    <Button x:Name="btnClearSelection" Margin="0,0,12,0" Padding="12,6" Content="Clear selection" Background="#E5E7EB" Foreground="#111827"/>
                    <Button x:Name="btnExport" Margin="0,0,12,0" Padding="12,6" Content="Export deletion list" Background="#E5E7EB" Foreground="#111827"/>
                    <Button x:Name="btnQuarantine" Margin="0,0,12,0" Padding="12,6" Content="Move selected to quarantine" Background="#DC2626" Foreground="White"/>
                    <Button x:Name="btnUndo" Margin="0,0,12,0" Padding="12,6" Content="Undo last quarantine" Background="#E5E7EB" Foreground="#111827"/>
                    <TextBlock x:Name="lblResultCount" VerticalAlignment="Center" Foreground="#2563EB" Text="Matches: 0"/>
                </WrapPanel>
            </Grid>
        </Border>

        <Border Grid.Row="2" Margin="0,12,0,12" Padding="10" CornerRadius="8" Background="#FFFFFF" BorderBrush="#D0D7DE" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ProgressBar x:Name="pbScan" Grid.Column="0" Height="18" Minimum="0" Maximum="100" IsIndeterminate="True" Visibility="Collapsed"/>
                <TextBlock x:Name="lblStatus" Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#4B5563" Text="Idle"/>
            </Grid>
        </Border>

        <DataGrid x:Name="dataGrid" Grid.Row="3" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="False" SelectionMode="Extended" HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowBackground="#FFFFFF" AlternatingRowBackground="#F8FAFC" Background="#FFFFFF" Foreground="#111827" BorderBrush="#CBD5E1">
            <DataGrid.Columns>
                <DataGridCheckBoxColumn Header="Delete" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="60"/>
                <DataGridTextColumn Header="Confidence" Binding="{Binding Confidence}" Width="80" IsReadOnly="True"/>
                <DataGridTextColumn Header="Level" Binding="{Binding Recommendation}" Width="90" IsReadOnly="True"/>
                <DataGridCheckBoxColumn Header="Hash" Binding="{Binding ExactHashMatch}" Width="60" IsReadOnly="True"/>
                <DataGridTextColumn Header="Keep File" Binding="{Binding KeepFileName}" Width="170" IsReadOnly="True"/>
                <DataGridTextColumn Header="Delete File" Binding="{Binding DeleteFileName}" Width="170" IsReadOnly="True"/>
                <DataGridTextColumn Header="Keep Bitrate" Binding="{Binding KeepBitrate}" Width="90" IsReadOnly="True"/>
                <DataGridTextColumn Header="Delete Bitrate" Binding="{Binding DeleteBitrate}" Width="100" IsReadOnly="True"/>
                <DataGridTextColumn Header="Keep Path" Binding="{Binding KeepPath}" Width="300" IsReadOnly="True"/>
                <DataGridTextColumn Header="Delete Path" Binding="{Binding DeletePath}" Width="300" IsReadOnly="True"/>
                <DataGridTextColumn Header="Reason" Binding="{Binding Reason}" Width="250" IsReadOnly="True"/>
                <DataGridTextColumn Header="Basis" Binding="{Binding Basis}" Width="200" IsReadOnly="True"/>
            </DataGrid.Columns>
        </DataGrid>

        <Border Grid.Row="4" Margin="0,12,0,0" Padding="10" CornerRadius="8" Background="#FFFFFF" BorderBrush="#D0D7DE" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <TextBlock FontWeight="Bold" Text="Activity Log (also written to disk under %LOCALAPPDATA%\MusicDuplicateScanner\logs)" Foreground="#111827"/>
                <TextBox x:Name="txtLog" Grid.Row="1" Margin="0,8,0,0" Background="#F8FAFC" Foreground="#111827" BorderBrush="#CBD5E1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$script:txtPath = $window.FindName('txtPath')
$script:txtQuarantine = $window.FindName('txtQuarantine')
$btnBrowse = $window.FindName('btnBrowse')
$btnBrowseQuarantine = $window.FindName('btnBrowseQuarantine')
$btnScan = $window.FindName('btnScan')
$btnCancelScan = $window.FindName('btnCancelScan')
$btnSelectHigh = $window.FindName('btnSelectHigh')
$btnClearSelection = $window.FindName('btnClearSelection')
$btnExport = $window.FindName('btnExport')
$btnQuarantine = $window.FindName('btnQuarantine')
$btnUndo = $window.FindName('btnUndo')
$script:chkRecurse = $window.FindName('chkRecurse')
$script:chkHash = $window.FindName('chkHash')
$script:sldThreshold = $window.FindName('sldThreshold')
$txtThresholdValue = $window.FindName('txtThresholdValue')
$script:dataGrid = $window.FindName('dataGrid')
$script:txtLog = $window.FindName('txtLog')
$script:lblResultCount = $window.FindName('lblResultCount')
$script:pbScan = $window.FindName('pbScan')
$script:lblStatus = $window.FindName('lblStatus')

# Apply saved / parameter-supplied settings.
$script:txtPath.Text = $script:Settings.LibraryPath
$script:txtQuarantine.Text = $script:Settings.QuarantinePath
$script:chkRecurse.IsChecked = [bool]$script:Settings.Recurse
$script:chkHash.IsChecked = [bool]$script:Settings.ComputeHash
$script:sldThreshold.Value = [int]$script:Settings.Threshold
$txtThresholdValue.Text = [string][int]$script:Settings.Threshold

$sldThreshold.Add_ValueChanged({ $txtThresholdValue.Text = [int]$sldThreshold.Value })

$btnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose your music library folder'
    if (-not [string]::IsNullOrWhiteSpace($script:txtPath.Text) -and (Test-Path -LiteralPath $script:txtPath.Text)) {
        $dialog.SelectedPath = $script:txtPath.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtPath.Text = $dialog.SelectedPath
    }
})

$btnBrowseQuarantine.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a quarantine folder for moved duplicates'
    if (-not [string]::IsNullOrWhiteSpace($script:txtQuarantine.Text) -and (Test-Path -LiteralPath $script:txtQuarantine.Text)) {
        $dialog.SelectedPath = $script:txtQuarantine.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtQuarantine.Text = $dialog.SelectedPath
    }
})

function Set-ScanUiState {
    param([bool]$Running)
    $btnScan.IsEnabled = -not $Running
    $btnCancelScan.IsEnabled = $Running
    $btnQuarantine.IsEnabled = -not $Running
    if ($Running) {
        # The quarantine progress bar leaves this in determinate mode with
        # a fixed Maximum/Value - reset to the scan's indeterminate spinner
        # every time a scan starts, regardless of what ran before it.
        $script:pbScan.IsIndeterminate = $true
    }
    $script:pbScan.Visibility = if ($Running) { 'Visible' } else { 'Collapsed' }
    $script:lblStatus.Text = if ($Running) { 'Scanning...' } else { 'Idle' }
}

$btnScan.Add_Click({
    try {
        Save-CurrentSettings
        Set-ScanUiState -Running $true
        Write-UiLog "Scanning $($script:txtPath.Text)"
        Start-BackgroundScan -RootPath $script:txtPath.Text -UseRecurse ([bool]$script:chkRecurse.IsChecked) `
            -Threshold ([int]$script:sldThreshold.Value) -HashAllCandidates ([bool]$script:chkHash.IsChecked)
        $script:scanTimer.Start()
    } catch {
        Write-UiLog "Scan error: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Scan Error', 'OK', 'Error') | Out-Null
        Set-ScanUiState -Running $false
    }
})

$btnCancelScan.Add_Click({
    if ($script:CancelState) { $script:CancelState.Cancelled = $true }
    Write-UiLog 'Cancellation requested...'
})

$btnSelectHigh.Add_Click({
    foreach ($row in $script:LastScanResults) { $row.Selected = ($row.Confidence -ge [int]$sldThreshold.Value) }
    Update-ResultsGrid -Data $script:LastScanResults
})

$btnClearSelection.Add_Click({
    foreach ($row in $script:LastScanResults) { $row.Selected = $false }
    Update-ResultsGrid -Data $script:LastScanResults
})

$btnExport.Add_Click({
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.FileName = 'duplicate-delete-list.csv'
        if ($dialog.ShowDialog()) {
            Export-DeletionList -Path $dialog.FileName
            Write-UiLog "Exported deletion list to $($dialog.FileName)"
            [System.Windows.MessageBox]::Show('Export complete.', 'Export', 'OK', 'Information') | Out-Null
        }
    } catch {
        Write-UiLog "Export error: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export Error', 'OK', 'Error') | Out-Null
    }
})

$btnQuarantine.Add_Click({
    Save-CurrentSettings
    Move-SelectedDuplicatesToQuarantine -QuarantineRoot $script:txtQuarantine.Text
    Update-ResultsGrid -Data $script:LastScanResults
})

$btnUndo.Add_Click({ Undo-LastQuarantine })

$script:dataGrid.Add_Sorting({
    param($sortEventSender, $sortEventArgs)
    $null = $sortEventSender # required by the WPF Sorting event delegate signature; unused here
    $sortEventArgs.Handled = $true
    $header = $sortEventArgs.Column.Header.ToString()

    $map = @{
        'Delete' = 'Selected'; 'Confidence' = 'Confidence'; 'Level' = 'Recommendation'
        'Hash' = 'ExactHashMatch'; 'Keep File' = 'KeepFileName'; 'Delete File' = 'DeleteFileName'
        'Keep Bitrate' = 'KeepBitrate'; 'Delete Bitrate' = 'DeleteBitrate'
        'Keep Path' = 'KeepPath'; 'Delete Path' = 'DeletePath'; 'Reason' = 'Reason'; 'Basis' = 'Basis'
    }

    if ($map.ContainsKey($header)) {
        if ($script:CurrentSortColumn -eq $map[$header]) {
            $script:CurrentSortDirection = if ($script:CurrentSortDirection -eq 'Descending') { 'Ascending' } else { 'Descending' }
        } else {
            $script:CurrentSortColumn = $map[$header]
            $script:CurrentSortDirection = 'Descending'
        }
        Update-ResultsGrid -Data $script:LastScanResults
    }
})

# ---------------------------------------------------------------------------
# UI timer: drains progress messages from the background scan and detects
# completion, without blocking the WPF message loop.
# ---------------------------------------------------------------------------
$script:scanTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:scanTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:scanTimer.Add_Tick({
    $line = $null
    while ($script:ProgressQueue.TryDequeue([ref]$line)) {
        Write-UiLog $line
        $script:lblStatus.Text = $line
    }

    if ($script:ActiveJob -and $script:ActiveJob.IsCompleted) {
        $script:scanTimer.Stop()
        try {
            $results = $script:ActivePowerShell.EndInvoke($script:ActiveJob)
            if ($script:ActivePowerShell.Streams.Error.Count -gt 0) {
                foreach ($err in $script:ActivePowerShell.Streams.Error) {
                    Write-UiLog "Scan error: $($err.Exception.Message)"
                }
            }
            $script:LastScanResults = @($results)
            Update-ResultsGrid -Data $script:LastScanResults
        } catch {
            Write-UiLog "Scan failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Scan Error', 'OK', 'Error') | Out-Null
        } finally {
            $script:ActivePowerShell.Dispose()
            $script:ActivePowerShell = $null
            $script:ActiveJob = $null
            Set-ScanUiState -Running $false
        }
    }
})

# ---------------------------------------------------------------------------
# UI timer: drains progress messages from the background quarantine move and
# detects completion, without blocking the WPF message loop. Reuses the
# scan's progress bar/status label since scanning and quarantining are never
# expected to run at the same time (both buttons that would start a
# concurrent scan are disabled while quarantining is in progress).
# ---------------------------------------------------------------------------
$script:quarantineTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:quarantineTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:quarantineTimer.Add_Tick({
    $line = $null
    while ($script:QuarantineProgressQueue.TryDequeue([ref]$line)) {
        if ($line -match '^PROGRESS:(\d+):(\d+):(.*)$') {
            $idx = [int]$Matches[1]
            $total = [int]$Matches[2]
            $msg = $Matches[3]
            $script:pbScan.Value = $idx
            $script:lblStatus.Text = "Quarantining $idx/$total..."
            Write-UiLog $msg
        } else {
            Write-UiLog $line
        }
    }

    if ($script:ActiveQuarantineJob -and $script:ActiveQuarantineJob.IsCompleted) {
        $script:quarantineTimer.Stop()
        try {
            $result = $script:ActiveQuarantinePowerShell.EndInvoke($script:ActiveQuarantineJob) | Select-Object -First 1
            if ($script:ActiveQuarantinePowerShell.Streams.Error.Count -gt 0) {
                foreach ($err in $script:ActiveQuarantinePowerShell.Streams.Error) {
                    Write-UiLog "Quarantine error: $($err.Exception.Message)"
                }
            }

            if ($result -and $result.ManifestEntries.Count -gt 0) {
                $manifestPath = Join-Path $script:ManifestDir "quarantine-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
                $result.ManifestEntries | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
                $script:LastManifestPath = $manifestPath
                Write-UiLog "Quarantine manifest written to $manifestPath"
            }

            $moved = if ($result) { $result.Moved } else { 0 }
            $failed = if ($result) { $result.Failed } else { 0 }
            [System.Windows.MessageBox]::Show("Moved to quarantine: $moved`nFailed: $failed", 'Quarantine Complete', 'OK', 'Information') | Out-Null
        } catch {
            Write-UiLog "Quarantine failed: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Quarantine Error', 'OK', 'Error') | Out-Null
        } finally {
            $script:ActiveQuarantinePowerShell.Dispose()
            $script:ActiveQuarantinePowerShell = $null
            $script:ActiveQuarantineJob = $null
            $script:pbScan.Visibility = 'Collapsed'
            $script:pbScan.IsIndeterminate = $true
            $script:lblStatus.Text = 'Idle'
            $btnQuarantine.IsEnabled = $true
            $btnUndo.IsEnabled = $true
            $btnScan.IsEnabled = $true
        }
    }
})

$window.Add_Closing({
    Save-CurrentSettings
    if ($script:CancelState) { $script:CancelState.Cancelled = $true }
})

Write-UiLog 'Ready.'
Write-UiLog "Log file: $script:LogPath"
Write-UiLog 'Place TagLibSharp.dll next to this script or under .\lib for tag-based matching (optional).'
Write-UiLog 'Selected duplicates are moved to quarantine, never permanently deleted, and can be restored with Undo Last Quarantine.'
Write-UiLog 'Tip: keep threshold around 75 for likely duplicates, and 90+ for aggressive cleanup.'
$window.ShowDialog() | Out-Null
