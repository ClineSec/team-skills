[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("install", "remove")]
    [string]$Action,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$RepositoryUrl,

    [Parameter(Position = 2)]
    [AllowEmptyString()]
    [string]$Prefix
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Team Skills milestone-2 lifecycle utility. Runtime dependencies: Windows PowerShell and Git.
$PrefixWasSupplied = $PSBoundParameters.ContainsKey("Prefix")
$WorkRoot = $null
$CandidateWorktree = $null
$ManagedRepo = $null

function Fail([string]$Message) {
    throw [System.InvalidOperationException]::new($Message)
}

function Get-Sha256([string]$Value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-PortableName([string]$Value, [int]$Maximum = 64) {
    return $Value.Length -le $Maximum -and $Value -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$'
}

function Get-FullSafeRoot([string]$Value, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Fail "$Label must not be blank"
    }
    if ($Value -match '[\x00-\x1f]') {
        Fail "$Label must not contain control characters"
    }
    if (-not [System.IO.Path]::IsPathRooted($Value)) {
        Fail "$Label must be an absolute path"
    }
    $full = [System.IO.Path]::GetFullPath($Value)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\', '/') -eq $pathRoot.TrimEnd('\', '/')) {
        Fail "$Label must not be a filesystem root"
    }
    return $full.TrimEnd('\', '/')
}

function Test-PathEntry([string]$Path) {
    try {
        $null = Get-Item -Force -LiteralPath $Path
        return $true
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $false
    }
}

function Test-ReparsePoint([System.IO.FileSystemInfo]$Item) {
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Invoke-Git([string[]]$Arguments, [ref]$Output) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& git @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    $Output.Value = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return $code
}

function Get-GitValue([string[]]$Arguments, [string]$FailureMessage) {
    $captured = ""
    if ((Invoke-Git $Arguments ([ref]$captured)) -ne 0) {
        Fail $FailureMessage
    }
    return $captured.Trim()
}

function Read-Utf8Text([string]$Path) {
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    return [System.IO.File]::ReadAllText($Path, $encoding)
}

function Test-Skill([string]$SkillDirectory, [string]$ExpectedName) {
    $skillFile = Join-Path $SkillDirectory "SKILL.md"
    if (-not (Test-PathEntry $skillFile)) { return $false }
    $item = Get-Item -Force -LiteralPath $skillFile
    if (-not ($item -is [System.IO.FileInfo]) -or (Test-ReparsePoint $item)) { return $false }
    try {
        $text = Read-Utf8Text $skillFile
    }
    catch { return $false }
    $lines = [System.Text.RegularExpressions.Regex]::Split($text, "\r?\n")
    if ($lines.Count -eq 0 -or $lines[0] -cne "---") { return $false }
    $closed = $false
    $names = @()
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -ceq "---") {
            $closed = $true
            break
        }
        if ($lines[$index] -cmatch '^name:[ \t]*(.*)$') {
            $names += $Matches[1]
        }
    }
    return $closed -and $names.Count -eq 1 -and $names[0] -ceq $ExpectedName
}

