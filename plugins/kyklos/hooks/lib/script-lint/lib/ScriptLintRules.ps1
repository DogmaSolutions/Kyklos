# ScriptLintRules.ps1 - the rules of the formal script check (Invoke-ScriptLint.ps1), as pure functions.
# Dot-source it. Every function takes plain values (bytes, lines, a tool probe) so each rule is testable without a
# repository or the tools installed. ASCII-only and Windows PowerShell 5.1 compatible: CI runs it under 5.1.
#
# Rules (a finding is blocking unless allow-listed):
#   SL001  non-ASCII byte in a PowerShell or batch file. Windows PowerShell 5.1 reads a file without a byte-order
#          mark in the ANSI code page and cmd.exe in the OEM code page: a UTF-8 em-dash becomes three characters,
#          the last one a typographic double quote that can end a string.
#   SL002  UTF-8 byte-order mark in any script.
#   SL003  CR line ending in a shell script.
#   SL004  bash syntax error (bash -n).
#   SL005  shellcheck error (warnings are reported, not blocking).
#   SL006  batch line without a CRLF ending (cmd.exe mis-parses labels and blocks with LF endings).
#   SL007  odd number of double quotes on a batch line (outside REM and :: comments).
#   SL008  unbalanced parentheses in a batch file (outside quotes and comments).
#   SL009  double quote inside a PowerShell here-string that is passed to a native program: Windows PowerShell 5.1
#          splits a native argument at every double quote, so the program receives a truncated script.
#   SL010  PowerShell parse error (the parser of the PowerShell running the check).
#   SL011  confusable character in any script: a Greek or Cyrillic letter, a typographic quote, a no-break space,
#          a zero-width character or a byte-order mark after the start of the file.
#   SL012  PowerShell 7-only syntax in a PowerShell file (pipeline chains && and ||, the ternary ?:, the null
#          operators ??, ??=, ?. and ?[], a clean block). Windows PowerShell 5.1 cannot parse it, so it is a parse
#          error on Windows hosts. Under 5.1 the parser already reports it as SL010; under PowerShell 7 the
#          parser accepts it, and this rule reports it instead, so the verdict is the same on both.
# Shell scripts may otherwise keep UTF-8 text: bash reads it correctly.

$script:ScriptLintExtensions = @{
    '.sh' = 'shell'; '.bash' = 'shell'
    '.ps1' = 'powershell'; '.psm1' = 'powershell'; '.psd1' = 'powershell'
    '.bat' = 'batch'; '.cmd' = 'batch'
}
$script:ScriptLintNativePrograms = 'docker|docker\.exe|bash|bash\.exe|sh|cmd|cmd\.exe|wsl|wsl\.exe|ssh|ssh\.exe|powershell|powershell\.exe|pwsh'

function Get-ScriptLintConfusablePattern {
    # Built from code points so this file stays ASCII: Greek and Cyrillic blocks, typographic quotes, no-break
    # space, zero-width space/non-joiner/joiner, word joiner, byte-order mark.
    $ranges = @(@(0x0370, 0x03FF), @(0x0400, 0x04FF))
    $points = @(0x2018, 0x2019, 0x201A, 0x201B, 0x201C, 0x201D, 0x201E, 0x00A0, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF)
    $body = ''
    foreach ($r in $ranges) { $body += ('\u{0:X4}-\u{1:X4}' -f $r[0], $r[1]) }
    foreach ($p in $points) { $body += ('\u{0:X4}' -f $p) }
    return '[' + $body + ']'
}

function New-ScriptLintFinding([string]$File, [int]$Line, [string]$Rule, [string]$Message) {
    return [pscustomobject]@{ File = $File; Line = $Line; Rule = $Rule; Message = $Message }
}

function Get-ScriptKind([string]$File) {
    $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
    if ($script:ScriptLintExtensions.ContainsKey($ext)) { return $script:ScriptLintExtensions[$ext] }
    return $null
}

