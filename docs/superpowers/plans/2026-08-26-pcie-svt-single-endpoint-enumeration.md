# Active Target App BAR Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make R-2020.12 Single-Endpoint SVT peers complete DUT-style BAR probing and official enumeration with three correctly sized 64-bit Prefetchable BARs.

**Architecture:** Each normalized Single-Endpoint descriptor configures one active Target App callback owned by `pcie_svt_topology_env`. The callback observes write-all-ones BAR probes and rewrites only their matching Completion payloads, while the official enumeration wrapper uses `is_ep_device_vip=0` and normal Target App handling remains responsible for Configuration and Memory traffic.

**Tech Stack:** SystemVerilog, UVM 1.2 callbacks, Synopsys SVT PCIe R-2020.12, VCS W-2024.09-SP1, serial PHY peer harness

---

## Working-State Contract

Use the existing isolated worktree and branch:

```text
/home/ryan/.config/superpowers/worktrees/pcie_work/svt-topology-env-rewrite
feature/svt-topology-env-rewrite
```

The baseline commits already provide per-port Endpoint selection, the PF0
capability image, model-specific CFG initialization, and the approved design:

```text
0d657d0 feat(pcie-svt): select endpoint model per port
c8a2284 feat(pcie-svt): build enumeratable endpoint PF0 image
1f8bd2a fix(pcie-svt): initialize target app by endpoint model
1c8267d docs(pcie-svt): correct single endpoint BAR sizing design
```

Preserve these uncommitted Task-4 enumeration files until Task 4 commits them:

```text
svt_pcie_integration/sim/pcie_svt_topology.f
svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv
svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv
svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv
svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv
svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv
```

Do not restore the rejected passive-monitor experiment. Do not change the
Synopsys installation, use `defparam` or `force`, or suppress warnings.

## File Responsibility Map

- Create `svt_pcie_integration/uvm/callbacks/pcie_svt_topology_ep_bar_sizing_callback.sv`: descriptor-driven active Target App sizing behavior.
- Create `svt_pcie_integration/sim/pcie_svt_topology_ep_bar_sizing_callback_unit_test.sv`: callback protocol, isolation, byte order, and failure tests.
- Modify `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`: own, select, register, and expose callback state per port.
- Modify `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv`: preload ordinary initial BAR values rather than sizing masks.
- Modify `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`: require a Single-Endpoint peer and force DUT-style probing.
- Modify `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv`: exact initial-image and callback-selection tests.
- Modify `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`: peer-model mapping, registration checks, and callback-idle checks.
- Modify `svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv`: wrapper model gate and DUT-semantics assertions.
- Modify `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`: include the callback after descriptor/config-space types and before the environment.
- Modify `svt_pcie_integration/sim/pcie_svt_topology.f`: compile the standalone callback test.
- Modify `svt_pcie_integration/sim/README.md`: record the proven Single-Endpoint configuration and acceptance commands.

## Remote VCS Commands

All simulation runs execute on `ubuntu@10.11.10.53` in the existing remote
tree. Stage without deleting remote build directories:

```bash
sshpass -p 123 rsync -az \
  --exclude '.git' --exclude 'sim/build*' \
  /home/ryan/.config/superpowers/worktrees/pcie_work/svt-topology-env-rewrite/ \
  ubuntu@10.11.10.53:/home/ubuntu/pcie-svt-topology.7mYKzi/
```

Open a login shell for every build or run:

```bash
sshpass -p 123 ssh ubuntu@10.11.10.53
bash -lic 'cd /home/ubuntu/pcie-svt-topology.7mYKzi/svt_pcie_integration/sim; exec bash -i'
export DESIGNWARE_HOME=/home/ubuntu/synopsys/designware_vip_R-2020.12
export PCIE_SVT_ROOT="$DESIGNWARE_HOME/vip/svt/pcie_svt/R-2020.12"
```

The canonical x16 compile command is:

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1fs \
  +define+UVM_DISABLE_AUTO_ITEM_RECORDING \
  +define+SVT_PCIE_ENABLE_GEN5 +define+SVT_PCIE_ENABLE_SERDES_ARCH \
  +define+PCIE_TOPO_EP_X16 +define+PCIE_USE_SVT_PEER \
  -f pcie_svt_topology.f -top pcie_svt_topology_top \
  -Mdir=BUILD_DIR/csrc -P pli.tab msglog.o \
  -o BUILD_DIR/simv -l BUILD_DIR/compile.log
```

Replace both `BUILD_DIR` occurrences with the directory named in each task.
For 2x8 and Switch builds, replace only `PCIE_TOPO_EP_X16` with
`PCIE_TOPO_EP_2X8` or `PCIE_TOPO_SWITCH_1X16_4X4`.

---

### Task 1: Restore Ordinary Initial BAR Values in the PF0 Image

**Files:**

- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv:527`
- Modify: `svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv:157`

- [ ] **Step 1: Change the unit test to demand ordinary initial BAR values**

Keep the direct `bar_sizing_value()` assertions because the callback will use
that helper. Replace only the six PF0 image assertions with:

