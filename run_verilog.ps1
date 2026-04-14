param (
    [string]$Project    = 'rv32',
    [string]$Hex        = '',
    [string]$Tb         = 'tb/tb_rv32_wave.sv',
    [switch]$Clean,
    [switch]$NoWaveform
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Join-Path $RepoRoot $Project)

if ($Clean -and (Test-Path 'sim')) { Remove-Item 'sim\*' -Force -Recurse -ErrorAction SilentlyContinue }
if (!(Test-Path 'sim')) { New-Item -ItemType Directory -Path 'sim' | Out-Null }

$vvp = 'sim\tb_rv32.vvp'

Write-Host "[INFO] Compiling $Tb ..."
$svFiles = Get-ChildItem 'rtl\*.sv' | ForEach-Object { $_.FullName }
$args = @('-g2012','-o',$vvp,'-I','rtl') + $svFiles + @($Tb)
& iverilog @args
if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] Compilation error"; exit 1 }
Write-Host "[OK]   Compilation succeeded"

$runArgs = @($vvp)
if ($Hex -and (Test-Path $Hex)) { $runArgs += "+hex=$((Resolve-Path $Hex).Path)" }

Write-Host "[INFO] Running simulation..."
$output = & vvp @runArgs 2>&1
Write-Host $output

$tbLine = ($output | Select-String '\[TB\]' | Select-Object -Last 1).Line
if ($tbLine -match 'PASS') {
    Write-Host "[OK]   PASS"; $code = 0
} elseif ($tbLine -match 'FAIL') {
    Write-Host "[FAIL] FAIL: $tbLine"; $code = 1
} else {
    Write-Host "[FAIL] TIMEOUT/UNKNOWN"; $code = 1
}

if (!$NoWaveform -and (Test-Path 'sim\tb_rv32_wave.vcd')) {
    $gw = Get-Command gtkwave -ErrorAction SilentlyContinue
    if ($gw) { Start-Process gtkwave 'sim\tb_rv32_wave.vcd' }
    else { Write-Host "[INFO] VCD: sim\tb_rv32_wave.vcd (open with GTKWave or Vivado)" }
}

exit $code
