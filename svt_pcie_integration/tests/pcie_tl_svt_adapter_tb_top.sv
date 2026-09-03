//------------------------------------------------------------------------------
// TL-root SVT adapter 最小顶层。
//------------------------------------------------------------------------------

module pcie_tl_svt_adapter_tb_top;
  import uvm_pkg::*;
  import host_mem_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5ns clk = ~clk;

  initial begin
    #100ns;
    rst_n = 1'b1;
  end

  // 为 SV_IF_MODE 提供基础 TL virtual interface；真实 DUT 集成时可由
  // 顶层替换为 serial/PIPE 适配后的接口实例。
  pcie_tl_if tl_if(.clk(clk), .rst_n(rst_n));

  // 占位接口保持 ready/credit 为确定值，避免 SV_IF monitor 在门禁测试中
  // 因 X 状态产生无关协议错误。真实 DUT 集成时由物理适配层接管这些信号。
  initial begin
    tl_if.tlp_ready  = 1'b1;
    tl_if.ph_credit  = 8'hff;
    tl_if.pd_credit  = 12'hfff;
    tl_if.nph_credit = 8'hff;
    tl_if.npd_credit = 12'hfff;
    tl_if.cplh_credit = 8'hff;
    tl_if.cpld_credit = 12'hfff;
    tl_if.fc_update  = 1'b0;
    tl_if.tlp_error  = 1'b0;
  end

  host_mem_manager host_mem;
  host_mem_manager dev_mem[16];

  initial begin
    uvm_config_db#(virtual pcie_tl_if)::set(null, "*", "vif", tl_if);

    host_mem = new("host_mem");
    uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env",
                                      "host_mem", host_mem);

    for (int i = 0; i < 16; i++) begin
      dev_mem[i] = new($sformatf("dev_mem_%0d", i));
      uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env",
                                        $sformatf("dev_mem_%0d", i), dev_mem[i]);
    end
  end

  initial run_test();
endmodule