```systemverilog
require(image['h010/4] == 32'h0000_000c &&
        image['h014/4] == 32'h0000_0000,
        "PF0 BAR0/1 initial pair is wrong");
require(image['h018/4] == 32'h0000_000c &&
        image['h01c/4] == 32'h0000_0000,
        "PF0 BAR2/3 initial pair is wrong");
require(image['h020/4] == 32'h0000_000c &&
        image['h024/4] == 32'h0000_0000,
        "PF0 BAR4/5 initial pair is wrong");
```

- [ ] **Step 2: Compile and run the test to verify RED**

Stage the tree, compile to `build_bar_initial_red`, and run:

```bash
./build_bar_initial_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_device_cfg_unit_test +UVM_NO_RELNOTES \
  -l build_bar_initial_red/device_cfg_unit.log
```

Expected: the test reports the old values `fe00_000c/ffff_ffff` or
`ffff_000c/ffff_ffff` and exits with a non-zero UVM error count.

- [ ] **Step 3: Make `build_ep_pf0()` use initial values for both models**

Replace the mode-dependent loop with:

```systemverilog
for (int unsigned i = 0; i < 6; i++) begin
  if ((i > 0) && descriptor.ep_bars[i-1].implemented &&
      descriptor.ep_bars[i-1].is_64bit)
    image[4+i] = bar_initial_value(descriptor.ep_bars[i-1], 1'b1);
  else
    image[4+i] = bar_initial_value(descriptor.ep_bars[i], 1'b0);
end
```

Do not remove `bar_sizing_value()`; it remains the single calculation used by
the active callback and its tests.

- [ ] **Step 4: Rebuild and verify GREEN**

Compile to `build_bar_initial_green`, rerun the device configuration unit test,
and require:

```text
UVM_WARNING : 0
UVM_ERROR   : 0
UVM_FATAL   : 0
```

- [ ] **Step 5: Commit the initial-image correction**

```bash
git add \
  svt_pcie_integration/uvm/cfg/pcie_svt_cfg_space_builder.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv
git commit -m "fix(pcie-svt): keep endpoint BAR image programmable"
```

---

### Task 2: Implement the Descriptor-Driven Active Target App Callback

**Files:**

- Create: `svt_pcie_integration/uvm/callbacks/pcie_svt_topology_ep_bar_sizing_callback.sv`
- Create: `svt_pcie_integration/sim/pcie_svt_topology_ep_bar_sizing_callback_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`

- [ ] **Step 1: Add a standalone failing callback test**

Add this line after `pcie_svt_topology_pkg.sv` in the file list:

```text
../sim/pcie_svt_topology_ep_bar_sizing_callback_unit_test.sv
```

Create this report catcher followed by the test module:

```systemverilog
import uvm_pkg::*;
`include "uvm_macros.svh"

class pcie_svt_topology_bar_expected_fatal_catcher extends
    uvm_report_catcher;
  string expected_id;
  int unsigned catch_count;

  function new(string name = "expected_fatal_catcher");
    super.new(name);
  endfunction

  function void arm(string report_id);
    expected_id = report_id;
  endfunction

  virtual function action_e catch();
    if ((get_severity() == UVM_FATAL) && (get_id() == expected_id)) begin
      catch_count++;
      set_severity(UVM_INFO);
      set_action(UVM_DISPLAY);
      return THROW;
    end
    return THROW;
  endfunction
endclass

