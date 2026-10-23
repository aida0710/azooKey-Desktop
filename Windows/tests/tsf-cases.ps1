# Types each case through the installed text service (tsf-harness) and checks
# the document text. Needs a desktop session (GitHub's Windows runners have one;
# an SSH session does not). Exit code is the number of failed cases.
#
#   pwsh Windows/tests/tsf-cases.ps1 -Harness build/windows-frontend/tsf-harness.exe -Screenshots build/screenshots
param(
    [Parameter(Mandatory)] [string]$Harness,
    [string]$Screenshots = '.'
)
$ErrorActionPreference = 'Stop'
$clsid = '{DC2488F5-F672-4910-9FEA-6D97306B86DA}'
$profileGuid = '{30051583-6CBB-49E0-AEAA-91AE64DCA550}'
# Expected texts are what the package converts to with Zenzai and its bundled
# model (typed through TSF in CI run 39773587468). Zenzai ranks ニホンゴ second
# for nihongo and keeps tesuto- in hiragana, where the dictionary alone gives
# にほんご and テストー.
$cases = @(
    @{ Name = 'convert and commit'; Keys = 'nihongo{SHOT:typing}{SPACE}{SHOT:converting}{ENTER}{SHOT:committed}'; Expected = '日本語' },
    @{ Name = 'commit live conversion with Enter'; Keys = 'nihongo{ENTER}'; Expected = '日本語' },
    @{ Name = 'F7 converts to katakana'; Keys = 'kanji{F7}'; Expected = 'カンジ' },
    @{ Name = 'Backspace edits the reading'; Keys = 'nihongo{BS}{ENTER}'; Expected = 'にほん' },
    @{ Name = 'number key chooses a candidate'; Keys = 'nihongo{SPACE}2'; Expected = 'ニホンゴ' },
    @{ Name = 'Down moves to the next candidate'; Keys = 'nihongo{SPACE}{DOWN}{SHOT:second-candidate}{ENTER}'; Expected = 'ニホンゴ' },
    # The panel grows from the tree to the list; its first frame at the new size must already show the list.
    @{ Name = 'the list replaces the tree in one frame'; Keys = 'nihongo{SPACE}{FIRSTFRAME:tree-to-list}{ENTER}'; Expected = '日本語' },
    @{ Name = 'punctuation in a sentence'; Keys = 'kyouha,iitennkidesune.{ENTER}'; Expected = '今日は、いい天気ですね。' },
    @{ Name = 'long vowel mark'; Keys = 'tesuto-{ENTER}'; Expected = 'てすとー' },
    @{ Name = 'Esc then typing again'; Keys = 'nihongo{ESC}kanji{ENTER}'; Expected = '感じ' },
    @{ Name = 'Hankaku/Zenkaku turns Japanese input off'; Keys = '{KANJI}abc'; Expected = 'abc' },
    @{ Name = 'Muhenkan leaves Japanese input'; Keys = '{NONCONVERT}abc'; Expected = 'abc' },
    @{ Name = 'Henkan turns Japanese input back on'; Keys = '{NONCONVERT}a{CONVERT}ka'; Expected = 'aか' },
    @{ Name = 'an application that draws candidates itself'; Keys = 'nihongo{SPACE}{DOWN}{ENTER}'; Expected = 'ニホンゴ'; UiLess = $true },
    # F10 shows the restored composition as its romaji, which only exists if the commit came back.
    @{ Name = 'Ctrl+Shift+Backspace undoes the commit'; Keys = 'nihongo{ENTER}{CTRL+SHIFT+BS}{SHOT:undo}{F10}'; Expected = 'nihongo' },
    # A selection comes back as its typed reading, which has no romaji; F6 shows that reading.
    @{ Name = 'Ctrl+Shift+R reconverts the selection after its reading'; Keys = 'nihongo{ENTER}{SHIFT+LEFT}{SHIFT+LEFT}{SHIFT+LEFT}{CTRL+SHIFT+R}{SHOT:reading}nihongo{ENTER}{SHOT:reconverted}{F6}'; Expected = 'にほんご' },
    @{ Name = 'Esc leaves the reading prompt'; Keys = 'nihongo{ENTER}{SHIFT+LEFT}{SHIFT+LEFT}{SHIFT+LEFT}{CTRL+SHIFT+R}ka{ESC}a'; Expected = 'あ' }
)
# The host warms the converter up when it starts (dictionary and Zenzai's model),
# as it does at sign-in before a user types. Start the cases after that, so they
# check typing rather than a cold start; the host integration test times the
# first key. A request with a long wait returns once the warm-up is done.
function Wait-HostReady([string]$hostExecutable, [int]$limitMilliseconds = 60000) {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $pipeName = "azooKeyTree-$sid"
    if (-not (Test-Path "\\.\pipe\$pipeName")) {
        Remove-Item $hostTrace -ErrorAction SilentlyContinue
        Start-Process -FilePath $hostExecutable -ArgumentList '--trace', "`"$hostTrace`"" -WindowStyle Hidden
    }
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect($limitMilliseconds)
    $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    $writer.WriteLine('{"operation":"ime-shortcuts"}')
    $writer.Flush()
    $reader = [System.IO.StreamReader]::new($pipe, [System.Text.UTF8Encoding]::new($false))
    $reply = $reader.ReadLineAsync()
    if (-not $reply.Wait($limitMilliseconds)) { throw 'the host did not answer after warming up' }
    $pipe.Dispose()
}
# The host started here records every converter request, so a case that a slow
# reply broke shows which request kept its key waiting.
New-Item -ItemType Directory -Force -Path $Screenshots | Out-Null
$hostTrace = Join-Path (Resolve-Path $Screenshots) 'host-trace.log'
Wait-HostReady (Join-Path $env:ProgramFiles 'azooKey Tree\azookey-windows-host.exe')

$failed = 0
foreach ($case in $cases) {
    $arguments = @('--clsid', $clsid, '--profile', $profileGuid, '--keys', $case.Keys, '--expect', $case.Expected, '--screenshots', $Screenshots)
    if ($case.UiLess) { $arguments += '--ui-less' }
    $output = & $Harness @arguments 2>&1 | Out-String
    $passed = $LASTEXITCODE -eq 0
    if (-not $passed) { $failed++ }
    $details = ($output -split "`n" | Where-Object { $_ -like 'TEXT=*' -or $_ -like 'UIELEMENT*' -or $_ -like 'FIRSTFRAME*' -or $_ -like 'FAIL*' }) -join ' | '
    '{0} {1}: {2}' -f ($(if ($passed) { 'PASS' } else { 'FAIL' })), $case.Name, $details.Trim()
}
"$($cases.Count - $failed)/$($cases.Count) cases passed"
# The text service waits 2 s for a reply; show the start of the trace (warm-up
# and the first case) and every request that took half of that or more.
$slowMilliseconds = 1000
if (Test-Path $hostTrace) {
    "host requests (waited for the converter / converted), first 40 and those of $slowMilliseconds ms or more:"
    $traceLines = @(Get-Content $hostTrace)
    for ($index = 0; $index -lt $traceLines.Count; $index++) {
        $slow = $traceLines[$index] -match 'waited=(\d+)ms converted=(\d+)ms' -and ([int]$Matches[1] + [int]$Matches[2]) -ge $slowMilliseconds
        if ($index -lt 40 -or $slow) { "  $($traceLines[$index])" }
    }
}
exit $failed