function ConvertTo-ScriptLintLines([byte[]]$Bytes) {
    $hasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($hasBom -and $text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return , @($text -split "`n")
}

function Get-EncodingFindings([string]$File, [byte[]]$Bytes, [string]$Kind) {
    $out = New-Object System.Collections.Generic.List[object]
    $hasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    if ($hasBom) { $out.Add((New-ScriptLintFinding $File 1 'SL002' 'UTF-8 byte-order mark')) }
    if ($Kind -eq 'powershell' -or $Kind -eq 'batch') {
        $line = 1; $lines = 0; $flagged = $false
        $start = 0; if ($hasBom) { $start = 3 }
        for ($i = $start; $i -lt $Bytes.Length; $i++) {
            $b = $Bytes[$i]
            if ($b -eq 10) { $line++; $flagged = $false; continue }
            if ($b -gt 127 -and -not $flagged) {
                $flagged = $true; $lines++
                if ($lines -le 5) { $out.Add((New-ScriptLintFinding $File $line 'SL001' 'non-ASCII byte (PowerShell and batch files must be ASCII-only)')) }
            }
        }
        if ($lines -gt 5) { $out.Add((New-ScriptLintFinding $File 0 'SL001' "non-ASCII bytes on $lines lines in total (first 5 listed)")) }
    }
    $pattern = Get-ScriptLintConfusablePattern
    $lineArr = ConvertTo-ScriptLintLines $Bytes
    $n = 0
    for ($k = 0; $k -lt $lineArr.Length; $k++) {
        $m = [regex]::Match($lineArr[$k], $pattern)
        if ($m.Success) {
            $out.Add((New-ScriptLintFinding $File ($k + 1) 'SL011' ('confusable character U+{0:X4} (looks like ASCII but is not)' -f [int][char]$m.Value)))
            $n++; if ($n -ge 5) { break }
        }
    }
    return , $out.ToArray()
}

function Get-ShellLineEndingFindings([string]$File, [string[]]$Lines, [string]$IndexEol = '') {
    # $IndexEol: git's record of the committed line endings ('lf', 'crlf', 'mixed', from git ls-files --eol). When
    # known it decides, because the working copy depends on the checkout settings (core.autocrlf on Windows adds CR).
    if ($IndexEol) {
        if ($IndexEol -eq 'crlf' -or $IndexEol -eq 'mixed') { return , @((New-ScriptLintFinding $File 1 'SL003' "CR line endings committed in a shell script ($IndexEol; use LF)")) }
        return , @()
    }
    for ($k = 0; $k -lt $Lines.Length; $k++) {
        if ($Lines[$k].EndsWith("`r")) { return , @((New-ScriptLintFinding $File ($k + 1) 'SL003' 'CR line ending in a shell script (use LF)')) }
    }
    return , @()
}

function ConvertFrom-BashSyntaxOutput([string]$File, [string[]]$Output) {
    # The output may carry noise that is not about the script (a terminal warning, a locale hint). Only a line that
    # looks like a bash diagnostic ("<file>: line <n>: ..." or "<file>: syntax error ...") is reported.
    $diag = @(@($Output) | Where-Object { "$_" -match ': line \d+: ' -or "$_" -match ': syntax error' })
    if ($diag.Count -eq 0) {
        $first = [string](@($Output) | Where-Object { "$_".Trim() } | Select-Object -First 1)
        return New-ScriptLintFinding $File 1 'SL004' ('bash -n failed but printed no diagnostic recognised as a syntax error' + $(if ($first) { ': ' + $first } else { '' }))
    }
    $msg = [string]$diag[0]
    $ln = 1
    if ($msg -match 'line (\d+)') { $ln = [int]$Matches[1] }
    return New-ScriptLintFinding $File $ln 'SL004' ('bash syntax error: ' + ($msg -replace '^.*?line \d+: ', ''))
}

function ConvertFrom-ShellcheckOutput([string]$File, [string[]]$Output) {
    # shellcheck -f gcc lines: <path>:<line>:<col>: <level>: <message>. Errors are findings; the rest are warnings.
    $findings = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($Output)) {
        if ($l -match '^.*?:(\d+):\d+: (error|warning|note|info|style): (.*)$') {
            if ($Matches[2] -eq 'error') { $findings.Add((New-ScriptLintFinding $File ([int]$Matches[1]) 'SL005' ('shellcheck: ' + $Matches[3]))) }
            else { $warnings.Add(('{0}:{1}: warning: shellcheck: {2}' -f $File, $Matches[1], $Matches[3])) }
        }
    }
    return [pscustomobject]@{ Findings = $findings.ToArray(); Warnings = $warnings.ToArray() }
}

function ConvertFrom-GitEolListing([string[]]$Lines) {
    # Parses `git ls-files --eol` lines ("i/lf    w/crlf  attr/text eol=crlf      path") into
    # path -> @{ Index = 'lf'|'crlf'|'mixed'|'none'|''; EolAttribute = 'crlf'|'lf'|'' }.
    $map = @{}
    foreach ($l in @($Lines)) {
        if ($l -notmatch '^i/(\S*)\s+w/\S*\s+attr/(.*?)\t(.+)$') { continue }
        $index = [string]$Matches[1]; $attrText = [string]$Matches[2]; $path = [string]$Matches[3]
        $attr = ''
        if ($attrText -match 'eol=(crlf|lf)') { $attr = $Matches[1] }
        $map[$path] = @{ Index = $index; EolAttribute = $attr }
    }
    return $map
}

