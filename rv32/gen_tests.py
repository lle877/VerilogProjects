#!/usr/bin/env python3
"""生成 RV32I 37 条指令的单元测试 hex 文件（教学脚本）。

输出位置:
    - 默认写入本文件同级目录下的 tests/*.hex

与 TB 的约定（非常重要）:
    - 这些测试程序会在末尾通过 store 向数据 RAM 写入“结果标志”：
        - 写 ram[1] = 1          表示 PASS
        - 写 ram[1] = 0xDEAD_BEEF 表示 FAIL
    - testbench 会在每个周期监视 ram[1]，一旦看到 PASS/FAIL 就结束仿真。

脚本结构概览:
    1) 指令编码器：r_type/i_type/s_type/b_type/u_type/j_type
    2) 常用指令包装：ADDI/LW/SW/BEQ/...（便于写测试用例）
    3) PASS/FAIL 序列：pass_seq()/fail_seq()
    4) 标准模板：alu_test() / branch_test() 快速拼装测试程序
    5) 为每条指令生成一个 tests/xxx.hex
"""

import os

# ---------- 指令编码器（拼 32 位指令字） ----------
# 说明：这些函数只负责把字段按 RISC-V 手册的 bit 位置打包成 32bit 指令。
#       立即数传入时会被 mask 到对应宽度（例如 I/S 的 imm12）。

def r_type(funct7, rs2, rs1, funct3, rd, opcode):
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)

def i_type(imm, rs1, funct3, rd, opcode):
    imm12 = imm & 0xFFF
    return (imm12 << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)

