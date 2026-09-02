//------------------------------------------------------------------------------
// Synopsys SVT PCIe R-2020.12 DPU register-plan executor package.
//
// This package is compiled only by DPU-aware SVT integrations.  The ordinary
// topology environment remains usable without dpu-common.
//------------------------------------------------------------------------------

package pcie_dpu_svt_backend_pkg;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_dpu_integration_pkg::*;
  import pcie_svt_topology_pkg::*;
  `include "import_pcie_svt_uvm_pkgs.svi"
  `include "uvm_macros.svh"

  class pcie_dpu_svt_reg_executor extends pcie_dpu_reg_executor_base;
    `uvm_object_utils(pcie_dpu_svt_reg_executor)

    protected pcie_svt_topology_virtual_sequencer topology_vseqr;
    protected svt_pcie_device_virtual_sequencer selected_rc_seqr;
    protected pcie_svt_port_descriptor selected_descriptor;
    protected string link_id;
    protected bit use_switch_routing;

    function new(string name = "pcie_dpu_svt_reg_executor");
      super.new(name);
      topology_vseqr = null;
      selected_rc_seqr = null;
      selected_descriptor = null;
      link_id = "";
      use_switch_routing = 1'b0;
    endfunction

    // One executor instance selects one SVT RC link.  A system with several
    // independent roots may install one instance per DPU plan/root pair.
    function void configure(
        pcie_svt_topology_virtual_sequencer new_topology_vseqr,
        pcie_global_cfg new_global_cfg,
        string new_link_id,
        dpu_execution_report new_report = null,
        bit new_use_switch_routing = 1'b0);
      topology_vseqr = new_topology_vseqr;
      selected_rc_seqr = null;
      selected_descriptor = null;
      link_id = new_link_id;
      use_switch_routing = new_use_switch_routing;
      configure_common(new_global_cfg, new_report);
    endfunction

    protected virtual function bit backend_ready(output string why);
      why = "";
      selected_rc_seqr = null;
      selected_descriptor = null;
      if (topology_vseqr == null) begin
        why = "SVT executor requires a non-null topology sequencer";
        return 1'b0;
      end
      if (link_id == "") begin
        why = "SVT executor requires a non-empty RC link ID";
        return 1'b0;
      end
      if (!topology_vseqr.seqr_by_link.exists(link_id) ||
          (topology_vseqr.seqr_by_link[link_id] == null)) begin
        why = $sformatf(
          "SVT executor cannot resolve the sequencer for link '%s'", link_id);
        return 1'b0;
      end
      if (!topology_vseqr.descriptor_by_link.exists(link_id) ||
          (topology_vseqr.descriptor_by_link[link_id] == null)) begin
        why = $sformatf(
          "SVT executor cannot resolve the descriptor for link '%s'", link_id);
        return 1'b0;
      end

      selected_rc_seqr = topology_vseqr.seqr_by_link[link_id];
      selected_descriptor = topology_vseqr.descriptor_by_link[link_id];
      if (selected_descriptor.role != PCIE_SVT_ROLE_RC) begin
        why = $sformatf(
          "SVT executor link '%s' is not owned by an RC VIP", link_id);
        return 1'b0;
      end
      if (!selected_rc_seqr.driver_transaction_seqr.exists(0) ||
          (selected_rc_seqr.driver_transaction_seqr[0] == null)) begin
        why = $sformatf(
          "SVT executor link '%s' has no RC driver transaction sequencer",
          link_id);
        return 1'b0;
      end
      return 1'b1;
    endfunction

    protected virtual function bit backend_accepts_device(
        dpu_reg_op operation,
        pcie_device_cfg device,
        output string why);
      pcie_svt_port_descriptor device_descriptor;

      why = "";
      if (device == null) begin
        why = $sformatf(
          "operation %s resolved to a null PCIe device", operation.op_id);
        return 1'b0;
      end

      // Direct RC-to-Endpoint traffic uses the same logical link on both the
      // projected device and the selected RC executor.
      if (device.link_id == link_id)
        return 1'b1;

      // A switch DUT separates the RC VIP's USP link from the Endpoint's DSP
      // attachment link.  Both descriptors must belong to the same root
      // hierarchy; accepting an arbitrary downstream link would route a DPU
      // operation through the wrong independent host.
      if (use_switch_routing &&
          topology_vseqr.descriptor_by_link.exists(device.link_id)) begin
        device_descriptor =
          topology_vseqr.descriptor_by_link[device.link_id];
        if ((device_descriptor != null) &&
            (device_descriptor.root_hierarchy ==
             selected_descriptor.root_hierarchy))
          return 1'b1;
      end

      why = $sformatf(
        {"operation %s resolves to PCIe link '%s', which is not reachable ",
         "from selected RC link '%s' in root hierarchy %0d"},
        operation.op_id, device.link_id, link_id,
        selected_descriptor.root_hierarchy);
      return 1'b0;
    endfunction

    protected function bit [3:0] first_dw_be(
        bit [63:0] address,
        int unsigned width_bytes);
      bit [3:0] enables;

      enables = '0;
      for (int unsigned index = 0; index < width_bytes; index++) begin
        if ((address[1:0] + index) < 4)
          enables[address[1:0] + index] = 1'b1;
      end
      return enables;
    endfunction

    protected function bit [3:0] last_dw_be(int unsigned width_bytes);
      return (width_bytes == 8) ? 4'hf : 4'h0;
    endfunction

    // This matches the vendor send_cfg_*_w_switch_env rule: requests beyond
    // the root secondary bus are Type 1; the secondary-bus target is Type 0.
    protected function bit cfg_type_for_bdf(bit [15:0] bdf);
      if (!use_switch_routing)
        return 1'b0;
      return bdf[15:8] > selected_descriptor.enum_cfg.bus_number;
    endfunction

    // Memory Writes are posted requests and therefore do not receive a
    // Completion TLP.  R-2020.12 leaves their completion_status at AWAITED
    // even when the blocking sequence has handed the request to the driver.
    // Reads remain non-posted and must report a successful Completion.
    protected function bit memory_completion_is_acceptable(
        bit is_write,
        svt_pcie_driver_app_transaction::completion_status_enum status);
      if (is_write)
        return status inside {
          svt_pcie_driver_app_transaction::AWAITED,
          svt_pcie_driver_app_transaction::SUCCESSFUL
        };
      return status == svt_pcie_driver_app_transaction::SUCCESSFUL;
    endfunction

    protected virtual task transport_cfg_write(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        int unsigned width_bytes,
        bit [63:0] data,
        output bit succeeded,
        output string why);
      svt_pcie_driver_app_cfg_request_sequence svt_sequence;
      svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
      bit [31:0] write_dword;
      bit [3:0] enables;
      bit cfg_type;

      write_dword = data[31:0] << (8 * byte_offset[1:0]);
      enables = first_dw_be(byte_offset, width_bytes);
      cfg_type = cfg_type_for_bdf(bdf);
      svt_sequence = svt_pcie_driver_app_cfg_request_sequence::type_id::create(
        "dpu_svt_cfg_write");
      svt_sequence.set_sequencer(
        selected_rc_seqr.driver_transaction_seqr[0]);
      if (!svt_sequence.randomize() with {
            transaction_type == svt_pcie_driver_app_transaction::CFG_WR;
            bdf == local::bdf;
            register_number == local::byte_offset[11:2];
            cfg_type == local::cfg_type;
            payload == local::write_dword;
            first_dw_be == local::enables;
            ep == 0;
            block == 1;
          }) begin
        succeeded = 1'b0;
        why = "SVT Configuration Write sequence randomization failed";
        return;
      end
      svt_sequence.start(selected_rc_seqr.driver_transaction_seqr[0]);
      cpl_status = svt_sequence.req.completion_status;
      succeeded =
        (cpl_status == svt_pcie_driver_app_transaction::SUCCESSFUL);
      why = succeeded ? "" : $sformatf(
        {"SVT Configuration Write failed at BDF=%04x offset=0x%03x ",
         "completion_status=%0d"}, bdf, byte_offset, cpl_status);
    endtask

    protected virtual task transport_cfg_read(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        int unsigned width_bytes,
        output bit [63:0] data,
        output bit succeeded,
        output string why);
      svt_pcie_driver_app_cfg_request_sequence svt_sequence;
      svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
      bit [3:0] enables;
      bit cfg_type;

      enables = first_dw_be(byte_offset, width_bytes);
      cfg_type = cfg_type_for_bdf(bdf);
      svt_sequence = svt_pcie_driver_app_cfg_request_sequence::type_id::create(
        "dpu_svt_cfg_read");
      svt_sequence.set_sequencer(
        selected_rc_seqr.driver_transaction_seqr[0]);
      if (!svt_sequence.randomize() with {
            transaction_type == svt_pcie_driver_app_transaction::CFG_RD;
            bdf == local::bdf;
            register_number == local::byte_offset[11:2];
            cfg_type == local::cfg_type;
            first_dw_be == local::enables;
            block == 1;
          }) begin
        data = '0;
        succeeded = 1'b0;
        why = "SVT Configuration Read sequence randomization failed";
        return;
      end
      svt_sequence.start(selected_rc_seqr.driver_transaction_seqr[0]);
      cpl_status = svt_sequence.req.completion_status;
      succeeded =
        (cpl_status == svt_pcie_driver_app_transaction::SUCCESSFUL) &&
        (svt_sequence.req.payload.size() >= 1);
      data = succeeded ?
        ((64'(svt_sequence.req.payload[0]) >>
          (8 * byte_offset[1:0])) &
         ((64'h1 << (width_bytes * 8)) - 1)) : '0;
      why = succeeded ? "" : $sformatf(
        {"SVT Configuration Read failed at BDF=%04x offset=0x%03x ",
         "completion_status=%0d"}, bdf, byte_offset, cpl_status);
    endtask

    protected task run_memory_sequence(
        bit is_write,
        bit [63:0] bus_address,
        int unsigned width_bytes,
        bit [63:0] write_data,
        output bit [63:0] read_data,
        output bit succeeded,
        output string why);
      svt_pcie_driver_app_mem_request_sequence svt_sequence;
      svt_pcie_driver_app_transaction::completion_status_enum cpl_status;
      bit [31:0] payload_words[];
      bit [63:0] aligned_address;
      bit [9:0] length_dw;
      bit [3:0] first_be;
      bit [3:0] last_be;

      aligned_address = {bus_address[63:2], 2'b00};
      length_dw = (width_bytes == 8) ? 2 : 1;
      first_be = first_dw_be(bus_address, width_bytes);
      last_be = last_dw_be(width_bytes);
      payload_words = new[is_write ? length_dw : 0];
      if (is_write) begin
        payload_words[0] = write_data[31:0] <<
                           (8 * bus_address[1:0]);
        if (length_dw == 2)
          payload_words[1] = write_data[63:32];
      end

      svt_sequence = svt_pcie_driver_app_mem_request_sequence::type_id::create(
        is_write ? "dpu_svt_mmio_write" : "dpu_svt_mmio_read");
      svt_sequence.set_sequencer(
        selected_rc_seqr.driver_transaction_seqr[0]);
      if (!svt_sequence.randomize() with {
            transaction_type == (local::is_write ?
              svt_pcie_driver_app_transaction::MEM_WR :
              svt_pcie_driver_app_transaction::MEM_RD);
            address == local::aligned_address;
            length == local::length_dw;
            write_payload.size() == local::payload_words.size();
            foreach (write_payload[index])
              write_payload[index] == local::payload_words[index];
            first_dw_be == local::first_be;
            last_dw_be == local::last_be;
            traffic_class == 0;
            address_translation == 0;
            ep == 0;
            block == 1;
          }) begin
        read_data = '0;
        succeeded = 1'b0;
        why = "SVT Memory request sequence randomization failed";
        return;
      end
      svt_sequence.start(selected_rc_seqr.driver_transaction_seqr[0]);
      cpl_status = svt_sequence.req.completion_status;
      succeeded = memory_completion_is_acceptable(is_write, cpl_status);
      read_data = '0;
      if (!is_write && succeeded) begin
        if (svt_sequence.req.payload.size() < length_dw) begin
          succeeded = 1'b0;
        end else begin
          read_data[31:0] = svt_sequence.req.payload[0] >>
                            (8 * bus_address[1:0]);
          if (length_dw == 2)
            read_data[63:32] = svt_sequence.req.payload[1];
          read_data &= (width_bytes == 8) ?
                       64'hffff_ffff_ffff_ffff :
                       ((64'h1 << (width_bytes * 8)) - 1);
        end
      end
      why = succeeded ? "" : $sformatf(
        {"SVT Memory %s failed at address=0x%016h ",
         "completion_status=%0d"},
        is_write ? "Write" : "Read", bus_address, cpl_status);
    endtask

    protected virtual task transport_mmio_write(
        bit [63:0] bus_address,
        int unsigned width_bytes,
        bit [63:0] data,
        output bit succeeded,
        output string why);
      bit [63:0] ignored_read_data;

      run_memory_sequence(1'b1, bus_address, width_bytes, data,
                          ignored_read_data, succeeded, why);
    endtask

    protected virtual task transport_mmio_read(
        bit [63:0] bus_address,
        int unsigned width_bytes,
        output bit [63:0] data,
        output bit succeeded,
        output string why);
      run_memory_sequence(1'b0, bus_address, width_bytes, '0,
                          data, succeeded, why);
    endtask
  endclass : pcie_dpu_svt_reg_executor
endpackage : pcie_dpu_svt_backend_pkg
