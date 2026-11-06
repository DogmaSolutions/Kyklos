#Requires -Version 5.1
<#
.SYNOPSIS
  One way to run a native program (git, bash, dotnet, ...) from a script that sets $ErrorActionPreference = 'Stop'.

  Under 'Stop', Windows PowerShell 5.1 turns ANY line a native program writes to stderr into a terminating error,
  even when the program succeeded and even when stderr is redirected (2>$null, 2>&1). A harmless hint or warning
  then aborts the whole script, indistinguishable from a real failure. PowerShell 7 does not do this, so the defect
  only shows on the Windows hosts and runners.

  Invoke-NativeCommand lowers the preference for its own call only and returns the output lines and the exit code;
  the caller decides on the exit code. Choose what happens to stderr:
    -StdErr Drop   stdout only. Use it whenever the output is PARSED (file names, versions, ids): a stderr line
                   must never be taken for data.
    -StdErr Merge  stdout and stderr interleaved, as text. Use it for diagnostics shown to a person or filtered by
                   a parser that selects the lines it recognises.
  $LASTEXITCODE is left set to the program's exit code as well, for callers that read it.

  ASCII only. Windows PowerShell 5.1 compatible. Dot-source it.
#>

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateSet('Drop', 'Merge')][string]$StdErr = 'Drop'
    )
    # A missing program would otherwise leave the previous $LASTEXITCODE in place and read as that call's result.
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) { throw "Invoke-NativeCommand: program not found: $FilePath" }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($StdErr -eq 'Merge') { $raw = & $FilePath @ArgumentList 2>&1 }
        else { $raw = & $FilePath @ArgumentList 2>$null }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    # A merged stderr line arrives as an ErrorRecord; its text is the line itself.
    $lines = @(@($raw) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = $code
    return [pscustomobject]@{ Lines = $lines; ExitCode = $code }
}
