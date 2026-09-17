//------------------------------------------------------------------------------
// tests 层：通过 AIP Tcl 命令驱动真实 SVT RC/EP 的 Serial 建链门禁。
//
// 本文件由专用 test-only HDL top 在 module 内 include；依赖此前已编译的
// aip_core_pkg、pcie_svt_adapter_pkg 和 pcie_svt_backend_auto_link_test。
// RC 仍由生产 backend 创建，外部 SVT EP 代替 DUT，因此该测试既检查 Tcl
// create/start 链路，也检查用户采用的 backend sequencer/status 绑定路径。
// 静态 context 只借用 test/env 持有的对象，不创建或销毁 vendor agent；其
// 生命周期限制在一次仿真内。每次仿真只允许执行一次建链命令，防止已经 L0
// 的链路使测试误判为 Tcl 成功触发训练。trace 参数只改变 wrapper 日志，
// 不改变 SVT 默认日志配置、物理训练策略或链路使能时序。
//------------------------------------------------------------------------------

`ifndef PCIE_SVT_AIP_LINK_TEST_SV
`define PCIE_SVT_AIP_LINK_TEST_SV

import aip_core_pkg::*;

// AIP 注册宏需要静态 sequencer 锚点；将它和正式 backend/外部 EP 句柄
// 集中保存在只供本测试使用的 context 中，避免 Tcl 访问 UVM 私有层次。
class pcie_svt_aip_link_context;
  static uvm_sequencer_base cmd_sqr;
  static pcie_svt_backend backend;
  static svt_pcie_device_agent endpoint;
  static svt_pcie_device_status endpoint_status;
  static string link_id;
  static bit completed;
endclass

