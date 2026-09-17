//------------------------------------------------------------------------------
// 所属层次：tests；可选 AIP sequence 库的真实 Serial 双向数据门禁。
// 依赖 formal_link_test 的 FULL_VIP/TL 配置、AIP Tcl bridge 及通用命令库。
// 不启动基类 run_phase，不自动发业务流量：所有建链、配置和内存访问均由
// Tcl 注册命令触发。test 拥有 observer/Host buffer，静态 context 只借用；
// observer 从接收端 monitor 记录实际穿过 Serial 的请求，而非请求端日志。
// test-local pair_check 只初始化/检查 backing 和状态，不代替通用 seq 发包。
// 最后两向读并行运行同一 access body；门禁必须核对两个命令的独立结果，
// 防止一端的 timeout 清理误杀另一端后，被默认 OK 或 fork 汇总掩盖。
//------------------------------------------------------------------------------
`ifndef PCIE_SVT_AIP_CMD_TEST_SV
`define PCIE_SVT_AIP_CMD_TEST_SV

import aip_core_pkg::*;

// 保留接收端的独立 TLP 副本；Completion 单独计数，避免读回成功但请求路径
// 未实际经过另一侧 Serial 的假通过。队列由一次仿真独占，结束后随 test 释放。
class pcie_aip_rx_observer extends uvm_subscriber #(pcie_tl_tlp);
  `uvm_component_utils(pcie_aip_rx_observer)
  pcie_tl_tlp requests[$];
  int unsigned completions;

  // 创建 subscriber；analysis_export 由基类构造，队列初始为空。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 在 monitor 发布时复制有效对象，不修改 responder 使用的原始请求。
  virtual function void write(pcie_tl_tlp t);
    pcie_tl_tlp saved;
    if (t == null)
      `uvm_fatal("SVT_AIP_CMD", "observer received null TLP")
    if (t.get_category() == TLP_CAT_COMPLETION) begin
      completions++;
      return;
    end
    if (!$cast(saved, t.clone()))
      `uvm_fatal("SVT_AIP_CMD", "observer cannot clone received TLP")
    requests.push_back(saved);
  endfunction
endclass

// 用户注册处持有目标句柄，通用 seq 不知道 env 层次或 host/rc 下标。
// endpoint 的 64 位稀疏内存与 Root 的 allocated Host memory 独立，防止
// 两端不小心共用 backing 后“未过链路也能读到刚写数据”。
class pcie_aip_cmd_context;
  static uvm_sequencer_base control_sqr;
  static uvm_sequencer_base rc_tl_sqr;
  static uvm_sequencer_base ep_tl_sqr;
  static uvm_sequencer_base rc_dl_sqr;
  static uvm_sequencer_base ep_dl_sqr;
  static pcie_tl_env tl_env;
  static host_mem_manager root_mem;
  static pcie_aip_rx_observer root_rx;
  static pcie_aip_rx_observer ep_rx;
  static bit [63:0] host_addr;
  static bit [63:0] endpoint_addr = 64'h0000_0001_8000_4000;
  static int checkpoint_root;
  static int checkpoint_ep;
  static bit setup_done;
  static bit rejection_checked;
  static bit parallel_read_checked;
  static bit completed;
endclass

// 测试控制命令不属于生产 API；它核对 Tcl 无法直接安全访问的接收字段、
// 稀疏/Host backing 和收包计数。参数错误用 FATAL 终止门禁，不伪造成功。
class pcie_aip_pair_check_seq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_aip_pair_check_seq)

  // UVM 命名由 aip_cmd_user_seq 提供，命令句柄按实例名查找。
  function new(string name = "pcie_aip_pair_check_seq");
    super.new(name);
  endfunction

  // 比较实际接收 payload 与地址递增的十六进制字节串；不依赖 endian 数值。
  function void check_payload(pcie_tl_tlp t, string expected);
    string actual;
    actual = "";
    foreach (t.payload[i]) actual = {actual, $sformatf("%02h", t.payload[i])};
    if (actual != expected)
      `uvm_fatal("SVT_AIP_CMD", $sformatf(
        "received payload mismatch got=%s expected=%s", actual, expected))
  endfunction

  // 校验 config 在 EP 实际收到的 BDF、字节偏移转换、BE 和 requester。
  // kind 同时验证 Type0；offset>>2 必须恰好落到正确 DWORD。
  function void check_cfg(int index, tlp_kind_e kind, bit [11:0] offset,
                          bit [3:0] first_be, string payload = "");
    pcie_tl_cfg_tlp t;
    if (!$cast(t, pcie_aip_cmd_context::ep_rx.requests[index]))
      `uvm_fatal("SVT_AIP_CMD", "expected received configuration TLP")
    if ((t.kind != kind) || (t.completer_id != 16'h0100) ||
        (t.reg_num != (offset >> 2)) || (t.first_be != first_be) ||
        (t.requester_id != 0) || (t.tc != 0) || (t.length != 1))
      `uvm_fatal("SVT_AIP_CMD", $sformatf("config field mismatch index=%0d %s",
        index, t.convert2string()))
    check_payload(t, payload);
  endfunction

  // 校验两端收到的 wire-aligned 地址、长度、BE、属性及完整 raw payload。
  // 不检查自动分配 tag 的固定值，tag 生命周期仍由生产 driver 管理。
  function void check_mem(pcie_aip_rx_observer observer, int index,
                          tlp_kind_e kind, bit [63:0] addr, int length_dw,
                          bit [3:0] first_be, bit [3:0] last_be,
                          bit [15:0] requester, string payload = "",
                          bit [2:0] expected_attr = 0);
    pcie_tl_mem_tlp t;
    if (!$cast(t, observer.requests[index]))
      `uvm_fatal("SVT_AIP_CMD", "expected received memory TLP")
    if ((t.kind != kind) || (t.addr != addr) || (t.length != length_dw) ||
        (t.first_be != first_be) || (t.last_be != last_be) ||
        (t.requester_id != requester) || (t.tc != 0) || (t.attr != expected_attr))
      `uvm_fatal("SVT_AIP_CMD", $sformatf("memory field mismatch index=%0d %s attr=%h",
        index, t.convert2string(), t.attr))
    if (t.is_64bit != (addr[63:32] != 0))
      `uvm_fatal("SVT_AIP_CMD", "Memory header format does not match address range")
    check_payload(t, payload);
  endfunction

  // 最终门禁精确检查两向所有请求，而非只看计数；检查 posted writes 实际
  // 修改 backing 的内容，同时必须观察到反向 Completion 才能报告通过。
  function void check_all_received();
    pcie_aip_rx_observer ep;
    pcie_aip_rx_observer rc;
    bit [63:0] ea;
    bit [63:0] ha;
    byte host_back[];
    string host_hex;
    string ep_hex;

    ep = pcie_aip_cmd_context::ep_rx;
    rc = pcie_aip_cmd_context::root_rx;
    ea = pcie_aip_cmd_context::endpoint_addr;
    ha = pcie_aip_cmd_context::host_addr;
    if ((ep.requests.size() != 12) || (rc.requests.size() != 6))
      `uvm_fatal("SVT_AIP_CMD", $sformatf(
        "unexpected Serial request counts ep=%0d root=%0d expected=12/6",
        ep.requests.size(), rc.requests.size()))

    check_cfg(0, TLP_CFG_RD0, 12'h000, 4'hf);
    check_cfg(1, TLP_CFG_WR0, 12'h004, 4'h3, "07000000");
    check_cfg(2, TLP_CFG_RD0, 12'h004, 4'hf);
    check_cfg(3, TLP_CFG_WR0, 12'h100, 4'hf, "44332211");
    check_cfg(4, TLP_CFG_WR0, 12'h100, 4'h5, "ddccbbaa");
    check_cfg(5, TLP_CFG_RD0, 12'h100, 4'hf);
    check_mem(ep, 6, TLP_MEM_WR, ea, 4, 4'hf, 4'hf, 0,
              "000102030405060708090a0b0c0d0e0f");
    check_mem(ep, 7, TLP_MEM_WR, ea, 2, 4'he, 4'h3, 0,
              "00a0a1a2a3a40000");
    check_mem(ep, 8, TLP_MEM_RD, ea, 4, 4'hf, 4'hf, 0);
    check_mem(ep, 9, TLP_MEM_WR, ea, 2, 4'he, 4'h3, 0,
              "1020304050607080", 3'b101);
    check_mem(ep, 10, TLP_MEM_RD, ea, 2, 4'he, 4'h3, 0);
    check_mem(ep, 11, TLP_MEM_RD, ea, 4, 4'hf, 4'hf, 0);

    check_mem(rc, 0, TLP_MEM_WR, ha, 4, 4'hf, 4'hf, 16'h0100,
              "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf");
    check_mem(rc, 1, TLP_MEM_WR, ha, 2, 4'hc, 4'h7, 16'h0100,
              "0000d0d1d2d3d400");
    check_mem(rc, 2, TLP_MEM_RD, ha, 4, 4'hf, 4'hf, 16'h0100);
    check_mem(rc, 3, TLP_MEM_WR, ha, 2, 4'hc, 4'hf, 16'h0100,
              "1122334455667788", 3'b101);
    check_mem(rc, 4, TLP_MEM_RD, ha, 2, 4'hc, 4'hf, 16'h0100);
    check_mem(rc, 5, TLP_MEM_RD, ha, 4, 4'hf, 4'hf, 16'h0100);

    pcie_aip_cmd_context::root_mem.read_mem(ha, 16, host_back);
    host_hex = "";
    foreach (host_back[i]) host_hex = {host_hex, $sformatf("%02h", host_back[i])};
    ep_hex = "";
    for (int i = 0; i < 16; i++) begin
      if (!pcie_aip_cmd_context::tl_env.ep_agent.ep_driver.mem_space.exists(ea+i))
        `uvm_fatal("SVT_AIP_CMD", "EP sparse backing byte was not written")
      ep_hex = {ep_hex, $sformatf("%02h",
        pcie_aip_cmd_context::tl_env.ep_agent.ep_driver.mem_space[ea+i])};
    end
    if (host_hex != "c0c1334455667788c8c9cacbcccdcecf")
      `uvm_fatal("SVT_AIP_CMD", {"Root posted-write backing mismatch: ", host_hex})
    if (ep_hex != "002030405060060708090a0b0c0d0e0f")
      `uvm_fatal("SVT_AIP_CMD", {"EP posted-write backing mismatch: ", ep_hex})
    if ((rc.completions < 9) || (ep.completions < 3))
      `uvm_fatal("SVT_AIP_CMD", "missing observed reverse Serial Completions")
    if (pcie_aip_cmd_context::tl_env.ep_agent.cfg_mgr.read(12'h100) != 32'h11bb33dd)
      `uvm_fatal("SVT_AIP_CMD", "configuration byte-enable backing mismatch")
  endfunction

  // fork 的父结果只有汇总，不能据此证明两个子 sequence 都收到 Completion。
  // 从真实注册句柄检查 SC 和完整读回字节；默认 OK、缺失数据或非零状态
  // 都是失败。返回原始结果给 Tcl 重用原有 data 断言，不重新合成成功文本。
  function string check_parallel_read(string command_name, string expected_data);
    aip_cmd command;
    command = aip_cmd::get_handle(command_name);
    if (command == null)
      `uvm_fatal("SVT_AIP_CMD", {"missing parallel read command: ", command_name})
    if ((command.status != 0) ||
        (aip_str::str_find(command.result_out, "COMPLETED cpl_status=SC ") != 0) ||
        (aip_cmd::get_arg(command.result_out, "data") != expected_data))
      `uvm_fatal("SVT_AIP_CMD", $sformatf(
        "parallel read incomplete command=%s status=%0d result=%s expected_data=%s",
        command_name, command.status, command.result_out, expected_data))
    return command.result_out;
  endfunction

  // setup 只分配并清零 Host buffer；checkpoint/rejected 检查负参没有发包；
  // parallel_rc/parallel_ep 只回传对应命令的原始读结果，不产生额外请求；
  // final 同时检查两个并行读的独立结果、全部接收请求并释放 Host allocation。
  task body();
    aip_cmd h;
    string stage;
    byte zeros[];
    h = aip_cmd::get_handle(get_name());
    if (h == null)
      `uvm_fatal("SVT_AIP_CMD", "test control handle is null")
    stage = aip_cmd::get_arg(h.args_in, "stage");
    case (stage)
      "setup": begin
        if (pcie_aip_cmd_context::setup_done)
          `uvm_fatal("SVT_AIP_CMD", "duplicate setup")
        #10us;
        pcie_aip_cmd_context::host_addr = pcie_aip_cmd_context::root_mem.alloc(64, 64);
        if (pcie_aip_cmd_context::host_addr == '1)
          `uvm_fatal("SVT_AIP_CMD", "Host allocation failed")
        zeros = new[64];
        pcie_aip_cmd_context::root_mem.write_mem(pcie_aip_cmd_context::host_addr, zeros);
        pcie_aip_cmd_context::setup_done = 1;
        h.result_out = $sformatf("READY host_addr=0x%016h endpoint_addr=0x%016h",
          pcie_aip_cmd_context::host_addr, pcie_aip_cmd_context::endpoint_addr);
      end
      "checkpoint": begin
        #1us;
        pcie_aip_cmd_context::checkpoint_root = pcie_aip_cmd_context::root_rx.requests.size();
        pcie_aip_cmd_context::checkpoint_ep = pcie_aip_cmd_context::ep_rx.requests.size();
        h.result_out = "CHECKPOINT";
      end
      "rejected": begin
        #1us;
        if ((pcie_aip_cmd_context::checkpoint_root != pcie_aip_cmd_context::root_rx.requests.size()) ||
            (pcie_aip_cmd_context::checkpoint_ep != pcie_aip_cmd_context::ep_rx.requests.size()))
          `uvm_fatal("SVT_AIP_CMD", "invalid parameters issued a Serial request")
        pcie_aip_cmd_context::rejection_checked = 1;
        h.result_out = "REJECT_NO_PACKET_PASS";
      end
      "parallel_rc": begin
        h.result_out = check_parallel_read("rc_mem_rd",
          "002030405060060708090a0b0c0d0e0f");
      end
      "parallel_ep": begin
        h.result_out = check_parallel_read("ep_mem_rd",
          "c0c1334455667788c8c9cacbcccdcecf");
      end
      "final": begin
        #1us;
        if (!pcie_aip_cmd_context::setup_done || !pcie_aip_cmd_context::rejection_checked)
          `uvm_fatal("SVT_AIP_CMD", "missing setup or rejection check")
        void'(check_parallel_read("rc_mem_rd", "002030405060060708090a0b0c0d0e0f"));
        void'(check_parallel_read("ep_mem_rd", "c0c1334455667788c8c9cacbcccdcecf"));
        pcie_aip_cmd_context::parallel_read_checked = 1;
        $display("PARALLEL_READ_PASS rc=COMPLETED_SC ep=COMPLETED_SC data=checked");
        check_all_received();
        pcie_aip_cmd_context::root_mem.free(pcie_aip_cmd_context::host_addr);
        pcie_aip_cmd_context::completed = 1;
        h.result_out = "SERIAL_BIDIR_PASS rc_to_ep=12 ep_to_rc=6 backing=checked fields=checked";
      end
      default: `uvm_fatal("SVT_AIP_CMD", {"unknown test stage: ", stage})
    endcase
    h.status = 0;
  endtask
endclass

// 命令名和目标都是用户侧选择；同一通用类复用于 RC/EP，不定义全局当前 Host。
`aip_cmd_user_seq(rc_link_up, pcie_aip_link_up_seq, pcie_aip_cmd_context::rc_dl_sqr)
`aip_cmd_user_seq(ep_link_up, pcie_aip_link_up_seq, pcie_aip_cmd_context::ep_dl_sqr)
`aip_cmd_user_seq(rc_cfg_rd, pcie_aip_cfg_rd_seq, pcie_aip_cmd_context::rc_tl_sqr)
`aip_cmd_user_seq(rc_cfg_wr, pcie_aip_cfg_wr_seq, pcie_aip_cmd_context::rc_tl_sqr)
`aip_cmd_user_seq(rc_mem_rd, pcie_aip_mem_rd_seq, pcie_aip_cmd_context::rc_tl_sqr)
`aip_cmd_user_seq(rc_mem_wr, pcie_aip_mem_wr_seq, pcie_aip_cmd_context::rc_tl_sqr)
`aip_cmd_user_seq(ep_mem_rd, pcie_aip_mem_rd_seq, pcie_aip_cmd_context::ep_tl_sqr)
`aip_cmd_user_seq(ep_mem_wr, pcie_aip_mem_wr_seq, pcie_aip_cmd_context::ep_tl_sqr)
`aip_cmd_user_seq(pair_check, pcie_aip_pair_check_seq, pcie_aip_cmd_context::control_sqr)

// 继承仅为复用验证过的 FULL_VIP/host_mem 构建，不运行基类自动训练/流量。
class pcie_svt_aip_cmd_test extends pcie_tl_svt_formal_link_test;
  `uvm_component_utils(pcie_svt_aip_cmd_test)
  uvm_sequencer #(uvm_sequence_item) control_sqr;
  pcie_aip_rx_observer root_observer;
  pcie_aip_rx_observer ep_observer;

  // 生命周期交给 UVM；句柄在 build 创建，在 connect 后才发布给静态注册锚点。
  function new(string name = "pcie_svt_aip_cmd_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 基类保持 FULL_VIP transport、Root Host memory 和 EP 自动响应策略。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    control_sqr = uvm_sequencer#(uvm_sequence_item)::type_id::create("control_sqr", this);
    root_observer = pcie_aip_rx_observer::type_id::create("root_observer", this);
    ep_observer = pcie_aip_rx_observer::type_id::create("ep_observer", this);
  endfunction

  // connect 自底向上执行，TL/SVT 子组件此时已就绪；绑定真实 TL/DL sqr。
  // EP 无独立 dev_mem 时使用原有 sparse backing，Root 保持真实 host_mem。
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if ((tl_env.v_seqr.rc_seqr == null) || (tl_env.v_seqr.ep_seqr == null))
      `uvm_fatal("SVT_AIP_CMD", "TL sequencers are not connected")
    tl_env.rc_agent.monitor.tlp_ap.connect(root_observer.analysis_export);
    tl_env.ep_agent.monitor.tlp_ap.connect(ep_observer.analysis_export);
    tl_env.ep_agent.ep_driver.use_unified_mem = 0;
    pcie_aip_cmd_context::control_sqr = control_sqr;
    pcie_aip_cmd_context::rc_tl_sqr = tl_env.v_seqr.rc_seqr;
    pcie_aip_cmd_context::ep_tl_sqr = tl_env.v_seqr.ep_seqr;
    pcie_aip_cmd_context::rc_dl_sqr = svt_env.root.virt_seqr.pcie_virt_seqr.dl_seqr;
    pcie_aip_cmd_context::ep_dl_sqr = svt_env.endpoint.virt_seqr.pcie_virt_seqr.dl_seqr;
    if (!pcie_aip_link_binding::bind_agent(svt_env.root, svt_env.root_status) ||
        !pcie_aip_link_binding::bind_agent(svt_env.endpoint, svt_env.endpoint_status))
      `uvm_fatal("SVT_AIP_CMD", "DL sequencer/status binding failed")
    pcie_aip_cmd_context::tl_env = tl_env;
    pcie_aip_cmd_context::root_mem = root_mem;
    pcie_aip_cmd_context::root_rx = root_observer;
    pcie_aip_cmd_context::ep_rx = ep_observer;
  endfunction

  // Tcl 控制业务次序；全局 2ms 上限独立于 AIP watchdog，防止脚本死等。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork : bridge_or_timeout
      aip_tcl_bridge::run_loop();
      begin
        #2ms;
        `uvm_fatal("SVT_AIP_CMD", "AIP bidirectional test timeout after 2ms")
      end
    join_any
    disable bridge_or_timeout;
    phase.drop_objection(this);
  endtask

  // 即使 Tcl 提前 end_test，也不能把零 ERROR 汇总误判为完整门禁通过。
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (!pcie_aip_cmd_context::completed || !pcie_aip_cmd_context::parallel_read_checked)
      `uvm_fatal("SVT_AIP_CMD", "Tcl did not complete parallel read/Serial/backing verification")
    `uvm_info("SVT_AIP_CMD", "SVT_AIP_CMD_REPORT_PASS", UVM_NONE)
  endfunction
endclass

`endif
