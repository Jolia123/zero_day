package mem_env_pkg;
  
  import mem_env_pkg::*; // harmless self-import for consistency when used externally
  
  // Forward declarations
  class mem_transaction; endclass
  class mem_sequencer;   endclass
  class mem_driver;      endclass
  class mem_monitor;     endclass
  class mem_subscriber;  endclass
  class mem_scoreboard;  endclass
  class mem_env;         endclass

  // Transaction contains DUT pins (except clock)
  class mem_transaction;
    // Inputs
    rand bit        en;
    rand bit [3:0]  addr;
    rand bit [31:0] data_in;
    // Outputs
    bit [31:0] data_out;
    bit        valid_out;

    function mem_transaction copy();
      copy = new();
      copy.en        = this.en;
      copy.addr      = this.addr;
      copy.data_in   = this.data_in;
      copy.data_out  = this.data_out;
      copy.valid_out = this.valid_out;
    endfunction

    function string sprint();
      return $sformatf("en=%0b addr=0x%0h din=0x%08x dout=0x%08x valid=%0b",
                       en, addr, data_in, data_out, valid_out);
    endfunction
  endclass

  // Simple directed sequencer
  class mem_sequencer;
    mailbox #(mem_transaction) sq2drv;
    mailbox #(int)             drv_done;

    function new(mailbox #(mem_transaction) sq2drv,
                 mailbox #(int)             drv_done);
      this.sq2drv  = sq2drv;
      this.drv_done = drv_done;
    endfunction

    // Generate N transactions: write addresses 0..15 repeatedly with a pattern
    task run(int num_transactions = 64);
      mem_transaction tr;
      int dummy;
      for (int i = 0; i < num_transactions; i++) begin
        tr = new();
        tr.en      = 1'b1;
        tr.addr    = i % 16;
        tr.data_in = 32'(32'h1000_0000 + i);
        sq2drv.put(tr);
        // wait for driver to complete driving this item
        drv_done.get(dummy);
      end
      // send an idle to separate last transaction
      tr = new();
      tr.en      = 1'b0;
      tr.addr    = '0;
      tr.data_in = '0;
      sq2drv.put(tr);
      drv_done.get(dummy);
    endtask
  endclass

  // Driver: maps transaction inputs onto virtual interface pins
  class mem_driver;
    virtual mem_if.DRV vif;
    mailbox #(mem_transaction) sq2drv;
    mailbox #(int)             drv_done;

    function new(virtual mem_if.DRV vif,
                 mailbox #(mem_transaction) sq2drv,
                 mailbox #(int)             drv_done);
      this.vif      = vif;
      this.sq2drv   = sq2drv;
      this.drv_done = drv_done;
    endfunction

    task run();
      mem_transaction tr;
      // Drive reset values
      vif.drv_cb.en      <= 1'b0;
      vif.drv_cb.addr    <= '0;
      vif.drv_cb.data_in <= '0;

      // Wait for reset deassertion
      @(posedge vif.clk);
      wait (vif.rst_n == 1'b1);

      forever begin
        sq2drv.get(tr);
        // Put on bus for one cycle
        vif.drv_cb.en      <= tr.en;
        vif.drv_cb.addr    <= tr.addr;
        vif.drv_cb.data_in <= tr.data_in;
        @(vif.drv_cb);
        // return to idle for a cycle
        vif.drv_cb.en      <= 1'b0;
        @(vif.drv_cb);
        drv_done.put(1);
      end
    endtask
  endclass

  // Monitor: samples DUT I/O and forwards transactions
  class mem_monitor;
    virtual mem_if.MON vif;
    mailbox #(mem_transaction) mon2scb;
    mailbox #(mem_transaction) mon2sub;

    function new(virtual mem_if.MON vif,
                 mailbox #(mem_transaction) mon2scb,
                 mailbox #(mem_transaction) mon2sub);
      this.vif     = vif;
      this.mon2scb = mon2scb;
      this.mon2sub = mon2sub;
    endfunction

    task run();
      mem_transaction tr;
      @(posedge vif.clk);
      wait (vif.rst_n == 1'b1);
      forever begin
        @(vif.mon_cb);
        tr = new();
        tr.en        = vif.mon_cb.en;
        tr.addr      = vif.mon_cb.addr;
        tr.data_in   = vif.mon_cb.data_in;
        tr.data_out  = vif.mon_cb.data_out;
        tr.valid_out = vif.mon_cb.valid_out;
        // Broadcast only when there is activity to reduce overhead
        if (tr.en || tr.valid_out) begin
          mon2scb.put(tr);
          mon2sub.put(tr.copy());
        end
      end
    endtask
  endclass

  // Subscriber: collects simple coverage on output activity
  class mem_subscriber;
    mailbox #(mem_transaction) mon2sub;

    // Parameterized covergroup that we sample explicitly
    covergroup outputs_cg with function sample(bit valid,
                                              bit [3:0] addr,
                                              bit [31:0] data_out);
      coverpoint valid { bins idle = {0}; bins active = {1}; }
      coverpoint addr iff (valid) { bins all_addrs[] = {[0:15]}; }
      // Keep data coverage light; just look at low byte
      coverpoint data_out[7:0] iff (valid) {
        bins low   = {8'h00};
        bins mid[] = {[8'h01:8'hFE]};
        bins high  = {8'hFF};
      }
      cross valid, addr;
    endgroup

    function new(mailbox #(mem_transaction) mon2sub);
      this.mon2sub = mon2sub;
      this.outputs_cg = new();
    endfunction

    task run();
      mem_transaction tr;
      forever begin
        mon2sub.get(tr);
        outputs_cg.sample(tr.valid_out, tr.addr, tr.data_out);
      end
    endtask
  endclass

  // Scoreboard: checks DUT against a cycle-accurate reference
  class mem_scoreboard;
    mailbox #(mem_transaction) mon2scb;

    bit [31:0] ref_mem [0:15];
    bit [31:0] expected_fifo[$];

    int total_checks;
    int total_errors;

    function new(mailbox #(mem_transaction) mon2scb);
      this.mon2scb = mon2scb;
      this.total_checks = 0;
      this.total_errors = 0;
      // initialize reference memory
      foreach (ref_mem[i]) ref_mem[i] = '0;
    endfunction

    task run();
      mem_transaction tr;
      forever begin
        mon2scb.get(tr);
        // Build expected output stream: when en is seen, push current value
        if (tr.en) begin
          expected_fifo.push_back(ref_mem[tr.addr]);
          ref_mem[tr.addr] = tr.data_in;
        end
        if (tr.valid_out) begin
          bit [31:0] expected;
          if (expected_fifo.size() == 0) begin
            $error("[SCB] valid_out without expectation: %s", tr.sprint());
            total_errors++;
          end else begin
            expected = expected_fifo.pop_front();
            total_checks++;
            if (tr.data_out !== expected) begin
              total_errors++;
              $error("[SCB] MISMATCH: got=0x%08x expected=0x%08x (addr=%0d)",
                     tr.data_out, expected, tr.addr);
            end else begin
              $display("[SCB] Match: data_out=0x%08x", tr.data_out);
            end
          end
        end
      end
    endtask

    function void report();
      $display("[SCB] Checks=%0d Errors=%0d", total_checks, total_errors);
    endfunction
  endclass

  // Environment: wires up all components and launches them
  class mem_env;
    // Components
    mem_sequencer  seqr;
    mem_driver     drv;
    mem_monitor    mon;
    mem_subscriber sub;
    mem_scoreboard scb;

    // Mailboxes
    mailbox #(mem_transaction) sq2drv;
    mailbox #(mem_transaction) mon2scb;
    mailbox #(mem_transaction) mon2sub;
    mailbox #(int)             drv_done;

    function new(virtual mem_if.DRV drv_vif,
                 virtual mem_if.MON mon_vif);
      // Create mailboxes
      sq2drv  = new();
      mon2scb = new();
      mon2sub = new();
      drv_done = new();
      // Instantiate components
      seqr = new(sq2drv, drv_done);
      drv  = new(drv_vif, sq2drv, drv_done);
      mon  = new(mon_vif, mon2scb, mon2sub);
      sub  = new(mon2sub);
      scb  = new(mon2scb);
    endfunction

    task run(int num_transactions = 64);
      fork
        drv.run();
        mon.run();
        sub.run();
        scb.run();
        seqr.run(num_transactions);
      join_none
    endtask

    function void report();
      scb.report();
    endfunction
  endclass

endpackage : mem_env_pkg
