# ============================================================
# run_all_tests.ps1
# ------------------------------------------------------------
# 功能:
#   批量运行 rv32/tests 下所有 RV32I 指令单元测试（.hex），并输出 PASS/FAIL 报表。
#
# 运行方式（在 rv32/ 目录下）:
#   pwsh -File run_all_tests.ps1
#   # 或 Windows PowerShell:
#   .\run_all_tests.ps1
#
# 依赖:
#   - iverilog + vvp（Icarus Verilog），并且已加入 PATH。
#
# 测试链路（核心理解点）:
#   1) 先用 iverilog 只编译一次 testbench，生成 sim\tb_rv32.vvp。
#   2) 遍历 tests\*.hex，每个用例用 vvp 运行一次：
#        vvp sim\tb_rv32.vvp "+hex=...\xxx.hex"
#   3) TB 内部通过 $value$plusargs("hex=%s", hex_path) 拿到路径，
#      再用 $readmemh(hex_path, rom) 加载 ROM。
#   4) TB 最终会打印一行 [TB] PASS/FAIL/TIMEOUT，本脚本取最后一条 [TB] 行做判定。
# ============================================================

$ErrorActionPreference = "Stop"

# 将工作目录切到脚本所在目录，避免从别处调用时相对路径失效
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$SimDir   = "sim"
$VvpFile  = "$SimDir\tb_rv32.vvp"
$TestsDir = "tests"

if (!(Test-Path $SimDir)) { New-Item -ItemType Directory -Path $SimDir | Out-Null }

Write-Host "=============================================="
Write-Host " RV32I Core Regression Suite"
Write-Host "=============================================="
Write-Host ""

# ---- Generate tests ----
Write-Host "[INFO] Regenerating instruction and hazard test hex files..."
if (Get-Command py -ErrorAction SilentlyContinue) {
    & py -3 gen_tests.py
} else {
    & python gen_tests.py
}
if ($LASTEXITCODE -ne 0) {
    Write-Error "[ERROR] Test generation failed – aborting."
    exit 1
}
Write-Host "[INFO] Test generation OK"
Write-Host ""

# ---- Compile ----
Write-Host "[INFO] Compiling testbench..."

# -g2012: 允许 SystemVerilog 语法（本工程使用 .sv/.svh）
# -I rtl : 让 `include "rv32_pkg.svh"` 能找到头文件
# 这里把 rtl 下所有 .sv 都喂给 iverilog，再加上 tb\tb_rv32.sv
$ivArgs = @("-g2012", "-o", $VvpFile, "-I", "rtl") +
          (Get-ChildItem rtl\*.sv | ForEach-Object { $_.FullName }) +
          @("tb\tb_rv32.sv")
if (Test-Path $VvpFile) { Remove-Item $VvpFile -Force }
& iverilog @ivArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "[ERROR] Compilation failed – aborting."
    exit 1
}
Write-Host "[INFO] Compilation OK"
Write-Host ""

# ---- Run tests ----
$pass    = 0
$fail    = 0
$timeout = 0
$failList = @()

Get-ChildItem "$TestsDir\*.hex" | Sort-Object Name | ForEach-Object {
    $name    = $_.BaseName
    $hexFile = $_.FullName

    # 运行单个用例：将 hex 路径以 plusarg 的形式传入 TB
    # TB 会打印多行 [TB] ...，这里取最后一条 [TB] 行作为最终状态。
    $output  = & vvp $VvpFile "+hex=$hexFile" 2>$null
    $tbLine  = ($output | Select-String '\[TB\]' | Select-Object -Last 1).Line

    if ($tbLine -match "PASS") {
        Write-Host ("  {0,-12}  PASS" -f $name)
        $pass++
    } elseif ($tbLine -match "FAIL") {
        Write-Host ("  {0,-12}  FAIL  ({1})" -f $name, $tbLine)
        $fail++
        $failList += $name
    } else {
        Write-Host ("  {0,-12}  TIMEOUT" -f $name)
        $timeout++
        $failList += "$name(timeout)"
    }
}

$total = $pass + $fail + $timeout

Write-Host ""
Write-Host "=============================================="
Write-Host " Results: $pass/$total PASS"
if ($failList.Count -gt 0) {
    Write-Host (" Failed:  " + ($failList -join ", "))
}
Write-Host "=============================================="

if (($fail + $timeout) -gt 0) { exit 1 } else { exit 0 }
