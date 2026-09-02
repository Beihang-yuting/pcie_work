//------------------------------------------------------------------------------
// TL-specific DPU register-plan executor package.
//
// Keeping this class in a small optional package prevents the backend-neutral
// DPU attachment/projection package from importing the full TL VIP.
//------------------------------------------------------------------------------

package pcie_dpu_tl_backend_pkg;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import pcie_topology_pkg::*;
  import pcie_tl_pkg::*;
  import pcie_dpu_integration_pkg::*;
  `include "uvm_macros.svh"

  class pcie_dpu_tl_reg_executor extends pcie_dpu_reg_executor_base;
    `uvm_object_utils(pcie_dpu_tl_reg_executor)

    protected pcie_tl_virtual_sequencer tl_vseqr;
    protected uvm_sequencer #(pcie_tl_tlp) selected_rc_seqr;
    protected int unsigned rc_index;

    function new(string name = "pcie_dpu_tl_reg_executor");
      super.new(name);
      tl_vseqr = null;
      selected_rc_seqr = null;
      rc_index = 0;
    endfunction

    // rc_index selects one independent root in multi-root TL environments.
    // Index zero may use the legacy rc_seqr alias when no array was published.
    function void configure(
        pcie_tl_virtual_sequencer new_vseqr,
        pcie_global_cfg new_global_cfg,
        dpu_execution_report new_report = null,
        int unsigned new_rc_index = 0);
      tl_vseqr = new_vseqr;
      rc_index = new_rc_index;
      selected_rc_seqr = null;
      configure_common(new_global_cfg, new_report);
    endfunction

    protected virtual function bit backend_ready(output string why);
      why = "";
      selected_rc_seqr = null;
      if (tl_vseqr == null) begin
        why = "TL executor requires a non-null virtual sequencer";
        return 1'b0;
      end

      if (rc_index < tl_vseqr.rc_seqr_arr.size())
        selected_rc_seqr = tl_vseqr.rc_seqr_arr[rc_index];
      else if ((rc_index == 0) && (tl_vseqr.rc_seqr != null))
        selected_rc_seqr = tl_vseqr.rc_seqr;

      if (selected_rc_seqr == null) begin
        why = $sformatf(
          "TL executor cannot resolve RC sequencer index %0d", rc_index);
        return 1'b0;
      end
      return 1'b1;
    endfunction

    protected function bit [3:0] byte_enable(
        bit [11:0] byte_offset,
        int unsigned width_bytes);
      bit [3:0] enables;

      enables = '0;
      for (int unsigned index = 0; index < width_bytes; index++)
        enables[byte_offset[1:0] + index] = 1'b1;
      return enables;
    endfunction

    protected virtual task transport_cfg_write(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        int unsigned width_bytes,
        bit [63:0] data,
        output bit succeeded,
        output string why);
      pcie_tl_cfg_wr_seq tl_sequence;

      tl_sequence = pcie_tl_cfg_wr_seq::type_id::create("dpu_cfg_write");
      tl_sequence.target_bdf = bdf;
      tl_sequence.reg_num = byte_offset[11:2];
      tl_sequence.first_be = byte_enable(byte_offset, width_bytes);
      tl_sequence.wr_data = data[31:0] << (8 * byte_offset[1:0]);
      tl_sequence.is_type1 = (bdf[15:8] > 8'h01);
      tl_sequence.start(selected_rc_seqr);
      succeeded = (tl_sequence.status == PCIE_RW_OK);
      why = succeeded ? "" : $sformatf(
        "TL Configuration Write failed at BDF=%04x offset=0x%03x",
        bdf, byte_offset);
    endtask

    protected virtual task transport_cfg_read(
        bit [15:0] bdf,
        bit [11:0] byte_offset,
        int unsigned width_bytes,
        output bit [63:0] data,
        output bit succeeded,
        output string why);
      pcie_tl_cfg_rd_seq tl_sequence;

      tl_sequence = pcie_tl_cfg_rd_seq::type_id::create("dpu_cfg_read");
      tl_sequence.target_bdf = bdf;
      tl_sequence.reg_num = byte_offset[11:2];
      tl_sequence.first_be = byte_enable(byte_offset, width_bytes);
      tl_sequence.is_type1 = (bdf[15:8] > 8'h01);
      tl_sequence.start(selected_rc_seqr);
      succeeded = (tl_sequence.status == PCIE_RW_OK);
      data = succeeded ?
        ((64'(tl_sequence.rd_data) >> (8 * byte_offset[1:0])) &
         ((64'h1 << (width_bytes * 8)) - 1)) : '0;
      why = succeeded ? "" : $sformatf(
        "TL Configuration Read failed at BDF=%04x offset=0x%03x",
        bdf, byte_offset);
    endtask

    protected virtual task transport_mmio_write(
        bit [63:0] bus_address,
        int unsigned width_bytes,
        bit [63:0] data,
        output bit succeeded,
        output string why);
      pcie_tl_rw_seq tl_sequence;

      tl_sequence = pcie_tl_rw_seq::type_id::create("dpu_mmio_write");
      tl_sequence.op = PCIE_RW_WRITE;
      tl_sequence.addr = bus_address;
      tl_sequence.byte_len = width_bytes;
      tl_sequence.wdata = new[width_bytes];
      foreach (tl_sequence.wdata[index])
        tl_sequence.wdata[index] = data[index * 8 +: 8];
      tl_sequence.start(selected_rc_seqr);
      succeeded = (tl_sequence.status == PCIE_RW_OK);
      why = succeeded ? "" : $sformatf(
        "TL Memory Write failed at address 0x%016h", bus_address);
    endtask

    protected virtual task transport_mmio_read(
        bit [63:0] bus_address,
        int unsigned width_bytes,
        output bit [63:0] data,
        output bit succeeded,
        output string why);
      pcie_tl_rw_seq tl_sequence;

      tl_sequence = pcie_tl_rw_seq::type_id::create("dpu_mmio_read");
      tl_sequence.op = PCIE_RW_READ;
      tl_sequence.addr = bus_address;
      tl_sequence.byte_len = width_bytes;
      tl_sequence.start(selected_rc_seqr);
      succeeded = (tl_sequence.status == PCIE_RW_OK) &&
                  (tl_sequence.rdata.size() == width_bytes);
      data = '0;
      if (succeeded)
        foreach (tl_sequence.rdata[index])
          data[index * 8 +: 8] = tl_sequence.rdata[index];
      why = succeeded ? "" : $sformatf(
        "TL Memory Read failed at address 0x%016h", bus_address);
    endtask
  endclass : pcie_dpu_tl_reg_executor
endpackage : pcie_dpu_tl_backend_pkg
