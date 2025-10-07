interface mem_if (
  input logic clk,
  input logic rst_n
);
  // DUT pins
  logic        en;
  logic [3:0]  addr;
  logic [31:0] data_in;
  logic [31:0] data_out;
  logic        valid_out;

  // Driver clocking block to avoid races
  clocking drv_cb @(posedge clk);
    default input #1step output #1step;
    output en, addr, data_in;
    input  data_out, valid_out;
  endclocking

  // Monitor clocking block to sample all pins
  clocking mon_cb @(posedge clk);
    default input #1step output #1step;
    input en, addr, data_in, data_out, valid_out;
  endclocking

  // Modports for typed virtual interface access
  modport DRV (clocking drv_cb, input clk, input rst_n);
  modport MON (clocking mon_cb, input clk, input rst_n);

endinterface
