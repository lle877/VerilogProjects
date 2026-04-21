param (
    [string]$Project = '',
    [string]$Hex,
    [string]$Tb = 'tb/tb_rv32.sv',
    [switch]$Clean,
    [switch]$NoWaveform
)

# Ensure sim directory exists
if (-not (Test-Path -Path 'sim')) {
    New-Item -ItemType Directory -Path 'sim' | Out-Null
}

# Clean if requested
if ($Clean) {
    Remove-Item 'sim\*' -Force -ErrorAction SilentlyContinue
}

# Compile the design - collect all RTL files and testbench
$rtlFiles = @(Get-ChildItem 'rtl\*.sv' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$allFiles = $rtlFiles + @($Tb)

# Build the iverilog command with proper escaping
$iverilogArgs = @('-g2012', '-o', 'sim\tb_rv32.vvp', '-I', 'rtl') + $allFiles

iverilog @iverilogArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Compilation error. Exiting with code 1.'
    exit 1
}

# Run the simulation with appropriate timeout
$runArgs = @('sim\tb_rv32.vvp')
if ($Hex) {
    $runArgs += "+hex=$Hex"
}

vvp @runArgs
$simExitCode = $LASTEXITCODE

# Check for no waveform requirement
if (-not $NoWaveform) {
    if ((Test-Path 'sim\tb_rv32.vcd') -and (Get-Command gtkwave -ErrorAction SilentlyContinue)) {
        Start-Process gtkwave 'sim\tb_rv32.vcd'
    }
}

# Exit with appropriate code
if ($simExitCode -eq 0) {
    Write-Host "Simulation PASSED"
    exit 0
} else {
    Write-Host "Simulation FAILED (exit code: $simExitCode)"
    exit 1
}