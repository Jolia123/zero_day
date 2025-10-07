`timescale 1ns/1ps

// Include paths are usually controlled by tool args; keep minimal includes here
`include "mem_if.sv"

import mem_env_pkg::*;

module top_tb;
  // Clock and reset
  logic clk;
  logic rst_n;

  // Clock gen: 10ns period
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // Reset
  initial begin
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
  end

  // Interface
  mem_if mem_if_i(.clk(clk), .rst_n(rst_n));

  // DUT instance
  memory16x32 dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .en       (mem_if_i.en),
    .addr     (mem_if_i.addr),
    .data_in  (mem_if_i.data_in),
    .data_out (mem_if_i.data_out),
    .valid_out(mem_if_i.valid_out)
  );

  // Environment
  mem_env env;

  initial begin
    env = new(mem_if_i, mem_if_i);
    env.run(64);
    // stop after some time
    repeat (300) @(posedge clk);
    env.report();
    $finish;
  end

endmodule
