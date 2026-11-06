/*
 * 所属层次：pcie_tl_vip/src；PCIe TL VIP 的公共 package 聚合入口。
 * 文件职责：按依赖顺序汇集类型、组件、配置和 sequence，保持唯一类型定义。
 * 主要依赖：UVM、PCIe topology/BDF/device profile 及 host_mem；不依赖 DPU package。
 * 所有权与生命周期：package 只定义类型，配置和组件由调用方/UVM 管理；不自动读取参数。
 * 可选 AIP 必须先编译 aip_core_pkg；其 AIP_CMDLINE_SV guard 决定是否启用显式加载接口。
 */

package pcie_tl_pkg;

    import uvm_pkg::*;
    import pcie_topology_pkg::*;
    import host_mem_pkg::*;
`ifdef AIP_CMDLINE_SV
    // 只借用已经编译的统一 AIP 类型，不直接 include 其实现，避免重复静态状态。
    import aip_core_pkg::*;
`endif
    import pcie_tl_bdf_utils_pkg::*;
    import pcie_tl_device_profile_pkg::*;
    `include "uvm_macros.svh"

    //--- Types ---
    `include "types/pcie_tl_types.sv"
    `include "types/pcie_tl_prefix.sv"
    `include "types/pcie_tl_tlp.sv"

    //--- Shared Components ---
    `include "shared/pcie_tl_codec.sv"
    `include "shared/pcie_tl_fc_manager.sv"
    `include "shared/pcie_tl_bw_shaper.sv"
    `include "shared/pcie_tl_tag_manager.sv"
    `include "shared/pcie_tl_ordering_engine.sv"
    `include "shared/pcie_tl_cfg_space_manager.sv"
    `include "shared/pcie_tl_link_delay_model.sv"
    `include "shared/pcie_tl_sriov_cap.sv"
    `include "shared/pcie_tl_func_manager.sv"
    `include "shared/pcie_tl_bar_decoder.sv"
    `include "shared/pcie_tl_config_proxy.sv"

    //--- Backend-neutral device translation ---
    // Included after pcie_tl_func_manager because the adapter targets its
    // independent per-device function context.
    `include "topology/pcie_tl_device_cfg_adapter.sv"

    //--- Adapter ---
    `include "adapter/pcie_tl_if_adapter.sv"

    //--- Switch ---
    `include "switch/pcie_tl_switch_config.sv"
    `include "switch/pcie_tl_switch_port.sv"
    `include "switch/pcie_tl_switch_fabric.sv"
    `include "switch/pcie_tl_switch.sv"

    //--- Agent ---
    `include "agent/pcie_tl_base_driver.sv"
    `include "agent/pcie_tl_base_monitor.sv"
    `include "agent/pcie_tl_base_agent.sv"
    `include "agent/pcie_tl_rc_driver.sv"
    `include "agent/pcie_tl_rc_agent.sv"
    `include "agent/pcie_tl_ep_driver.sv"
    `include "agent/pcie_tl_ep_agent.sv"

    //--- Env ---
    `include "env/pcie_tl_env_config.sv"

    //--- Backend-neutral provider contract ---
    // SVT-specific implementations are compiled only by the SVT integration
    // filelist and are discovered through this neutral interface.
    `include "env/pcie_tl_backend_provider.sv"

    //--- Topology Adapter (requires native Switch and Env configuration) ---
    `include "adapter/pcie_tl_topology_adapter.sv"

    `include "env/pcie_tl_virtual_sequencer.sv"
    `include "env/pcie_tl_scoreboard.sv"
    `include "env/pcie_tl_coverage_collector.sv"
    `include "env/pcie_tl_env.sv"

    //--- Sequences: Base ---
    `include "seq/base/pcie_tl_mem_rd_seq.sv"
    `include "seq/base/pcie_tl_mem_wr_seq.sv"
    `include "seq/base/pcie_tl_rw_seq.sv"
    `include "seq/base/pcie_tl_reg_seq.sv"
    `include "seq/base/pcie_tl_io_rd_seq.sv"
    `include "seq/base/pcie_tl_io_wr_seq.sv"
    `include "seq/base/pcie_tl_cfg_rd_seq.sv"
    `include "seq/base/pcie_tl_cfg_wr_seq.sv"
    `include "seq/base/pcie_tl_cpl_seq.sv"
    `include "seq/base/pcie_tl_msg_seq.sv"
    `include "seq/base/pcie_tl_atomic_seq.sv"
    `include "seq/base/pcie_tl_vendor_msg_seq.sv"
    `include "seq/base/pcie_tl_ltr_seq.sv"

    //--- Sequences: Constraints ---
    `include "seq/constraints/pcie_tl_legal_constraints.sv"
    `include "seq/constraints/pcie_tl_illegal_constraints.sv"
    `include "seq/constraints/pcie_tl_corner_constraints.sv"

    //--- Sequences: Scenario ---
    `include "seq/scenario/pcie_tl_bar_enum_seq.sv"
    `include "seq/scenario/pcie_tl_dma_rdwr_seq.sv"
    `include "seq/scenario/pcie_tl_msi_seq.sv"
    `include "seq/scenario/pcie_tl_cpl_timeout_seq.sv"
    `include "seq/scenario/pcie_tl_err_malformed_seq.sv"
    `include "seq/scenario/pcie_tl_err_poisoned_seq.sv"
    `include "seq/scenario/pcie_tl_err_unexpected_cpl_seq.sv"
    `include "seq/scenario/pcie_tl_err_tag_conflict_seq.sv"

    //--- Sequences: Virtual ---
    `include "seq/virtual/pcie_tl_base_vseq.sv"
    `include "seq/virtual/pcie_tl_rc_ep_rdwr_vseq.sv"
    `include "seq/virtual/pcie_tl_enum_then_dma_vseq.sv"
    `include "seq/virtual/pcie_tl_backpressure_vseq.sv"

endpackage : pcie_tl_pkg
