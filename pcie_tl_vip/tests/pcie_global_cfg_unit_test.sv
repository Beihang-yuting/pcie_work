//------------------------------------------------------------------------------
// PCIe global configuration contract test.
//
// This test is intentionally backend-neutral.  It verifies that the global
// object preserves the existing topology graph and rejects configurations that
// would exceed the statically compiled HDL/UVM limits before a backend is built.
//------------------------------------------------------------------------------
import uvm_pkg::*;
import pcie_topology_pkg::*;
`include "uvm_macros.svh"

class pcie_global_cfg_unit_test extends uvm_test;
  `uvm_component_utils(pcie_global_cfg_unit_test)

  function new(string name = "pcie_global_cfg_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("GLOBAL_CFG", message)
  endfunction

  function void expect_error(string errors[$], string fragment,
                              string label);
    bit found;

    found = 1'b0;
    foreach (errors[i]) begin
      if ((fragment.len() != 0) && (errors[i].len() >= fragment.len())) begin
        for (int j = 0; j <= errors[i].len() - fragment.len(); j++) begin
          if (errors[i].substr(j, j + fragment.len() - 1) == fragment)
            found = 1'b1;
        end
      end
    end
    require(found, {label, ": expected validation message was not found"});
  endfunction

  task run_phase(uvm_phase phase);
    pcie_topology_cfg topology;
    pcie_global_cfg global_cfg;
    pcie_global_cfg invalid_cfg;
    pcie_global_cfg svt_cfg;
    pcie_link_cfg extra_link;
    string errors[$];

    phase.raise_objection(this);

    // The three profile builders remain the source of topology connectivity;
    // global-cfg must add policy without rebuilding those graph edges.
    topology = pcie_topology_builder::build_ep_x16(4);
    global_cfg = pcie_global_cfg::type_id::create("ep_x16_global_cfg");
    global_cfg.build_default_for_topology(topology);
    global_cfg.backend = PCIE_BACKEND_TL_ONLY;
    global_cfg.runtime_num_links = topology.links.size();
    global_cfg.validate(errors);
    require(errors.size() == 0,
            "valid EP_X16 TL-only configuration produced validation errors");
    require(global_cfg.topology == topology,
            "global-cfg did not preserve the authoritative topology handle");
    require(global_cfg.links.size() == 1,
            $sformatf("EP_X16 link count expected 1, got %0d",
                      global_cfg.links.size()));
    require(global_cfg.devices.size() == topology.nodes.size(),
            "default device records do not cover every topology node");

    // SVT link policy must identify the physical node simulated by SVT.  The
    // explicit node/role pair is what distinguishes SVT RC + DUT EP from DUT
    // RC + SVT EP on the same graph edge.
    svt_cfg = pcie_global_cfg::type_id::create("svt_global_cfg");
    svt_cfg.build_default_for_topology(topology);
    svt_cfg.backend = PCIE_BACKEND_SVT_REAL_DUT;
    svt_cfg.links[0].use_svt = 1'b1;
    svt_cfg.links[0].svt_role_valid = 1'b1;
    svt_cfg.links[0].svt_node_id = "RC0";
    svt_cfg.links[0].svt_role = PCIE_DEVICE_RC;
    svt_cfg.links[0].has_hdl_slot = 1'b1;
    svt_cfg.links[0].hdl_slot = 0;
    svt_cfg.links[0].vif_key = "link_0_vif_0";
    errors.delete();
    svt_cfg.validate(errors);
    require(errors.size() == 0,
            "valid SVT RC link policy produced validation errors");

    // The SVT node must be one of this link's two graph endpoints.  Merely
    // naming an existing RC/EP node is insufficient: accepting an unrelated
    // node would bind the backend agent to the wrong physical link.
    svt_cfg = pcie_global_cfg::type_id::create("svt_unrelated_node_cfg");
    svt_cfg.build_default_for_topology(
      pcie_topology_builder::build_ep_2x8(4));
    svt_cfg.backend = PCIE_BACKEND_SVT_REAL_DUT;
    svt_cfg.links[0].use_svt = 1'b1;
    svt_cfg.links[0].svt_role_valid = 1'b1;
    svt_cfg.links[0].svt_role = PCIE_DEVICE_RC;
    // RC1 is a valid RC node in the graph, but is not an endpoint of RC0_EP0.
    svt_cfg.links[0].svt_node_id = "RC1";
    errors.delete();
    svt_cfg.validate(errors);
    expect_error(errors, "not an endpoint of link", "SVT endpoint ownership");

    // A runtime link count above the compile-time limit must be rejected before
    // any backend creates an agent or HDL-facing object.
    invalid_cfg = pcie_global_cfg::type_id::create("invalid_limit_cfg");
    invalid_cfg.build_default_for_topology(topology);
    invalid_cfg.runtime_num_links = `PCIE_SVT_ENV_MAX_NUM_LINKS + 1;
    errors.delete();
    invalid_cfg.validate(errors);
    expect_error(errors, "runtime_num_links", "compile-limit rejection");

    // Duplicate HDL slots are ambiguous because one static VIF cannot belong to
    // two logical links.  The validator must catch this independently of backend.
    if (global_cfg.links.size() > 0) begin
      global_cfg.links[0].has_hdl_slot = 1'b1;
      global_cfg.links[0].hdl_slot = 0;
      extra_link = pcie_link_cfg::type_id::create("duplicate_slot_link");
      extra_link.link_id = "duplicate_slot_link";
      extra_link.enabled = 1'b1;
      extra_link.hdl_slot = global_cfg.links[0].hdl_slot;
      extra_link.has_hdl_slot = 1'b1;
      global_cfg.links.push_back(extra_link);
      errors.delete();
      global_cfg.validate(errors);
      expect_error(errors, "HDL slot", "duplicate-slot rejection");
    end

    phase.drop_objection(this);
  endtask
endclass