module pcie_svt_topology_ep_bar_sizing_callback_unit_test;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import svt_pcie_uvm_pkg::*;
  import pcie_svt_topology_pkg::*;

  function automatic void require(bit condition, string message);
    if (!condition)
      `uvm_fatal("TOPO_BAR_CB_TEST", message)
  endfunction

  function automatic svt_pcie_tlp make_cfg(
      string name, int unsigned bar_number, bit is_write,
      bit [31:0] raw_payload, bit [9:0] tag);
    svt_pcie_tlp request = new(name);
    request.tlp_type = svt_pcie_tlp::TYPE_0_CFG_REQ;
    request.fmt = is_write ? svt_pcie_tlp::WITH_DATA_3_DWORD :
                             svt_pcie_tlp::NO_DATA_3_DWORD;
    request.length = 1;
    request.requester_id = 16'h0000;
    request.tag = tag;
    request.function_number = 0;
    request.register_number = 10'h004 + bar_number;
    request.first_dw_be = 4'hf;
    request.last_dw_be = 4'h0;
    request.payload = new[is_write ? 1 : 0];
    if (is_write)
      request.payload[0] = raw_payload;
    return request;
  endfunction

  function automatic svt_pcie_tlp make_completion(
      string name, svt_pcie_tlp request, bit [31:0] raw_payload);
    svt_pcie_tlp completion = new(name);
    completion.tlp_type = svt_pcie_tlp::CPL;
    completion.fmt = svt_pcie_tlp::WITH_DATA_3_DWORD;
    completion.length = 1;
    completion.requester_id = request.requester_id;
    completion.tag = request.tag;
    completion.completion_status = svt_pcie_tlp::SUCCESSFUL;
    completion.payload = new[1];
    completion.payload[0] = raw_payload;
    return completion;
  endfunction

  function automatic pcie_svt_port_descriptor make_descriptor();
    pcie_svt_port_descriptor descriptor =
      pcie_svt_port_descriptor::type_id::create("descriptor");
    descriptor.link_id = "PEER_LINK_0";
    descriptor.role = PCIE_SVT_ROLE_EP;
    descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
    foreach (descriptor.ep_bars[i]) begin
      descriptor.ep_bars[i].implemented = 1'b0;
      descriptor.ep_bars[i].initial_base = 0;
    end
    foreach (descriptor.ep_bars[i]) begin
      if (i inside {0, 2, 4}) begin
        descriptor.ep_bars[i].implemented = 1'b1;
        descriptor.ep_bars[i].is_64bit = 1'b1;
        descriptor.ep_bars[i].prefetchable = 1'b1;
        descriptor.ep_bars[i].aperture =
          (i == 0) ? 64'd33554432 : 64'd65536;
      end
    end
    return descriptor;
  endfunction

  initial begin
    const bit [31:0] expected_raw_mask[6] = '{
      32'h0c00_00fe, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff,
      32'h0c00_ffff, 32'hffff_ffff};
    pcie_svt_topology_ep_bar_sizing_callback callback;
    pcie_svt_topology_bar_expected_fatal_catcher catcher;
    pcie_svt_port_descriptor descriptor;
    svt_pcie_tlp sizing_read[6];
    svt_pcie_tlp transaction;
    bit drop = 1'b0;

    callback = pcie_svt_topology_ep_bar_sizing_callback::type_id::create(
      "callback");
    catcher = new("catcher");
    uvm_report_cb::add(null, catcher);
    descriptor = make_descriptor();
    callback.configure(descriptor);

    transaction = make_cfg("ordinary_read", 0, 0, 0, 10'h010);
    callback.post_rx_tlp_get(null, transaction, drop);
    transaction = make_completion(
      "ordinary_completion", transaction, 32'h0c00_0010);
    callback.pre_tx_tlp_put(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h0c00_0010,
            "ordinary BAR read was modified or dropped");

    transaction = make_cfg("non_bar_cfg", 0, 1, 32'h4433_2211, 10'h011);
    transaction.register_number = 10'h001;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h4433_2211,
            "non-BAR Configuration write was modified or dropped");

    transaction = make_cfg("other_function", 0, 1, 32'h8877_6655, 10'h012);
    transaction.function_number = 1;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.payload[0] == 32'h8877_6655,
            "another Function's Configuration write was modified or dropped");

    for (int unsigned bar = 0; bar < 6; bar++) begin
      transaction = make_cfg(
        $sformatf("size_write_%0d", bar), bar, 1,
        32'hffff_ffff, 10'h020 + bar);
      callback.post_rx_tlp_get(null, transaction, drop);
      sizing_read[bar] = make_cfg(
        $sformatf("size_read_%0d", bar), bar, 0, 0, 10'h100 + bar);
      callback.post_rx_tlp_get(null, sizing_read[bar], drop);
    end
    for (int bar = 5; bar >= 0; bar--) begin
      transaction = make_completion(
        $sformatf("size_cpl_%0d", bar), sizing_read[bar], 0);
      callback.pre_tx_tlp_put(null, transaction, drop);
      require(transaction.payload[0] === expected_raw_mask[bar],
        $sformatf("BAR%0d sizing payload expected=%08h actual=%08h",
          bar, expected_raw_mask[bar], transaction.payload[0]));
    end

    transaction = make_cfg("assigned", 0, 1, 32'h0000_0010, 10'h180);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(transaction.payload[0] == 32'h0c00_0010,
            "assigned BAR write lost 64-bit Prefetchable attributes");
    transaction = make_cfg("assigned_upper", 1, 1,
                           32'h1000_0000, 10'h181);
    callback.post_rx_tlp_get(null, transaction, drop);
    require(transaction.payload[0] == 32'h1000_0000,
            "upper BAR DWORD received low-DWORD attributes");

    transaction = new("memory_request");
    transaction.tlp_type = svt_pcie_tlp::MEM_REQ;
    transaction.fmt = svt_pcie_tlp::NO_DATA_4_DWORD;
    callback.post_rx_tlp_get(null, transaction, drop);
    require(!drop && transaction.tlp_type == svt_pcie_tlp::MEM_REQ,
            "Memory request was modified or dropped");

    require(callback.is_idle(), "callback retained probe state");
    require(callback.sizing_write_count == 6 &&
            callback.sizing_read_count == 6 &&
            callback.sizing_completion_count == 6,
            "callback counters are unbalanced");
    $display("TOPOLOGY_EP_BAR_SIZING_CALLBACK_PASS bars=6 ordinary=5 memory=1");
    $finish;
  end
endmodule
```

- [ ] **Step 2: Compile the standalone top to verify RED**

Use the common compile flags, change `-top` to
`pcie_svt_topology_ep_bar_sizing_callback_unit_test`, and build
`build_topology_bar_cb_red`.

Expected: compilation fails because
`pcie_svt_topology_ep_bar_sizing_callback` is undefined.

- [ ] **Step 3: Add the complete callback implementation**

Add `+incdir+../uvm/callbacks` to `pcie_svt_topology.f`. Include the new class
in `pcie_svt_topology_pkg.sv` after `pcie_svt_cfg_space_builder.sv` and before
`pcie_svt_topology_env.sv`:

