interface pcie_svt_reset_if #(int MAX_LINKS = 5);
  logic [MAX_LINKS-1:0] asserted = '1;

  task automatic hold_all();
    asserted = '1;
  endtask

  task automatic release_all();
    asserted = '0;
  endtask

  task automatic hold_link(int unsigned id);
    if (id >= MAX_LINKS)
      $fatal(1, "reset link index %0d out of range", id);
    else
      asserted[id] = 1'b1;
  endtask

  task automatic release_link(int unsigned id);
    if (id >= MAX_LINKS)
      $fatal(1, "reset link index %0d out of range", id);
    else
      asserted[id] = 1'b0;
  endtask
endinterface
