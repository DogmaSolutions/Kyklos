#Requires -Version 5.1
<#
.SYNOPSIS
    Formal check of shell, PowerShell and batch scripts: encoding, line endings, quoting and parse errors - the
    checks that must pass even where a script cannot be tested.

.DESCRIPTION
    One implementation, used by the pre-push hook and by the script-lint CI job, under PowerShell 7 or Windows
    PowerShell 5.1 with the same verdict: what 5.1 cannot parse is SL010 under 5.1 and SL012 under PowerShell 7. The
    rules live in lib/ScriptLintRules.ps1 (SL001-SL012, listed there). A rule whose tool is missing (bash, shellcheck)
    is reported as a notice, never passed silently; -RequireTool makes the missing tool an error, and -SkipTool
    treats an installed tool as missing (same notice), so a host that happens to have it does not change the verdict.

    Allow-list: <repo>/.script-lint-allow (or -AllowList), one entry per line, <path>|<RULE>|<reason>; the reason is
    mandatory and an entry that matches nothing is reported as stale.

    Explicit opt-out: environment variable SCRIPT_LINT=off.

.PARAMETER Repo
    Repository root. Default: the current folder.
.PARAMETER ChangedSince
    Check only the scripts added, copied, modified or renamed between this ref and HEAD.
.PARAMETER Path
    Check these files (relative to -Repo) instead of the tracked scripts.
.PARAMETER AllowList
    Allow-list file, relative to -Repo. Default: .script-lint-allow.
.PARAMETER RequireTool
    Tools whose absence is an error: bash, shellcheck.
.PARAMETER SkipTool
    Tools not to run even when installed (bash, shellcheck); their rules are reported as not checked. A tool cannot be
    both required and skipped.

.NOTES
    Output: one line per finding, "path:line: RULE: message", then a summary line.
    Exit code: 0 clean, 1 blocking findings, 2 usage or environment error.
    Must stay ASCII-only and Windows PowerShell 5.1 compatible: CI checks this file with itself under 5.1.
