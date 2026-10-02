// tb_core_random_long: tb_core on the long random programs (tb/core/programs/list_random_long.txt,
// sources in sw/tests/random_long from scripts/gen_random_programs.py --long, at least 10,000
// retirements each; step 1.9). Every retirement and trap is compared with the reference model
// scripts/px_iss.py; see tb_core.sv. The same programs are compared with Spike by
// scripts/compliance/run_trace_compare.py. A separate bench keeps tb_core_random within its
// wall-clock limit.

`timescale 1ns/1ps

module tb_core_random_long;
  tb_core #(.LIST("tb/core/programs/list_random_long.txt"), .RANDOM_SET(1),
            .NAME("tb_core_random_long")) u_tb ();
endmodule
