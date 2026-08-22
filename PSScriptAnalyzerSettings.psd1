@{
    # Repo-wide PSScriptAnalyzer configuration.
    # Used locally (Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1)
    # and by the CI workflow in .github/workflows/ci.yml.
    Severity    = @('Error', 'Warning')
    ExcludeRules = @(
        # 'Metadata', 'Details', and 'Settings' are accepted mass/collective
        # nouns in common PowerShell modules (e.g. Get-ADDefaultDomainPasswordPolicy-
        # style names) and read naturally here; pluralizing them to satisfy this
        # rule would make the API less clear, not more.
        'PSUseSingularNouns',

        # This rule targets reusable cmdlets in modules. The functions it
        # flags here (Start-DuplicateScanCore, Start-BackgroundScan,
        # Update-ResultsGrid, Set-ScanUiState) are internal WPF event-handler
        # plumbing in a single GUI application, not exported cmdlets a caller
        # would ever invoke with -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
