`timescale 1ns/1ps

// ============================================================
// rv32_top
// ------------------------------------------------------------
// 顶层封装模块：实例化 rv32_core，并将全部
// 指令/数据存储器端口（含 ready/valid 信号）
// 暴露给测试平台或 SoC 集成层。
// ============================================================
module rv32_top (
  input  wire        clk,
  input  wire        rst_n,

  // 指令存储器端口
  output wire        imem_valid,        // 内核请求取指
  output wire [31:0] imem_addr,         // 取指地址（字节地址）
  input  wire        imem_ready,        // 存储器接受请求
  input  wire        imem_rdata_valid,  // 指令数据有效
  input  wire [31:0] imem_rdata,        // 指令字

  // 数据存储器端口
  output wire        dmem_valid,        // 内核请求数据访问
  output wire        dmem_we,           // 1=写存储，0=读加载
  output wire [3:0]  dmem_wstrb,        // 字节写使能（小端）
  output wire [31:0] dmem_addr,         // 数据地址（字节地址）
  output wire [31:0] dmem_wdata,        // 写数据
  input  wire        dmem_ready,        // 存储器接受请求
  input  wire        dmem_rdata_valid,  // 读数据有效（加载）
  input  wire [31:0] dmem_rdata         // 读数据
);

  rv32_core u_core (
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

endmodule