function Test-BatchCodeLine([string]$Line) {
    $t = $Line.TrimStart(" `t@")
    if ($t -match '^rem(\s|$)' -or $t.StartsWith('::')) { return $false }
    return $true
}

function Get-BatchFindings([string]$File, [string[]]$Lines, [string]$IndexEol = '', [string]$EolAttribute = '') {
    # $IndexEol / $EolAttribute: git's record of the committed line endings and the file's eol attribute. With
    # eol=crlf git writes CRLF on every checkout, so LF in the repository is fine.
    $out = New-Object System.Collections.Generic.List[object]
    if ($IndexEol) {
        if ($EolAttribute -ne 'crlf' -and ($IndexEol -eq 'lf' -or $IndexEol -eq 'mixed')) {
            $out.Add((New-ScriptLintFinding $File 1 'SL006' "LF line endings committed in a batch file ($IndexEol; use CRLF or an eol=crlf attribute)"))
        }
    } else {
        for ($k = 0; $k -lt $Lines.Length - 1; $k++) {
            if (-not $Lines[$k].EndsWith("`r")) { $out.Add((New-ScriptLintFinding $File ($k + 1) 'SL006' 'line without a CRLF ending')); break }
        }
    }
    $open = 0; $close = 0; $q = 0
    for ($k = 0; $k -lt $Lines.Length; $k++) {
        $l = $Lines[$k].TrimEnd("`r")
        if (-not (Test-BatchCodeLine $l)) { continue }
        $quotes = ([regex]::Matches($l, '"')).Count
        if (($quotes % 2) -eq 1 -and $q -lt 5) { $out.Add((New-ScriptLintFinding $File ($k + 1) 'SL007' 'odd number of double quotes on this line')); $q++ }
        $bare = [regex]::Replace($l, '"[^"]*"', '').Replace('^(', '').Replace('^)', '')
        $open += ([regex]::Matches($bare, '\(')).Count
        $close += ([regex]::Matches($bare, '\)')).Count
    }
    if ($open -ne $close) { $out.Add((New-ScriptLintFinding $File 0 'SL008' "unbalanced parentheses: $open '(' and $close ')'")) }
    return , $out.ToArray()
}

function Get-NativeHereStringFindings([string]$File, [string[]]$Lines) {
    # A here-string assigned to a variable and later passed to a native program must not contain a double quote.
    $firstQuote = @{}; $start = @{}; $current = $null
    for ($k = 0; $k -lt $Lines.Length; $k++) {
        $l = $Lines[$k].TrimEnd("`r")
        if ($null -ne $current) {
            if ($l -match "^[`"']@") { $current = $null; continue }
            if ($l.Contains('"') -and -not $firstQuote.ContainsKey($current)) { $firstQuote[$current] = $k + 1 }
            continue
        }
        if ($l -match "^\s*\`$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*@[`"']\s*$") { $current = $Matches[1]; $start[$current] = $k + 1 }
    }
    $out = New-Object System.Collections.Generic.List[object]
    $native = "(^|[\s&(])($script:ScriptLintNativePrograms)(\s|$)|&\s*\`$[A-Za-z_]|(bash|sh)\s+-c|cmd(\.exe)?\s+/c"
    foreach ($name in @($firstQuote.Keys)) {
        $esc = [regex]::Escape($name)
        for ($k = 0; $k -lt $Lines.Length; $k++) {
            $l = $Lines[$k]
            if ($l -match ('\$' + $esc + '\b') -and $l -match $native -and $l -notmatch ('^\s*\$' + $esc + '\s*=')) {
                $out.Add((New-ScriptLintFinding $File $start[$name] 'SL009' ("here-string `$$name is passed to a native program (line $($k + 1)) but contains a double quote (line $($firstQuote[$name]))")))
                break
            }
        }
    }
    return , $out.ToArray()
}

function Get-PowerShellParseFindings([string]$File, [string]$FullPath) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$tokens, [ref]$errors)
    $out = New-Object System.Collections.Generic.List[object]
    $ver = '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
    foreach ($e in @($errors)) {
        if ($out.Count -ge 5) { break }
        $out.Add((New-ScriptLintFinding $File $e.Extent.StartLineNumber 'SL010' ("PowerShell $ver parse error: " + ($e.Message -replace '[\r\n]+', ' '))))
    }
    if (@($errors).Count -eq 0) { foreach ($f in (Get-PowerShell7SyntaxFindings $File $ast $tokens)) { $out.Add($f) } }
    return , $out.ToArray()
}