```systemverilog
`include "callbacks/pcie_svt_topology_ep_bar_sizing_callback.sv"
```

Create the class with this state and behavior:

```systemverilog
class pcie_svt_topology_ep_bar_sizing_callback extends
    svt_pcie_target_app_callback;
  `uvm_object_utils(pcie_svt_topology_ep_bar_sizing_callback)

  typedef bit [25:0] request_key_t;
  protected bit valid[6];
  protected bit is_lower[6];
  protected bit [3:0] fixed_attributes[6];
  protected bit armed[6];
  protected bit [31:0] raw_mask[6];
  protected int unsigned pending_bar[request_key_t];
  protected string link_id;
  int unsigned sizing_write_count;
  int unsigned sizing_read_count;
  int unsigned sizing_completion_count;

  function new(string name =
      "pcie_svt_topology_ep_bar_sizing_callback");
    super.new(name);
  endfunction

  protected function automatic bit [31:0] byte_swap(bit [31:0] value);
    return {value[7:0], value[15:8], value[23:16], value[31:24]};
  endfunction

  protected function automatic request_key_t key(svt_pcie_tlp tlp);
    return {tlp.requester_id, tlp.tag};
  endfunction

  function void configure(pcie_svt_port_descriptor descriptor);
    pcie_svt_cfg_space_builder builder;

    if ((descriptor == null) ||
        (descriptor.role != PCIE_SVT_ROLE_EP) ||
        (descriptor.endpoint_model != PCIE_SVT_EP_SINGLE)) begin
      `uvm_fatal("TOPO_BAR_CB_CFG",
        "callback requires a non-null Single-Endpoint descriptor")
      return;
    end
    builder = pcie_svt_cfg_space_builder::type_id::create(
      {get_name(), "_builder"});
    if ((builder == null) || !builder.validate_ep_descriptor(descriptor))
      return;
    link_id = descriptor.link_id;
    sizing_write_count = 0;
    sizing_read_count = 0;
    sizing_completion_count = 0;
    pending_bar.delete();
    foreach (valid[i]) begin
      valid[i] = 0;
      is_lower[i] = 0;
      fixed_attributes[i] = 0;
      armed[i] = 0;
      raw_mask[i] = 0;
    end
    foreach (descriptor.ep_bars[i]) begin
      if (!descriptor.ep_bars[i].implemented)
        continue;
      valid[i] = 1;
      is_lower[i] = 1;
      fixed_attributes[i] =
        {descriptor.ep_bars[i].prefetchable,
         descriptor.ep_bars[i].is_64bit, 1'b0, 1'b0};
      raw_mask[i] = byte_swap(
        builder.bar_sizing_value(descriptor.ep_bars[i], 0));
      if (descriptor.ep_bars[i].is_64bit) begin
        valid[i+1] = 1;
        raw_mask[i+1] = byte_swap(
          builder.bar_sizing_value(descriptor.ep_bars[i], 1));
      end
    end
  endfunction

  protected function bit decode_bar(
      svt_pcie_tlp tlp, output int unsigned bar);
    bar = 0;
    if ((tlp == null) ||
        (tlp.tlp_type != svt_pcie_tlp::TYPE_0_CFG_REQ) ||
        (tlp.function_number != 0) || (tlp.length != 1) ||
        (tlp.first_dw_be != 4'hf) || (tlp.last_dw_be != 4'h0) ||
        (tlp.register_number < 10'h004) ||
        (tlp.register_number > 10'h009))
      return 0;
    bar = tlp.register_number - 10'h004;
    return valid[bar];
  endfunction

  virtual function void post_rx_tlp_get(
      svt_pcie_target_app target_app, svt_pcie_tlp transaction,
      ref bit drop);
    int unsigned bar;
    request_key_t request_key;
    bit [31:0] host_payload;

    if (!decode_bar(transaction, bar))
      return;
    if (transaction.fmt == svt_pcie_tlp::WITH_DATA_3_DWORD) begin
      if ((transaction.payload.size() == 1) &&
          (transaction.payload[0] == 32'hffff_ffff)) begin
        armed[bar] = 1;
        sizing_write_count++;
      end else begin
        armed[bar] = 0;
        if ((transaction.payload.size() == 1) && is_lower[bar]) begin
          host_payload = byte_swap(transaction.payload[0]);
          host_payload[3:0] = fixed_attributes[bar];
          transaction.payload[0] = byte_swap(host_payload);
        end
      end
      return;
    end
    if ((transaction.fmt != svt_pcie_tlp::NO_DATA_3_DWORD) || !armed[bar])
      return;
    request_key = key(transaction);
    if (pending_bar.exists(request_key)) begin
      armed[bar] = 0;
      `uvm_fatal("TOPO_BAR_CB_DUP", $sformatf(
        "%s duplicate requester=%04h tag=%03h",
        link_id, transaction.requester_id, transaction.tag))
      return;
    end
    armed[bar] = 0;
    pending_bar[request_key] = bar;
    sizing_read_count++;
  endfunction

  virtual function void pre_tx_tlp_put(
      svt_pcie_target_app target_app, svt_pcie_tlp transaction,
      ref bit drop);
    request_key_t request_key;
    int unsigned bar;

    if ((transaction == null) ||
        (transaction.tlp_type != svt_pcie_tlp::CPL))
      return;
    request_key = key(transaction);
    if (!pending_bar.exists(request_key))
      return;
    bar = pending_bar[request_key];
    pending_bar.delete(request_key);
    if ((transaction.fmt != svt_pcie_tlp::WITH_DATA_3_DWORD) ||
        (transaction.completion_status != svt_pcie_tlp::SUCCESSFUL) ||
        (transaction.length != 1) || (transaction.payload.size() != 1)) begin
      `uvm_fatal("TOPO_BAR_CB_CPL", $sformatf(
        "%s malformed sizing Completion requester=%04h tag=%03h",
        link_id, transaction.requester_id, transaction.tag))
      return;
    end
    transaction.payload[0] = raw_mask[bar];
    sizing_completion_count++;
  endfunction

  function bit is_idle();
    foreach (armed[i])
      if (armed[i])
        return 0;
    return pending_bar.num() == 0;
  endfunction
endclass
```

- [ ] **Step 4: Add explicit rejected-descriptor and malformed-Completion tests**

Add these rejected-descriptor, duplicate-key, and malformed-Completion checks
before deleting the catcher and finishing the standalone test:

```systemverilog
descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
catcher.arm("TOPO_BAR_CB_CFG");
callback.configure(descriptor);
require(catcher.catch_count == 1,
        "Multiple-BDF descriptor was not rejected");

callback.configure(make_descriptor());
transaction = make_cfg("dup_write_bar0", 0, 1,
                       32'hffff_ffff, 10'h1a0);
callback.post_rx_tlp_get(null, transaction, drop);
sizing_read[0] = make_cfg("dup_read_bar0", 0, 0, 0, 10'h1a1);
callback.post_rx_tlp_get(null, sizing_read[0], drop);
transaction = make_cfg("dup_write_bar2", 2, 1,
                       32'hffff_ffff, 10'h1a2);
callback.post_rx_tlp_get(null, transaction, drop);
transaction = make_cfg("dup_read_bar2", 2, 0, 0, 10'h1a1);
catcher.arm("TOPO_BAR_CB_DUP");
callback.post_rx_tlp_get(null, transaction, drop);
require(catcher.catch_count == 2,
        "duplicate requester/tag was not rejected");
transaction = make_completion("dup_cleanup", sizing_read[0], 0);
callback.pre_tx_tlp_put(null, transaction, drop);
require(callback.is_idle(), "duplicate-key test retained callback state");

callback.configure(make_descriptor());
transaction = make_cfg("bad_size_write", 0, 1, 32'hffff_ffff, 10'h1a0);
callback.post_rx_tlp_get(null, transaction, drop);
sizing_read[0] = make_cfg("bad_size_read", 0, 0, 0, 10'h1a1);
callback.post_rx_tlp_get(null, sizing_read[0], drop);
transaction = make_completion("bad_size_cpl", sizing_read[0], 0);
transaction.completion_status = svt_pcie_tlp::UNSUPPORTED_REQ;
catcher.arm("TOPO_BAR_CB_CPL");
callback.pre_tx_tlp_put(null, transaction, drop);
require(catcher.catch_count == 3 && callback.is_idle(),
        "malformed Completion was not rejected and cleared");
uvm_report_cb::delete(null, catcher);
```

- [ ] **Step 5: Rebuild and run the standalone callback test GREEN**

Compile the standalone top to `build_topology_bar_cb_green` and run:

```bash
./build_topology_bar_cb_green/simv -no_save +UVM_NO_RELNOTES \
  -l build_topology_bar_cb_green/callback_unit.log
```

Expected:

```text
TOPOLOGY_EP_BAR_SIZING_CALLBACK_PASS bars=6 ordinary=5 memory=1
UVM_WARNING/UVM_ERROR/UVM_FATAL = 0/0/0
```

- [ ] **Step 6: Commit the callback core and its test**

```bash
git add \
  svt_pcie_integration/uvm/callbacks/pcie_svt_topology_ep_bar_sizing_callback.sv \
  svt_pcie_integration/sim/pcie_svt_topology_ep_bar_sizing_callback_unit_test.sv
git add -p svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv
git add -p svt_pcie_integration/sim/pcie_svt_topology.f
git diff --cached -- \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/sim/pcie_svt_topology.f
git commit -m "feat(pcie-svt): model active target BAR sizing"
```

At both `git add -p` prompts, stage only the callback include/incdir/test
hunks. Leave the enumeration registry, enumeration wrapper, and registry unit
test hunks unstaged for Task 4. The displayed cached diff is the mandatory
check before committing.

---

### Task 3: Register One Callback per Single-Endpoint Port

**Files:**

- Modify: `svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`

- [ ] **Step 1: Add failing selection and peer-environment assertions**

Add this pure selection check to the device configuration unit test:

```systemverilog
descriptor.role = PCIE_SVT_ROLE_RC;
descriptor.endpoint_model = PCIE_SVT_EP_SINGLE;
require(!pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
        "RC requested an Endpoint BAR callback");
descriptor.role = PCIE_SVT_ROLE_EP;
require(pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
        "Single Endpoint did not request a BAR callback");
descriptor.endpoint_model = PCIE_SVT_EP_MULTI_BDF;
require(!pcie_svt_topology_env::requires_bar_sizing_callback(descriptor),
        "Multiple-BDF Endpoint requested a Single-Endpoint callback");
```

In `pcie_svt_peer_test::end_of_elaboration_phase()`, add a loop over both
environments. For each descriptor require that `has_bar_sizing_callback()` and
`bar_sizing_callback_is_registered()` equal
`requires_bar_sizing_callback(descriptor)`.

- [ ] **Step 2: Compile to verify RED**

Compile x16 to `build_topology_bar_registration_red`.

Expected: compilation fails because the three callback-selection/query
methods do not exist.

- [ ] **Step 3: Add callback ownership and query methods to the environment**

Add these members and methods:

```systemverilog
pcie_svt_topology_ep_bar_sizing_callback
  bar_sizing_callback_by_link[string];
bit bar_sizing_callback_registered_by_link[string];

static function bit requires_bar_sizing_callback(
    pcie_svt_port_descriptor descriptor);
  return (descriptor != null) &&
         (descriptor.role == PCIE_SVT_ROLE_EP) &&
         (descriptor.endpoint_model == PCIE_SVT_EP_SINGLE);
endfunction

function bit has_bar_sizing_callback(string link_id);
  return bar_sizing_callback_by_link.exists(link_id) &&
         (bar_sizing_callback_by_link[link_id] != null);
endfunction

function bit bar_sizing_callback_is_registered(string link_id);
  return bar_sizing_callback_registered_by_link.exists(link_id) &&
         bar_sizing_callback_registered_by_link[link_id];
endfunction

function bit bar_sizing_callbacks_are_idle();
  foreach (bar_sizing_callback_by_link[link_id])
    if ((bar_sizing_callback_by_link[link_id] == null) ||
        !bar_sizing_callback_by_link[link_id].is_idle())
      return 0;
  return 1;
endfunction
```

After creating each `port_agent[i]` in `build_phase`, create and configure the
callback only when selected:

```systemverilog
if (requires_bar_sizing_callback(descriptors[i])) begin
  bar_sizing_callback_by_link[descriptors[i].link_id] =
    pcie_svt_topology_ep_bar_sizing_callback::type_id::create(
      $sformatf("bar_sizing_callback_%0d", i));
  if (bar_sizing_callback_by_link[descriptors[i].link_id] == null)
    `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
      "%s callback creation failed", descriptors[i].link_id))
  bar_sizing_callback_by_link[descriptors[i].link_id].configure(
    descriptors[i]);
end
```

In `connect_phase`, after connecting the virtual sequencer, register selected
callbacks:

```systemverilog
if (requires_bar_sizing_callback(descriptors[i])) begin
  string link_id = descriptors[i].link_id;
  if ((port_agent[i] == null) || !port_agent[i].target.exists(0) ||
      (port_agent[i].target[0] == null))
    `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
      "%s active Target App target[0] is missing", link_id))
  if (!has_bar_sizing_callback(link_id) ||
      bar_sizing_callback_is_registered(link_id))
    `uvm_fatal("SVT_ENV_BAR_CB", $sformatf(
      "%s callback ownership/registration state is invalid", link_id))
  uvm_callbacks#(
    svt_pcie_target_app,
    svt_pcie_target_app_callback
  )::add(port_agent[i].target[0], bar_sizing_callback_by_link[link_id]);
  bar_sizing_callback_registered_by_link[link_id] = 1'b1;
end
```

- [ ] **Step 4: Complete the peer test registration and idle checks**

Factor the end-of-elaboration loop into:

```systemverilog
function void check_callback_registration(
    string label, pcie_svt_topology_env selected_env);
  foreach (selected_env.descriptors[i]) begin
    pcie_svt_port_descriptor descriptor = selected_env.descriptors[i];
    bit expected =
      pcie_svt_topology_env::requires_bar_sizing_callback(descriptor);
    if ((descriptor.role == PCIE_SVT_ROLE_EP) &&
        (selected_env.port_cfg[i].pcie_cfg.enable_multi_endpoint_mode !=
          (descriptor.endpoint_model == PCIE_SVT_EP_MULTI_BDF)))
      `uvm_fatal("SVT_PEER_BAR_CB", $sformatf(
        "%s link=%s enable_multi_endpoint_mode disagrees with model",
        label, descriptor.link_id))
    if ((selected_env.has_bar_sizing_callback(descriptor.link_id) !=
          expected) ||
        (selected_env.bar_sizing_callback_is_registered(
          descriptor.link_id) != expected))
      `uvm_fatal("SVT_PEER_BAR_CB", $sformatf(
        "%s link=%s expected=%0d owned=%0d registered=%0d",
        label, descriptor.link_id, expected,
        selected_env.has_bar_sizing_callback(descriptor.link_id),
        selected_env.bar_sizing_callback_is_registered(descriptor.link_id)))
  end
endfunction
```

Call it for `env` and `peer_env`. After enumeration and before dropping the
run-phase objection, require both environments' callbacks to be idle:

```systemverilog
if (!env.bar_sizing_callbacks_are_idle() ||
    !peer_env.bar_sizing_callbacks_are_idle())
  `uvm_fatal("SVT_PEER_BAR_CB",
    "primary or peer BAR sizing callback retained pending state")
```

- [ ] **Step 5: Rebuild and run focused registration verification**

Compile x16 to `build_topology_bar_registration_green`. Run the device unit
test, then run x16 compile-only peer elaboration:

```bash
./build_topology_bar_registration_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_device_cfg_unit_test +UVM_NO_RELNOTES \
  -l build_topology_bar_registration_green/device_cfg_unit.log
./build_topology_bar_registration_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES \
  -l build_topology_bar_registration_green/x16_registration.log
```

Expected: the primary RC owns no callback, the peer Single Endpoint owns and
registers one callback, and both summaries are `0/0/0`.

- [ ] **Step 6: Commit environment registration**

```bash
git add \
  svt_pcie_integration/uvm/env/pcie_svt_topology_env.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_device_cfg_unit_test.sv
git add -p svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv
git diff --cached -- svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv
git commit -m "feat(pcie-svt): register endpoint BAR sizing callbacks"
```

Stage only callback registration and idle-check hunks from the peer test. The
cached diff must not contain `pcie_svt_enumeration_registry`,
`pcie_svt_enumeration_vseq`, or `run_direct_enumeration`; those existing hunks
remain for Task 4.

---

### Task 4: Switch Official Enumeration to DUT-Style BAR Probing

**Files:**

- Modify: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv`
- Modify: `svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv`
- Modify: `svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv`
- Modify: `svt_pcie_integration/sim/pcie_svt_topology.f`
- Create: `svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv`

- [ ] **Step 1: Change the wrapper unit test to demand unconditional model mapping**

Remove every assignment to `enumeration.is_ep_device_vip`. Keep the missing,
Single-Endpoint, and Multiple-BDF cases, and add:

```systemverilog
require(!enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic),
        "missing peer mapping bypassed DUT-style probing");
enumeration.peer_endpoint_model_by_link["RC0_EP0"] = PCIE_SVT_EP_SINGLE;
require(enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic),
        "Single-Endpoint peer was rejected");
enumeration.peer_endpoint_model_by_link["RC0_EP0"] = PCIE_SVT_EP_MULTI_BDF;
require(!enumeration.peer_model_allows_official_enum(
          "RC0_EP0", diagnostic) &&
        uvm_is_match("*Multiple-BDF*", diagnostic),
        "Multiple-BDF peer was accepted or poorly diagnosed");
```

- [ ] **Step 2: Run the registry unit test to verify RED**

Compile `build_dut_enum_semantics_red` and run:

```bash
./build_dut_enum_semantics_red/simv -no_save \
  +UVM_TESTNAME=pcie_svt_enumeration_registry_unit_test \
  +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_red/registry_unit.log
```

Expected: the missing mapping is accepted because the old
`is_ep_device_vip==0` bypass still exists, or the old property references no
longer compile.

- [ ] **Step 3: Remove the VIP bypass and force both R-2020.12 copies to zero**

Delete `bit is_ep_device_vip` from the wrapper. Implement the model gate as:

```systemverilog
function bit peer_model_allows_official_enum(
    string link_id, output string diagnostic);
  diagnostic = "";
  if (!peer_endpoint_model_by_link.exists(link_id)) begin
    diagnostic = $sformatf(
      "%s peer Endpoint model mapping is missing", link_id);
    return 0;
  end
  if (peer_endpoint_model_by_link[link_id] != PCIE_SVT_EP_SINGLE) begin
    diagnostic = $sformatf(
      {"%s peer model is Multiple-BDF; R-2020.12 full Endpoint ",
       "enumeration requires Single Endpoint"}, link_id);
    return 0;
  end
  return 1;
endfunction
```

In the official sequence constraint use:

```systemverilog
device_parms.is_ep_device_vip == 1'b0;
```

Immediately before `enum_seq.start(rc_seqr)`, set and verify the status copy:

```systemverilog
enum_seq.ep_enumeration_status.is_ep_device_vip = 1'b0;
if (enum_seq.device_parms.is_ep_device_vip ||
    enum_seq.ep_enumeration_status.is_ep_device_vip)
  `uvm_fatal("SVT_ENUM_BAR_MODE", $sformatf(
    "%s official sequence did not select DUT BAR probing", link_id))
```

Remove `enumeration.is_ep_device_vip = 1'b1` from the peer test. Preserve its
slot-index peer-model mapping, concurrency, watchdog, three-BAR validation,
Command readback, and registry finalization.

- [ ] **Step 4: Rebuild and run unit GREEN before the long simulation**

Compile x16 to `build_dut_enum_semantics_green`, then run:

```bash
./build_dut_enum_semantics_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_enumeration_registry_unit_test \
  +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_green/registry_unit.log
```

Expected: `PCIE_SVT_ENUM_REGISTRY_UNIT_PASS=1` and `W/E/F=0/0/0`.

- [ ] **Step 5: Run Gen4 x16 link and enumeration**

Run:

```bash
./build_dut_enum_semantics_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_ENUM_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_green/enum_gen4_x16.log
```

Require:

```text
1 PCIE_SVT_LINK_PASS with Gen4 x16
1 PCIE_SVT_ENUM_PASS with bars=3
CFG=PASS LINK=PASS ENUM=PASS TRAFFIC=NOT_RUN
callback state idle after enumeration
UVM_WARNING/UVM_ERROR/UVM_FATAL = 0/0/0
```

Confirm the official registry reports 32 MiB, 64 KiB, and 64 KiB apertures,
not the previous 256 MiB/default result.

- [ ] **Step 6: Commit the complete enumeration set**

```bash
git add \
  svt_pcie_integration/sim/pcie_svt_topology.f \
  svt_pcie_integration/uvm/pcie_svt_topology_pkg.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_peer_test.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_registry.sv \
  svt_pcie_integration/uvm/sequences/pcie_svt_enumeration_vseq.sv \
  svt_pcie_integration/uvm/tests/pcie_svt_enumeration_registry_unit_test.sv
git commit -m "feat(pcie-svt): enumerate endpoint BARs through active target"
```

---

### Task 5: Verify Two Independent x8 Hierarchies and Regress Affected Modes

**Files:**

- Modify: `svt_pcie_integration/sim/README.md`

- [ ] **Step 1: Build and run EP_2X8 Gen4**

Compile the final tree with `PCIE_TOPO_EP_2X8` to
`build_dut_enum_2x8_gen4`, then run:

```bash
./build_dut_enum_2x8_gen4/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_ENUM_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_2x8_gen4/enum_gen4.log
```

Require exactly two link passes, two enumeration passes, roots 0 and 1, three
BAR pairs per root, two idle peer callbacks, two PASS stage rows, and
`W/E/F=0/0/0`. Independent roots may both allocate BDF `01:00.0`.

- [ ] **Step 2: Run Gen5 x16 and 2x8 coverage**

Run the x16 Gen5 image and build/run the 2x8 Gen5 image:

```bash
./build_dut_enum_semantics_green/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_ENUM_ONLY +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_dut_enum_semantics_green/enum_gen5_x16.log
./build_dut_enum_2x8_gen5/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_ENUM_ONLY +PCIE_GEN=5 +UVM_NO_RELNOTES \
  -l build_dut_enum_2x8_gen5/enum_gen5.log
```

Require one and two enumeration passes respectively, correct apertures, idle
callbacks, and `W/E/F=0/0/0`.

- [ ] **Step 3: Regress Switch callback placement without claiming Switch enumeration**

Compile `PCIE_TOPO_SWITCH_1X16_4X4` to `build_dut_enum_switch` and run:

```bash
./build_dut_enum_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_COMPILE_ONLY +UVM_NO_RELNOTES \
  -l build_dut_enum_switch/registration.log
./build_dut_enum_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_peer_test \
  +PCIE_LINK_ONLY +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_switch/link_gen4.log
```

Require four callbacks on primary downstream Endpoint SVTs, one callback on
the peer upstream Endpoint SVT, none on RC ports, five link passes, ENUM and
TRAFFIC `NOT_RUN`, and `W/E/F=0/0/0`. Do not report Switch enumeration as
supported until a real Switch DUT supplies Type-1 spaces and forwarding.

- [ ] **Step 4: Run the affected unit and CFG regression**

Using the final x16 image, run:

```bash
for test_name in \
  pcie_svt_topology_model_unit_test \
  pcie_svt_topology_adapter_unit_test \
  pcie_svt_cli_parser_unit_test \
  pcie_svt_device_cfg_unit_test \
  pcie_svt_enumeration_registry_unit_test; do
  ./build_dut_enum_semantics_green/simv -no_save \
    +UVM_TESTNAME="$test_name" +UVM_NO_RELNOTES \
    -l "build_dut_enum_semantics_green/${test_name}.log"
done
./build_dut_enum_switch/simv -no_save \
  +UVM_TESTNAME=pcie_svt_cfg_init_directed_test \
  +PCIE_GEN=4 +UVM_NO_RELNOTES \
  -l build_dut_enum_switch/cfg_directed.log
```

Require every summary to be `W/E/F=0/0/0`. The directed CFG test must still
prove Single-Endpoint ports skip Multi-Endpoint services and an explicit
Multiple-BDF run performs all documented BAR service operations.

- [ ] **Step 5: Update the simulation contract with the proven behavior**

Add this contract to `sim/README.md`:

```markdown
Current Endpoint peers default to `PCIE_SVT_EP_SINGLE` with
`enable_multi_endpoint_mode=0`. CFG initialization loads ordinary PF0 BAR
bases and attributes. During official enumeration, the wrapper selects DUT
semantics (`is_ep_device_vip=0`), and one active Target App callback per
Single-Endpoint port returns the descriptor-derived write-all-ones sizing
response. The callback does not drop TLPs and does not intercept ordinary
Configuration or Memory traffic.

The proven BAR contract is BAR0/1=32 MiB, BAR2/3=64 KiB, and BAR4/5=64 KiB;
all three are 64-bit Prefetchable Memory BARs. Multiple-BDF ports retain the
documented Target App BAR services and are excluded from full official
Endpoint enumeration.
```

Document the exact x16 and 2x8 commands above and their observed PASS counts.

- [ ] **Step 6: Commit the verified contract**

```bash
git add svt_pcie_integration/sim/README.md
git commit -m "docs(pcie-svt): document active target enumeration"
```

- [ ] **Step 7: Perform final repository verification**

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -10
```

Expected: no whitespace errors; no uncommitted implementation files; only
deliberately untracked simulation build artifacts remain outside Git; the log
contains one focused commit for each task.