// 用户 sequence 自己设置 enable=1 并确认两端 L0；aip_cmd_user_seq 只
// 负责调度，不能仅凭其 USER_SEQ start/done 日志断言实际链路状态。
class pcie_svt_aip_pair_link_seq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(pcie_svt_aip_pair_link_seq)

  // 构造函数仅初始化 UVM sequence 名称；agent/status 均在 body 执行时
  // 从已经完成 connect/elaboration 的 context 获取，不持有其所有权。
  function new(string name = "pcie_svt_aip_pair_link_seq");
    super.new(name);
  endfunction

  // 将失败同步写回 Tcl 命令句柄并终止本次仿真，避免 end_test 或 UVM
  // 正常结束掩盖建链失败；句柄本身缺失时仍保留 UVM FATAL 诊断。
  function void fail_command(aip_cmd handle, string message);
    if (handle != null) begin
      handle.status = 1;
      handle.result_out = {"ERROR: ", message};
    end
    `uvm_fatal("SVT_AIP_LINK", message)
  endfunction

  // 只格式化已验证非空的公开状态字段。这里不猜测不同 VIP 版本的速率/
  // 宽度成员名；LTSSM 原始编码与 link_up 足以判断本门禁的双端 L0 条件。
  function string format_states(svt_pcie_device_status root_status,
                                svt_pcie_device_status endpoint_status);
    return $sformatf("rc_link_up=%0b rc_ltssm=%0d ep_link_up=%0b ep_ltssm=%0d",
      root_status.pcie_status.pl_status.link_up,
      root_status.pcie_status.pl_status.ltssm_state,
      endpoint_status.pcie_status.pl_status.link_up,
      endpoint_status.pcie_status.pl_status.ltssm_state);
  endfunction

  // 接收 trace=0|1，验证静态绑定，等待 HDL 复位稳定，再并行使能 RC/EP。
  // 1ms 的独立超时覆盖复位等待、两次官方 sequence.start 和 L0 等待，
  // 不依赖 AIP watchdog 清理。trace=1 的状态轮询仅在观察值变化时打印；
  // trace=0 不打印 wrapper 信息，便于复现“无训练日志但命令已执行”。
  virtual task body();
    aip_cmd handle;
    pcie_svt_backend selected_backend;
    svt_pcie_device_agent root_agent;
    svt_pcie_device_agent endpoint_agent;
    svt_pcie_device_status root_status;
    svt_pcie_device_status endpoint_status;
    svt_pcie_dl_service_set_link_en_sequence root_link_en;
    svt_pcie_dl_service_set_link_en_sequence endpoint_link_en;
    string selected_link_id;
    string trace_arg;
    bit trace_enabled;
    bit reached_l0;
    time started_at;

    handle = aip_cmd::get_handle("svt_pair_link_up");
    if (handle == null) begin
      fail_command(handle, "svt_pair_link_up command handle is null");
      return;
    end
    trace_arg = aip_cmd::get_arg(handle.args_in, "trace");
    if ((trace_arg != "") && (trace_arg != "0") && (trace_arg != "1")) begin
      fail_command(handle, "trace must be 0 or 1");
      return;
    end
    trace_enabled = (trace_arg == "1");
    if (trace_enabled)
      `uvm_info("SVT_AIP_LINK", "SVT_AIP_COMMAND_ENTER svt_pair_link_up", UVM_NONE)

    selected_backend = pcie_svt_aip_link_context::backend;
    selected_link_id = pcie_svt_aip_link_context::link_id;
    endpoint_agent = pcie_svt_aip_link_context::endpoint;
    endpoint_status = pcie_svt_aip_link_context::endpoint_status;
    if ((pcie_svt_aip_link_context::cmd_sqr == null) ||
        (selected_backend == null) || (endpoint_agent == null) ||
        (selected_link_id == "")) begin
      fail_command(handle, "command sequencer/backend/endpoint/link binding is missing");
      return;
    end
    if (pcie_svt_aip_link_context::completed) begin
      fail_command(handle, "svt_pair_link_up may run only once per simulation");
      return;
    end
    if (!selected_backend.svt_agent_by_link.exists(selected_link_id) ||
        !selected_backend.svt_status_by_link.exists(selected_link_id)) begin
      fail_command(handle, {"backend agent/status missing for ", selected_link_id});
      return;
    end
    root_agent = selected_backend.svt_agent_by_link[selected_link_id];
    root_status = selected_backend.svt_status_by_link[selected_link_id];
    if ((root_agent == null) || (root_status == null) ||
        (endpoint_status == null)) begin
      fail_command(handle, "RC agent or RC/EP status handle is null");
      return;
    end
    // device agent 首先持有 virt_seqr；pcie_virt_seqr 是其下一层成员，
    // 不能把官方 example 的 device virtual sequencer 当作 device agent。
    if ((root_agent.virt_seqr == null) ||
        (endpoint_agent.virt_seqr == null)) begin
      fail_command(handle, "RC/EP device virtual sequencer is null");
      return;
    end
    if ((root_agent.virt_seqr.pcie_virt_seqr == null) ||
        (endpoint_agent.virt_seqr.pcie_virt_seqr == null)) begin
      fail_command(handle, "RC/EP PCIe virtual sequencer is null");
      return;
    end
    if ((root_agent.virt_seqr.pcie_virt_seqr.dl_seqr == null) ||
        (endpoint_agent.virt_seqr.pcie_virt_seqr.dl_seqr == null)) begin
      fail_command(handle, "RC/EP DL sequencer is null");
      return;
    end
    if ((root_status.pcie_status == null) ||
        (endpoint_status.pcie_status == null)) begin
      fail_command(handle, "RC/EP PCIe status is null");
      return;
    end
    if ((root_status.pcie_status.pl_status == null) ||
        (endpoint_status.pcie_status.pl_status == null)) begin
      fail_command(handle, "RC/EP PL status is null");
      return;
    end

    root_link_en = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
      "tcl_root_link_en");
    endpoint_link_en = svt_pcie_dl_service_set_link_en_sequence::type_id::create(
      "tcl_endpoint_link_en");
    if ((root_link_en == null) || (endpoint_link_en == null)) begin
      fail_command(handle, "official link-enable sequence create failed");
      return;
    end
    root_link_en.enable = 1'b1;
    endpoint_link_en.enable = 1'b1;
    reached_l0 = 1'b0;
    started_at = $time;

    fork : pair_link_or_timeout
      begin : train_both_ends
        // 专用顶层在 200ns 释放 reset；命令再等待 10us，使被测条件明确
        // 位于复位之后。若任一端此前已经 L0，不能归因于本 Tcl 命令。
        #10us;
        if (((root_status.pcie_status.pl_status.link_up == 1'b1) &&
             (root_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0)) ||
            ((endpoint_status.pcie_status.pl_status.link_up == 1'b1) &&
             (endpoint_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0))) begin
          fail_command(handle, {"link was already L0 before Tcl enable: ",
            format_states(root_status, endpoint_status)});
        end
        else begin
          if (trace_enabled)
            `uvm_info("SVT_AIP_LINK", {"SVT_AIP_PRELINK_NOT_L0 ",
              format_states(root_status, endpoint_status)}, UVM_NONE)

          // 双 SVT 都是 active 端，必须各自设置 enable；真实 DUT 场景只
          // 对 SVT 侧执行该 sequence，DUT 侧由其自身复位/训练控制负责。
          fork
            begin
              if (trace_enabled)
                `uvm_info("SVT_AIP_LINK", "SVT_AIP_ENABLE_START side=RC enable=1", UVM_NONE)
              root_link_en.start(root_agent.virt_seqr.pcie_virt_seqr.dl_seqr);
              if (trace_enabled)
                `uvm_info("SVT_AIP_LINK", "SVT_AIP_ENABLE_DONE side=RC", UVM_NONE)
            end
            begin
              if (trace_enabled)
                `uvm_info("SVT_AIP_LINK", "SVT_AIP_ENABLE_START side=EP enable=1", UVM_NONE)
              endpoint_link_en.start(endpoint_agent.virt_seqr.pcie_virt_seqr.dl_seqr);
              if (trace_enabled)
                `uvm_info("SVT_AIP_LINK", "SVT_AIP_ENABLE_DONE side=EP", UVM_NONE)
            end
          join

          // 必须同时满足双端状态，不能让“RC 曾经 L0、EP 后来 L0”在
          // RC 已掉链时仍通过。进入此条件后才允许命令向 Tcl 报告成功。
          wait ((root_status.pcie_status.pl_status.link_up == 1'b1) &&
                (endpoint_status.pcie_status.pl_status.link_up == 1'b1) &&
                (root_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0) &&
                (endpoint_status.pcie_status.pl_status.ltssm_state == svt_pcie_types::L0));
          reached_l0 = 1'b1;
        end
      end
      begin : bounded_timeout
        #1ms;
        fail_command(handle, {"SVT pair link-up timeout (1ms): ",
          format_states(root_status, endpoint_status)});
      end
      begin : optional_state_trace
        string previous_states;
        string current_states;

        previous_states = "";
        // 无 trace 时仍保持该 fork 分支阻塞，避免它立刻返回触发 join_any
        // 并错误中止训练；成功/超时分支结束后统一 disable 掉所有观察者。
        if (!trace_enabled)
          wait (1'b0);
        forever begin
          current_states = format_states(root_status, endpoint_status);
          if (current_states != previous_states) begin
            `uvm_info("SVT_AIP_LINK", {"SVT_AIP_STATE ", current_states}, UVM_NONE)
            previous_states = current_states;
          end
          #1us;
        end
      end
    join_any
    disable pair_link_or_timeout;

    if (!reached_l0)
      return;

    pcie_svt_aip_link_context::completed = 1'b1;
    handle.status = 0;
    handle.result_out = $sformatf("PAIR_LINK_L0 link=%s %s elapsed_ns=%0d",
      selected_link_id, format_states(root_status, endpoint_status),
      ($time - started_at) / 1ns);
    if (trace_enabled)
      `uvm_info("SVT_AIP_LINK", {"SVT_AIP_PAIR_L0 ", handle.result_out}, UVM_NONE)
  endtask
endclass

// 一次性用户命令，不引入 count/time 字段；两端官方 sequence 的配置和
// 超时都由上述用户 sequence 负责，保持 AIP 的零适配调用语义。
`aip_cmd_user_seq(svt_pair_link_up, pcie_svt_aip_pair_link_seq,
                  pcie_svt_aip_link_context::cmd_sqr)

// 复用已验证的 backend 自动创建配置和静态 Serial RC/EP 拓扑，只替换
// run_phase 为 Tcl 编排。基类的 build/elaboration 断言继续作为前置门禁。
class pcie_svt_aip_link_test extends pcie_svt_backend_auto_link_test;
  `uvm_component_utils(pcie_svt_aip_link_test)

  uvm_sequencer #(uvm_sequence_item) command_sqr;

  // 构造函数只向 UVM 传递名字/父组件；环境及 sequencer 在 build 创建。
  function new(string name = "pcie_svt_aip_link_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 基类创建 backend RC 和外部 EP 后、子组件 build 之前，补齐 EP 的
  // Gen4/x16/full-EQ 能力，使其与生产 backend RC 的默认策略一致。
  // 两端由 HDL mode=0 选择内部 bit clock，不派生 backend 或覆盖
  // disable_ext_bit_clock_mode；厂商日志开关不变，单独比较 trace=0/1。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if ((external_endpoint_cfg == null) ||
        (external_endpoint_cfg.pcie_cfg == null))
      `uvm_fatal("SVT_AIP_LINK", "external endpoint configuration is null")
    if (external_endpoint_cfg.pcie_cfg.pl_cfg == null)
      `uvm_fatal("SVT_AIP_LINK", "external endpoint PL configuration is null")

    external_endpoint_cfg.pcie_spec_ver =
      svt_pcie_device_configuration::PCIE_SPEC_VER_4_0;
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_width_values(16, 32'h3f, 16);
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_speed_values(
      (`SVT_PCIE_SPEED_2_5G | `SVT_PCIE_SPEED_5_0G |
       `SVT_PCIE_SPEED_8_0G | `SVT_PCIE_SPEED_16_0G),
      `SVT_PCIE_SPEED_16_0G, `SVT_PCIE_SPEED_16_0G);
    external_endpoint_cfg.pcie_cfg.pl_cfg.set_link_eq_attribute_values(
      svt_pcie_pl_configuration::LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED,
      1'b0, 3);

    command_sqr = uvm_sequencer#(uvm_sequence_item)::type_id::create(
      "command_sqr", this);
    pcie_svt_aip_link_context::completed = 1'b0;
  endfunction

  // 所有子组件 build 完成后绑定静态锚点；backend_provider 不在父 test
  // build 时 cast，避免 provider 尚未创建的空对象问题。canonical link_id
  // 直接从 policy 获取，不把数组序号或节点名误当成 backend 映射的 key。
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    if ((tl_env == null) || (command_sqr == null))
      `uvm_fatal("SVT_AIP_LINK", "TL env or command sequencer is null")
    if (!$cast(pcie_svt_aip_link_context::backend, tl_env.backend_provider) ||
        (pcie_svt_aip_link_context::backend == null))
      `uvm_fatal("SVT_AIP_LINK", "backend_provider is not a live pcie_svt_backend")
    if ((global_cfg == null) || (global_cfg.links.size() != 1))
      `uvm_fatal("SVT_AIP_LINK", "Tcl pair test requires exactly one physical link")
    if (global_cfg.links[0] == null)
      `uvm_fatal("SVT_AIP_LINK", "the sole link policy is null")

    pcie_svt_aip_link_context::cmd_sqr = command_sqr;
    pcie_svt_aip_link_context::endpoint = external_endpoint;
    pcie_svt_aip_link_context::endpoint_status = external_endpoint_status;
    pcie_svt_aip_link_context::link_id = global_cfg.links[0].link_id;
  endfunction

  // 由 Tcl 调用 svt_pair_link_up/end_test 控制运行期；不调用基类短暂等待
  // 的 run_phase，也不设置官方 default_sequence，保证训练触发来自 Tcl。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    aip_tcl_bridge::run_loop();
    phase.drop_objection(this);
  endtask

  // 防止 Tcl 漏执行命令、超时取消或提前 end_test 导致零错误假通过；只
  // 接受 wrapper 确认双端同时 L0 后写入的完成标志，不凭日志数量判断。
  // 独立 report 标志供 shell 确认 end_test 后真正完成 UVM 收尾，不属于训练过程日志。
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (!pcie_svt_aip_link_context::completed)
      `uvm_fatal("SVT_AIP_LINK", "Tcl command did not complete RC/EP L0 validation")
    `uvm_info("SVT_AIP_LINK", "SVT_AIP_REPORT_PASS", UVM_NONE)
  endfunction
endclass

`endif
