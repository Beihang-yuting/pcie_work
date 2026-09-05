import uvm_pkg::*;
import dpu_resource_pkg::*;
import pcie_topology_pkg::*;
import pcie_dpu_integration_pkg::*;
`include "uvm_macros.svh"

// Test-only probe used to create a malformed frozen snapshot.  Production
// code never mutates a frozen snapshot; the probe lets the adapter's
// preflight checks be exercised without weakening snapshot encapsulation.
class pcie_dpu_corruptible_snapshot extends dpu_device_snapshot;
  `uvm_object_utils(pcie_dpu_corruptible_snapshot)

  function new(string name = "pcie_dpu_corruptible_snapshot");
    super.new(name);
  endfunction

  function void corrupt_bar_base(
      dpu_function_key_t key,
      dpu_bar_role_e role,
      bit [63:0] base);
    m_bars[dpu_function_bar_key_name(key, role)].base = base;
  endfunction
endclass

class pcie_dpu_cfg_adapter_unit_test extends uvm_test;
  `uvm_component_utils(pcie_dpu_cfg_adapter_unit_test)

  function new(string name = "pcie_dpu_cfg_adapter_unit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void require(bit condition, string message);
    if (!condition)
      `uvm_error("DPU_CFG_ADAPTER", message)
  endfunction

  function dpu_function_key_t pf0_key();
    dpu_function_key_t key;
    key.host_id = 0;
    key.pf_id = 0;
    key.kind = DPU_FUNCTION_PF;
    key.vf_id = 0;
    return key;
  endfunction

  function dpu_device_snapshot make_snapshot(
      bit corrupt_base = 1'b0);
    dpu_device_snapshot snapshot;
    dpu_dut_caps caps;
    dpu_function_key_t key;
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    string why;

    snapshot = corrupt_base ?
      pcie_dpu_corruptible_snapshot::type_id::create("snapshot") :
      dpu_device_snapshot::type_id::create("snapshot");
    caps = dpu_dut_caps::type_id::create("caps");
    key = pf0_key();
    pcie_id.domain.host_id = 0;
    pcie_id.domain.segment_id = 3;
    pcie_id.bdf = 16'h2340;
    require(snapshot.set_dut_caps(caps, why), {"set caps: ", why});
    require(snapshot.add_function(key, pcie_id, why),
            {"add function: ", why});
    bar.role = DPU_BAR_DEVICE_MEMORY;
    bar.even_bar_id = 0;
    bar.base = 64'h0000_0001_0000_0000;
    bar.size = 64'h0000_0000_0200_0000;
    require(snapshot.add_bar(key, bar, why), {"add BAR0: ", why});
    bar.role = DPU_BAR_MAILBOX;
    bar.even_bar_id = 2;
    bar.base = 64'h0000_0001_0200_0000;
    bar.size = 64'h0000_0000_0001_0000;
    require(snapshot.add_bar(key, bar, why), {"add BAR2: ", why});
    bar.role = DPU_BAR_MSIX;
    bar.even_bar_id = 4;
    bar.base = 64'h0000_0001_0201_0000;
    bar.size = 64'h0000_0000_0001_0000;
    require(snapshot.add_bar(key, bar, why), {"add BAR4: ", why});
    require(snapshot.set_expected_af(key, why), {"set AF: ", why});
    require(snapshot.freeze(why), {"freeze snapshot: ", why});

    if (corrupt_base) begin
      pcie_dpu_corruptible_snapshot corruptible;
      if (!$cast(corruptible, snapshot))
        `uvm_fatal("DPU_CFG_ADAPTER", "snapshot corruption cast failed")
      corruptible.corrupt_bar_base(key, DPU_BAR_MAILBOX,
                                   64'h0000_0001_0200_0001);
    end
    return snapshot;
  endfunction

  function pcie_topology_cfg make_topology();
    pcie_topology_cfg topology;
    pcie_topology_node_cfg rc;
    pcie_topology_node_cfg ep;
    pcie_topology_link_cfg link;

    topology = pcie_topology_cfg::type_id::create("topology");
    rc = pcie_topology_node_cfg::type_id::create("RC0");
    rc.node_id = "RC0";
    rc.kind = PCIE_TOPO_NODE_RC;
    ep = pcie_topology_node_cfg::type_id::create("EP0");
    ep.node_id = "EP0";
    ep.kind = PCIE_TOPO_NODE_EP;
    link = pcie_topology_link_cfg::type_id::create("RC0_EP0");
    link.link_id = "RC0_EP0";
    link.upstream_node_id = "RC0";
    link.upstream_role = PCIE_TOPO_PORT_RC;
    link.downstream_node_id = "EP0";
    link.downstream_role = PCIE_TOPO_PORT_EP;
    link.link_width = 16;
    link.max_gen = 4;
    topology.nodes.push_back(rc);
    topology.nodes.push_back(ep);
    topology.links.push_back(link);
    return topology;
  endfunction

  function pcie_dpu_attachment_cfg make_attachments();
    pcie_dpu_attachment_cfg attachments;
    string why;
    attachments = pcie_dpu_attachment_cfg::type_id::create("attachments");
    require(attachments.add(pf0_key(), "EP0", "RC0_EP0", 1'b1, 0, why),
            {"add attachment: ", why});
    return attachments;
  endfunction

  task run_phase(uvm_phase phase);
    pcie_dpu_cfg_adapter adapter;
    pcie_global_cfg global_cfg;
    pcie_topology_cfg topology;
    pcie_dpu_attachment_cfg attachments;
    pcie_dpu_root_binding_cfg root_bindings;
    dpu_device_snapshot snapshot;
    string errors[$];
    string why;
    bit [15:0] expected_bdf;

    phase.raise_objection(this);
    adapter = pcie_dpu_cfg_adapter::type_id::create("adapter");
    topology = make_topology();
    attachments = make_attachments();
    root_bindings = pcie_dpu_root_binding_cfg::type_id::create(
      "root_bindings");
    require(root_bindings.bind_domain_to_root(0, 3, 0, why),
            {"add Root binding: ", why});
    expected_bdf = 16'h2340;

    snapshot = make_snapshot();
    require(adapter.project(snapshot, null, topology, attachments,
                            global_cfg, errors),
            "valid frozen snapshot projection failed");
    require(errors.size() == 0, "valid projection returned errors");
    require(global_cfg != null, "valid projection returned null global cfg");
    require(global_cfg.devices.size() == 2,
            "projection should retain RC and add one DPU EP function");
    require(global_cfg.devices[1].bdf == expected_bdf,
            "projected BDF does not match frozen DPU BDF");
    require(global_cfg.devices[1].domain_segment_id == 3,
            "projected domain segment was not preserved");
    require(global_cfg.devices[1].domain_host_id == 0,
            "projected domain host was not preserved");
    require(global_cfg.devices[1].bars[0].initial_base ==
            64'h0000_0001_0000_0000 &&
            global_cfg.devices[1].bars[0].aperture ==
            64'h0000_0000_0200_0000 &&
            global_cfg.devices[1].bars[0].is_64bit &&
            global_cfg.devices[1].bars[0].prefetchable,
            "BAR0 projection does not match frozen lease");
    require(global_cfg.devices[1].bars[2].initial_base ==
            64'h0000_0001_0200_0000 &&
            global_cfg.devices[1].bars[4].initial_base ==
            64'h0000_0001_0201_0000,
            "BAR role mapping does not preserve BAR2/BAR4 bases");
    require(global_cfg.devices[1].physical_node_id == "EP0" &&
            global_cfg.devices[1].link_id == "RC0_EP0",
            "physical attachment was not carried into device policy");

    global_cfg = null;
    errors.delete();
    require(adapter.project_with_root_bindings(
              snapshot, null, topology, attachments, root_bindings,
              global_cfg, errors),
            "Root-aware frozen snapshot projection failed");
    require(global_cfg.devices[1].root_index_valid &&
            (global_cfg.devices[1].root_index == 0),
            "Root/domain binding was not projected onto DPU device");

    // 拓扑可以保留一个尚未承载 DPU function 的空 Root。只要该 Root
    // 仍有显式逻辑域绑定，快照校验不应把“快照域数量较少”误判为错误。
    begin
      pcie_dpu_root_binding_cfg empty_root_bindings;

      empty_root_bindings = pcie_dpu_root_binding_cfg::type_id::create(
        "empty_root_bindings");
      require(empty_root_bindings.bind_domain_to_root(0, 3, 0, why),
              {"bind populated Root: ", why});
      require(empty_root_bindings.bind_domain_to_root(9, 9, 1, why),
              {"bind empty Root: ", why});
      errors.delete();
      empty_root_bindings.validate_for_snapshot(snapshot, 2, errors);
      require(errors.size() == 0,
              "a legal empty Root was rejected by snapshot validation");
    end

    snapshot = dpu_device_snapshot::type_id::create("unfrozen");
    global_cfg = null;
    errors.delete();
    require(!adapter.project(snapshot, null, topology, attachments,
                             global_cfg, errors),
            "unfrozen snapshot was accepted");
    require(global_cfg == null && errors.size() != 0,
            "unfrozen snapshot created backend policy");

    snapshot = make_snapshot();
    attachments = pcie_dpu_attachment_cfg::type_id::create("missing");
    global_cfg = null;
    errors.delete();
    require(!adapter.project(snapshot, null, topology, attachments,
                             global_cfg, errors),
            "missing physical attachment was accepted");
    require(global_cfg == null && errors.size() != 0,
            "missing attachment created backend policy");

    root_bindings = pcie_dpu_root_binding_cfg::type_id::create("missing_root");
    global_cfg = null;
    errors.delete();
    require(!adapter.project_with_root_bindings(
              snapshot, null, topology, make_attachments(), root_bindings,
              global_cfg, errors),
            "missing Root/domain binding was accepted");
    require(global_cfg == null && errors.size() != 0,
            "missing Root binding created backend policy");

    snapshot = make_snapshot(1'b1);
    global_cfg = null;
    errors.delete();
    require(!adapter.project(snapshot, null, topology, make_attachments(),
                             global_cfg, errors),
            "misaligned BAR pair was accepted");
    require(global_cfg == null && errors.size() != 0,
            "invalid BAR pair created backend policy");
    phase.drop_objection(this);
  endtask
endclass
