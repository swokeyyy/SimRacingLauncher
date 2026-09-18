@{
    # Run with: Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    # Deliberate choices, recorded so a clean run is reproducible:
    #  - New-Result (module) and Show-Status (scripts) are private helpers with a fixed positional
    #    contract (declared with [Parameter(Position = n)]); naming their arguments at every call
    #    site would only add noise.
    #  - Brace style is Stroustrup ("}" on its own line before else/catch), PSScriptAnalyzer's
    #    default formatting preset.
    IncludeDefaultRules = $true
    Rules               = @{
        PSAvoidUsingPositionalParameters = @{
            Enable           = $true
            CommandAllowList = @('New-Result', 'Show-Status')
        }
    }
}