function Get-PowerShell7SyntaxFindings([string]$File, $Ast, $Tokens) {
    # SL012 [RiskMitigation RA-03]: the same verdict on Linux as under 5.1. Names are compared as strings: the token kinds and AST types of PowerShell 7 do not exist in 5.1, and
    # this file must load under 5.1 (where the parser rejects the syntax itself, so nothing is found here).
    $out = New-Object System.Collections.Generic.List[object]
    $kinds = @{ 'AndAnd' = '&&'; 'OrOr' = '||'; 'QuestionQuestion' = '??'; 'QuestionQuestionEquals' = '??='; 'QuestionDot' = '?.'; 'QuestionLBracket' = '?[' }
    $seen = @{}
    foreach ($t in @($Tokens)) {
        if ($null -eq $t) { continue }
        $k = $t.Kind.ToString()
        if ($kinds.ContainsKey($k)) { $seen["$($t.Extent.StartLineNumber)|$($kinds[$k])"] = $t.Extent.StartLineNumber }
    }
    if ($null -ne $Ast) {
        foreach ($n in @($Ast.FindAll({ param($x) $x.GetType().Name -eq 'TernaryExpressionAst' }, $true))) {
            $seen["$($n.Extent.StartLineNumber)|?:"] = $n.Extent.StartLineNumber
        }
        foreach ($n in @($Ast.FindAll({ param($x) $x.GetType().Name -eq 'NamedBlockAst' -and $x.BlockKind.ToString() -eq 'Clean' }, $true))) {
            $seen["$($n.Extent.StartLineNumber)|clean"] = $n.Extent.StartLineNumber
        }
    }
    foreach ($key in @($seen.Keys | Sort-Object { $seen[$_] }, { $_ })) {
        if ($out.Count -ge 5) { break }
        $what = $key.Substring($key.IndexOf('|') + 1)
        $out.Add((New-ScriptLintFinding $File $seen[$key] 'SL012' "PowerShell 7-only syntax '$what' (Windows PowerShell 5.1 cannot parse it)"))
    }
    return , $out.ToArray()
}

function Read-ScriptLintAllowList([string[]]$Lines, [string]$Name) {
    # Entries: <path>|<RULE>|<reason>. Throws on an entry without a path, a rule or a reason.
    $allowed = @{}
    $n = 0
    foreach ($raw in @($Lines)) {
        $n++
        $e = ([string]$raw).Trim()
        if (-not $e -or $e.StartsWith('#')) { continue }
        $parts = $e.Split('|')
        $reason = ''
        if ($parts.Count -ge 3) { $reason = (($parts[2..($parts.Count - 1)]) -join '|').Trim() }
        if ($parts.Count -lt 3 -or -not $parts[0].Trim() -or -not $parts[1].Trim() -or -not $reason) {
            throw "${Name}:${n}: an entry needs <path>|<RULE>|<reason>: $e"
        }
        $allowed[$parts[0].Trim() + '|' + $parts[1].Trim()] = $reason
    }
    return $allowed
}

function Resolve-ScriptLintFindings([object[]]$Findings, [hashtable]$Allowed) {
    # Splits findings into blocking and allowed, and names the allow-list entries that matched nothing.
    $blocking = New-Object System.Collections.Generic.List[object]
    $allowedHits = New-Object System.Collections.Generic.List[object]
    $used = @{}
    foreach ($f in @($Findings)) {
        $key = $f.File + '|' + $f.Rule
        if ($Allowed.ContainsKey($key)) { $used[$key] = $true; $allowedHits.Add([pscustomobject]@{ Finding = $f; Reason = $Allowed[$key] }) }
        else { $blocking.Add($f) }
    }
    $stale = @($Allowed.Keys | Where-Object { -not $used.ContainsKey($_) } | Sort-Object)
    return [pscustomobject]@{ Blocking = $blocking.ToArray(); Allowed = $allowedHits.ToArray(); Stale = $stale }
}

function Format-ScriptLintFinding($Finding) {
    return '{0}:{1}: {2}: {3}' -f $Finding.File, $Finding.Line, $Finding.Rule, $Finding.Message
}
