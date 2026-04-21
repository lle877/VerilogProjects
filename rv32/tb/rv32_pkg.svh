// ============================================================
// rv32_pkg.vh
// ------------------------------------------------------------
// 功能:
//   定义 RV32I 主 opcode 常量（对应 instr[6:0]）。
//   core 通过对 opcode 做 case 来识别指令大类。
//
// 备注:
//   - 这里只定义最小内核需要的 opcode。
//   - OPC_MISC/OPC_SYSTEM 在本最小实现里暂不支持（可作为后续扩展）。
// ============================================================
`ifndef RV32_PKG_VH
`define RV32_PKG_VH

// RISC-V RV32I 主 opcode（instr[6:0]）
// 注意：同一个 opcode 下，还需要用 funct3/funct7 区分具体操作。
localparam logic [6:0] OPC_LUI    = 7'b0110111; // LUI
localparam logic [6:0] OPC_AUIPC  = 7'b0010111; // AUIPC
localparam logic [6:0] OPC_JAL    = 7'b1101111; // JAL
localparam logic [6:0] OPC_JALR   = 7'b1100111; // JALR
localparam logic [6:0] OPC_BRANCH = 7'b1100011; // BEQ/BNE/BLT/... (B-type)
localparam logic [6:0] OPC_LOAD   = 7'b0000011; // LB/LH/LW/LBU/LHU
localparam logic [6:0] OPC_STORE  = 7'b0100011; // SB/SH/SW
localparam logic [6:0] OPC_OPIMM  = 7'b0010011; // ADDI/ANDI/... (I-type ALU)
localparam logic [6:0] OPC_OP     = 7'b0110011; // ADD/SUB/AND/... (R-type ALU)
localparam logic [6:0] OPC_MISC   = 7'b0001111; // FENCE（最小核未实现）
localparam logic [6:0] OPC_SYSTEM = 7'b1110011; // ECALL/EBREAK/CSR（最小核未实现）

`endif