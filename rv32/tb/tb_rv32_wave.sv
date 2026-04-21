`timescale 1ns/1ps
`include "rv32_pkg.svh"

// ============================================================
// tb_rv32_wave
// ------------------------------------------------------------
// 适配 Vivado/xsim 的 RV32I 五级流水线测试平台。
//
// 目的：
//   - 单次运行展示全部 37 条标准 RV32I 指令的波形。
//   - ROM 初始化由 gen_tests.py 生成的 include 文件直接内嵌。
//   - 导出 test_id（1..37）与 test_done 脉冲用于波形观察。
//
// 存储器约定：
//   ram[1]（字节地址 0x04）：进度标记（test_id 1..37），失败时为 0xDEADBEEF。
//   ram[2]（字节地址 0x08）：37 项测试全部通过时置 1。
//
// 建议加入 Vivado 波形窗口的信号：
//   tb_rv32_wave.test_id          -- 当前测试编号（1..37）
//   tb_rv32_wave.test_done        -- 每次 test_id 递增时给出 1 周期脉冲
//   tb_rv32_wave.dut.imem_addr    -- 取指 PC
//   tb_rv32_wave.dut.imem_rdata   -- 取到的指令字
//   tb_rv32_wave.dut.u_core.pc_q  -- PC 寄存器（流水 IF 级）
//   tb_rv32_wave.dut.dmem_valid   -- 数据存储访问使能
//   tb_rv32_wave.dut.dmem_we      -- 1=存储，0=加载
//   tb_rv32_wave.dut.dmem_addr    -- 数据地址
//   tb_rv32_wave.dut.dmem_wdata   -- 存储数据
//   tb_rv32_wave.dut.dmem_rdata   -- 加载数据（来自 RAM）
//
// Vivado 使用方法：
//   1. 将 rv32/rtl/*.sv 与 rv32/tb/tb_rv32_wave.sv 加入工程源文件。
//   2. 将 tb_rv32_wave 设为仿真顶层。
//   3. 运行 Simulation -> Run All（或 Tcl 控制台执行 'run 200us'）。
//   4. 将上述信号添加到波形窗口。
//   可使用 test_done 脉冲作为测试分段的自然标记。
//
// PASS/FAIL 输出：
//   [TB] PASS    -- 全部 37 项测试成功完成。
//   [TB] FAIL    -- 某项测试失败（ram[1] == 0xDEADBEEF）。
//   [TB] TIMEOUT -- 仿真超过 MAX_CYCLES 仍无结果。
// ============================================================
module tb_rv32_wave;

  // -------------------------------------------------------------------
  // 时钟 / 复位
  // -------------------------------------------------------------------
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk; // 100 MHz，周期 10 ns

  // -------------------------------------------------------------------
  // DUT <-> TB 连接
  // -------------------------------------------------------------------
  wire        imem_valid;
  wire [31:0] imem_addr;
  reg         imem_ready;
  reg         imem_rdata_valid;
  reg  [31:0] imem_rdata;

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

  // -------------------------------------------------------------------
  // 指令 ROM（2K words）与数据 RAM（1 KiB）
  // -------------------------------------------------------------------
  reg [31:0] rom [0:2047];
  reg [31:0] ram [0:255];
  integer    i;

  // -------------------------------------------------------------------
  // 零等待存储器模型
  // -------------------------------------------------------------------
  always @(*) begin
    imem_ready       = 1'b1;
    imem_rdata_valid = rst_n && imem_valid;
    imem_rdata       = rom[imem_addr[12:2]];
  end

  always @(*) begin
    dmem_ready       = 1'b1;
    dmem_rdata_valid = rst_n && dmem_valid & ~dmem_we;
    dmem_rdata       = ram[dmem_addr[9:2]];
  end

  always @(posedge clk) begin
    if (dmem_valid && dmem_we) begin : ram_write_blk
      integer   wi;
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

  // -------------------------------------------------------------------
  // 波形可见性：test_id 与 test_done
  // -------------------------------------------------------------------
  integer    test_id;
  reg        test_done;
  reg [31:0] last_ram1;

  initial begin
    test_id   = 0;
    test_done = 1'b0;
    last_ram1 = 32'h0;
  end

  always @(posedge clk) begin
    test_done <= 1'b0;
    if (ram[1] !== last_ram1) begin
      last_ram1 <= ram[1];
      if (ram[1] > 0 && ram[1] <= 37) begin
        test_id   <= ram[1];
        test_done <= 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------
  // 仿真控制
  // -------------------------------------------------------------------
  localparam integer MAX_CYCLES = 20000;

  initial begin
    for (i = 0; i < 2048; i = i + 1) rom[i] = 32'h00000013;
    for (i = 0; i <  256; i = i + 1) ram[i] = 32'h0;

    // -------------------------------------------------------------------
    // 内嵌指令程序由 gen_tests.py 生成。
    // ram[1] = 每项测试完成后的当前 test_id（1..37）
    // ram[2] = 全部通过时置 1；失败时 ram[1] = 0xDEADBEEF
    // -------------------------------------------------------------------
`include "tb_rv32_wave_rom_init.vh"

    // -------------------------------------------------------------------
    // 复位并运行
    // -------------------------------------------------------------------
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    repeat (MAX_CYCLES) begin
      @(posedge clk);
      if (ram[2] == 32'h1) begin
        $display("[TB] PASS: all 37 RV32I tests completed, test_id=%0d", test_id);
        $finish;
      end
      if (ram[1] == 32'hDEADBEEF) begin
        $display("[TB] FAIL: last passing test=%0d, ram[1]=0x%08h", test_id, ram[1]);
        $finish;
      end
    end
    $display("[TB] TIMEOUT: test_id=%0d ram[1]=0x%08h ram[2]=0x%08h",
             test_id, ram[1], ram[2]);
    $finish;
  end

`ifdef IVERILOG_SIM
  initial begin
    $dumpfile("sim/tb_rv32_wave.vcd");
    $dumpvars(0, tb_rv32_wave);
  end
`endif

endmodule