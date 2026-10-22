# Runs the packaged bridge with and without Zenzai's model and reports, for each,
# the response time of every key, the bridge's memory and the first candidate
# that Space shows for each reading. docs/windows.md quotes its numbers.
#
#   pwsh Windows\tools\measure-zenzai.ps1 [-Package <dir>] [-Readings <romaji>, ...]
#
# Each run starts the bridge with an empty data folder, so learning from an
# earlier run cannot change the candidates.
param(
    [string]$Package = (Join-Path $PSScriptRoot '..\..\build\windows-package'),
    [string[]]$Readings = @('kyouhaisyaniiku', 'hasinohasiwowataru', 'kisyanokisyagakisyadekisyasita', 'kaigiwokaisaisuru', 'sonokeikakuhamudaninatta')
)
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $Package 'bridge\azookey-desktop-bridge.exe'
$models = Join-Path $Package 'models'
# Core's key codes (macOS kVK_*): letters go by their characters alone.
$characterKeyCode = 65535
$spaceKeyCode = 49

function Start-Bridge([string]$resources) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($bridge)
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.UseShellExecute = $false
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.Environment['AZOOKEY_DATA_DIR'] = Join-Path ([System.IO.Path]::GetTempPath()) "azookey-measure-$([guid]::NewGuid())"
    $info.Environment.Remove('AZOOKEY_RESOURCES') | Out-Null
    if ($resources) { $info.Environment['AZOOKEY_RESOURCES'] = $resources }
    $process = [System.Diagnostics.Process]::Start($info)
    $writer = [System.IO.StreamWriter]::new($process.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    return [pscustomobject]@{ Process = $process; Writer = $writer; DataDirectory = $info.Environment['AZOOKEY_DATA_DIR'] }
}

function Send-Request($bridgeProcess, [string]$line) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $bridgeProcess.Writer.WriteLine($line)
    $bridgeProcess.Writer.Flush()
    $reply = $bridgeProcess.Process.StandardOutput.ReadLine()
    $stopwatch.Stop()
    if ($null -eq $reply) { throw 'the bridge exited' }
    return [pscustomobject]@{ Milliseconds = $stopwatch.Elapsed.TotalMilliseconds; Snapshot = ($reply | ConvertFrom-Json) }
}

function Get-KeyRequest([string]$characters, [int]$keyCode) {
    $quoted = $characters | ConvertTo-Json
    return '{"operation":"key","context":"measure","event":{"keyCode":' + $keyCode + ',"characters":' + $quoted +
        ',"charactersIgnoringModifiers":' + $quoted + ',"modifierFlags":0}}'
}

function Get-Percentile([double[]]$values, [double]$fraction) {
    $sorted = $values | Sort-Object
    return $sorted[[math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * $fraction))]
}

function Measure-Mode([string]$name, [string]$resources) {
    $bridgeProcess = Start-Bridge $resources
    $keyTimes = [System.Collections.Generic.List[double]]::new()
    $spaceTimes = [System.Collections.Generic.List[double]]::new()
    $firstKeyMilliseconds = $null
    $conversions = foreach ($reading in $Readings) {
        foreach ($character in $reading.ToCharArray()) {
            $reply = Send-Request $bridgeProcess (Get-KeyRequest ([string]$character) $characterKeyCode)
            # The first key also loads the dictionary (and the first
            # conversion Zenzai's model); it is reported on its own.
            if ($null -eq $firstKeyMilliseconds) { $firstKeyMilliseconds = $reply.Milliseconds } else { $keyTimes.Add($reply.Milliseconds) }
        }
        $space = Send-Request $bridgeProcess (Get-KeyRequest ' ' $spaceKeyCode)
        $spaceTimes.Add($space.Milliseconds)
        Send-Request $bridgeProcess '{"operation":"reset","context":"measure","submit":false}' | Out-Null
        [pscustomobject]@{ Mode = $name; Reading = $reading; First = $space.Snapshot.candidates[0].text; ZenzaiLoaded = $space.Snapshot.zenzaiLoaded }
    }
    $bridgeProcess.Process.Refresh()
    $summary = [pscustomobject]@{
        Mode = $name
        FirstKeyMs = [math]::Round($firstKeyMilliseconds, 1)
        KeyMedianMs = [math]::Round((Get-Percentile $keyTimes 0.5), 1)
        KeyP95Ms = [math]::Round((Get-Percentile $keyTimes 0.95), 1)
        KeyMaxMs = [math]::Round(($keyTimes | Measure-Object -Maximum).Maximum, 1)
        SpaceMedianMs = [math]::Round((Get-Percentile $spaceTimes 0.5), 1)
        Keys = $keyTimes.Count
        WorkingSetMiB = [math]::Round($bridgeProcess.Process.WorkingSet64 / 1MB, 1)
        PeakWorkingSetMiB = [math]::Round($bridgeProcess.Process.PeakWorkingSet64 / 1MB, 1)
        PrivateMiB = [math]::Round($bridgeProcess.Process.PrivateMemorySize64 / 1MB, 1)
    }
    $bridgeProcess.Writer.Close()
    $bridgeProcess.Process.WaitForExit(5000) | Out-Null
    Remove-Item -Recurse -Force $bridgeProcess.DataDirectory -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Summary = $summary; Conversions = $conversions }
}

$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
Write-Output "CPU: $cpu, logical processors: $([Environment]::ProcessorCount)"
$results = @((Measure-Mode 'dictionary' $null), (Measure-Mode 'zenzai' $models))
$results.Summary | Format-Table -AutoSize | Out-String -Width 200
$results.Conversions | Format-Table -AutoSize | Out-String -Width 200
