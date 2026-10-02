// tb_core_random: tb_core on the generated random programs (tb/core/programs/list_random.txt,
// sources in sw/tests/random from scripts/gen_random_programs.py). Every retirement and
// trap is compared with the reference model scripts/px_iss.py; see tb_core.sv.

`timescale 1ns/1ps

module tb_core_random;
  tb_core #(.LIST("tb/core/programs/list_random.txt"), .RANDOM_SET(1), .NAME("tb_core_random")) u_tb ();
endmodule