function Read-Catalog([string]$CatalogRoot) {
    $manifestPath = Join-Path $CatalogRoot "catalog.json"
    if (-not (Test-PathEntry $manifestPath)) { return $null }
    $manifestItem = Get-Item -Force -LiteralPath $manifestPath
    if (-not ($manifestItem -is [System.IO.FileInfo]) -or (Test-ReparsePoint $manifestItem)) {
        return $null
    }
    try {
        $manifest = (Read-Utf8Text $manifestPath) | ConvertFrom-Json
    }
    catch { return $null }
    if ($null -eq $manifest -or $manifest -isnot [System.Management.Automation.PSCustomObject]) {
        return $null
    }
    $expectedKeys = @('$schema', 'catalog_id', 'default_prefix', 'display_name', 'schema_version', 'skills_directory')
    $actualKeys = @($manifest.PSObject.Properties.Name | Sort-Object)
    if (($actualKeys -join "`n") -cne (($expectedKeys | Sort-Object) -join "`n")) { return $null }
    if ($manifest.'$schema' -cne './schemas/catalog.schema.json') { return $null }
    if (($manifest.schema_version -isnot [int] -and $manifest.schema_version -isnot [long]) -or $manifest.schema_version -ne 1) { return $null }
    if ($manifest.skills_directory -cne 'skills') { return $null }
    if ($manifest.catalog_id -isnot [string] -or -not (Test-PortableName $manifest.catalog_id)) { return $null }
    if ($manifest.display_name -isnot [string] -or $manifest.display_name.Length -eq 0 -or $manifest.display_name.Length -gt 128) { return $null }
    if ($manifest.default_prefix -isnot [string]) { return $null }
    if ($manifest.default_prefix.Length -gt 0 -and -not (Test-PortableName $manifest.default_prefix 62)) { return $null }

    $skillsRoot = Join-Path $CatalogRoot "skills"
    if (-not (Test-PathEntry $skillsRoot)) { return $null }
    $skillsRootItem = Get-Item -Force -LiteralPath $skillsRoot
    if (-not ($skillsRootItem -is [System.IO.DirectoryInfo]) -or (Test-ReparsePoint $skillsRootItem)) { return $null }
    foreach ($descendant in @(Get-ChildItem -Force -Recurse -LiteralPath $skillsRoot)) {
        if (Test-ReparsePoint $descendant) { return $null }
    }
    $skillDirectories = @(Get-ChildItem -Force -LiteralPath $skillsRoot)
    if ($skillDirectories.Count -eq 0) { return $null }
    foreach ($skillDirectory in $skillDirectories) {
        if (-not ($skillDirectory -is [System.IO.DirectoryInfo])) { return $null }
        if (-not (Test-PortableName $skillDirectory.Name)) { return $null }
        if (-not (Test-Skill $skillDirectory.FullName $skillDirectory.Name)) { return $null }
    }
    return $manifest
}

function New-DirectoryExposure([string]$Path, [string]$Target) {
    if ($env:OS -eq "Windows_NT") {
        $null = New-Item -ItemType Junction -Path $Path -Target $Target
    }
    else {
        $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target
    }
}

function Remove-DirectoryExposure([string]$Path) {
    $item = Get-Item -Force -LiteralPath $Path
    if (-not ($item -is [System.IO.DirectoryInfo]) -or -not (Test-ReparsePoint $item)) {
        Fail "refusing to remove a path that is not a directory link: $Path"
    }
    # Directory.Delete removes the junction/symlink itself and never traverses its target.
    [System.IO.Directory]::Delete($Path)
}

