// ============================================================
// rv32_regfile
// ------------------------------------------------------------
// 功能:
//   RV32I 32x32 寄存器堆（x0~x31）。
//   - 2 读端口：组合读（异步读），并带同周期写后读旁路
//   - 1 写端口：时钟上升沿写入
//
// 关键规则:
//   - x0 恒为 0：读取 x0 永远返回 0；写入 x0 会被屏蔽。
// ============================================================
module rv32_regfile (
  input  logic        clk,    // 时钟：写端口在 posedge 更新
  input  logic        we,     // 写使能
  input  logic [4:0]  waddr,  // 写地址（rd）
  input  logic [31:0] wdata,  // 写数据
  input  logic [4:0]  raddr1, // 读地址1（rs1）
  input  logic [4:0]  raddr2, // 读地址2（rs2）
  output logic [31:0] rdata1, // 读数据1
  output logic [31:0] rdata2  // 读数据2
);
  // 32 个 32 位寄存器
  logic [31:0] regs [31:0];

  // 读端口：组合读（注意：x0 强制为 0）
  always_comb begin
    if (raddr1 == 0) begin
      rdata1 = 32'h0;
    end else if (we && (waddr == raddr1) && (waddr != 0)) begin
      rdata1 = wdata;
    end else begin
      rdata1 = regs[raddr1];
    end

    if (raddr2 == 0) begin
      rdata2 = 32'h0;
    end else if (we && (waddr == raddr2) && (waddr != 0)) begin
      rdata2 = wdata;
    end else begin
      rdata2 = regs[raddr2];
    end
  end

  // 写端口：时序写（注意：禁止写 x0）
  always_ff @(posedge clk) begin
    if (we && (waddr != 0)) begin
      regs[waddr] <= wdata;
    end
  end
endmodule