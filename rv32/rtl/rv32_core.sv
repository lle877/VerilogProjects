`include "rv32_pkg.svh"

// ============================================================
// rv32_core - RV32I 五级流水线（IF / ID / EX / MEM / WB）
// ------------------------------------------------------------
// 架构说明：
//   - 五级流水线，包含 IF/ID、ID/EX、EX/MEM、MEM/WB 级间寄存器。
//   - 通过 EX/MEM、MEM/WB 前递处理常见 RAW 数据冒险。
//   - 对 load-use 冒险自动插入 1 个气泡。
//   - 对被采纳的分支/JAL/JALR 自动冲刷 IF/ID 与 ID/EX。
//   - 仍假定指令/数据存储器为零等待，不处理 ready/valid 停顿。
//
// 存储器接口约定：
//   - 端口形式仍保留 ready/valid 信号，便于后续扩展。
//   - 当前核心按零等待存储器使用这些端口，不会因 ready/valid 停顿。
//
// 端口约定：
//   - 所有地址均为字节地址。
//   - dmem_wstrb 为小端：wstrb[0] 对应 byte0（bits[7:0]）。
// ============================================================
module rv32_core (
  input  logic        clk,
  input  logic        rst_n,

  // 指令存储器
  output logic        imem_valid,        // 内核请求一条指令
  output logic [31:0] imem_addr,         // 取指地址（字节地址）
  input  logic        imem_ready,        // 存储器接受请求
  input  logic        imem_rdata_valid,  // 指令数据有效
  input  logic [31:0] imem_rdata,        // 指令字

  // 数据存储器
  output logic        dmem_valid,        // 内核请求一次数据访问
  output logic        dmem_we,           // 1=存储，0=加载
  output logic [3:0]  dmem_wstrb,        // 字节写使能（仅存储）
  output logic [31:0] dmem_addr,         // 数据地址（字节地址）
  output logic [31:0] dmem_wdata,        // 写数据（仅存储）
  input  logic        dmem_ready,        // 存储器接受请求
  input  logic        dmem_rdata_valid,  // 读数据有效（仅加载）
  input  logic [31:0] dmem_rdata         // 读数据
);

  // -----------------------------------------------------------
  // ALU 操作编码（必须与 rv32_alu.v 一致）
  // -----------------------------------------------------------
  localparam logic [3:0] ALU_ADD  = 4'd0;
  localparam logic [3:0] ALU_SUB  = 4'd1;
  localparam logic [3:0] ALU_AND  = 4'd2;
  localparam logic [3:0] ALU_OR   = 4'd3;
  localparam logic [3:0] ALU_XOR  = 4'd4;
  localparam logic [3:0] ALU_SLT  = 4'd5;
  localparam logic [3:0] ALU_SLTU = 4'd6;
  localparam logic [3:0] ALU_SLL  = 4'd7;
  localparam logic [3:0] ALU_SRL  = 4'd8;
  localparam logic [3:0] ALU_SRA  = 4'd9;

  // ALU A 操作数来源
  localparam logic       ALU_SRC_A_RS1 = 1'b0; // A = rs1
  localparam logic       ALU_SRC_A_PC  = 1'b1; // A = PC（用于 AUIPC）

  // ALU B 操作数来源
  localparam logic [1:0] ALU_SRC_B_RS2   = 2'd0;
  localparam logic [1:0] ALU_SRC_B_IMM_I = 2'd1;
  localparam logic [1:0] ALU_SRC_B_IMM_S = 2'd2;
  localparam logic [1:0] ALU_SRC_B_IMM_U = 2'd3;

  // 写回数据来源
  localparam logic [1:0] WB_SRC_ALU   = 2'd0; // ALU 结果
  localparam logic [1:0] WB_SRC_MEM   = 2'd1; // 加载数据
  localparam logic [1:0] WB_SRC_PC4   = 2'd2; // PC+4（JAL/JALR 链接地址）
  localparam logic [1:0] WB_SRC_IMM_U = 2'd3; // imm_u（LUI）

  // PC 下一值来源（在 ID 译码，在 EX 计算）
  localparam logic [1:0] PC_SRC_PC4    = 2'd0;
  localparam logic [1:0] PC_SRC_BRANCH = 2'd1;
  localparam logic [1:0] PC_SRC_JAL    = 2'd2;
  localparam logic [1:0] PC_SRC_JALR   = 2'd3;

  // -----------------------------------------------------------
  // PC 寄存器
  // -----------------------------------------------------------
  logic [31:0] pc_q;

  // -----------------------------------------------------------
  // 控制信号
  // -----------------------------------------------------------

  // -----------------------------------------------------------
  // IF/ID 流水寄存器
  // -----------------------------------------------------------
  logic [31:0] ifid_pc;
  logic [31:0] ifid_instr;
  logic        ifid_valid;

  // -----------------------------------------------------------
  // ID 级：译码信号（由 IF/ID 寄存器组合产生）
  // -----------------------------------------------------------
  logic [6:0]  id_opcode, id_funct7;
  logic [2:0]  id_funct3;
  logic [4:0]  id_rd, id_rs1, id_rs2;
  logic [31:0] id_imm_i, id_imm_s, id_imm_b, id_imm_u, id_imm_j;
  logic [31:0] id_rs1_val, id_rs2_val;
  logic        id_uses_rs1, id_uses_rs2;
  logic        load_use_hazard;
  // ID 控制信号
  logic        id_rf_we;
  logic [1:0]  id_wb_sel;
  logic        id_alu_src_a_sel;
  logic [1:0]  id_alu_src_b_sel;
  logic [3:0]  id_alu_op;
  logic [1:0]  id_pc_sel;
  logic        id_mem_req;
  logic        id_mem_write;

  // -----------------------------------------------------------
  // ID/EX 流水寄存器
  // -----------------------------------------------------------
  logic [31:0] idex_pc;
  logic [4:0]  idex_rs1, idex_rs2;
  logic [31:0] idex_rs1_val, idex_rs2_val;
  logic [4:0]  idex_rd;
  logic [31:0] idex_imm_i, idex_imm_s, idex_imm_b, idex_imm_u, idex_imm_j;
  logic [2:0]  idex_funct3;
  logic        idex_valid;
  // ID/EX 控制信号
  logic        idex_rf_we;
  logic [1:0]  idex_wb_sel;
  logic        idex_alu_src_a_sel;
  logic [1:0]  idex_alu_src_b_sel;
  logic [3:0]  idex_alu_op;
  logic [1:0]  idex_pc_sel;
  logic        idex_mem_req;
  logic        idex_mem_write;

  // -----------------------------------------------------------
  // EX 级信号（由 ID/EX 寄存器组合产生）
  // -----------------------------------------------------------
  logic [31:0] ex_rs1_val, ex_rs2_val;
  logic [31:0] ex_alu_a, ex_alu_b, ex_alu_y;
  logic        ex_br_take;
  logic [31:0] ex_pc4, ex_branch_target, ex_jal_target, ex_jalr_target;
  logic        ex_pc_redirect;
  logic [31:0] ex_pc_target;
  logic [31:0] ex_wb_data;      // 在 EX 计算的非加载写回数据
  logic [3:0]  ex_store_wstrb;
  logic [31:0] ex_store_wdata;

  // -----------------------------------------------------------
  // EX/MEM 流水寄存器
  // -----------------------------------------------------------
  logic [31:0] exmem_alu_y;
  logic [3:0]  exmem_store_wstrb;
  logic [31:0] exmem_store_wdata;
  logic [4:0]  exmem_rd;
  logic [2:0]  exmem_funct3;
  logic        exmem_valid;
  logic [31:0] exmem_wb_data;  // 非加载写回数据
  // EX/MEM 控制信号
  logic        exmem_rf_we;
  logic [1:0]  exmem_wb_sel;
  logic        exmem_mem_req;
  logic        exmem_mem_write;

  // -----------------------------------------------------------
  // MEM 级信号（由 EX/MEM 寄存器组合产生）
  // -----------------------------------------------------------
  logic [7:0]  mem_load_byte;
  logic [15:0] mem_load_half;
  logic [31:0] mem_load_data;
  logic [31:0] mem_wb_data;    // 最终写回：加载数据或 ex_wb_data

  // -----------------------------------------------------------
  // MEM/WB 流水寄存器
  // -----------------------------------------------------------
  logic [31:0] memwb_wdata;
  logic [4:0]  memwb_rd;
  logic        memwb_rf_we;
  logic        memwb_valid;

  // ===========================================================
  // 子模块实例
  // ===========================================================

  // 指令译码（ID 级，来自 IF/ID 寄存器的组合逻辑）
  rv32_decode u_dec (
    .instr  (ifid_instr),
    .opcode (id_opcode),
    .funct3 (id_funct3),
    .funct7 (id_funct7),
    .rd     (id_rd),
    .rs1    (id_rs1),
    .rs2    (id_rs2)
  );

  // 立即数生成（ID 级）
  rv32_imm u_imm (
    .instr (ifid_instr),
    .imm_i (id_imm_i),
    .imm_s (id_imm_s),
    .imm_b (id_imm_b),
    .imm_u (id_imm_u),
    .imm_j (id_imm_j)
  );

  // 寄存器堆：ID 读，WB 写
  rv32_regfile u_rf (
    .clk    (clk),
    .we     (memwb_rf_we && memwb_valid),
    .waddr  (memwb_rd),
    .wdata  (memwb_wdata),
    .raddr1 (id_rs1),
    .raddr2 (id_rs2),
    .rdata1 (id_rs1_val),
    .rdata2 (id_rs2_val)
  );

  // ALU（EX 级）
  rv32_alu u_alu (
    .alu_op (idex_alu_op),
    .a      (ex_alu_a),
    .b      (ex_alu_b),
    .y      (ex_alu_y)
  );

  // 分支比较器（EX 级）
  rv32_branch u_br (
    .funct3 (idex_funct3),
    .rs1    (ex_rs1_val),
    .rs2    (ex_rs2_val),
    .take   (ex_br_take)
  );

  // ===========================================================
  // IMEM 接口
  // ===========================================================
  // 复位期间拉低，避免对存储器可见的伪取指。
  // 当前实现假定指令存储器零等待，不根据 ready/valid 进行停顿。
  assign imem_valid = rst_n;
  assign imem_addr  = pc_q;

  // ===========================================================
  // DMEM 接口（由 EX/MEM 流水寄存器驱动）
  // ===========================================================
  assign dmem_valid = exmem_valid && exmem_mem_req;
  assign dmem_we    = exmem_mem_write;
  assign dmem_addr  = exmem_alu_y;
  assign dmem_wstrb = exmem_mem_write ? exmem_store_wstrb : 4'b0000;
  assign dmem_wdata = exmem_mem_write ? exmem_store_wdata : 32'h0;

  // ===========================================================
  // PC 寄存器
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n)             pc_q <= 32'h0000_0000;
    else if (ex_pc_redirect) pc_q <= ex_pc_target;  // 分支/跳转被采纳时重定向
    else if (!load_use_hazard) pc_q <= pc_q + 32'd4; // load-use 时冻结 PC
  end

  // ===========================================================
  // IF/ID 流水寄存器
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ifid_pc    <= 32'h0;
      ifid_instr <= 32'h0000_0013; // NOP（addi x0,x0,0）
      ifid_valid <= 1'b0;
    end else if (ex_pc_redirect) begin
      ifid_pc    <= 32'h0;
      ifid_instr <= 32'h0000_0013;
      ifid_valid <= 1'b0;
    end else if (!load_use_hazard) begin
      ifid_pc    <= pc_q;
      ifid_instr <= imem_rdata;
      ifid_valid <= 1'b1;
    end
  end

  // ===========================================================
  // ID 级：控制译码器
  // ===========================================================
  always_comb begin
    // 默认值 = NOP：无写回、无访存、PC+4、ADD
    id_uses_rs1      = 1'b0;
    id_uses_rs2      = 1'b0;
    id_rf_we         = 1'b0;
    id_wb_sel        = WB_SRC_ALU;
    id_alu_src_a_sel = ALU_SRC_A_RS1;
    id_alu_src_b_sel = ALU_SRC_B_RS2;
    id_alu_op        = ALU_ADD;
    id_pc_sel        = PC_SRC_PC4;
    id_mem_req       = 1'b0;
    id_mem_write     = 1'b0;

    if (ifid_valid) begin
      case (id_opcode)

        OPC_LUI: begin
          id_rf_we  = 1'b1;
          id_wb_sel = WB_SRC_IMM_U;
        end

        OPC_AUIPC: begin
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_ALU;
          id_alu_src_a_sel = ALU_SRC_A_PC;
          id_alu_src_b_sel = ALU_SRC_B_IMM_U;
        end

        OPC_JAL: begin
          id_rf_we  = 1'b1;
          id_wb_sel = WB_SRC_PC4;
          id_pc_sel = PC_SRC_JAL;
        end

        OPC_JALR: begin
          id_uses_rs1      = 1'b1;
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_PC4;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_I;
          id_pc_sel        = PC_SRC_JALR;
        end

        OPC_BRANCH: begin
          id_uses_rs1 = 1'b1;
          id_uses_rs2 = 1'b1;
          // 实际的取分支/不取分支在 EX 级判定；
          // 传递 PC_SRC_BRANCH 让 EX 知道需要判断条件。
          id_pc_sel = PC_SRC_BRANCH;
        end

        OPC_OPIMM: begin
          id_uses_rs1      = 1'b1;
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_ALU;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_I;
          case (id_funct3)
            3'b000: id_alu_op = ALU_ADD;
            3'b010: id_alu_op = ALU_SLT;
            3'b011: id_alu_op = ALU_SLTU;
            3'b100: id_alu_op = ALU_XOR;
            3'b110: id_alu_op = ALU_OR;
            3'b111: id_alu_op = ALU_AND;
            3'b001: id_alu_op = ALU_SLL;
            3'b101: id_alu_op = id_funct7[5] ? ALU_SRA : ALU_SRL;
            default: id_rf_we = 1'b0;
          endcase
        end

        OPC_OP: begin
          id_uses_rs1      = 1'b1;
          id_uses_rs2      = 1'b1;
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_ALU;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_RS2;
          case (id_funct3)
            3'b000: id_alu_op = id_funct7[5] ? ALU_SUB : ALU_ADD;
            3'b001: id_alu_op = ALU_SLL;
            3'b010: id_alu_op = ALU_SLT;
            3'b011: id_alu_op = ALU_SLTU;
            3'b100: id_alu_op = ALU_XOR;
            3'b101: id_alu_op = id_funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110: id_alu_op = ALU_OR;
            3'b111: id_alu_op = ALU_AND;
            default: id_rf_we = 1'b0;
          endcase
        end

        OPC_LOAD: begin
          id_uses_rs1      = 1'b1;
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_MEM;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_I;
          id_alu_op        = ALU_ADD;
          id_mem_req       = 1'b1;
          // 过滤不支持的 funct3
          case (id_funct3)
            3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin end
            default: id_rf_we = 1'b0;
          endcase
        end

        OPC_STORE: begin
          id_uses_rs1      = 1'b1;
          id_uses_rs2      = 1'b1;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_S;
          id_alu_op        = ALU_ADD;
          id_mem_req       = 1'b1;
          id_mem_write     = 1'b1;
          case (id_funct3)
            3'b000, 3'b001, 3'b010: begin end
            default: begin id_mem_req = 1'b0; id_mem_write = 1'b0; end
          endcase
        end

        default: begin end // 未识别 opcode -> NOP
      endcase
    end
  end

  assign load_use_hazard = ifid_valid && idex_valid && idex_rf_we &&
                           (idex_wb_sel == WB_SRC_MEM) && (idex_rd != 5'h0) &&
                           ((id_uses_rs1 && (id_rs1 == idex_rd)) ||
                            (id_uses_rs2 && (id_rs2 == idex_rd)));

  // ===========================================================
  // ID/EX 流水寄存器
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // 复位：插入 NOP 气泡
      idex_valid         <= 1'b0;
      idex_pc            <= 32'h0;
      idex_rs1           <= 5'h0;
      idex_rs2           <= 5'h0;
      idex_rs1_val       <= 32'h0;
      idex_rs2_val       <= 32'h0;
      idex_rd            <= 5'h0;
      idex_funct3        <= 3'h0;
      idex_imm_i         <= 32'h0;
      idex_imm_s         <= 32'h0;
      idex_imm_b         <= 32'h0;
      idex_imm_u         <= 32'h0;
      idex_imm_j         <= 32'h0;
      idex_rf_we         <= 1'b0;
      idex_wb_sel        <= WB_SRC_ALU;
      idex_alu_src_a_sel <= ALU_SRC_A_RS1;
      idex_alu_src_b_sel <= ALU_SRC_B_RS2;
      idex_alu_op        <= ALU_ADD;
      idex_pc_sel        <= PC_SRC_PC4;
      idex_mem_req       <= 1'b0;
      idex_mem_write     <= 1'b0;
    end else if (ex_pc_redirect || load_use_hazard) begin
      idex_valid         <= 1'b0;
      idex_pc            <= 32'h0;
      idex_rs1           <= 5'h0;
      idex_rs2           <= 5'h0;
      idex_rs1_val       <= 32'h0;
      idex_rs2_val       <= 32'h0;
      idex_rd            <= 5'h0;
      idex_funct3        <= 3'h0;
      idex_imm_i         <= 32'h0;
      idex_imm_s         <= 32'h0;
      idex_imm_b         <= 32'h0;
      idex_imm_u         <= 32'h0;
      idex_imm_j         <= 32'h0;
      idex_rf_we         <= 1'b0;
      idex_wb_sel        <= WB_SRC_ALU;
      idex_alu_src_a_sel <= ALU_SRC_A_RS1;
      idex_alu_src_b_sel <= ALU_SRC_B_RS2;
      idex_alu_op        <= ALU_ADD;
      idex_pc_sel        <= PC_SRC_PC4;
      idex_mem_req       <= 1'b0;
      idex_mem_write     <= 1'b0;
    end else begin
      idex_valid         <= ifid_valid;
      idex_pc            <= ifid_pc;
      idex_rs1           <= id_rs1;
      idex_rs2           <= id_rs2;
      idex_rs1_val       <= id_rs1_val;
      idex_rs2_val       <= id_rs2_val;
      idex_rd            <= id_rd;
      idex_funct3        <= id_funct3;
      idex_imm_i         <= id_imm_i;
      idex_imm_s         <= id_imm_s;
      idex_imm_b         <= id_imm_b;
      idex_imm_u         <= id_imm_u;
      idex_imm_j         <= id_imm_j;
      idex_rf_we         <= id_rf_we;
      idex_wb_sel        <= id_wb_sel;
      idex_alu_src_a_sel <= id_alu_src_a_sel;
      idex_alu_src_b_sel <= id_alu_src_b_sel;
      idex_alu_op        <= id_alu_op;
      idex_pc_sel        <= id_pc_sel;
      idex_mem_req       <= id_mem_req;
      idex_mem_write     <= id_mem_write;
    end
  end

  // ===========================================================
  // EX 级
  // ===========================================================

  // 对 ALU、分支比较、JALR 基址和 store 数据统一做前递选择。
  always_comb begin
    ex_rs1_val = idex_rs1_val;
    if (exmem_valid && exmem_rf_we && (exmem_rd != 5'h0) &&
        (exmem_rd == idex_rs1) && (exmem_wb_sel != WB_SRC_MEM)) begin
      ex_rs1_val = exmem_wb_data;
    end else if (memwb_valid && memwb_rf_we && (memwb_rd != 5'h0) &&
                 (memwb_rd == idex_rs1)) begin
      ex_rs1_val = memwb_wdata;
    end

    ex_rs2_val = idex_rs2_val;
    if (exmem_valid && exmem_rf_we && (exmem_rd != 5'h0) &&
        (exmem_rd == idex_rs2) && (exmem_wb_sel != WB_SRC_MEM)) begin
      ex_rs2_val = exmem_wb_data;
    end else if (memwb_valid && memwb_rf_we && (memwb_rd != 5'h0) &&
                 (memwb_rd == idex_rs2)) begin
      ex_rs2_val = memwb_wdata;
    end
  end

  // PC 目标候选
  assign ex_pc4           = idex_pc + 32'd4;
  assign ex_branch_target = idex_pc + idex_imm_b;
  assign ex_jal_target    = idex_pc + idex_imm_j;
  assign ex_jalr_target   = {ex_alu_y[31:1], 1'b0}; // (rs1+imm_i) & ~1

  // ALU 操作数多路选择
  assign ex_alu_a = (idex_alu_src_a_sel == ALU_SRC_A_PC) ? idex_pc : ex_rs1_val;

  always_comb begin
    unique case (idex_alu_src_b_sel)
      ALU_SRC_B_RS2:   ex_alu_b = ex_rs2_val;
      ALU_SRC_B_IMM_I: ex_alu_b = idex_imm_i;
      ALU_SRC_B_IMM_S: ex_alu_b = idex_imm_s;
      ALU_SRC_B_IMM_U: ex_alu_b = idex_imm_u;
      default:         ex_alu_b = ex_rs2_val;
    endcase
  end

  // 分支/跳转的 PC 重定向判定
  always_comb begin
    ex_pc_redirect = 1'b0;
    ex_pc_target   = ex_pc4; // 默认值（redirect=0 时不使用）
    if (idex_valid) begin
      case (idex_pc_sel)
        PC_SRC_BRANCH: begin
          if (ex_br_take) begin
            ex_pc_redirect = 1'b1;
            ex_pc_target   = ex_branch_target;
          end
        end
        PC_SRC_JAL: begin
          ex_pc_redirect = 1'b1;
          ex_pc_target   = ex_jal_target;
        end
        PC_SRC_JALR: begin
          ex_pc_redirect = 1'b1;
          ex_pc_target   = ex_jalr_target;
        end
        default: begin end // PC_SRC_PC4：正常顺序执行，不重定向
      endcase
    end
  end

  // 在 EX 预计算非加载写回数据，使 MEM/WB 仅需一个数据字段。
  // 对于加载（WB_SRC_MEM），真实数据在 MEM 级选择；
  // 此处占位值会在 mem_wb_data 中被 mem_load_data 覆盖。
  always_comb begin
    case (idex_wb_sel)
      WB_SRC_PC4:   ex_wb_data = ex_pc4;
      WB_SRC_IMM_U: ex_wb_data = idex_imm_u;
      WB_SRC_ALU:   ex_wb_data = ex_alu_y;
      default:      ex_wb_data = ex_alu_y; // WB_SRC_MEM：在 MEM 级覆盖
    endcase
  end

  // 生成存储指令的 wstrb / wdata
  always_comb begin
    ex_store_wstrb = 4'b0000;
    ex_store_wdata = 32'h0;
    if (idex_mem_write) begin
      case (idex_funct3)
        3'b000: begin // SB
          case (ex_alu_y[1:0])
            2'd0: begin ex_store_wstrb = 4'b0001; ex_store_wdata = {24'h0, ex_rs2_val[7:0]}; end
            2'd1: begin ex_store_wstrb = 4'b0010; ex_store_wdata = {16'h0, ex_rs2_val[7:0], 8'h0}; end
            2'd2: begin ex_store_wstrb = 4'b0100; ex_store_wdata = {8'h0, ex_rs2_val[7:0], 16'h0}; end
            2'd3: begin ex_store_wstrb = 4'b1000; ex_store_wdata = {ex_rs2_val[7:0], 24'h0}; end
            default: begin ex_store_wstrb = 4'b0; ex_store_wdata = 32'h0; end
          endcase
        end
        3'b001: begin // SH
          if (!ex_alu_y[1]) begin
            ex_store_wstrb = 4'b0011;
            ex_store_wdata = {16'h0, ex_rs2_val[15:0]};
          end else begin
            ex_store_wstrb = 4'b1100;
            ex_store_wdata = {ex_rs2_val[15:0], 16'h0};
          end
        end
        3'b010: begin // SW
          ex_store_wstrb = 4'b1111;
          ex_store_wdata = ex_rs2_val;
        end
        default: begin ex_store_wstrb = 4'b0; ex_store_wdata = 32'h0; end
      endcase
    end
  end

  // ===========================================================
  // EX/MEM 流水寄存器
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      exmem_valid       <= 1'b0;
      exmem_alu_y       <= 32'h0;
      exmem_store_wstrb <= 4'b0;
      exmem_store_wdata <= 32'h0;
      exmem_rd          <= 5'h0;
      exmem_funct3      <= 3'h0;
      exmem_wb_data     <= 32'h0;
      exmem_rf_we       <= 1'b0;
      exmem_wb_sel      <= WB_SRC_ALU;
      exmem_mem_req     <= 1'b0;
      exmem_mem_write   <= 1'b0;
    end else begin
      // 分支/跳转指令仍会进入 MEM（用于 JAL/JALR 写回）
      exmem_valid       <= idex_valid;
      exmem_alu_y       <= ex_alu_y;
      exmem_store_wstrb <= ex_store_wstrb;
      exmem_store_wdata <= ex_store_wdata;
      exmem_rd          <= idex_rd;
      exmem_funct3      <= idex_funct3;
      exmem_wb_data     <= ex_wb_data;
      exmem_rf_we       <= idex_rf_we;
      exmem_wb_sel      <= idex_wb_sel;
      exmem_mem_req     <= idex_mem_req;
      exmem_mem_write   <= idex_mem_write;
    end
  end

  // ===========================================================
  // MEM 级：加载数据格式化 + 写回数据选择
  // ===========================================================

  always_comb begin
    // 按地址对齐从 dmem_rdata 中选择字节/半字
    unique case (exmem_alu_y[1:0])
      2'd0: mem_load_byte = dmem_rdata[7:0];
      2'd1: mem_load_byte = dmem_rdata[15:8];
      2'd2: mem_load_byte = dmem_rdata[23:16];
      2'd3: mem_load_byte = dmem_rdata[31:24];
      default: mem_load_byte = dmem_rdata[7:0];
    endcase

    mem_load_half = exmem_alu_y[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    // 按 funct3 进行有符号/无符号扩展
    unique case (exmem_funct3)
      3'b000: mem_load_data = {{24{mem_load_byte[7]}}, mem_load_byte}; // LB
      3'b001: mem_load_data = {{16{mem_load_half[15]}}, mem_load_half}; // LH
      3'b010: mem_load_data = dmem_rdata;                              // LW
      3'b100: mem_load_data = {24'h0, mem_load_byte};                  // LBU
      3'b101: mem_load_data = {16'h0, mem_load_half};                  // LHU
      default: mem_load_data = dmem_rdata;
    endcase
  end

  // 选择最终写回数据：加载结果（MEM）或 EX 预计算值
  assign mem_wb_data = (exmem_wb_sel == WB_SRC_MEM) ? mem_load_data : exmem_wb_data;

  // ===========================================================
  // MEM/WB 流水寄存器
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      memwb_valid  <= 1'b0;
      memwb_wdata  <= 32'h0;
      memwb_rd     <= 5'h0;
      memwb_rf_we  <= 1'b0;
    end else begin
      memwb_valid  <= exmem_valid;
      memwb_wdata  <= mem_wb_data;
      memwb_rd     <= exmem_rd;
      memwb_rf_we  <= exmem_rf_we;
    end
  end

  // WB 级：寄存器堆写入由上方 u_rf 实例完成。
  // we = memwb_rf_we && memwb_valid, waddr = memwb_rd, wdata = memwb_wdata.

endmodule
