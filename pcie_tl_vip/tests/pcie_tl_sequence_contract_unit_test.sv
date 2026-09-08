//------------------------------------------------------------------------------
// 基础 TL sequence 的可观测性契约测试。
//
// 该测试使用一个最小的 capture driver，不依赖真实 PCIe 链路。driver 只
// 记录 sequence 实际交给 sequencer 的 TLP，并为非 posted 请求补回一个
// Completion。这样可以独立验证：
//   1. sequence.issued_tlp 指向真正发出的对象，而不是 body 内的临时副本；
//   2. Config Write 的 wr_data 按 little-endian 字节进入 payload；
//   3. Memory Write 的 write_data 在 finish_item() 前进入完整 payload；
//   4. Read sequence 可以通过同一个 issued_tlp 观察 Completion 状态和数据。
//
// 该文件先作为回归契约加入 filelist。若生产 sequence 尚未提供上述公开
// 句柄，VCS 编译应在这里明确失败，而不是让问题延后到真实 DUT 流程。
//------------------------------------------------------------------------------

`include "uvm_macros.svh"

import uvm_pkg::*;
import pcie_tl_pkg::*;

//------------------------------------------------------------------------------
// 最小 driver：记录每个请求，并立即生成成功 Completion。
//------------------------------------------------------------------------------
class pcie_tl_sequence_capture_driver extends uvm_driver #(pcie_tl_tlp);
  `uvm_component_utils(pcie_tl_sequence_capture_driver)

  pcie_tl_tlp captured[$];

  // 构造函数：仅透传参数，无额外初始化。
  function new(string name = "pcie_tl_sequence_capture_driver",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 主循环：记录每个到达的 TLP，并对需要 Completion 的请求直接在原
  // 对象上回写确定性的 rb_data/rb_status（不构造独立 CplD），让
  // sequence 的等待逻辑立即返回。永不退出，随 phase 结束。
  task run_phase(uvm_phase phase);
    pcie_tl_tlp item;
    forever begin
      seq_item_port.get_next_item(item);
      captured.push_back(item);

      // Read/Config 请求需要一个可观察的 read-back 结果；Write 请求在
      // sequence 中是 posted，但 Config Write 仍由其 sequence 等待 Cpl。
      if (item.requires_completion()) begin
        item.rb_status = CPL_STATUS_SC;
        if (item.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK}) begin
          item.rb_data.delete();
          for (int i = 0; i < (item.length == 0 ? 4096 : item.length * 4); i++)
            item.rb_data.push_back(8'h80 + i);
        end
        else if (item.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
          item.rb_data.delete();
          item.rb_data.push_back(8'h44);
          item.rb_data.push_back(8'h33);
          item.rb_data.push_back(8'h22);
          item.rb_data.push_back(8'h11);
        end
        item.rb_done = 1'b1;
      end

      seq_item_port.item_done();
    end
  endtask
endclass

//------------------------------------------------------------------------------
// sequence 契约测试主体：依次启动 Config Write/Read 与 Memory
// Write/Read 四条生产 sequence，断言 issued_tlp 公开句柄、payload 字节
// 序和 Completion 可观测性。
//------------------------------------------------------------------------------
class pcie_tl_sequence_contract_unit_test extends uvm_test;
  `uvm_component_utils(pcie_tl_sequence_contract_unit_test)

  uvm_sequencer #(pcie_tl_tlp) sequencer;
  pcie_tl_sequence_capture_driver driver;

  // 构造函数：仅透传参数。
  function new(string name = "pcie_tl_sequence_contract_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 创建裸 sequencer 与 capture driver——契约验证不需要完整 env。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sequencer = uvm_sequencer#(pcie_tl_tlp)::type_id::create(
      "sequencer", this);
    driver = pcie_tl_sequence_capture_driver::type_id::create(
      "driver", this);
  endfunction

  // 连接 driver 与 sequencer 的标准 TLM 端口。
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction

  // 断言辅助：条件不成立时报 UVM_ERROR，message 说明违反的契约。
  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("SEQ_CONTRACT", message)
  endfunction

  // 按 Config Write → Config Read → Memory Write → Memory Read 顺序
  // 执行四组契约断言；顺序无依赖，仅便于日志对照文件头的编号说明。
  task run_phase(uvm_phase phase);
    pcie_tl_cfg_wr_seq cfg_wr;
    pcie_tl_cfg_rd_seq cfg_rd;
    pcie_tl_mem_wr_seq mem_wr;
    pcie_tl_mem_rd_seq mem_rd;
    pcie_tl_mem_tlp mem_tlp;
    pcie_tl_cfg_tlp cfg_tlp;
    bit [7:0] write_payload[];

    phase.raise_objection(this);

    // Config Write：检查公开句柄、地址字段和 little-endian payload。
    cfg_wr = pcie_tl_cfg_wr_seq::type_id::create("cfg_wr");
    cfg_wr.target_bdf = 16'h0200;
    cfg_wr.reg_num = 10'h010;
    cfg_wr.first_be = 4'hf;
    cfg_wr.wr_data = 32'hA1B2_C3D4;
    cfg_wr.mode = CONSTRAINT_LEGAL;
    cfg_wr.start(sequencer);
    require(cfg_wr.issued_tlp != null,
            "Config Write issued_tlp must be non-null");
    if ($cast(cfg_tlp, cfg_wr.issued_tlp)) begin
      require(cfg_tlp.payload.size() == 4,
              "Config Write payload must contain one DWORD");
      require(cfg_tlp.payload[0] == 8'hD4 &&
              cfg_tlp.payload[1] == 8'hC3 &&
              cfg_tlp.payload[2] == 8'hB2 &&
              cfg_tlp.payload[3] == 8'hA1,
              "Config Write payload byte order is not little-endian");
      require(cfg_tlp.completer_id == 16'h0200 &&
              cfg_tlp.reg_num == 10'h010,
              "Config Write issued TLP fields do not match sequence input");
    end
    else begin
      `uvm_error("SEQ_CONTRACT", "Config Write issued_tlp has wrong type");
    end
    require(cfg_wr.status == PCIE_RW_OK,
            "Config Write Completion status must be OK");

    // Config Read：检查同一 issued_tlp 上的 Completion 数据回写。
    cfg_rd = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd");
    cfg_rd.target_bdf = 16'h0200;
    cfg_rd.reg_num = 10'h010;
    cfg_rd.first_be = 4'hf;
    cfg_rd.mode = CONSTRAINT_LEGAL;
    cfg_rd.start(sequencer);
    require(cfg_rd.issued_tlp != null,
            "Config Read issued_tlp must be non-null");
    require(cfg_rd.status == PCIE_RW_OK && cfg_rd.rd_data == 32'h1122_3344,
            "Config Read did not expose Completion through issued_tlp");

    // Memory Write：显式指定完整 DW 对齐 payload。地址使用 64-bit，byte
    // enable 使用非全字节组合，确认这些 header 字段也保留在 issued_tlp。
    write_payload = new[8];
    write_payload[0] = 8'h10;
    write_payload[1] = 8'h21;
    write_payload[2] = 8'h32;
    write_payload[3] = 8'h43;
    write_payload[4] = 8'h54;
    write_payload[5] = 8'h65;
    write_payload[6] = 8'h76;
    write_payload[7] = 8'h87;

    mem_wr = pcie_tl_mem_wr_seq::type_id::create("mem_wr");
    mem_wr.addr = 64'h0000_0001_0000_1001;
    mem_wr.length = 2;
    mem_wr.first_be = 4'hE;
    mem_wr.last_be = 4'h3;
    mem_wr.is_64bit = 1'b1;
    mem_wr.mode = CONSTRAINT_LEGAL;
    mem_wr.write_data = write_payload;
    mem_wr.start(sequencer);
    require(mem_wr.issued_tlp != null,
            "Memory Write issued_tlp must be non-null");
    if ($cast(mem_tlp, mem_wr.issued_tlp)) begin
      require(mem_tlp.addr == mem_wr.addr && mem_tlp.length == 2 &&
              mem_tlp.first_be == 4'hE && mem_tlp.last_be == 4'h3,
              "Memory Write header fields were not preserved");
      require(mem_tlp.payload.size() == write_payload.size(),
              "Memory Write payload size does not match write_data");
      foreach (write_payload[i])
        require(mem_tlp.payload[i] == write_payload[i],
                $sformatf("Memory Write payload mismatch at byte %0d", i));
    end
    else begin
      `uvm_error("SEQ_CONTRACT", "Memory Write issued_tlp has wrong type");
    end

    // Memory Read：检查 64-bit 地址和长度，并确认 Completion 数据可从
    // issued_tlp 关联对象中读取。
    mem_rd = pcie_tl_mem_rd_seq::type_id::create("mem_rd");
    mem_rd.addr = 64'h0000_0001_0000_2000;
    mem_rd.length = 2;
    mem_rd.first_be = 4'hf;
    // LEGAL 模式下多 DW 读要求 last_be 非零。
    mem_rd.last_be = 4'h3;
    mem_rd.is_64bit = 1'b1;
    mem_rd.mode = CONSTRAINT_LEGAL;
    mem_rd.start(sequencer);
    require(mem_rd.issued_tlp != null,
            "Memory Read issued_tlp must be non-null");
    if ($cast(mem_tlp, mem_rd.issued_tlp)) begin
      require(mem_tlp.addr == mem_rd.addr && mem_tlp.length == 2 &&
              mem_tlp.first_be == 4'hf && mem_tlp.last_be == 4'h3,
              "Memory Read issued TLP fields do not match sequence input");
    end
    require(mem_rd.rb_data.size() == 8,
            "Memory Read Completion payload size is incorrect");
    require(mem_rd.rb_data[0] == 8'h80 && mem_rd.rb_data[7] == 8'h87,
            "Memory Read Completion data is not observable");

    phase.drop_objection(this);
  endtask
endclass
