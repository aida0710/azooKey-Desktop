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
# Expected texts come from the converter's dictionary-only results (no Zenzai),
# checked against the bridge directly before they were written here.
$cases = @(
    @{ Name = 'convert and commit'; Keys = 'nihongo{SHOT:typing}{SPACE}{SHOT:converting}{ENTER}{SHOT:committed}'; Expected = '日本語' },
    @{ Name = 'commit live conversion with Enter'; Keys = 'nihongo{ENTER}'; Expected = '日本語' },
    @{ Name = 'F7 converts to katakana'; Keys = 'kanji{F7}'; Expected = 'カンジ' },
    @{ Name = 'Backspace edits the reading'; Keys = 'nihongo{BS}{ENTER}'; Expected = 'にほん' },
    @{ Name = 'number key chooses a candidate'; Keys = 'nihongo{SPACE}2'; Expected = 'にほんご' },
    @{ Name = 'Down moves to the next candidate'; Keys = 'nihongo{SPACE}{DOWN}{SHOT:second-candidate}{ENTER}'; Expected = 'にほんご' },
    @{ Name = 'punctuation in a sentence'; Keys = 'kyouha,iitennkidesune.{ENTER}'; Expected = '今日は、いい天気ですね。' },
    @{ Name = 'long vowel mark'; Keys = 'tesuto-{ENTER}'; Expected = 'テストー' },
    @{ Name = 'Esc then typing again'; Keys = 'nihongo{ESC}kanji{ENTER}'; Expected = '感じ' },
    @{ Name = 'Hankaku/Zenkaku turns Japanese input off'; Keys = '{KANJI}abc'; Expected = 'abc' },
    @{ Name = 'Muhenkan leaves Japanese input'; Keys = '{NONCONVERT}abc'; Expected = 'abc' },
    @{ Name = 'Henkan turns Japanese input back on'; Keys = '{NONCONVERT}a{CONVERT}ka'; Expected = 'aか' },
    @{ Name = 'an application that draws candidates itself'; Keys = 'nihongo{SPACE}{DOWN}{ENTER}'; Expected = 'にほんご'; UiLess = $true }
)
$failed = 0
foreach ($case in $cases) {
    $arguments = @('--clsid', $clsid, '--profile', $profileGuid, '--keys', $case.Keys, '--expect', $case.Expected, '--screenshots', $Screenshots)
    if ($case.UiLess) { $arguments += '--ui-less' }
    $output = & $Harness @arguments 2>&1 | Out-String
    $passed = $LASTEXITCODE -eq 0
    if (-not $passed) { $failed++ }
    $details = ($output -split "`n" | Where-Object { $_ -like 'TEXT=*' -or $_ -like 'UIELEMENT*' -or $_ -like 'FAIL*' }) -join ' | '
    '{0} {1}: {2}' -f ($(if ($passed) { 'PASS' } else { 'FAIL' })), $case.Name, $details.Trim()
}
"$($cases.Count - $failed)/$($cases.Count) cases passed"
exit $failed