#>
[CmdletBinding()]
param(
    [string]$Repo = '.',
    [string]$ChangedSince = '',
    [string[]]$Path = @(),
    [string]$AllowList = '.script-lint-allow',
    [string[]]$RequireTool = @(),
    [string[]]$SkipTool = @()
)
$ErrorActionPreference = 'Stop'
# pwsh -File passes a comma-separated list as one string: split it.
$RequireTool = @($RequireTool | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$SkipTool = @($SkipTool | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($t in $SkipTool) {
    if ($t -notin @('bash', 'shellcheck')) { Write-Output "script-lint: -SkipTool accepts bash and shellcheck, not '$t'"; exit 2 }
    if ($RequireTool -contains $t) { Write-Output "script-lint: '$t' cannot be both required and skipped"; exit 2 }
}
. (Join-Path $PSScriptRoot 'lib/ScriptLintRules.ps1')
. (Join-Path $PSScriptRoot 'lib/NativeCommand.ps1')   # native tools must not abort the check by writing to stderr

if ($env:SCRIPT_LINT -eq 'off') { Write-Output 'script-lint: disabled by SCRIPT_LINT=off'; exit 0 }
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Write-Output "script-lint: repository folder not found: $Repo"; exit 2 }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
# git writes file names as UTF-8: decode native output as UTF-8 (Windows PowerShell 5.1 would use the OEM code page).
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { Write-Output 'script-lint: notice: could not switch the console to UTF-8; non-ASCII file names may be misread' }

function Get-TargetFiles {
    # pwsh -File passes a comma-separated list as one string: split it.
    if ($Path.Count -gt 0) { return @($Path | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    # core.quotePath=false: git otherwise quotes a path with non-ASCII bytes ("caf\303\251.ps1"), which then matches
    # no file and would be skipped. A listed script that cannot be found is reported (SL000), never dropped silently.
    # stderr is dropped: these lines are parsed as file names.
    if ($ChangedSince) { $git = Invoke-NativeCommand git @('-C', $Repo, '-c', 'core.quotePath=false', 'diff', '--name-only', '--diff-filter=ACMR', $ChangedSince, 'HEAD') }
    else { $git = Invoke-NativeCommand git @('-C', $Repo, '-c', 'core.quotePath=false', 'ls-files') }
    if ($git.ExitCode -ne 0) { Write-Output "script-lint: git could not list the files in $Repo (exit $($git.ExitCode))"; exit 2 }
    return @(@($git.Lines) | Where-Object { $_ -and (Get-ScriptKind $_) })
}

$files = Get-TargetFiles
# git's record of the committed line endings (the working copy depends on core.autocrlf); empty outside git.
$eol = @{}
$eolListing = Invoke-NativeCommand git @('-C', $Repo, '-c', 'core.quotePath=false', 'ls-files', '--eol')
if ($eolListing.ExitCode -eq 0) { $eol = ConvertFrom-GitEolListing @($eolListing.Lines) }
$findings = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$hasBash = ($SkipTool -notcontains 'bash') -and [bool](Get-Command bash -ErrorAction SilentlyContinue)
$hasShellcheck = ($SkipTool -notcontains 'shellcheck') -and [bool](Get-Command shellcheck -ErrorAction SilentlyContinue)
$shellCount = 0

foreach ($rel in $files) {
    $full = Join-Path $Repo $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $findings.Add((New-ScriptLintFinding $rel 0 'SL000' 'file not found')); continue }
    $kind = Get-ScriptKind $rel
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $lines = ConvertTo-ScriptLintLines $bytes
    $indexEol = ''; $eolAttr = ''
    if ($eol.ContainsKey($rel)) { $indexEol = $eol[$rel].Index; $eolAttr = $eol[$rel].EolAttribute }
    foreach ($f in (Get-EncodingFindings $rel $bytes $kind)) { $findings.Add($f) }
    switch ($kind) {
        'shell' {
            $shellCount++
            foreach ($f in (Get-ShellLineEndingFindings $rel $lines $indexEol)) { $findings.Add($f) }
            if ($hasBash) {
                # Merged: bash reports syntax errors on stderr; the parser picks the diagnostic lines out of any noise.
                $out = Invoke-NativeCommand bash @('-n', $full) -StdErr Merge
                if ($out.ExitCode -ne 0) { $findings.Add((ConvertFrom-BashSyntaxOutput $rel $out.Lines)) }
            }
            if ($hasShellcheck) {
                $sc = ConvertFrom-ShellcheckOutput $rel (Invoke-NativeCommand shellcheck @('-f', 'gcc', '-S', 'style', $full)).Lines
                foreach ($f in $sc.Findings) { $findings.Add($f) }
                foreach ($w in $sc.Warnings) { $warnings.Add($w) }
            }
        }
        'batch' { foreach ($f in (Get-BatchFindings $rel $lines $indexEol $eolAttr)) { $findings.Add($f) } }
        'powershell' {
            foreach ($f in (Get-NativeHereStringFindings $rel $lines)) { $findings.Add($f) }
            foreach ($f in (Get-PowerShellParseFindings $rel $full)) { $findings.Add($f) }
        }
    }
}

$notices = New-Object System.Collections.Generic.List[string]
foreach ($tool in @(@{ Name = 'bash'; Has = $hasBash; Rule = 'SL004' }, @{ Name = 'shellcheck'; Has = $hasShellcheck; Rule = 'SL005' })) {
    if ($shellCount -gt 0 -and -not $tool.Has) {
        if ($RequireTool -contains $tool.Name) { $findings.Add((New-ScriptLintFinding '(environment)' 0 $tool.Rule "$($tool.Name) is required here but is not installed")) }
        else {
            $why = if ($SkipTool -contains $tool.Name) { 'is skipped here (-SkipTool)' } else { 'is not installed here' }
            $notices.Add("notice: $($tool.Name) $why, $($tool.Rule) was not checked on $shellCount shell script(s)")
        }
    }
}

$allowFile = Join-Path $Repo $AllowList
$allowed = @{}
if (Test-Path -LiteralPath $allowFile -PathType Leaf) {
    try { $allowed = Read-ScriptLintAllowList ([System.IO.File]::ReadAllLines($allowFile)) $AllowList }
    catch { Write-Output "script-lint: $($_.Exception.Message)"; exit 2 }
}
$result = Resolve-ScriptLintFindings $findings.ToArray() $allowed

foreach ($f in $result.Blocking) { Write-Output (Format-ScriptLintFinding $f) }
foreach ($a in $result.Allowed) { Write-Output ((Format-ScriptLintFinding $a.Finding) + " (allowed: $($a.Reason))") }
foreach ($w in $warnings) { Write-Output $w }
foreach ($s in $result.Stale) { Write-Output "script-lint: stale allow-list entry (matches nothing): $s" }
foreach ($n in $notices) { Write-Output "script-lint: $n" }
Write-Output ('script-lint: {0} script(s) checked with PowerShell {1}, {2} blocking finding(s)' -f $files.Count, $PSVersionTable.PSVersion.ToString(), $result.Blocking.Count)
if ($result.Blocking.Count -gt 0) { exit 1 }
exit 0
