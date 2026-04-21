`timescale 1ns/1ps

// ============================================================
// tb_rv32
// ------------------------------------------------------------
// RV32I 五级流水线内核测试平台。
//
// 存储器模型（零等待）：
//   - imem_ready = 1, imem_rdata_valid = imem_valid  （组合逻辑）
//   - dmem_ready = 1
//   - dmem_rdata_valid = dmem_valid & ~dmem_we        （组合逻辑）
//   当前核心不处理冒险，因此测试程序会显式插入：
//   - 数据相关气泡：寄存器写后至少 3 条 NOP
//   - 控制延迟槽：分支/跳转后至少 2 条 NOP
//
// PASS/FAIL 约定（与之前一致）：
//   ram[1] == 1           -> PASS
//   ram[1] == 0xDEAD_BEEF -> FAIL
//   timeout               -> TIMEOUT
//
// 用法：
//   vvp sim/tb_rv32.vvp +hex=tests/xxx.hex
// ============================================================
module tb_rv32;

  // ----------------------------
  // 时钟 / 复位
  // ----------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk; // 100 MHz（周期 10 ns）

  // ----------------------------
  // DUT <-> TB 连接
  // ----------------------------
  // IMEM
  wire        imem_valid;
  wire [31:0] imem_addr;
  reg         imem_ready;
  reg         imem_rdata_valid;
  reg  [31:0] imem_rdata;

  // DMEM
  wire        dmem_valid;
  wire        dmem_we;
  wire [3:0]  dmem_wstrb;
  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  reg         dmem_ready;
  reg         dmem_rdata_valid;
  reg  [31:0] dmem_rdata;

  rv32_top dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .imem_valid       (imem_valid),
    .imem_addr        (imem_addr),
    .imem_ready       (imem_ready),
    .imem_rdata_valid (imem_rdata_valid),
    .imem_rdata       (imem_rdata),
    .dmem_valid       (dmem_valid),
    .dmem_we          (dmem_we),
    .dmem_wstrb       (dmem_wstrb),
    .dmem_addr        (dmem_addr),
    .dmem_wdata       (dmem_wdata),
    .dmem_ready       (dmem_ready),
    .dmem_rdata_valid (dmem_rdata_valid),
    .dmem_rdata       (dmem_rdata)
  );

  // ----------------------------
  // ROM / RAM 数组
  // ----------------------------
  reg [31:0] rom [0:255];
  reg [31:0] ram [0:255];
  integer i;

  // ----------------------------
  // 零等待存储器模型
  // ----------------------------
  // IMEM：始终 ready；当 valid 时，rdata_valid 组合拉高。
  // 使用 rst_n 门控，避免复位期间锁存无效数据。
  always @(*) begin
    imem_ready       = 1'b1;
    imem_rdata_valid = rst_n && imem_valid;  // 零等待：同周期数据有效
    imem_rdata       = rom[imem_addr[9:2]];
  end

  // DMEM：始终 ready；加载时 rdata_valid 组合拉高。
  // 使用 rst_n 门控，避免复位期间出现伪有效信号。
  always @(*) begin
    dmem_ready       = 1'b1;
    dmem_rdata_valid = rst_n && dmem_valid & ~dmem_we; // 仅加载
    dmem_rdata       = ram[dmem_addr[9:2]];
  end

  // RAM 写入：时钟沿写，带字节使能
  always @(posedge clk) begin
    if (dmem_valid && dmem_we) begin
      integer wi;
      reg [31:0] cur;
      wi  = dmem_addr[9:2];
      cur = ram[wi];
      if (dmem_wstrb[0]) cur[7:0]   = dmem_wdata[7:0];
      if (dmem_wstrb[1]) cur[15:8]  = dmem_wdata[15:8];
      if (dmem_wstrb[2]) cur[23:16] = dmem_wdata[23:16];
      if (dmem_wstrb[3]) cur[31:24] = dmem_wdata[31:24];
      ram[wi] <= cur;
    end
  end

  // ----------------------------
  // 程序加载与仿真控制
  // ----------------------------
  reg [1023:0] hex_path;

  initial begin
    for (i = 0; i < 256; i = i + 1) begin
      rom[i] = 32'h00000013; // NOP
      ram[i] = 32'h0;
    end

    // 从 +hex= 参数加载 hex（默认 tests/addi.hex，便于手工运行）
    if (!$value$plusargs("hex=%s", hex_path)) begin
      hex_path = "tests/addi.hex";
    end

    $display("[TB] loading program: %0s", hex_path);
    $readmemh(hex_path, rom);

    // 复位序列
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // 最多运行 5000 周期；检查 ram[1] 中的 PASS/FAIL 标记
    repeat (5000) begin
      @(posedge clk);
      if (ram[1] == 32'h1) begin
        $display("[TB] PASS: ram[0]=%h ram[1]=%h", ram[0], ram[1]);
        $finish;
      end
      if (ram[1] == 32'hDEAD_BEEF) begin
        $display("[TB] FAIL: ram[0]=%h ram[1]=%h", ram[0], ram[1]);
        $finish;
      end
    end

    $display("[TB] TIMEOUT: ram[0]=%h ram[1]=%h", ram[0], ram[1]);
    $finish;
  end

  initial begin
    $dumpfile("sim/tb_rv32.vcd");
    $dumpvars(0, tb_rv32);
  end

endmodule
