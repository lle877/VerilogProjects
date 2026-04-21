#!/usr/bin/env bash
# ============================================================
# run_all_tests.sh
# ------------------------------------------------------------
# 功能:
#   批量运行 rv32/tests 下所有 RV32I 指令单元测试（.hex），并输出 PASS/FAIL 报表。
#
# 运行方式:
#   cd rv32/
#   bash run_all_tests.sh
#
# 依赖:
#   - iverilog + vvp（Icarus Verilog），并且已加入 PATH。
#
# 测试链路（核心理解点）:
#   1) 先用 iverilog 只编译一次 testbench，生成 sim/tb_rv32.vvp。
#   2) 遍历 tests/*.hex，每个用例用 vvp 运行一次：
#        vvp sim/tb_rv32.vvp "+hex=tests/xxx.hex"
#   3) TB 内部通过 $value$plusargs("hex=%s", hex_path) 拿到路径，
#      再用 $readmemh(hex_path, rom) 加载 ROM。
#   4) TB 最终会打印一行 [TB] PASS/FAIL/TIMEOUT，本脚本取最后一条 [TB] 行做判定。
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIM_DIR="sim"
VVP="$SIM_DIR/tb_rv32.vvp"
TESTS_DIR="tests"

mkdir -p "$SIM_DIR"

echo "=============================================="
echo " RV32I Core Regression Suite"
echo "=============================================="
echo ""

# ---- Generate tests ----
echo "[INFO] Regenerating instruction and hazard test hex files..."
python3 gen_tests.py
echo "[INFO] Test generation OK"
echo ""

# ---- Compile ----
echo "[INFO] Compiling testbench..."

# -g2012: 允许 SystemVerilog 语法（本工程使用 .sv/.svh）
# -I rtl : 让 `include "rv32_pkg.svh"` 能找到头文件
rm -f "$VVP"
if ! iverilog -g2012 -o "$VVP" -I rtl rtl/*.sv tb/tb_rv32.sv; then
    echo "[ERROR] Compilation failed – aborting."
    exit 1
fi
echo "[INFO] Compilation OK"
echo ""

# ---- Run tests ----
PASS=0
FAIL=0
TIMEOUT=0
FAIL_LIST=()

for hex_file in "$TESTS_DIR"/*.hex; do
    name=$(basename "$hex_file" .hex)

    # 运行单个用例：将 hex 路径以 plusarg 的形式传入 TB
    # TB 会打印多行 [TB] ...，这里取最后一条 [TB] 行作为最终状态。
    output=$(vvp "$VVP" "+hex=$hex_file" 2>/dev/null)
    tb_line=$(echo "$output" | grep '\[TB\]' | tail -1)

    if echo "$tb_line" | grep -q "PASS"; then
        printf "  %-12s  PASS\n" "$name"
        PASS=$((PASS + 1))
    elif echo "$tb_line" | grep -q "FAIL"; then
        printf "  %-12s  FAIL  (%s)\n" "$name" "$tb_line"
        FAIL=$((FAIL + 1))
        FAIL_LIST+=("$name")
    else
        printf "  %-12s  TIMEOUT\n" "$name"
        TIMEOUT=$((TIMEOUT + 1))
        FAIL_LIST+=("$name(timeout)")
    fi
done

TOTAL=$((PASS + FAIL + TIMEOUT))

echo ""
echo "=============================================="
echo " Results: $PASS/$TOTAL PASS"
if [ ${#FAIL_LIST[@]} -gt 0 ]; then
    echo " Failed:  ${FAIL_LIST[*]}"
fi
echo "=============================================="

# Exit non-zero if any test failed
[ $((FAIL + TIMEOUT)) -eq 0 ]