function Get-LinkTarget([string]$Path) {
    try {
        $item = Get-Item -Force -LiteralPath $Path
    }
    catch { return $null }
    if (-not (Test-ReparsePoint $item)) { return $null }
    $target = $item.Target
    if ($target -is [array]) { $target = $target[0] }
    if ([string]::IsNullOrEmpty([string]$target)) { return $null }
    if (-not [System.IO.Path]::IsPathRooted([string]$target)) {
        $target = Join-Path $item.Parent.FullName ([string]$target)
    }
    return [System.IO.Path]::GetFullPath([string]$target).TrimEnd('\', '/')
}

function Test-OwnedExposure([string]$Path, [string]$ExpectedTarget) {
    $actual = Get-LinkTarget $Path
    if ($null -eq $actual) { return $false }
    $expected = [System.IO.Path]::GetFullPath($ExpectedTarget).TrimEnd('\', '/')
    if ($env:OS -eq "Windows_NT") { return $actual -ieq $expected }
    return $actual -ceq $expected
}

function Activate-Generation([string]$InstallRoot, [string]$GenerationPath) {
    $current = Join-Path $InstallRoot "current"
    $next = Join-Path $InstallRoot (".current." + [guid]::NewGuid().ToString("N"))
    $previous = Join-Path $InstallRoot (".previous." + [guid]::NewGuid().ToString("N"))
    New-DirectoryExposure $next $GenerationPath
    if (-not (Test-PathEntry $current)) {
        Move-Item -LiteralPath $next -Destination $current
        return
    }
    if ($null -eq (Get-LinkTarget $current)) {
        Remove-DirectoryExposure $next
        Fail "catalog current view is not an owned directory link"
    }
    Move-Item -LiteralPath $current -Destination $previous
    try {
        Move-Item -LiteralPath $next -Destination $current
    }
    catch {
        Move-Item -LiteralPath $previous -Destination $current
        if (Test-PathEntry $next) { Remove-DirectoryExposure $next }
        throw
    }
    Remove-DirectoryExposure $previous
}

try {
    if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        Fail "repository URL must not be blank"
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Fail "USERPROFILE must be set"
    }
    $defaultState = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:USERPROFILE ".local\share\team-skills"
    } else {
        Join-Path $env:LOCALAPPDATA "team-skills"
    }
    $stateValue = if ($env:TEAM_SKILLS_STATE_ROOT) { $env:TEAM_SKILLS_STATE_ROOT } else { $defaultState }
    $agentsValue = if ($env:TEAM_SKILLS_AGENTS_ROOT) { $env:TEAM_SKILLS_AGENTS_ROOT } else { Join-Path $env:USERPROFILE ".agents\skills" }
    $claudeValue = if ($env:TEAM_SKILLS_CLAUDE_ROOT) { $env:TEAM_SKILLS_CLAUDE_ROOT } else { Join-Path $env:USERPROFILE ".claude\skills" }
    $StateRoot = Get-FullSafeRoot $stateValue "TEAM_SKILLS_STATE_ROOT"
    $AgentsRoot = Get-FullSafeRoot $agentsValue "TEAM_SKILLS_AGENTS_ROOT"
    $ClaudeRoot = Get-FullSafeRoot $claudeValue "TEAM_SKILLS_CLAUDE_ROOT"

    $null = New-Item -ItemType Directory -Force -Path $StateRoot
    $WorkRoot = Join-Path $StateRoot (".operation." + [guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Path $WorkRoot

    $suppliedDigest = Get-Sha256 $RepositoryUrl
    $originIndexRoot = Join-Path $StateRoot "origins"
    $originIndex = Join-Path $originIndexRoot ($suppliedDigest + ".instance")
    $existingInstance = $false
    if (Test-PathEntry $originIndex) {
        $indexItem = Get-Item -Force -LiteralPath $originIndex
        if (-not ($indexItem -is [System.IO.FileInfo]) -or (Test-ReparsePoint $indexItem)) {
            Fail "catalog origin index is invalid"
        }
        $instanceKey = ([System.IO.File]::ReadAllText($originIndex)).Trim()
        if ($instanceKey -cnotmatch '^[a-z0-9-]+$') { Fail "catalog origin index is invalid" }
        $instanceRoot = Join-Path (Join-Path $StateRoot "catalogs") $instanceKey
        $ManagedRepo = Join-Path $instanceRoot "repo"
        if (-not (Test-PathEntry (Join-Path $ManagedRepo ".git"))) {
            Fail "catalog origin index does not reference a managed clone"
        }
        $manifest = Read-Catalog $ManagedRepo
        if ($null -eq $manifest) {
            Fail "managed catalog clone is invalid; keeping the last known-good installation"
        }
        $configuredOrigin = Get-GitValue @('-C', $ManagedRepo, 'remote', 'get-url', 'origin') "managed clone has no configured origin"
        $originDigest = Get-Sha256 $configuredOrigin
        if ($originDigest -cne $suppliedDigest) { Fail "managed clone origin no longer matches this catalog instance" }
        if ($instanceKey -cne ($manifest.catalog_id + '-' + $originDigest)) { Fail "catalog origin index identity mismatch" }
        $existingInstance = $true
    }
    else {
        $bootstrapClone = Join-Path $WorkRoot "bootstrap"
        $captured = ""
        if ((Invoke-Git @('clone', '--quiet', '--no-local', '--', $RepositoryUrl, $bootstrapClone) ([ref]$captured)) -ne 0) {
            Fail "unable to clone the supplied repository"
        }
        $manifest = Read-Catalog $bootstrapClone
        if ($null -eq $manifest) { Fail "supplied repository is not a valid catalog" }
        $configuredOrigin = Get-GitValue @('-C', $bootstrapClone, 'remote', 'get-url', 'origin') "clone has no configured origin"
        if ([string]::IsNullOrEmpty($configuredOrigin)) { Fail "clone origin must not be blank" }
        $originDigest = Get-Sha256 $configuredOrigin
        $instanceKey = $manifest.catalog_id + '-' + $originDigest
        $instanceRoot = Join-Path (Join-Path $StateRoot "catalogs") $instanceKey
        $ManagedRepo = Join-Path $instanceRoot "repo"
    }

    if (-not $PrefixWasSupplied) { $Prefix = $manifest.default_prefix }
    if ($Prefix.Length -gt 0 -and -not (Test-PortableName $Prefix 62)) { Fail "invalid prefix" }
    $installKey = if ($Prefix.Length -gt 0) { $Prefix } else { "_default" }
    $installRoot = Join-Path (Join-Path $instanceRoot "installs") $installKey

    if ($Action -ceq "remove") {
        if (-not (Test-PathEntry $ManagedRepo)) { Fail "catalog instance is not installed" }
        if (-not (Test-PathEntry $installRoot)) {
            Write-Output "Catalog $($manifest.catalog_id) prefix '$Prefix' is already absent."
            exit 0
        }
        foreach ($product in @('agents', 'claude')) {
            $productRoot = if ($product -ceq 'agents') { $AgentsRoot } else { $ClaudeRoot }
            $owners = Join-Path (Join-Path $installRoot "ownership") $product
            if (-not (Test-PathEntry $owners)) { continue }
            foreach ($ownerFile in @(Get-ChildItem -File -Filter "*.owner" -LiteralPath $owners)) {
                $effectiveName = $ownerFile.BaseName
                $destination = Join-Path $productRoot $effectiveName
                $expectedTarget = ([System.IO.File]::ReadAllText($ownerFile.FullName)).Trim()
                if (Test-OwnedExposure $destination $expectedTarget) {
                    Remove-DirectoryExposure $destination
                }
                elseif (Test-PathEntry $destination) {
                    [Console]::Error.WriteLine("warning: not removing changed path $destination")
                }
            }
        }
        Remove-Item -Recurse -Force -LiteralPath $installRoot
        $installsRoot = Join-Path $instanceRoot "installs"
        if ((Test-PathEntry $installsRoot) -and @(Get-ChildItem -Force -LiteralPath $installsRoot).Count -eq 0) {
            Remove-Item -Recurse -Force -LiteralPath $instanceRoot
            if ((Test-PathEntry $originIndex) -and ([System.IO.File]::ReadAllText($originIndex)).Trim() -ceq $instanceKey) {
                Remove-Item -Force -LiteralPath $originIndex
            }
        }
        Write-Output "Removed catalog $($manifest.catalog_id) prefix '$Prefix'."
        exit 0
    }

    if (-not $existingInstance) {
        if (Test-PathEntry $instanceRoot) { Fail "catalog instance state already exists without an origin index" }
        $null = New-Item -ItemType Directory -Path $instanceRoot
        Move-Item -LiteralPath $bootstrapClone -Destination $ManagedRepo
        $null = New-Item -ItemType Directory -Force -Path $originIndexRoot
        $indexTemp = Join-Path $originIndexRoot ("." + $suppliedDigest + "." + [guid]::NewGuid().ToString("N"))
        [System.IO.File]::WriteAllText($indexTemp, $instanceKey + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $indexTemp -Destination $originIndex
        $sourceRoot = $ManagedRepo
    }
    else {
        $captured = ""
        if ((Invoke-Git @('-C', $ManagedRepo, 'fetch', '--quiet', 'origin') ([ref]$captured)) -ne 0) {
            Fail "unable to fetch the managed catalog origin"
        }
        $remoteHead = Get-GitValue @('-C', $ManagedRepo, 'symbolic-ref', '-q', 'refs/remotes/origin/HEAD') "managed origin has no default branch"
        $CandidateWorktree = Join-Path $WorkRoot "candidate"
        if ((Invoke-Git @('-C', $ManagedRepo, 'worktree', 'add', '--quiet', '--detach', $CandidateWorktree, $remoteHead) ([ref]$captured)) -ne 0) {
            Fail "unable to stage the fetched catalog"
        }
        $sourceRoot = $CandidateWorktree
        $manifest = Read-Catalog $sourceRoot
        if ($null -eq $manifest) { Fail "fetched catalog is invalid; keeping the last known-good installation" }
    }

    $manifest = Read-Catalog $sourceRoot
    if ($null -eq $manifest) { Fail "catalog is invalid; keeping the last known-good installation" }
    if ($instanceKey -cne ($manifest.catalog_id + '-' + $originDigest)) {
        Fail "fetched catalog identity changed; keeping the last known-good installation"
    }
    if (-not $PrefixWasSupplied) { $Prefix = $manifest.default_prefix }
    $installKey = if ($Prefix.Length -gt 0) { $Prefix } else { "_default" }
    $installRoot = Join-Path (Join-Path $instanceRoot "installs") $installKey

    $generationId = Get-GitValue @('-C', $sourceRoot, 'rev-parse', 'HEAD') "catalog has no Git revision"
    $stagedGeneration = Join-Path $WorkRoot "generation"
    $null = New-Item -ItemType Directory -Path $stagedGeneration
    foreach ($skillDirectory in @(Get-ChildItem -Directory -LiteralPath (Join-Path $sourceRoot "skills"))) {
        $effectiveName = if ($Prefix.Length -gt 0) { $Prefix + '-' + $skillDirectory.Name } else { $skillDirectory.Name }
        if (-not (Test-PortableName $effectiveName)) { Fail "effective skill name is invalid or exceeds 64 characters: $effectiveName" }
        $stagedSkill = Join-Path $stagedGeneration $effectiveName
        Copy-Item -Recurse -LiteralPath $skillDirectory.FullName -Destination $stagedSkill
        if ($Prefix.Length -gt 0) {
            $skillFile = Join-Path $stagedSkill "SKILL.md"
            $text = Read-Utf8Text $skillFile
            # Leave the original LF or CRLF delimiter byte-for-byte intact.
            $rewritten = [System.Text.RegularExpressions.Regex]::Replace($text, '(?m)^name:[ \t]*[^\r\n]*(?=\r?$)', "name: $effectiveName")
            [System.IO.File]::WriteAllText($skillFile, $rewritten, [System.Text.UTF8Encoding]::new($false))
        }
        if (-not (Test-Skill $stagedSkill $effectiveName)) { Fail "generated skill failed validation: $effectiveName" }
    }

    $generationsRoot = Join-Path $installRoot "generations"
    $ownershipRoot = Join-Path $installRoot "ownership"
    $null = New-Item -ItemType Directory -Force -Path $generationsRoot
    foreach ($product in @('agents', 'claude')) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $ownershipRoot $product)
    }
    $generationPath = Join-Path $generationsRoot $generationId
    $currentTarget = Join-Path $installRoot "current"

    foreach ($product in @('agents', 'claude')) {
        $productRoot = if ($product -ceq 'agents') { $AgentsRoot } else { $ClaudeRoot }
        if ((Test-PathEntry $productRoot) -and -not ((Get-Item -Force -LiteralPath $productRoot) -is [System.IO.DirectoryInfo])) {
            Fail "product skills root is not a directory: $productRoot"
        }
        foreach ($generatedSkill in @(Get-ChildItem -Directory -LiteralPath $stagedGeneration)) {
            $destination = Join-Path $productRoot $generatedSkill.Name
            $ownerFile = Join-Path (Join-Path $ownershipRoot $product) ($generatedSkill.Name + ".owner")
            $expectedTarget = Join-Path $currentTarget $generatedSkill.Name
            if ((Test-PathEntry $destination) -and -not ((Test-PathEntry $ownerFile) -and (Test-OwnedExposure $destination $expectedTarget))) {
                [Console]::Error.WriteLine("warning: catalog $($manifest.catalog_id) skill $($generatedSkill.Name) skipped; destination exists: $destination")
            }
        }
    }

    if (-not (Test-PathEntry $generationPath)) {
        Move-Item -LiteralPath $stagedGeneration -Destination $generationPath
    }
    Activate-Generation $installRoot $generationPath

    foreach ($product in @('agents', 'claude')) {
        $productRoot = if ($product -ceq 'agents') { $AgentsRoot } else { $ClaudeRoot }
        $null = New-Item -ItemType Directory -Force -Path $productRoot
        $owners = Join-Path $ownershipRoot $product
        foreach ($ownerFile in @(Get-ChildItem -File -Filter "*.owner" -LiteralPath $owners)) {
            $ownedName = $ownerFile.BaseName
            if (Test-PathEntry (Join-Path $currentTarget $ownedName)) { continue }
            $destination = Join-Path $productRoot $ownedName
            $expectedTarget = ([System.IO.File]::ReadAllText($ownerFile.FullName)).Trim()
            if (Test-OwnedExposure $destination $expectedTarget) {
                Remove-DirectoryExposure $destination
            }
            elseif (Test-PathEntry $destination) {
                [Console]::Error.WriteLine("warning: not removing changed path $destination")
            }
            Remove-Item -Force -LiteralPath $ownerFile.FullName
        }
        foreach ($generatedSkill in @(Get-ChildItem -Directory -LiteralPath $currentTarget)) {
            $destination = Join-Path $productRoot $generatedSkill.Name
            $ownerFile = Join-Path $owners ($generatedSkill.Name + ".owner")
            $expectedTarget = Join-Path $currentTarget $generatedSkill.Name
            if (Test-PathEntry $destination) {
                if ((Test-PathEntry $ownerFile) -and (Test-OwnedExposure $destination $expectedTarget)) { continue }
                continue
            }
            [System.IO.File]::WriteAllText($ownerFile, $expectedTarget + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
            $linkTemp = Join-Path $productRoot (".team-skills-" + $generatedSkill.Name + "." + [guid]::NewGuid().ToString("N"))
            try {
                New-DirectoryExposure $linkTemp $expectedTarget
                Move-Item -LiteralPath $linkTemp -Destination $destination
            }
            catch {
                if (Test-PathEntry $linkTemp) { Remove-DirectoryExposure $linkTemp }
                Remove-Item -Force -LiteralPath $ownerFile
                Fail "cannot expose skill $($generatedSkill.Name)"
            }
        }
    }

    if ($null -ne $CandidateWorktree) {
        $captured = ""
        if ((Invoke-Git @('-C', $ManagedRepo, 'reset', '--quiet', '--hard', $remoteHead) ([ref]$captured)) -ne 0) {
            Fail "installed view is valid but managed clone could not advance"
        }
    }
    Write-Output "Installed catalog $($manifest.catalog_id) as instance $instanceKey with prefix '$Prefix'."
}
catch {
    [Console]::Error.WriteLine("error: " + $_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $CandidateWorktree -and $null -ne $ManagedRepo -and (Test-PathEntry $ManagedRepo)) {
        $captured = ""
        $null = Invoke-Git @('-C', $ManagedRepo, 'worktree', 'remove', '--force', $CandidateWorktree) ([ref]$captured)
    }
    if ($null -ne $WorkRoot -and (Test-PathEntry $WorkRoot)) {
        Remove-Item -Recurse -Force -LiteralPath $WorkRoot
    }
}
