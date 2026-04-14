# Vivado Waveform Testbench — tb_rv32_wave

## Purpose
`rv32/tb/tb_rv32_wave.sv` is a self-contained Vivado/xsim testbench that
runs all **37 standard RV32I instructions** in one simulation and exposes
clear waveform markers for each test.

## How to run in Vivado

1. Create or open a Vivado project.
2. Add sources: `rv32/rtl/*.sv` and `rv32/tb/tb_rv32_wave.sv`.
3. Set **tb_rv32_wave** as the simulation top module.
4. Click **Run Simulation → Run Behavioral Simulation**.
5. In the Tcl console: `run 200us` (or click **Run All**).

## Key signals to add to the waveform window

| Signal | Description |
|--------|-------------|
| `tb_rv32_wave.test_id` | Current test number (1–37) |
| `tb_rv32_wave.test_done` | 1-cycle pulse when test_id advances |
| `tb_rv32_wave.dut.imem_addr` | Fetch PC |
| `tb_rv32_wave.dut.imem_rdata` | Fetched instruction word |
| `tb_rv32_wave.dut.u_core.pc_q` | IF-stage PC register |
| `tb_rv32_wave.dut.dmem_valid` | Data memory access |
| `tb_rv32_wave.dut.dmem_we` | 1=store, 0=load |
| `tb_rv32_wave.dut.dmem_addr` | Data address |
| `tb_rv32_wave.dut.dmem_wdata` | Store data |
| `tb_rv32_wave.dut.dmem_rdata` | Load data |

## Test order

1:LUI 2:AUIPC 3:JAL 4:JALR 5:BEQ 6:BNE 7:BLT 8:BGE 9:BLTU 10:BGEU
11:LB 12:LH 13:LW 14:LBU 15:LHU 16:SB 17:SH 18:SW
19:ADDI 20:SLTI 21:SLTIU 22:XORI 23:ORI 24:ANDI 25:SLLI 26:SRLI 27:SRAI
28:ADD 29:SUB 30:SLL 31:SLT 32:SLTU 33:XOR 34:SRL 35:SRA 36:OR 37:AND

## PASS/FAIL detection
- `[TB] PASS` printed when `ram[2] == 1` (all 37 tests completed).
- `[TB] FAIL` printed when `ram[1] == 0xDEADBEEF` (a test failed).
- `[TB] TIMEOUT` if simulation ends with no result.

## Icarus Verilog (iverilog) usage
```bash
cd rv32
iverilog -g2012 -DIVERILOG_SIM -o sim/tb_wave.vvp -I rtl rtl/*.sv tb/tb_rv32_wave.sv
vvp sim/tb_wave.vvp
```

## Notes
- No external hex files or Python scripts are needed.
- The original `tb_rv32.sv` and regression scripts are unchanged.
