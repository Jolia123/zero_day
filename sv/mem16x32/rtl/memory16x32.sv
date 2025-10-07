// 16x32 single-port synchronous memory with enable
module memory16x32 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [3:0]  addr,
  input  logic [31:0] data_in,
  output logic [31:0] data_out,
  output logic        valid_out
);

  logic [31:0] mem_array [0:15];
  logic [31:0] read_data_q;
  logic        valid_q;

  // Simple model: when en is high, write and read same cycle; data_out valid next cycle
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_data_q <= '0;
      valid_q     <= 1'b0;
    end else begin
      if (en) begin
        mem_array[addr] <= data_in; // write
        read_data_q     <= mem_array[addr]; // read previous value at addr
        valid_q         <= 1'b1;
      end else begin
        read_data_q <= '0;
        valid_q     <= 1'b0;
      end
    end
  end

  assign data_out  = read_data_q;
  assign valid_out = valid_q;

endmodule
