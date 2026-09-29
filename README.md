# PX32 RISC-V Power MCU

PX32 is a 32-bit RISC-V microcontroller (MCU: a CPU with its memory and peripherals on one chip) designed specifically for the digital control of power electronics: DC-DC converters, power factor correction stages, inverters and motor drives. It pairs a small, fully deterministic in-order core with the peripherals that a switching converter actually needs: high-resolution PWM, ADCs that are triggered by the PWM, fast analog comparators, and a hardware protection path that does not depend on software.

The first target application is an isolated 48 V to 12 V, 500 W converter built with GaN transistors. That design drives the requirements for the chip and serves as the reference for closed-loop verification.

This repository contains the RTL, testbenches and verification scripts. The project is at an early stage. See [Project status](#project-status) for what is implemented and verified today.

## Contents

- [Why a dedicated controller](#why-a-dedicated-controller)
- [Design targets](#design-targets)
- [Architecture](#architecture)
- [How a control cycle works](#how-a-control-cycle-works)
- [Reference application](#reference-application)
- [Project status](#project-status)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Verification approach](#verification-approach)
- [Coding conventions](#coding-conventions)
- [Roadmap](#roadmap)

## Why a dedicated controller

A converter controller has different priorities from a general-purpose microcontroller. What matters is not average throughput but the worst-case delay between sampling a current or voltage and updating the switching waveform. Every nanosecond of that delay is phase lag inside the control loop. Caches, dynamic branch prediction and long uninterruptible instructions all make that delay variable, so PX32 leaves them out.

The second priority is protection. A firmware bug, a stuck bus or a halted debugger must never be able to destroy the power stage. Over-current and over-voltage events therefore shut the PWM outputs down through dedicated hardware, and the CPU is informed afterwards.

## Design targets

These are design targets. They are verified as the corresponding blocks are built, and none should be read as a measured result until the status section says so.

| Target | Value | Reason |
|---|---|---|
| Execution timing | Fixed and data independent on the fast path; no caches, no dynamic branch prediction | Worst-case execution time can be computed by counting cycles |
| Interrupt latency | 6 cycles or fewer from a qualifying control interrupt to the first handler instruction (30 ns at 200 MHz) | Keeps sampling-to-update delay short |
| PWM resolution | Approximately 150 ps programmable edge placement (5 ns counter plus a 32-step delay line) | Fine duty-cycle steps at high switching frequency |
| Hardware protection | Trip path from comparator to PWM outputs that works without the CPU and without the system clock | Software can never be the only line of defence |
| Clock | 200 MHz on a 28 to 40 nm class process, around 100 MHz on FPGA | |

Out of scope: an MMU, caches, out-of-order or superscalar execution, and running a general-purpose operating system.

## Architecture

### Block diagram

```
                 +-------------------------------------------------------+
                 |                       PX32 core                       |
                 | RV32IMC + Zfinx + Zb* + Zicond + CORE-V extensions    |
                 | 4-stage in-order pipeline, 2 register banks           |
                 +----+-------------+-------------+---------------+------+
                      |             |             |               |
                   I-port        D-port      System port  Fast periph. port
                      |             |             |               |
              +-------+----+ +------+-----+       |    +----------+---------------------+
              | ITCM 64 KB | | DTCM A + B |       |    | Control Peripheral Bus (CPB)   |
              | ECC        | | 2 x 32 KB  |       |    | fixed one-cycle response       |
              +------------+ | ECC        |       |    +--------------------------------+
                             +------+-----+       |    | 8x HRPWM (16 outputs)          |
                                    |             |    | 3x 12-bit ADC, post-processing |
                                    | bank B      |    | 8x comparator + DAC + ramp     |
                                    | (DMA)       |    | 4x SDFM, 2x eQEP, 4x eCAP      |
                                    |             |    | CORDIC, signal crossbar        |
                                    |             |    +--------------------------------+
                                    |             |
   +--------------------------------+-------------+-------------------+
   |               System crossbar (OBI-style, 32-bit)                |
   +----+--------------+------------+------------+-------------+------+
        |              |            |            |             |
   +----+-----+  +-----+-----+  +---+---+  +-----+------+  +---+----+
   | Boot ROM |  | Flash     |  | SRAM  |  | DMA        |  | APB    |
   | 32 KB    |  | 512 KB,   |  | 64 KB |  | 6 channels |  | bridge |
   +----------+  | A/B slots |  +-------+  +------------+  +---+----+
                 +-----------+                                 |
   +------------------+                    +-------------------+-----------------+
   | Debug module     |                    | General peripherals (APB)           |
   | JTAG, system bus |                    | CAN-FD, 2x UART, 2x SPI, I2C/PMBus, |
   | access (crossbar |                    | GPIO, timers, windowed watchdog,    |
   | master)          |                    | clock monitor                       |
   +------------------+                    +-------------------------------------+

 Hardwired paths, no CPU involved:
   comparators and ADC limit checks -> signal crossbar -> PWM trip
   PWM events -> ADC start of conversion
   ADC end of conversion -> DMA or interrupt controller
```

### Instruction set

PX32 implements RV32I with the M and C extensions, Zicsr and Zifencei, in machine mode with an optional user mode and 8 PMP regions. The full target adds:

| Extension | Use in control code |
|---|---|
| Zfinx | Single-precision floating point held in the integer registers. There is no separate floating-point register file, which saves area and removes floating-point context saving from interrupt handlers. |
| Zba, Zbb, Zbs | Address generation, `min`/`max` for clamping, bit-field access to peripheral registers |
| Zicond | Branch-free conditional selection, so limiters and anti-windup logic run in constant time |
| CORE-V Xcvhwlp | Zero-overhead hardware loops for filters and averaging |
| CORE-V Xcvmac, Xcvalu | Multiply-accumulate, fixed-point rounding and saturation (Q15/Q31) |
| CORE-V Xcvmem | Post-increment loads and stores for walking sample buffers |

The CORE-V extensions come from the OpenHW Group, which means existing toolchain support rather than a custom instruction set. Upstream GCC 15.2 supports Xcvmac and Xcvalu. Hardware loops and post-increment accesses are emitted with the assembler's `.insn` directive until the compiler supports them.

The first implementation phase builds only RV32IMC with Zicsr and Zifencei. Everything else is added in later phases, and the ISA string the core reports always matches what is actually implemented.

### Pipeline

The core has a 4-stage, in-order, single-issue pipeline:

```
 IF  ->  ID  ->  EX  ->  MEM/WB
```

| Stage | Work |
|---|---|
| IF | Instruction fetch from ITCM or the flash prefetch buffer; realignment and expansion of compressed instructions |
| ID | Decode, register read (three read ports), operand forwarding, jump target calculation, hardware-loop end check |
| EX | ALU, branch resolution, address generation, first multiplier and FPU stages, CSR access |
| MEM/WB | Data memory and fast peripheral access, second multiplier stage, register write-back |

Instructions retire in order, one per cycle at most. Multi-cycle results carry an identity tag, so a result that has been cancelled can never write the register file later. Target timings for isolated operations:

| Operation | Cycles |
|---|---|
| ALU operation | 1 |
| Load from DTCM or the control peripheral bus | 1, plus 1 if the next instruction uses the result |
| Multiply and multiply-accumulate | 1 throughput, 2 latency |
| Taken branch | 3 (resolved in EX, static not-taken) |
| JAL | 2 (resolved in ID) |
| Hardware-loop back edge | 0 |
| Floating-point add, multiply, fused multiply-add | 1 throughput, 3 latency |
| Floating-point divide and square root | 14, fixed |
| Integer divide and remainder | 17, fixed |

Long operations (integer divide, floating-point divide and square root) are abandoned when a control interrupt arrives and restarted after it returns. Interrupt latency therefore does not grow by the length of whatever instruction happened to be executing.

### Register file and fast interrupt context

The integer register file has two complete banks of 31 registers (x0 is hardwired to zero), with three read ports and two write ports. Bank 0 is used by normal code. Bank 1 belongs to the highest interrupt level, which is reserved for the control-loop handler.

When a level 15 interrupt is taken, the core switches banks in hardware instead of saving registers to memory. Because floating point lives in the integer registers (Zfinx), this covers floating-point operands too. The floating-point status register, both hardware-loop contexts and `mscratch` are banked as well. A dedicated one-entry trap frame preserves the interrupted handler's `mepc`, `mcause`, `mtval` and status. Level 15 cannot interrupt itself.

Reads are combinational with write-through: a register written in the current cycle returns its new value on any read port in the same cycle. If both write ports target the same register, port 0 wins.

### Interrupts

Interrupts are handled by a CLIC-style controller with 64 inputs, 16 priority levels, per-source hardware vectoring, nesting and tail chaining. Level 15 is the control level described above.

The latency target applies inside a hardware-enforced operating profile called CONTROL_ACTIVE. In that profile the core may only access memories and peripherals with a fixed, known response time, so no bus transaction can delay a control interrupt. Slow services such as flash and communications are reached through non-blocking mailboxes. Boot and maintenance run with the power stage disarmed, where the latency guarantee does not apply.

A safety NMI is fail-stop. The hardware safe state is asserted first, the cause is recorded, and recovery happens through reset and verified boot rather than by resuming the interrupted code.

### Memory map

| Address | Size | Region | Notes |
|---|---|---|---|
| `0x0000_0000` | 32 KB | Boot ROM | Reset vector, signature verification of firmware images |
| `0x0800_0000` | 512 KB | Flash | Two 240 KB firmware slots, 16 KB boot metadata, 16 KB fault log; ECC, prefetch buffer |
| `0x1000_0000` | 64 KB | ITCM | Single-cycle instruction memory with ECC; time-critical handlers run from here |
| `0x2000_0000` | 32 KB | DTCM bank A | Single-cycle data memory owned by the CPU |
| `0x2000_8000` | 32 KB | DTCM bank B | Shared with DMA, for example for ADC results, without stalling the CPU on bank A |
| `0x2010_0000` | 64 KB | System SRAM | General data and communication buffers |
| `0x4000_0000` | 1 MB | Control Peripheral Bus | PWM, ADC, comparators, SDFM, eQEP, eCAP, CORDIC, signal crossbar |
| `0x5000_0000` | 1 MB | APB peripherals | Communications, GPIO, timers, watchdog, clocks |
| `0xE000_0000` | 64 KB | Interrupt controller and machine timer | |
| `0xF000_0000` | 4 KB | Debug module | |

There are no caches anywhere in the system.

### Buses

All core memory ports use one simple request/grant/response protocol in the style of OBI (`req`, `gnt`, `addr`, `we`, `be`, `wdata`, `rvalid`, `rdata`, `err`). Tightly coupled memories and the control peripheral bus grant immediately and respond in the next cycle.

The fast peripheral port gives the core a dedicated path to the control peripherals. Reading an ADC result or writing a PWM compare register therefore costs the same as a data memory access. This matters because a control handler consists mostly of peripheral reads and writes. A 32-bit crossbar connects the core, DMA and debug module to flash, SRAM and an APB bridge for slower peripherals.

### Control peripherals

| Block | Count | Function |
|---|---|---|
| High-resolution PWM | 8 modules, 16 outputs | 16-bit time base, 4 compare registers, dead-band, shadow registers with synchronised global load, phase-shift chain, trip zones with a per-output safe state, comparator-event actions, leading-edge blanking, synchronous-rectifier diode emulation |
| ADC | 3 | 12-bit SAR, 4 MSPS, 16 inputs each; simultaneous sampling across the three converters; conversions triggered by PWM events; post-processing with limit checks that can trip the PWM |
| Comparator subsystem | 8 | Window comparators with 12-bit reference DACs, a slope-compensation ramp for peak current-mode control, digital filtering |
| Sigma-delta filter (SDFM) | 4 channels | Demodulates isolated sigma-delta modulators, with a fast comparator path |
| eQEP, eCAP | 2, 4 | Encoder interface, edge timestamping, frequency and duty measurement |
| CORDIC | 1 | sin/cos, atan2, magnitude and square root. Non-blocking: every register access completes in one cycle, and software polls a status flag. |
| Signal crossbar | 1 | Programmable routing of GPIO, comparator, ADC-limit and trip signals |

General peripherals: CAN-FD, two UARTs, two SPIs, an I2C interface with SMBus timeouts, PEC and alert response (for PMBus), GPIO, three 32-bit timers, a windowed watchdog on an independent clock, and a 6-channel DMA.

### Safety and security

- The protection path from comparators and ADC limit checks to the PWM trip inputs is asynchronous and excludes the CPU.
- Core lockup, a double fault, watchdog expiry, clock loss or a debug halt force every PWM output into its configured safe state.
- SECDED ECC on the tightly coupled memories, SRAM and flash. A single-bit error is corrected and counted; a double-bit error raises a fault.
- Clock failure detection with fallback to an internal oscillator, brown-out and power-on reset, per-domain reset release.
- Key-protected writes to PWM, trip and clock configuration registers; PMP separates protection code from application code.
- Firmware images are signed (Ed25519) and verified by the boot ROM. A/B slots with a trial boot, confirmation before the anti-rollback counter advances, and automatic fallback.

## How a control cycle works

The sequence below shows one cycle of the reference converter's voltage loop, which runs every second switching period (500 kHz switching, 250 kHz control).

1. The PWM time base reaches its sampling point and triggers the ADC directly in hardware.
2. The ADC samples the output voltage and current. Its end-of-conversion event raises a level 15 interrupt.
3. The core switches to register bank 1 and starts the handler from ITCM, with no registers saved to memory.
4. The handler reads the results through the fast peripheral port, runs a discrete compensator in floating point, adds input-voltage feed-forward and writes the new current reference to the comparator DAC.
5. Between control updates, the inner peak-current loop runs entirely in hardware on every switching cycle. The comparator ends each power-transfer interval when the primary current reaches the reference minus the slope-compensation ramp.
6. New PWM settings take effect at the next synchronised shadow-register load, so all related outputs change in the same cycle.

If an over-current or over-voltage comparator fires at any point, the PWM outputs go to their safe state immediately, without waiting for the core.

## Reference application

The first design built around PX32 is an isolated 48 V to 12 V bus converter:

| Parameter | Value |
|---|---|
| Input | 40 to 60 V (48 V nominal) |
| Output | 12 V, up to 42 A (500 W) |
| Topology | Phase-shifted full bridge with GaN transistors, planar 5:2 transformer, center-tapped synchronous rectification |
| Switching frequency | 500 kHz |
| Isolation | Functional, 1500 VDC |
| Control | PX32 on the secondary side. Peak current-mode control in hardware, output voltage loop in software. |

The controller sits on the output side of the isolation barrier so that it measures the output voltage directly and drives the synchronous rectifiers without isolator delay. The primary gate signals cross the barrier through isolated GaN gate drivers. Primary current is sensed with a current transformer, and input voltage through an isolated sigma-delta modulator read by the SDFM.

For monitoring, each converter speaks PMBus to a local gateway. The gateway translates to MQTT, Modbus TCP, SNMP or Redfish for monitoring systems and a web dashboard. The microcontroller itself is never connected to a network, and all setpoint limits are enforced on the device, so a compromised gateway still cannot drive the converter outside its safe range.

## Project status

The project is in Phase 1, the base core. Implemented and verified so far:

| Block | Status | Evidence |
|---|---|---|
| Build and regression infrastructure | Done | Self-checking runner that requires a clean simulator exit, a PASS line, no error diagnostics and a timeout |
| `px_alu` | Done | 24,118 checks against a SystemVerilog reference model, 238 of 238 functional coverage bins hit, 10,000 vectors from an independent Python model, 6 of 6 injected faults detected; synthesises to 1,290 generic cells with no latches; clean Verilator lint |
| `px_regfile` | Done | 20,766 checks including write-through, collisions, bank switching and asynchronous reset, 329 of 329 coverage bins hit, 7 of 7 injected faults detected; synthesises to exactly 1,984 flip-flops with no latches; clean Verilator lint |
| `px_decoder` | Done | RV32I, M, Zicsr and Zifencei in machine mode. 109,939 checks, including 54,957 vectors from a table-driven golden model that is itself cross-checked against the GNU disassembler with no unexplained differences; 89 of 89 coverage bins hit; 13 of 13 injected faults detected; 296 generic cells, no latches; clean Verilator lint |
| `px_decompressor` | Done | Expands RV32C to 32-bit instructions. Checked exhaustively over all 49,152 compressed encodings (104,328 checks) against a golden model that agrees with the GNU disassembler on every encoding, with the real decoder attached; 14 of 14 injected faults detected; 382 generic cells, no latches; clean Verilator lint |
| Pipeline (fetch, decode, execute, memory and write-back with forwarding and hazards) | Next | |
| CSRs and traps, multiply and divide, compliance tests | Planned | |

Generic gate counts come from technology-independent synthesis. They are useful for tracking size, but they are not timing results. Timing at 200 MHz can only be established with a target library or FPGA and static timing analysis.

## Repository layout

```
rtl/
  pkg/        Shared package: opcodes, CSR addresses, ALU operation codes
  core/       CPU core blocks (ALU, register file, and later decoder, pipeline, CSRs)
  mem/        Memories and flash model
  bus/        Crossbar, APB bridge, control peripheral bus
  irq/        Interrupt controller
  periph/     PWM, ADC interface, comparators, SDFM, communication peripherals
  soc/        Top level
tb/
  unit/       One self-checking testbench per block, plus a source list (.f) for each
  unit/vectors/  Golden vectors generated by independent models
  core/, soc/ Core-level and system-level tests
  models/     Behavioural models of analog parts and the power stage
scripts/      Test runner, regression, synthesis, vector generators, status dashboard
sw/           Startup code, linker scripts, test programs and firmware
```

Source comments refer to internal design documents (architecture, contracts and decision log). Those are maintained separately and are summarised in this README.

## Getting started

### Tools

| Tool | Version used | Purpose |
|---|---|---|
| Icarus Verilog | 12.0 | Simulation (`iverilog -g2012`) |
| GTKWave | 3.3 | Waveform viewing |
| Python | 3.12 | Golden vector generation and the status dashboard (standard library only) |
| OSS CAD Suite | 2026-09-29 | Yosys with the slang SystemVerilog front end for synthesis checks, and Verilator for lint |
| RISC-V GCC (xPack `riscv-none-elf`) | 15.2.0 | Test programs and firmware, from the pipeline phase onward |

The scripts run under Bash (Git Bash on Windows, or any Linux or macOS shell). On Windows the Icarus install directory `C:\iverilog\bin` is added to the path automatically. On other systems, put `iverilog` and `vvp` on the path. The synthesis script looks for the OSS CAD Suite in `C:\oss-cad-suite`; set `OSS_CAD_SUITE` to use a different location.

### Running tests

Run every testbench and print a summary:

```bash
bash scripts/regress.sh
```

Run one testbench, optionally dumping a waveform to `sim/<name>.vcd`:

```bash
bash scripts/run_unit.sh tb_px_regfile +vcd
```

Run synthesis and lint for every block listed in `scripts/synth_targets.txt`:

```bash
bash scripts/synth.sh
```

On Windows, `scripts\regress.ps1` and `scripts\run_unit.ps1` wrap the same scripts for PowerShell. Logs go to `sim/logs/`, synthesis reports to `sim/synth/`, and regression also writes an HTML status page to `sim/dashboard/index.html`.

To regenerate the ALU golden vectors after changing the Python model:

```bash
python scripts/gen_alu_vectors.py
```

## Verification approach

Every block has to pass the same gates before it is considered done:

1. **Self-checking testbench.** The testbench prints PASS or FAIL itself and needs no waveform inspection. It has a cycle limit so a hang cannot pass silently.
2. **Independent reference model.** Results are compared against a model written separately from the RTL. Where practical, a second model in another language (Python) generates golden vectors, so a mistake shared by the RTL and the first model is still caught.
3. **Directed tests with explicit expected values** for every corner case listed in the module header, alongside constrained-random stimulus.
4. **Functional coverage.** Coverage bins are written by hand, since Icarus has no covergroups. Any bin that is not hit fails the test.
5. **Mutation testing.** Realistic bugs are injected into a copy of the RTL to confirm that the testbench detects them.
6. **Synthesis and lint.** Generic Yosys synthesis must complete with no latches and a clean structural check, and Verilator lint must pass with `-Wall`.

At the core level, the plan adds the official RISC-V architectural tests, instruction-by-instruction trace comparison against the Spike reference simulator, and cycle-counting tests for every entry in the timing table. From Phase 5, the firmware runs in closed loop against averaged and switching-level models of the power stage.

## Coding conventions

- SystemVerilog restricted to the subset that Icarus Verilog 12 compiles with `-g2012 -Wall`: `logic`, `always_ff`, `always_comb`, packages, packed structs and enums. No interfaces, classes or concurrent assertions.
- One module per file, named after the module, with the prefix `px_`.
- Single clock `clk_i`. Active-low reset `rst_ni` with asynchronous assertion and synchronised release.
- Port suffixes `_i` and `_o`; registers named `name_q` with next-state `name_d`.
- No latches. Every combinational block assigns every output on every path.
- Every module header states its purpose, interface timing, latency and the corner cases its testbench covers.

## Roadmap

| Phase | Scope |
|---|---|
| 0 | Scaffolding, scripts, regression flow (done) |
| 1 | Base core: RV32IMC, machine mode, tightly coupled memories, architectural compliance (in progress) |
| 2 | Control features: bit manipulation, Zicond, interrupt controller, register bank switching, CORE-V extensions, PMP |
| 3 | Zfinx floating-point unit |
| 4 | SoC infrastructure: crossbar, flash, DMA, timers, ECC, safety supervisor |
| 5 | Control peripherals and closed-loop simulation against the converter model |
| 6 | Communications (PMBus, CAN-FD), secure boot, FPGA prototype |
| 7 | High-resolution PWM delay line, full safety verification, debug, physical implementation |
