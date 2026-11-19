# RISC-V pipelined CPU (RV32I + Zicsr) on FPGA

A 5-stage pipelined RV32I processor in VHDL-2008 for the Nexys A7-100T,
with full hazard control, branch prediction and precise interrupts from
physical inputs. Project for Advanced Logic Design, Università di Trento.

## Features

- Classic 5-stage pipeline IF – ID – EX – MEM – WB (Hennessy & Patterson
  register names), Harvard Block RAM memories (4 KiB code, 16 KiB data)
- Data hazards in hardware: forwarding from EX/MEM and MEM/WB, write-through
  register file, 1-cycle load-use stall. Bubbles are empty slots (valid = 0,
  all control signals off): no filler instructions are needed in software
- Control hazards: branches resolved in MEM, 3-cycle flush on a
  misprediction, 16-entry branch target buffer with 2-bit counters and tags
- Precise external interrupts (Zicsr: `mstatus`, `mie`, `mtvec`, `mscratch`,
  `mepc`, `mcause`, `mip`, `misa`, `mret`), taken on the instruction in EX
- Interrupt controller: UART RX (level), BTNC and SW5 (edge, write-1-to-clear),
  `irq = OR(IRQ_PENDING and IRQ_ENABLE)`
- Peripherals: UART with 16-byte FIFOs (115200 baud, RX also on Pmod JA1 for
  an ESP32), I²C master for the on-board ADT7420 temperature sensor, 8-digit
  7-segment display, LEDs, switches, debounced buttons
- Hardware counters (cycles, instructions, stalls, flushes, branches)
- Debug mode on the board: SW15 freezes the CPU, BTNU steps one cycle, SW14
  slow motion; the display shows the instructions in ID, EX, MEM, WB
- Optional Vivado ILA (generic `USE_ILA`), with a register-write mode
  (`ILA_WB`) to compare the board with the simulation instruction by
  instruction

## Repository

| Path | Content |
| --- | --- |
| `rtl/core/` | the CPU: pipeline, decoder, ALU, forwarding and hazard units, branch predictor, CSR unit, register file |
| `rtl/mem/` | instruction and data memories (Block RAM, initialised from `.hex` files) |
| `rtl/io/` | peripherals and interrupt controller (`io_ctrl`), UART, I²C, display, debouncer, FIFO |
| `rtl/soc.vhd`, `rtl/fpga_top.vhd` | system on chip and FPGA top level (clock 100 → 50 MHz with an MMCM) |
| `constraints/nexys_a7.xdc` | pins and clock of the Nexys A7-100T |
| `tb/tb_soc.vhd` | system testbench: the whole SoC with models of the UART host, the ESP32, the temperature sensor (`adt7420_model.vhd`), buttons, switches and display, plus an I²C timing checker (`i2c_timing_check.vhd`) |
| `program/irq_alu.imem.hex`, `program/irq_alu.dmem.hex` | the demo program for the instruction and data memories (one 32-bit hex word per line) |
| `esp32/rand_sender/` | ESP32-S3 firmware (PlatformIO) that sends a random number every second to Pmod JA1 |

## Simulation

The testbench loads the program image given by `IMEM_FILE` / `DMEM_FILE`
(text files with one 32-bit hex word per line), for example the demo program
in `program/`. With GHDL:

```sh
ghdl -i --std=08 rtl/core/*.vhd rtl/mem/*.vhd rtl/io/*.vhd rtl/soc.vhd tb/*.vhd
ghdl -m --std=08 tb_soc
ghdl -r --std=08 tb_soc -gIMEM_FILE=program/irq_alu.imem.hex -gDMEM_FILE=program/irq_alu.dmem.hex \
     -gSW_INIT=12800 -gSW5_AT=3000 -gEXPECT_SEG7=200.40000 -gMAX_CYCLES=20000
```

The example sets the switches to 200 (SW13..SW6), raises SW5 and passes when
the display shows `200.40000` (200 and 200²). The testbench reports PASS / FAIL (from the `TOHOST` register), the cycle,
instruction, stall and flush counts, the CPI and all 32 registers. Generics
select the stimuli (`RX_TEXT`, `BTNC_AT`, `SW5_AT`, `SW_INIT`, `TEMP_RAW`),
the expected display text (`EXPECT_SEG7`) and an instruction trace (`TRACE`).

In the Vivado simulator (XSim), in a project created as in the next
section, add the testbench to the simulation set and give it the program:

```tcl
add_files -fileset sim_1 [glob $root/tb/*.vhd]
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] *.vhd]
set_property top tb_soc [get_filesets sim_1]
set_property generic "IMEM_FILE=\"$root/program/irq_alu.imem.hex\" DMEM_FILE=\"$root/program/irq_alu.dmem.hex\" SW_INIT=12800 SW5_AT=3000 EXPECT_SEG7=\"200.40000\" MAX_CYCLES=20000" [get_filesets sim_1]
set_property -name xsim.simulate.runtime -value all -objects [get_filesets sim_1]
launch_simulation
```

## FPGA

The files are enough to build the bitstream. In the Vivado Tcl console, from
the folder of the cloned repository:

```tcl
set root [pwd]
create_project riscv_cpu $root/vivado -part xc7a100tcsg324-1 -force
add_files [glob $root/rtl/*.vhd $root/rtl/*/*.vhd]
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top fpga_top [current_fileset]
set_property generic "IMEM_FILE=\"$root/program/irq_alu.imem.hex\" DMEM_FILE=\"$root/program/irq_alu.dmem.hex\"" [current_fileset]
add_files -fileset constrs_1 $root/constraints/nexys_a7.xdc
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

Two settings matter: the files must be compiled as **VHDL-2008**, and the two
`.hex` paths must be absolute, because the memories read them during
synthesis. The bitstream is in `vivado/riscv_cpu.runs/impl_1/fpga_top.bit`.

Results (Vivado, xc7a100t, 50 MHz): timing met with WNS = +3.25 ns
(f<sub>max</sub> ≈ 60 MHz), 1723 LUTs (2.7 %), 1347 flip-flops (1.1 %),
5 RAMB36, 0.231 W estimated.

## ESP32

Wiring: ESP32-S3 GPIO17 (TX) → Pmod JA pin 1, GND → Pmod JA pin 5.
`cd esp32/rand_sender && pio run -t upload`.

## License

MIT, see `LICENSE`.