def s_type(imm, rs2, rs1, funct3, opcode):
    imm12 = imm & 0xFFF
    return (((imm12 >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((imm12 & 0x1F) << 7) | (opcode & 0x7F)

def b_type(imm, rs2, rs1, funct3, opcode):
    # B-type 偏移是 13bit，且 bit0 永远为 0（2 字节对齐），这里先把 imm 做对齐 mask。
    imm_val = imm & 0x1FFE  # 13-bit, bit0 always 0 (mask to keep even)
    imm12   = (imm_val >> 12) & 1
    imm10_5 = (imm_val >> 5)  & 0x3F
    imm4_1  = (imm_val >> 1)  & 0xF
    imm11   = (imm_val >> 11) & 1
    return (imm12 << 31) | (imm10_5 << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           (imm4_1 << 8) | (imm11 << 7) | (opcode & 0x7F)

def u_type(imm20, rd, opcode):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

def j_type(imm, rd, opcode):
    # J-type 偏移是 21bit，且 bit0 永远为 0（2 字节对齐）
    imm_val  = imm & 0x1FFFFE  # 21-bit, bit0 always 0
    imm20    = (imm_val >> 20) & 1
    imm10_1  = (imm_val >> 1)  & 0x3FF
    imm11    = (imm_val >> 11) & 1
    imm19_12 = (imm_val >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | \
           (imm19_12 << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)

# ---------- 主 opcode 常量（instr[6:0]） ----------
OPC_LUI    = 0b0110111
OPC_AUIPC  = 0b0010111
OPC_JAL    = 0b1101111
OPC_JALR   = 0b1100111
OPC_BRANCH = 0b1100011
OPC_LOAD   = 0b0000011
OPC_STORE  = 0b0100011
OPC_OPIMM  = 0b0010011
OPC_OP     = 0b0110011

# ---------- 常用指令包装（便于写测试用例） ----------
# 说明：下面这些函数返回 32bit 指令字（Python int），最终会被写入 .hex。
def NOP():                       return i_type(0, 0, 0, 0, OPC_OPIMM)  # addi x0,x0,0
def ADDI(rd, rs1, imm):          return i_type(imm, rs1, 0b000, rd, OPC_OPIMM)
def LUI_I(rd, imm20):            return u_type(imm20, rd, OPC_LUI)
def AUIPC_I(rd, imm20):          return u_type(imm20, rd, OPC_AUIPC)
def JAL_I(rd, offset):           return j_type(offset, rd, OPC_JAL)
def JAL_HALT():                  return j_type(0, 0, OPC_JAL)  # jal x0,0 -> infinite loop
def JALR_I(rd, rs1, imm):        return i_type(imm, rs1, 0b000, rd, OPC_JALR)
def BEQ(rs1, rs2, offset):       return b_type(offset, rs2, rs1, 0b000, OPC_BRANCH)
def BNE(rs1, rs2, offset):       return b_type(offset, rs2, rs1, 0b001, OPC_BRANCH)
def BLT(rs1, rs2, offset):       return b_type(offset, rs2, rs1, 0b100, OPC_BRANCH)
def BGE(rs1, rs2, offset):       return b_type(offset, rs2, rs1, 0b101, OPC_BRANCH)
def BLTU(rs1, rs2, offset):      return b_type(offset, rs2, rs1, 0b110, OPC_BRANCH)
def BGEU(rs1, rs2, offset):      return b_type(offset, rs2, rs1, 0b111, OPC_BRANCH)
def LB(rd, rs1, imm):            return i_type(imm, rs1, 0b000, rd, OPC_LOAD)
def LH(rd, rs1, imm):            return i_type(imm, rs1, 0b001, rd, OPC_LOAD)
def LW(rd, rs1, imm):            return i_type(imm, rs1, 0b010, rd, OPC_LOAD)
def LBU(rd, rs1, imm):           return i_type(imm, rs1, 0b100, rd, OPC_LOAD)
def LHU(rd, rs1, imm):           return i_type(imm, rs1, 0b101, rd, OPC_LOAD)
def SB(rs2, rs1, imm):           return s_type(imm, rs2, rs1, 0b000, OPC_STORE)
def SH(rs2, rs1, imm):           return s_type(imm, rs2, rs1, 0b001, OPC_STORE)
def SW(rs2, rs1, imm):           return s_type(imm, rs2, rs1, 0b010, OPC_STORE)
def SLTI(rd, rs1, imm):          return i_type(imm, rs1, 0b010, rd, OPC_OPIMM)
def SLTIU(rd, rs1, imm):         return i_type(imm, rs1, 0b011, rd, OPC_OPIMM)
def XORI(rd, rs1, imm):          return i_type(imm, rs1, 0b100, rd, OPC_OPIMM)
def ORI(rd, rs1, imm):           return i_type(imm, rs1, 0b110, rd, OPC_OPIMM)
def ANDI(rd, rs1, imm):          return i_type(imm, rs1, 0b111, rd, OPC_OPIMM)
def SLLI(rd, rs1, shamt):        return i_type(shamt & 0x1F, rs1, 0b001, rd, OPC_OPIMM)
def SRLI(rd, rs1, shamt):        return i_type(shamt & 0x1F, rs1, 0b101, rd, OPC_OPIMM)
def SRAI(rd, rs1, shamt):        return i_type(0x400 | (shamt & 0x1F), rs1, 0b101, rd, OPC_OPIMM)
def ADD(rd, rs1, rs2):           return r_type(0b0000000, rs2, rs1, 0b000, rd, OPC_OP)
def SUB(rd, rs1, rs2):           return r_type(0b0100000, rs2, rs1, 0b000, rd, OPC_OP)
def SLL(rd, rs1, rs2):           return r_type(0b0000000, rs2, rs1, 0b001, rd, OPC_OP)
def SLT(rd, rs1, rs2):           return r_type(0b0000000, rs2, rs1, 0b010, rd, OPC_OP)
def SLTU_R(rd, rs1, rs2):        return r_type(0b0000000, rs2, rs1, 0b011, rd, OPC_OP)
def XOR(rd, rs1, rs2):           return r_type(0b0000000, rs2, rs1, 0b100, rd, OPC_OP)
def SRL(rd, rs1, rs2):           return r_type(0b0000000, rs2, rs1, 0b101, rd, OPC_OP)
def SRA(rd, rs1, rs2):           return r_type(0b0100000, rs2, rs1, 0b101, rd, OPC_OP)
def OR(rd, rs1, rs2):            return r_type(0b0000000, rs2, rs1, 0b110, rd, OPC_OP)
def AND_R(rd, rs1, rs2):         return r_type(0b0000000, rs2, rs1, 0b111, rd, OPC_OP)

# ---------- 五级流水线辅助 ----------
# 当前 core 是 5-stage pipeline，且“不处理冒险”。
# 因此测试程序里需要同时处理两类软件插槽：
#   1) 数据相关：在“写寄存器 -> 下一条读该寄存器”之间插入 NOP
#   2) 控制相关：在可能改变 PC 的分支/跳转之后插入 NOP
PIPELINE_GAP = 3
CONTROL_GAP = 2

def gap(n=PIPELINE_GAP):
    """Return n pipeline-bubble NOPs."""
    return [NOP()] * n

def ctrl_gap(n=CONTROL_GAP):
    """Return n control-delay NOPs."""
    return [NOP()] * n

def pad_linear(instrs, after_last=True):
    """Insert PIPELINE_GAP NOPs after each instruction in a linear sequence."""
    out = []
    for idx, instr in enumerate(instrs):
        out.append(instr)
        if after_last or idx != len(instrs) - 1:
            out.extend(gap())
    return out

# ---------- PASS/FAIL 序列（与 TB 约定） ----------
# PASS: 向 ram[1]（地址 4）写入 1，然后进入死循环（JAL x0,0）
# FAIL: 向 ram[1]（地址 4）写入 0xDEAD_BEEF，然后进入死循环
#
# 注意：很多用例会用到 0xDEAD_BEEF 常量。
# 这里用两条指令构造它：
#   0xDEAD_BEEF = (LUI 0xDEADC -> 0xDEADC000) + (ADDI 0xEEF -> -273)
# 即 0xDEADC000 + (-273) = 0xDEADBEEF

def pass_seq(rd=5):
    """Pipeline-safe PASS sequence."""
    return [
        ADDI(rd, 0, 1),      # rd = 1
        *gap(),              # wait for rd to reach WB before SW reads it
        SW(rd, 0, 4),        # sw rd, 4(x0) -> ram[1] = 1 (PASS)
        JAL_HALT(),          # infinite loop
    ]

def fail_seq(rd=5):
    """Pipeline-safe FAIL sequence."""
    return [
        LUI_I(rd, 0xDEADC),  # rd = 0xDEADC000
        *gap(),              # wait before dependent ADDI reads rd
        ADDI(rd, rd, 0xEEF), # rd = 0xDEADC000 + (-273) = 0xDEADBEEF
        *gap(),              # wait before SW reads rd
        SW(rd, 0, 4),        # ram[1] = DEADBEEF (FAIL)
        JAL_HALT(),          # infinite loop
    ]

def write_hex(path, instrs):
    """Write list of 32-bit instruction words as hex file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        for instr in instrs:
            f.write(f'{instr:08x}\n')

def checked_addi_imm(value, what):
    """Ensure a constant fits in ADDI's signed 12-bit immediate."""
    if not -2048 <= value <= 2047:
        raise ValueError(f"{what} out of ADDI range: {value}")
    return value

def select_by_bne(result_reg, expected_reg, success_seq, fail_seq_):
    """Branch to fail-path on mismatch, with explicit control delay slots."""
    success = list(success_seq)
    fail = list(fail_seq_)
    bne_to_fail = 4 * (1 + CONTROL_GAP + len(success))
    return [BNE(result_reg, expected_reg, bne_to_fail), *ctrl_gap()] + success + fail

def alu_test(setup_instrs, result_reg, expected_reg, success_seq=None, fail_seq_=None):
    """Build a pipeline-safe ALU-style test program."""
    success = pass_seq() if success_seq is None else list(success_seq)
    fail = fail_seq() if fail_seq_ is None else list(fail_seq_)
    setup = pad_linear(setup_instrs, after_last=True)
    return setup + select_by_bne(result_reg, expected_reg, success, fail)

def branch_test(setup1, setup2, branch_instr_fn, success_seq=None, fail_seq_=None):
    """Build a taken-branch test with explicit control delay slots."""
    success = pass_seq() if success_seq is None else list(success_seq)
    fail = fail_seq() if fail_seq_ is None else list(fail_seq_)
    branch_pass_offset = 4 * (1 + CONTROL_GAP + len(fail))
    return pad_linear([setup1, setup2], after_last=True) + [
        branch_instr_fn(branch_pass_offset),
        *ctrl_gap(),
    ] + fail + success

def jal_test(base_pc=0, success_seq=None, fail_seq_=None):
    """Build a JAL test. base_pc is needed when this block is placed later in ROM."""
    success = pass_seq() if success_seq is None else list(success_seq)
    fail_fallthrough = fail_seq() if fail_seq_ is None else list(fail_seq_)
    fail_check = fail_seq() if fail_seq_ is None else list(fail_seq_)
    expected_ra = checked_addi_imm(base_pc + 4, "jal return pc")
    jal_check = pad_linear([ADDI(2, 0, expected_ra)], after_last=True) + \
        select_by_bne(1, 2, success, fail_check)
    jump_offset = 4 * (1 + CONTROL_GAP + len(fail_fallthrough))
    return [
        JAL_I(1, jump_offset),
        *ctrl_gap(),
    ] + fail_fallthrough + jal_check

def jalr_test(base_pc=0, success_seq=None, fail_seq_=None):
    """Build a JALR test. base_pc is needed for absolute target/return addresses."""
    success = pass_seq() if success_seq is None else list(success_seq)
    fail_fallthrough = fail_seq() if fail_seq_ is None else list(fail_seq_)
    fail_check = fail_seq() if fail_seq_ is None else list(fail_seq_)

    jalr_return_idx = 1 + PIPELINE_GAP + 1
    jalr_prefix_len = jalr_return_idx + CONTROL_GAP
    jalr_target_pc = checked_addi_imm(4 * (jalr_prefix_len + len(fail_fallthrough)) + base_pc,
                                      "jalr target pc")
    jalr_return_pc = checked_addi_imm(4 * jalr_return_idx + base_pc,
                                      "jalr return pc")

    jalr_check = pad_linear([ADDI(3, 0, jalr_return_pc)], after_last=True) + \
        select_by_bne(2, 3, success, fail_check)

    return [
        ADDI(1, 0, jalr_target_pc),
        *gap(),
        JALR_I(2, 1, 0),
        *ctrl_gap(),
    ] + fail_fallthrough + jalr_check

def progress_seq(test_id, rd=29):
    """Write current test id to ram[1] and continue."""
    return [
        ADDI(rd, 0, test_id),
        *gap(),
        SW(rd, 0, 4),
    ]

def wave_done_seq(rd=28):
    """Write final PASS flag to ram[2] and halt."""
    return [
        ADDI(rd, 0, 1),
        *gap(),
        SW(rd, 0, 8),
        JAL_HALT(),
    ]

def write_wave_rom_init(path, instrs):
    """Emit a Verilog include file containing rom[...] assignments."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('// Auto-generated by gen_tests.py. Do not edit manually.\n')
        f.write(f'// Total words: {len(instrs)}\n')
        for idx, instr in enumerate(instrs):
            f.write(f'    rom[{idx:4d}] = 32\'h{instr:08x};\n')

def static_alu_case(setup_instrs, result_reg, expected_reg):
    return lambda base_pc, success_seq, fail_seq_: \
        alu_test(setup_instrs, result_reg, expected_reg, success_seq, fail_seq_)

def static_branch_case(setup1, setup2, branch_instr_fn):
    return lambda base_pc, success_seq, fail_seq_: \
        branch_test(setup1, setup2, branch_instr_fn, success_seq, fail_seq_)

TEST_CASES = []

def register_case(name, builder):
    TEST_CASES.append((name, builder))

# =============================================
# 注册测试程序（每个指令 1 个 .hex）
# builder(base_pc, success_seq, fail_seq_) -> 指令列表
# =============================================
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tests')
WAVE_ROM_INCLUDE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tb',
                                'tb_rv32_wave_rom_init.vh')

# ---- 1. LUI ----
register_case('lui', static_alu_case(
    [LUI_I(1, 0x12345),
     LUI_I(2, 0x12345)],
    result_reg=1, expected_reg=2
))

# ---- 2. AUIPC ----
register_case('auipc', lambda base_pc, success_seq, fail_seq_: alu_test(
    [AUIPC_I(1, 1),
     LUI_I(2, 1)] + ([] if base_pc == 0 else [ADDI(2, 2, checked_addi_imm(base_pc, 'auipc base pc'))]),
    result_reg=1,
    expected_reg=2,
    success_seq=success_seq,
    fail_seq_=fail_seq_
))

# ---- 3. JAL ----
register_case('jal', lambda base_pc, success_seq, fail_seq_: jal_test(base_pc, success_seq, fail_seq_))

# ---- 4. JALR ----
register_case('jalr', lambda base_pc, success_seq, fail_seq_: jalr_test(base_pc, success_seq, fail_seq_))

# ---- 5. BEQ ----
register_case('beq', static_branch_case(
    ADDI(1, 0, 7),
    ADDI(2, 0, 7),
    lambda off: BEQ(1, 2, off)
))

# ---- 6. BNE ----
register_case('bne', static_branch_case(
    ADDI(1, 0, 3),
    ADDI(2, 0, 5),
    lambda off: BNE(1, 2, off)
))

# ---- 7. BLT ----
register_case('blt', static_branch_case(
    ADDI(1, 0, 0xFFF),
    ADDI(2, 0, 1),
    lambda off: BLT(1, 2, off)
))

# ---- 8. BGE ----
register_case('bge', static_branch_case(
    ADDI(1, 0, 5),
    ADDI(2, 0, 0xFFF),
    lambda off: BGE(1, 2, off)
))

# ---- 9. BLTU ----
register_case('bltu', static_branch_case(
    ADDI(1, 0, 1),
    ADDI(2, 0, 0xFFF),
    lambda off: BLTU(1, 2, off)
))

# ---- 10. BGEU ----
register_case('bgeu', static_branch_case(
    ADDI(1, 0, 0xFFF),
    ADDI(2, 0, 1),
    lambda off: BGEU(1, 2, off)
))

# ---- 11. LB ----
register_case('lb', static_alu_case(
    [ADDI(1, 0, 0xFFF),
     SB(1, 0, 8),
     LB(3, 0, 8),
     ADDI(4, 0, 0xFFF)],
    result_reg=3, expected_reg=4
))

# ---- 12. LH ----
register_case('lh', static_alu_case(
    [ADDI(1, 0, 0xFFF),
     SH(1, 0, 8),
     LH(3, 0, 8),
     ADDI(4, 0, 0xFFF)],
    result_reg=3, expected_reg=4
))

# ---- 13. LW ----
register_case('lw', static_alu_case(
    [ADDI(1, 0, 42),
     SW(1, 0, 8),
     LW(3, 0, 8),
     ADDI(4, 0, 42)],
    result_reg=3, expected_reg=4
))

# ---- 14. LBU ----
register_case('lbu', static_alu_case(
    [ADDI(1, 0, 0xFFF),
     SB(1, 0, 8),
     LBU(3, 0, 8),
     ADDI(4, 0, 255)],
    result_reg=3, expected_reg=4
))

# ---- 15. LHU ----
register_case('lhu', static_alu_case(
    [ADDI(1, 0, 0x7FF),
     SH(1, 0, 8),
     LHU(3, 0, 8),
     ADDI(4, 0, 0x7FF)],
    result_reg=3, expected_reg=4
))

# ---- 16. SB ----
register_case('sb', static_alu_case(
    [ADDI(1, 0, 171),
     SB(1, 0, 8),
     LBU(3, 0, 8),
     ADDI(4, 0, 171)],
    result_reg=3, expected_reg=4
))

# ---- 17. SH ----
register_case('sh', static_alu_case(
    [ADDI(1, 0, 1234),
     SH(1, 0, 8),
     LHU(3, 0, 8),
     ADDI(4, 0, 1234)],
    result_reg=3, expected_reg=4
))

# ---- 18. SW ----
register_case('sw', static_alu_case(
    [ADDI(1, 0, 2047),
     SW(1, 0, 8),
     LW(3, 0, 8),
     ADDI(4, 0, 2047)],
    result_reg=3, expected_reg=4
))

# ---- 19. ADDI ----
register_case('addi', static_alu_case(
    [ADDI(1, 0, 5),
     ADDI(3, 1, 3),
     ADDI(4, 0, 8)],
    result_reg=3, expected_reg=4
))

# ---- 20. SLTI ----
register_case('slti', static_alu_case(
    [ADDI(1, 0, 0xFFF),
     SLTI(3, 1, 0),
     ADDI(4, 0, 1)],
    result_reg=3, expected_reg=4
))

# ---- 21. SLTIU ----
register_case('sltiu', static_alu_case(
    [ADDI(1, 0, 0),
     SLTIU(3, 1, 0xFFF),
     ADDI(4, 0, 1)],
    result_reg=3, expected_reg=4
))

# ---- 22. XORI ----
register_case('xori', static_alu_case(
    [ADDI(1, 0, 0xAA),
     XORI(3, 1, 0xFF),
     ADDI(4, 0, 0x55)],
    result_reg=3, expected_reg=4
))

# ---- 23. ORI ----
register_case('ori', static_alu_case(
    [ADDI(1, 0, 0x0F),
     ORI(3, 1, 0xF0),
     ADDI(4, 0, 255)],
    result_reg=3, expected_reg=4
))

# ---- 24. ANDI ----
register_case('andi', static_alu_case(
    [ADDI(1, 0, 255),
     ANDI(3, 1, 0xF0),
     ADDI(4, 0, 240)],
    result_reg=3, expected_reg=4
))

# ---- 25. SLLI ----
register_case('slli', static_alu_case(
    [ADDI(1, 0, 5),
     SLLI(3, 1, 3),
     ADDI(4, 0, 40)],
    result_reg=3, expected_reg=4
))

# ---- 26. SRLI ----
register_case('srli', static_alu_case(
    [ADDI(1, 0, 20),
     SRLI(3, 1, 2),
     ADDI(4, 0, 5)],
    result_reg=3, expected_reg=4
))

# ---- 27. SRAI ----
register_case('srai', static_alu_case(
    [ADDI(1, 0, 0xFFC),
     SRAI(3, 1, 1),
     ADDI(4, 0, 0xFFE)],
    result_reg=3, expected_reg=4
))

# ---- 28. ADD ----
register_case('add', static_alu_case(
    [ADDI(1, 0, 100),
     ADDI(2, 0, 200),
     ADD(3, 1, 2),
     ADDI(4, 0, 300)],
    result_reg=3, expected_reg=4
))

# ---- 29. SUB ----
register_case('sub', static_alu_case(
    [ADDI(1, 0, 10),
     ADDI(2, 0, 3),
     SUB(3, 1, 2),
     ADDI(4, 0, 7)],
    result_reg=3, expected_reg=4
))

# ---- 30. SLL ----
register_case('sll', static_alu_case(
    [ADDI(1, 0, 1),
     ADDI(2, 0, 8),
     SLL(3, 1, 2),
     ADDI(4, 0, 256)],
    result_reg=3, expected_reg=4
))

# ---- 31. SLT ----
register_case('slt', static_alu_case(
    [ADDI(1, 0, 0xFFF),
     ADDI(2, 0, 0),
     SLT(3, 1, 2),
     ADDI(4, 0, 1)],
    result_reg=3, expected_reg=4
))

# ---- 32. SLTU ----
register_case('sltu', static_alu_case(
    [ADDI(1, 0, 0),
     ADDI(2, 0, 0xFFF),
     SLTU_R(3, 1, 2),
     ADDI(4, 0, 1)],
    result_reg=3, expected_reg=4
))

# ---- 33. XOR ----
register_case('xor', static_alu_case(
    [ADDI(1, 0, 0xF0),
     ADDI(2, 0, 0x0F),
     XOR(3, 1, 2),
     ADDI(4, 0, 255)],
    result_reg=3, expected_reg=4
))

# ---- 34. SRL ----
register_case('srl', static_alu_case(
    [ADDI(1, 0, 256),
     ADDI(2, 0, 4),
     SRL(3, 1, 2),
     ADDI(4, 0, 16)],
    result_reg=3, expected_reg=4
))

# ---- 35. SRA ----
register_case('sra', static_alu_case(
    [ADDI(1, 0, 0xFF8),
     ADDI(2, 0, 2),
     SRA(3, 1, 2),
     ADDI(4, 0, 0xFFE)],
    result_reg=3, expected_reg=4
))

# ---- 36. OR ----
register_case('or', static_alu_case(
    [ADDI(1, 0, 0xA0),
     ADDI(2, 0, 0x0B),
     OR(3, 1, 2),
     ADDI(4, 0, 0xAB)],
    result_reg=3, expected_reg=4
))

# ---- 37. AND ----
register_case('and', static_alu_case(
    [ADDI(1, 0, 255),
     ADDI(2, 0, 0x0F),
     AND_R(3, 1, 2),
     ADDI(4, 0, 15)],
    result_reg=3, expected_reg=4
))

def build_wave_program():
    prog = []
    total = len(TEST_CASES)
    for idx, (_, builder) in enumerate(TEST_CASES, start=1):
        success = progress_seq(idx)
        if idx == total:
            success = success + wave_done_seq()
        block = builder(len(prog) * 4, success, fail_seq(30))
        prog.extend(block)
    return prog

for name, builder in TEST_CASES:
    write_hex(f'{OUT}/{name}.hex', builder(0, pass_seq(), fail_seq()))

wave_prog = build_wave_program()
write_wave_rom_init(WAVE_ROM_INCLUDE, wave_prog)

print('Generated all test hex files in:', OUT)
import glob
files = sorted(glob.glob(f'{OUT}/*.hex'))
print(f'Total files: {len(files)}')
for f in files:
    print(f'  {os.path.basename(f)}')
print('Generated waveform ROM include:', WAVE_ROM_INCLUDE)
print('Waveform ROM words:', len(wave_prog))
