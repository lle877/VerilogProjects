`include "rv32_pkg.svh"
module rv32_core (
  input  logic        clk,
  input  logic        rst_n,

  // Instruction memory
  output logic        imem_valid,        // core requesting an instruction
  output logic [31:0] imem_addr,         // fetch address (byte address)
  input  logic        imem_ready,        // memory accepts request
  input  logic        imem_rdata_valid,  // instruction data is valid
  input  logic [31:0] imem_rdata,        // instruction word

  // Data memory
  output logic        dmem_valid,        // core requesting a data access
  output logic        dmem_we,           // 1=store, 0=load
  output logic [3:0]  dmem_wstrb,        // byte enables (store only)
  output logic [31:0] dmem_addr,         // data address (byte address)
  output logic [31:0] dmem_wdata,        // write data (store only)
  input  logic        dmem_ready,        // memory accepts request
  input  logic        dmem_rdata_valid,  // read data valid (load only)
  input  logic [31:0] dmem_rdata         // read data
);

  // -----------------------------------------------------------
  // ALU operation encodings (must match rv32_alu.v)
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

  // ALU A-operand source
  localparam logic       ALU_SRC_A_RS1 = 1'b0; // A = rs1
  localparam logic       ALU_SRC_A_PC  = 1'b1; // A = PC (for AUIPC)

  // ALU B-operand source
  localparam logic [1:0] ALU_SRC_B_RS2   = 2'd0;
  localparam logic [1:0] ALU_SRC_B_IMM_I = 2'd1;
  localparam logic [1:0] ALU_SRC_B_IMM_S = 2'd2;
  localparam logic [1:0] ALU_SRC_B_IMM_U = 2'd3;

  // Writeback data source
  localparam logic [1:0] WB_SRC_ALU   = 2'd0; // ALU result
  localparam logic [1:0] WB_SRC_MEM   = 2'd1; // load data
  localparam logic [1:0] WB_SRC_PC4   = 2'd2; // PC+4 (JAL/JALR link)
  localparam logic [1:0] WB_SRC_IMM_U = 2'd3; // imm_u (LUI)

  // PC next-value source (used in ID stage, evaluated in EX)
  localparam logic [1:0] PC_SRC_PC4    = 2'd0;
  localparam logic [1:0] PC_SRC_BRANCH = 2'd1;
  localparam logic [1:0] PC_SRC_JAL    = 2'd2;
  localparam logic [1:0] PC_SRC_JALR   = 2'd3;

  // -----------------------------------------------------------
  // PC register
  // -----------------------------------------------------------
  logic [31:0] pc_q;

  // -----------------------------------------------------------
  // Hazard / control signals
  // -----------------------------------------------------------
  logic imem_stall; // IF waiting for instruction data
  logic dmem_stall; // MEM waiting for data memory
  logic stall;      // global stall: freeze all pipeline regs and PC
  logic flush_ex;   // EX determined branch/jump taken; flush IF/ID and ID/EX

  // -----------------------------------------------------------
  // IF/ID pipeline register
  // -----------------------------------------------------------
  logic [31:0] ifid_pc;
  logic [31:0] ifid_instr;
  logic        ifid_valid;

  // -----------------------------------------------------------
  // ID stage: decode signals (combinatorial from IF/ID register)
  // -----------------------------------------------------------
  logic [6:0]  id_opcode, id_funct7;
  logic [2:0]  id_funct3;
  logic [4:0]  id_rd, id_rs1, id_rs2;
  logic [31:0] id_imm_i, id_imm_s, id_imm_b, id_imm_u, id_imm_j;
  logic [31:0] id_rs1_val, id_rs2_val;
  // ID control signals
  logic        id_rf_we;
  logic [1:0]  id_wb_sel;
  logic        id_alu_src_a_sel;
  logic [1:0]  id_alu_src_b_sel;
  logic [3:0]  id_alu_op;
  logic [1:0]  id_pc_sel;
  logic        id_mem_req;
  logic        id_mem_write;

  // -----------------------------------------------------------
  // ID/EX pipeline register
  // -----------------------------------------------------------
  logic [31:0] idex_pc;
  logic [31:0] idex_rs1_val, idex_rs2_val;
  logic [4:0]  idex_rd;
  logic [31:0] idex_imm_i, idex_imm_s, idex_imm_b, idex_imm_u, idex_imm_j;
  logic [2:0]  idex_funct3;
  logic        idex_valid;
  // ID/EX control
  logic        idex_rf_we;
  logic [1:0]  idex_wb_sel;
  logic        idex_alu_src_a_sel;
  logic [1:0]  idex_alu_src_b_sel;
  logic [3:0]  idex_alu_op;
  logic [1:0]  idex_pc_sel;
  logic        idex_mem_req;
  logic        idex_mem_write;

  // -----------------------------------------------------------
  // EX stage signals (combinatorial from ID/EX register)
  // -----------------------------------------------------------
  logic [31:0] ex_alu_a, ex_alu_b, ex_alu_y;
  logic        ex_br_take;
  logic [31:0] ex_pc4, ex_branch_target, ex_jal_target, ex_jalr_target;
  logic        ex_pc_redirect;
  logic [31:0] ex_pc_target;
  logic [31:0] ex_wb_data;      // non-load writeback data computed in EX
  logic [3:0]  ex_store_wstrb;
  logic [31:0] ex_store_wdata;

  // -----------------------------------------------------------
  // EX/MEM pipeline register
  // -----------------------------------------------------------
  logic [31:0] exmem_alu_y;
  logic [3:0]  exmem_store_wstrb;
  logic [31:0] exmem_store_wdata;
  logic [4:0]  exmem_rd;
  logic [2:0]  exmem_funct3;
  logic        exmem_valid;
  logic [31:0] exmem_wb_data;  // non-load writeback data
  // EX/MEM control
  logic        exmem_rf_we;
  logic [1:0]  exmem_wb_sel;
  logic        exmem_mem_req;
  logic        exmem_mem_write;

  // -----------------------------------------------------------
  // MEM stage signals (combinatorial from EX/MEM register)
  // -----------------------------------------------------------
  logic [7:0]  mem_load_byte;
  logic [15:0] mem_load_half;
  logic [31:0] mem_load_data;
  logic [31:0] mem_wb_data;    // final writeback: load data or ex_wb_data

  // -----------------------------------------------------------
  // MEM/WB pipeline register
  // -----------------------------------------------------------
  logic [31:0] memwb_wdata;
  logic [4:0]  memwb_rd;
  logic        memwb_rf_we;
  logic        memwb_valid;

  // ===========================================================
  // Submodule instances
  // ===========================================================

  // Instruction decode (ID stage â€? combinatorial from IF/ID reg)
  rv32_decode u_dec (
    .instr  (ifid_instr),
    .opcode (id_opcode),
    .funct3 (id_funct3),
    .funct7 (id_funct7),
    .rd     (id_rd),
    .rs1    (id_rs1),
    .rs2    (id_rs2)
  );

  // Immediate generation (ID stage)
  rv32_imm u_imm (
    .instr (ifid_instr),
    .imm_i (id_imm_i),
    .imm_s (id_imm_s),
    .imm_b (id_imm_b),
    .imm_u (id_imm_u),
    .imm_j (id_imm_j)
  );

  // Register file: reads in ID, writes from WB
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

  // ALU (EX stage)
  rv32_alu u_alu (
    .alu_op (idex_alu_op),
    .a      (ex_alu_a),
    .b      (ex_alu_b),
    .y      (ex_alu_y)
  );

  // Branch comparator (EX stage)
  rv32_branch u_br (
    .funct3 (idex_funct3),
    .rs1    (idex_rs1_val),
    .rs2    (idex_rs2_val),
    .take   (ex_br_take)
  );

  // ===========================================================
  // IMEM interface
  // ===========================================================
  // De-assert during reset so no spurious fetches are visible to memory.
  // During a stall the PC is frozen, so re-issuing the same address is safe.
  assign imem_valid = rst_n;
  assign imem_addr  = pc_q;

  // Stall while instruction data has not arrived
  assign imem_stall = ~imem_rdata_valid;

  // ===========================================================
  // DMEM interface (driven from EX/MEM pipeline register)
  // ===========================================================
  assign dmem_valid = exmem_valid && exmem_mem_req;
  assign dmem_we    = exmem_mem_write;
  assign dmem_addr  = exmem_alu_y;
  assign dmem_wstrb = exmem_mem_write ? exmem_store_wstrb : 4'b0000;
  assign dmem_wdata = exmem_mem_write ? exmem_store_wdata : 32'h0;

  // Stall while data memory access has not completed:
  //   store: stall until dmem_ready (request accepted)
  //   load:  stall until dmem_rdata_valid (data returned)
  assign dmem_stall = exmem_valid && exmem_mem_req && (
                        ( exmem_mem_write && ~dmem_ready      ) ||
                        (~exmem_mem_write && ~dmem_rdata_valid)
                      );

  // Global stall and flush.
  // flush_ex is gated by ~stall: when a stall is active the pipeline is frozen,
  // so the branch/jump instruction stays in the ID/EX register.  On the first
  // cycle after the stall clears, ex_pc_redirect is still asserted (because
  // ID/EX still holds the branch/jump), so flush_ex fires then and both
  // redirects the PC and clears IF/ID and ID/EX in the correct order.
  assign stall    = imem_stall | dmem_stall;
  assign flush_ex = ex_pc_redirect && ~stall;

  // ===========================================================
  // PC register
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n)       pc_q <= 32'h0000_0000;
    else if (flush_ex) pc_q <= ex_pc_target;  // redirect on taken branch/jump
    else if (!stall)   pc_q <= pc_q + 32'd4;  // normal sequential advance
    // else: stall â€? hold PC
  end

  // ===========================================================
  // IF/ID pipeline register
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ifid_pc    <= 32'h0;
      ifid_instr <= 32'h0000_0013; // NOP (addi x0,x0,0)
      ifid_valid <= 1'b0;
    end else if (flush_ex) begin
      // Discard the instruction that was in flight during fetch.
      // Use ex_pc_target as debug PC so waveforms show the redirect address.
      ifid_instr <= 32'h0000_0013;
      ifid_valid <= 1'b0;
      ifid_pc    <= ex_pc_target;
    end else if (!stall) begin
      ifid_pc    <= pc_q;
      ifid_instr <= imem_rdata;
      ifid_valid <= 1'b1;
    end
    // else: stall â€? hold
  end

  // ===========================================================
  // ID stage: control decoder
  // ===========================================================
  always_comb begin
    // Defaults = NOP: no writeback, no memory, PC+4, ADD
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
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_PC4;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_I;
          id_pc_sel        = PC_SRC_JALR;
        end

        OPC_BRANCH: begin
          // Actual taken/not-taken decision is made in EX;
          // pass PC_SRC_BRANCH so EX knows to evaluate the condition.
          id_pc_sel = PC_SRC_BRANCH;
        end

        OPC_OPIMM: begin
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
          id_rf_we         = 1'b1;
          id_wb_sel        = WB_SRC_MEM;
          id_alu_src_a_sel = ALU_SRC_A_RS1;
          id_alu_src_b_sel = ALU_SRC_B_IMM_I;
          id_alu_op        = ALU_ADD;
          id_mem_req       = 1'b1;
          // filter unsupported funct3
          case (id_funct3)
            3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin end
            default: id_rf_we = 1'b0;
          endcase
        end

        OPC_STORE: begin
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

        default: begin end // unrecognised opcode -> NOP
      endcase
    end
  end

  // ===========================================================
  // ID/EX pipeline register
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n || flush_ex) begin
      // Reset or flush: insert NOP bubble
      idex_valid         <= 1'b0;
      idex_pc            <= 32'h0;
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
    end else if (!stall) begin
      idex_valid         <= ifid_valid;
      idex_pc            <= ifid_pc;
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
    // else: stall â€? hold
  end

  // ===========================================================
  // EX stage
  // ===========================================================

  // PC target candidates
  assign ex_pc4           = idex_pc + 32'd4;
  assign ex_branch_target = idex_pc + idex_imm_b;
  assign ex_jal_target    = idex_pc + idex_imm_j;
  assign ex_jalr_target   = {ex_alu_y[31:1], 1'b0}; // (rs1+imm_i) & ~1

  // ALU operand mux
  assign ex_alu_a = (idex_alu_src_a_sel == ALU_SRC_A_PC) ? idex_pc : idex_rs1_val;

  always_comb begin
    unique case (idex_alu_src_b_sel)
      ALU_SRC_B_RS2:   ex_alu_b = idex_rs2_val;
      ALU_SRC_B_IMM_I: ex_alu_b = idex_imm_i;
      ALU_SRC_B_IMM_S: ex_alu_b = idex_imm_s;
      ALU_SRC_B_IMM_U: ex_alu_b = idex_imm_u;
      default:         ex_alu_b = idex_rs2_val;
    endcase
  end

  // Branch/jump PC redirect decision
  always_comb begin
    ex_pc_redirect = 1'b0;
    ex_pc_target   = ex_pc4; // default (unused when redirect=0)
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
        default: begin end // PC_SRC_PC4: normal sequential, no redirect
      endcase
    end
  end

  // Pre-compute non-load writeback data in EX so MEM/WB only needs one field.
  // For loads (WB_SRC_MEM), the actual data is selected in the MEM stage;
  // the placeholder value here is overridden by mem_load_data in mem_wb_data.
  always_comb begin
    case (idex_wb_sel)
      WB_SRC_PC4:   ex_wb_data = ex_pc4;
      WB_SRC_IMM_U: ex_wb_data = idex_imm_u;
      WB_SRC_ALU:   ex_wb_data = ex_alu_y;
      default:      ex_wb_data = ex_alu_y; // WB_SRC_MEM: overridden in MEM stage
    endcase
  end

  // Store wstrb / wdata generation
  always_comb begin
    ex_store_wstrb = 4'b0000;
    ex_store_wdata = 32'h0;
    if (idex_mem_write) begin
      case (idex_funct3)
        3'b000: begin // SB
          case (ex_alu_y[1:0])
            2'd0: begin ex_store_wstrb = 4'b0001; ex_store_wdata = {24'h0, idex_rs2_val[7:0]}; end
            2'd1: begin ex_store_wstrb = 4'b0010; ex_store_wdata = {16'h0, idex_rs2_val[7:0], 8'h0}; end
            2'd2: begin ex_store_wstrb = 4'b0100; ex_store_wdata = {8'h0, idex_rs2_val[7:0], 16'h0}; end
            2'd3: begin ex_store_wstrb = 4'b1000; ex_store_wdata = {idex_rs2_val[7:0], 24'h0}; end
            default: begin ex_store_wstrb = 4'b0; ex_store_wdata = 32'h0; end
          endcase
        end
        3'b001: begin // SH
          if (!ex_alu_y[1]) begin
            ex_store_wstrb = 4'b0011;
            ex_store_wdata = {16'h0, idex_rs2_val[15:0]};
          end else begin
            ex_store_wstrb = 4'b1100;
            ex_store_wdata = {idex_rs2_val[15:0], 16'h0};
          end
        end
        3'b010: begin // SW
          ex_store_wstrb = 4'b1111;
          ex_store_wdata = idex_rs2_val;
        end
        default: begin ex_store_wstrb = 4'b0; ex_store_wdata = 32'h0; end
      endcase
    end
  end

  // ===========================================================
  // EX/MEM pipeline register
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
    end else if (!stall) begin
      // The branch/jump instruction in EX still moves to MEM (for JAL/JALR WB)
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
    // else: stall â€? hold
  end

  // ===========================================================
  // MEM stage: load data formatting + writeback data selection
  // ===========================================================

  always_comb begin
    // Select byte/halfword from dmem_rdata based on address alignment
    unique case (exmem_alu_y[1:0])
      2'd0: mem_load_byte = dmem_rdata[7:0];
      2'd1: mem_load_byte = dmem_rdata[15:8];
      2'd2: mem_load_byte = dmem_rdata[23:16];
      2'd3: mem_load_byte = dmem_rdata[31:24];
      default: mem_load_byte = dmem_rdata[7:0];
    endcase

    mem_load_half = exmem_alu_y[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    // Sign/zero-extend based on funct3
    unique case (exmem_funct3)
      3'b000: mem_load_data = {{24{mem_load_byte[7]}}, mem_load_byte}; // LB
      3'b001: mem_load_data = {{16{mem_load_half[15]}}, mem_load_half}; // LH
      3'b010: mem_load_data = dmem_rdata;                              // LW
      3'b100: mem_load_data = {24'h0, mem_load_byte};                  // LBU
      3'b101: mem_load_data = {16'h0, mem_load_half};                  // LHU
      default: mem_load_data = dmem_rdata;
    endcase
  end

  // Select final writeback data: load result (MEM) or precomputed EX value
  assign mem_wb_data = (exmem_wb_sel == WB_SRC_MEM) ? mem_load_data : exmem_wb_data;

  // ===========================================================
  // MEM/WB pipeline register
  // ===========================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      memwb_valid  <= 1'b0;
      memwb_wdata  <= 32'h0;
      memwb_rd     <= 5'h0;
      memwb_rf_we  <= 1'b0;
    end else if (!stall) begin
      memwb_valid  <= exmem_valid;
      memwb_wdata  <= mem_wb_data;
      memwb_rd     <= exmem_rd;
      memwb_rf_we  <= exmem_rf_we;
    end
    // else: stall â€? hold
  end

  // WB stage: register file write is handled by the u_rf instance above.
  // we = memwb_rf_we && memwb_valid, waddr = memwb_rd, wdata = memwb_wdata.

endmodule
