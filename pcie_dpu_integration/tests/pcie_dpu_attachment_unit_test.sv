import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_dpu_integration_pkg::*;
`include "uvm_macros.svh"

class pcie_dpu_attachment_unit_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_attachment_unit_test)

  function new(string name = "pcie_dpu_attachment_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_ATTACHMENT", message)
  endfunction

  function dpu_function_key_t function_key(
      int unsigned host_id,
      int unsigned pf_id,
      dpu_function_kind_e kind,
      int unsigned vf_id);
    dpu_function_key_t key;
    key.host_id = host_id;
    key.pf_id = pf_id;
    key.kind = kind;
    key.vf_id = vf_id;
    return key;
  endfunction

  task run_phase(uvm_phase phase);
    pcie_dpu_attachment_cfg attachments;
    dpu_function_key_t pf0;
    dpu_function_key_t pf1;
    string physical_node_id;
    string link_id;
    bit has_function_number;
    int unsigned function_number;
    string errors[$];
    string why;

    phase.raise_objection(this);

    attachments = pcie_dpu_attachment_cfg::type_id::create("attachments");
    pf0 = function_key(0, 0, DPU_FUNCTION_PF, 0);
    pf1 = function_key(0, 1, DPU_FUNCTION_PF, 0);

    require(attachments.add(pf0, "EP0", "RC0_EP0", 1'b1, 0, why),
            {"PF0 attachment rejected: ", why});
    require(attachments.add(pf1, "EP1", "RC0_EP1", 1'b1, 0, why),
            {"PF1 attachment rejected: ", why});
    require(attachments.find_by_function(
              pf1, physical_node_id, link_id,
              has_function_number, function_number),
            "PF1 attachment lookup failed");
    require(physical_node_id == "EP1" && link_id == "RC0_EP1" &&
            has_function_number && function_number == 0,
            "PF1 attachment lookup returned wrong mapping");
    attachments.validate(errors);
    require(errors.size() == 0,
            "valid attachment set produced validation errors");

    require(!attachments.add(pf0, "EP2", "RC0_EP2", 1'b0, 0, why),
            "duplicate function key was accepted");

    attachments = pcie_dpu_attachment_cfg::type_id::create(
      "empty_link_attachments");
    require(!attachments.add(pf0, "EP0", "", 1'b0, 0, why),
            "empty link ID was accepted");

    attachments = pcie_dpu_attachment_cfg::type_id::create(
      "function_collision_attachments");
    require(attachments.add(pf0, "EP0", "RC0_EP0", 1'b1, 0, why),
            "first function-number attachment was rejected");
    require(!attachments.add(pf1, "EP0", "RC0_EP0", 1'b1, 0, why),
            "function-number collision on one Endpoint was accepted");

    phase.drop_objection(this);
  endtask
endclass
