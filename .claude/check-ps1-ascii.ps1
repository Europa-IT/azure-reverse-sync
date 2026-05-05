$d = [Console]::In.ReadToEnd() | ConvertFrom-Json
$f = $d.tool_input.file_path
if ($f -match '\.ps1$' -and (Test-Path $f)) {
    $n = 0
    $bad = @()
    foreach ($line in (Get-Content $f -Encoding UTF8)) {
        $n++
        if ($line -cmatch '[^\x00-\x7F]') {
            $bad += "Line ${n}: $line"
        }
    }
    if ($bad) {
        $ctx = "Non-ASCII characters found in $f. Use only ASCII in .ps1 files (use # for decorators, -> for arrows, -- for dashes). Offending lines: " + ($bad -join "; ")
        [Console]::Out.WriteLine((@{hookSpecificOutput = @{hookEventName = "PostToolUse"; additionalContext = $ctx}} | ConvertTo-Json -Compress))
        exit 1
    }
}
