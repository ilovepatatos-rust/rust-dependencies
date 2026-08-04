@{
    RootModule = 'RustDependencies.psm1'
    ModuleVersion = '1.0.0'
    GUID = '5f635052-e20e-455a-96b4-9ba0d3299314'
    Author = 'ilovepatatos contributors'
    Description = 'Cross-platform Rust server dependency acquisition toolkit.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-RustDependencies',
        'Read-RdManifest',
        'Resolve-RdPlatform',
        'Resolve-RdOutputPath',
        'Clear-RdOutput',
        'Expand-RdArchive'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
