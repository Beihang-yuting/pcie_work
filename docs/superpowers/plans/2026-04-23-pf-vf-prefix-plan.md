# PF/VF Management & TLP Prefix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SR-IOV PF/VF management and TLP Prefix support to the PCIe TL VIP, with full backward compatibility.

**Architecture:** Centralized Function Manager inside EP Agent manages PF/VF contexts with BDF lookup. TLP Prefix is an independent array on the TLP base class. Both features default OFF (`sriov_enable=0`, `prefix_enable=0`) — existing tests unchanged.

**Tech Stack:** SystemVerilog, UVM, PCIe Base Spec Rev 5.0

**Spec:** `docs/superpowers/specs/2026-04-23-pf-vf-prefix-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `src/types/pcie_tl_prefix.sv` | Prefix class: raw DW storage, field accessors, factory helpers |
| `src/shared/pcie_tl_sriov_cap.sv` | SR-IOV Extended Capability register model |
| `src/shared/pcie_tl_func_manager.sv` | Function Manager: PF/VF context array, BDF lookup, VF enable/disable, config dispatch |

### Modified Files

| File | Change Summary |
|------|---------------|
| `src/types/pcie_tl_types.sv` | Add `tlp_prefix_type_e` enum, `func_id_t` struct, ext cap IDs |
| `src/types/pcie_tl_tlp.sv` | Add `prefixes[$]`, `has_prefix`, constraints, post_randomize validation |
| `src/shared/pcie_tl_codec.sv` | Prefix encode/decode in `encode()` and `decode()` |
| `src/shared/pcie_tl_fc_manager.sv` | Header credit calculation includes prefix DW overhead |
| `src/agent/pcie_tl_ep_driver.sv` | BDF-based dispatch to func_manager, UR for unknown BDF |
| `src/agent/pcie_tl_ep_agent.sv` | Hold `func_manager` reference, pass to ep_driver |
| `src/env/pcie_tl_env_config.sv` | New SR-IOV and Prefix config fields |
| `src/env/pcie_tl_env.sv` | Conditional func_manager creation, config wiring |
| `src/env/pcie_tl_scoreboard.sv` | Prefix E2E integrity check, format legality check |
| `src/env/pcie_tl_coverage_collector.sv` | New `prefix_cg` covergroup |
| `src/pcie_tl_pkg.sv` | Include 3 new files |
| `tests/pcie_tl_advanced_test.sv` | Tests 23-35 |

---

### Task 1: Add Prefix and Function Type Definitions

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_types.sv:198-237`

- [ ] **Step 1: Add tlp_prefix_type_e enum and func_id_t struct**

After the existing `ext_cap_id_e` enum (line 210), and before the switch types (line 213), add the new prefix type enum, two new extended capability IDs, and the function locator struct. Insert at line 211 (before the blank line before `// Switch port role`):

```systemverilog
// TLP Prefix type (byte 0 of prefix DW: Fmt[2:0]=100 + Type[4:0])
typedef enum bit [7:0] {
    PREFIX_MRIOV         = 8'h80,  // Local:  MR-IOV Routing ID
    PREFIX_LOCAL_VENDOR  = 8'h8E,  // Local:  Vendor-Defined
    PREFIX_EXT_TPH       = 8'h90,  // E2E:    Extended TPH
    PREFIX_PASID         = 8'h91,  // E2E:    PASID
    PREFIX_IDE           = 8'h92,  // E2E:    IDE
    PREFIX_E2E_VENDOR    = 8'h9E   // E2E:    Vendor-Defined
} tlp_prefix_type_e;

// Function locator (for SR-IOV PF/VF identification)
typedef struct {
    int        pf_index;    // PF number (0..N-1)
    int        vf_index;    // VF number within PF (-1 = PF itself)
    bit [15:0] bdf;         // Full Bus/Device/Function
    bit        is_vf;
} func_id_t;
```

Also add missing extended capability IDs to `ext_cap_id_e` (line 198-210). Add these entries before the closing brace:

```systemverilog
    EXT_CAP_ID_PASID   = 16'h001B,
    EXT_CAP_ID_TPH     = 16'h0017
```

- [ ] **Step 2: Verify no syntax errors**

Open the file and visually verify the enum and struct are correctly placed and all commas/semicolons are correct.

- [ ] **Step 3: Commit**

```bash
git add pcie_tl_vip/src/types/pcie_tl_types.sv
git commit -m "feat: add TLP Prefix type enum and func_id_t struct"
```

---

### Task 2: Create TLP Prefix Class

**Files:**
- Create: `pcie_tl_vip/src/types/pcie_tl_prefix.sv`

- [ ] **Step 1: Create the prefix class file**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - TLP Prefix
// Represents a single TLP Prefix DW (Local or End-to-End)
//-----------------------------------------------------------------------------

class pcie_tl_prefix extends uvm_object;
    `uvm_object_utils(pcie_tl_prefix)

    rand tlp_prefix_type_e  prefix_type;
    rand bit [31:0]         raw_dw;

    constraint c_type_matches_raw {
        raw_dw[31:24] == prefix_type;
    }

    function new(string name = "pcie_tl_prefix");
        super.new(name);
    endfunction

    //--- Type query ---
    function bit is_local();
        return raw_dw[28] == 0;  // Type[4] == 0
    endfunction

    function bit is_e2e();
        return raw_dw[28] == 1;  // Type[4] == 1
    endfunction

    //--- PASID field accessors (valid when prefix_type == PREFIX_PASID) ---
    function bit [19:0] get_pasid();
        return raw_dw[19:0];
    endfunction

    function bit get_pasid_exe();
        return raw_dw[21];
    endfunction

    function bit get_pasid_pmr();
        return raw_dw[22];
    endfunction

    //--- Extended TPH accessor (valid when prefix_type == PREFIX_EXT_TPH) ---
    function bit [7:0] get_tph_st_upper();
        return raw_dw[23:16];
    endfunction

    //--- MR-IOV accessor (valid when prefix_type == PREFIX_MRIOV) ---
    function bit [7:0] get_mriov_vhid();
        return raw_dw[15:8];
    endfunction

    //--- IDE accessors (valid when prefix_type == PREFIX_IDE) ---
    function bit get_ide_tee();
        return raw_dw[23];
    endfunction

    function bit [7:0] get_ide_stream_id();
        return raw_dw[21:14];
    endfunction

    function bit get_ide_pcrc();
        return raw_dw[12];
    endfunction

    function bit get_ide_mac();
        return raw_dw[11];
    endfunction

    function bit get_ide_keyset();
        return raw_dw[10];
    endfunction

    //--- Vendor-Defined accessors ---
    function bit [3:0] get_vendor_subfield();
        return raw_dw[23:20];
    endfunction

    function bit [19:0] get_vendor_data();
        return raw_dw[19:0];
    endfunction

    //--- Factory helpers ---
    static function pcie_tl_prefix create_pasid(
        bit [19:0] pasid, bit exe = 0, bit pmr = 0);
        pcie_tl_prefix p = new("pasid_prefix");
        p.prefix_type = PREFIX_PASID;
        p.raw_dw = {8'h91, 1'b0, pmr, exe, 1'b0, pasid};
        return p;
    endfunction

    static function pcie_tl_prefix create_mriov(bit [7:0] vhid);
        pcie_tl_prefix p = new("mriov_prefix");
        p.prefix_type = PREFIX_MRIOV;
        p.raw_dw = {8'h80, 8'h00, vhid, 8'h00};
        return p;
    endfunction

    static function pcie_tl_prefix create_ext_tph(bit [7:0] st_upper);
        pcie_tl_prefix p = new("ext_tph_prefix");
        p.prefix_type = PREFIX_EXT_TPH;
        p.raw_dw = {8'h90, st_upper, 16'h0000};
        return p;
    endfunction

    static function pcie_tl_prefix create_ide(
        bit tee, bit [7:0] stream_id, bit pcrc, bit mac, bit keyset);
        pcie_tl_prefix p = new("ide_prefix");
        p.prefix_type = PREFIX_IDE;
        p.raw_dw = {8'h92, tee, 1'b0, stream_id, 1'b0, pcrc, mac, keyset, 10'h000};
        return p;
    endfunction

    //--- String conversion ---
    virtual function string convert2string();
        return $sformatf("Prefix: type=%s raw=0x%08h local=%0b",
                         prefix_type.name(), raw_dw, is_local());
    endfunction

    //--- Compare ---
    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        pcie_tl_prefix rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (prefix_type == rhs_.prefix_type && raw_dw == rhs_.raw_dw);
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/types/pcie_tl_prefix.sv
git commit -m "feat: add TLP Prefix class with field accessors and factory helpers"
```

---

### Task 3: Extend TLP Base Class with Prefix Support

**Files:**
- Modify: `pcie_tl_vip/src/types/pcie_tl_tlp.sv:66-205`

- [ ] **Step 1: Add prefix fields to pcie_tl_tlp**

After the existing `constraint_mode_sel` field (line 89) and before the `c_no_inject` constraint (line 92), add:

```systemverilog
    //--- TLP Prefix ---
    rand pcie_tl_prefix  prefixes[$];
    rand bit             has_prefix;
```

- [ ] **Step 2: Add prefix constraints**

After the `c_default_mode` constraint (line 100-102), add:

```systemverilog
    //--- Prefix constraints ---
    constraint c_prefix_count {
        has_prefix == (prefixes.size() > 0);
        prefixes.size() <= 4;
    }

    constraint c_default_no_prefix {
        soft has_prefix == 0;
    }
```

- [ ] **Step 3: Add post_randomize for prefix ordering validation**

After the `new` function (line 118-120), add:

```systemverilog
    function void post_randomize();
        int local_count = 0;
        bit seen_e2e = 0;
        // Validate prefix ordering: Local before E2E, max 1 Local
        foreach (prefixes[i]) begin
            if (prefixes[i].is_local()) begin
                local_count++;
                if (seen_e2e)
                    `uvm_error("TLP", "Local TLP Prefix must appear before E2E Prefixes")
                if (local_count > 1)
                    `uvm_error("TLP", "At most 1 Local TLP Prefix allowed")
            end else begin
                seen_e2e = 1;
            end
        end
    endfunction
```

- [ ] **Step 4: Update convert2string to show prefixes**

In the existing `convert2string()` function (line 164-173), before the `return s;` at line 173, add:

```systemverilog
        if (prefixes.size() > 0)
            s = {s, $sformatf(" [PREFIXES: %0d]", prefixes.size())};
```

- [ ] **Step 5: Update do_compare to include prefix comparison**

In the existing `do_compare()` function (line 176-191), add `prefixes.size() == rhs_.prefixes.size()` to the comparison chain at line 190, before the closing `);`.

- [ ] **Step 6: Commit**

```bash
git add pcie_tl_vip/src/types/pcie_tl_tlp.sv
git commit -m "feat: add TLP Prefix fields, constraints, and validation to base TLP class"
```

---

### Task 4: Create SR-IOV Extended Capability

**Files:**
- Create: `pcie_tl_vip/src/shared/pcie_tl_sriov_cap.sv`

- [ ] **Step 1: Create the SR-IOV capability class**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - SR-IOV Extended Capability
// Models the SR-IOV Extended Capability Structure (Cap ID 0x0010)
// per PCIe Base Spec Rev 5.0 Section 9.3.3
//-----------------------------------------------------------------------------

class pcie_tl_sriov_cap extends pcie_ext_capability;
    `uvm_object_utils(pcie_tl_sriov_cap)

    //--- PF identity (set by func_manager during build) ---
    bit [15:0]  pf_bdf;

    //--- SR-IOV Capability Register (offset+0x04) ---
    bit         vf_migration_capable    = 0;
    bit         ari_capable_hierarchy   = 0;

    //--- SR-IOV Control Register (offset+0x08) ---
    bit         vf_enable               = 0;
    bit         vf_migration_enable     = 0;
    bit         ari_capable             = 0;
    bit         vf_mse                  = 0;    // VF Memory Space Enable

    //--- SR-IOV Status Register (offset+0x0A) ---
    bit         vf_migration_status     = 0;

    //--- SR-IOV Parameters ---
    bit [15:0]  initial_vfs             = 0;
    bit [15:0]  total_vfs               = 256;
    bit [15:0]  num_vfs                 = 0;
    bit [15:0]  first_vf_offset         = 1;
    bit [15:0]  vf_stride               = 1;
    bit [15:0]  vf_device_id            = 16'h1235;

    //--- VF BARs (6 BARs, each 32-bit register) ---
    bit [31:0]  vf_bar[6];

    //--- System Page Size ---
    bit [31:0]  supported_page_sizes    = 32'h00000553;  // 4K, 8K, 64K, 256K, 1M, 4M
    bit [31:0]  system_page_size        = 32'h00000001;  // 4K default

    function new(string name = "pcie_tl_sriov_cap");
        super.new(name);
        cap_id  = EXT_CAP_ID_SRIOV;
        cap_ver = 4'h1;
    endfunction

    //=========================================================================
    // Compute VF Routing ID (BDF) from PF BDF + offset/stride
    //=========================================================================
    function bit [15:0] get_vf_rid(int vf_idx);
        return pf_bdf + first_vf_offset + vf_idx * vf_stride;
    endfunction

    //=========================================================================
    // Serialize to config space data bytes
    // SR-IOV capability is 64 bytes (0x40) total:
    //   0x00: Extended Cap Header (4 bytes, handled by register_ext_capability)
    //   0x04: SR-IOV Capabilities (4 bytes)
    //   0x08: SR-IOV Control (2 bytes) + Status (2 bytes)
    //   0x0C: InitialVFs (2) + TotalVFs (2)
    //   0x10: NumVFs (2) + FuncDepLink (2)
    //   0x14: First VF Offset (2) + VF Stride (2)
    //   0x18: Reserved (2) + VF Device ID (2)
    //   0x1C: Supported Page Sizes (4)
    //   0x20: System Page Size (4)
    //   0x24-0x3C: VF BAR[0..5] (6 x 4 = 24 bytes)
    //=========================================================================
    function void build_data();
        data = new[60];  // 0x04..0x3F (60 bytes after the 4-byte ext cap header)

        // SR-IOV Capabilities (offset+0x04, data[0..3])
        data[0] = {6'b0, ari_capable_hierarchy, vf_migration_capable};
        data[1] = 8'h00;
        data[2] = 8'h00;
        data[3] = 8'h00;

        // SR-IOV Control (offset+0x08, data[4..5])
        data[4] = {4'b0, vf_mse, ari_capable, vf_migration_enable, vf_enable};
        data[5] = 8'h00;

        // SR-IOV Status (offset+0x0A, data[6..7])
        data[6] = {7'b0, vf_migration_status};
        data[7] = 8'h00;

        // InitialVFs (offset+0x0C, data[8..9])
        data[8]  = initial_vfs[7:0];
        data[9]  = initial_vfs[15:8];

        // TotalVFs (offset+0x0E, data[10..11])
        data[10] = total_vfs[7:0];
        data[11] = total_vfs[15:8];

        // NumVFs (offset+0x10, data[12..13])
        data[12] = num_vfs[7:0];
        data[13] = num_vfs[15:8];

        // Function Dependency Link (offset+0x12, data[14..15])
        data[14] = 8'h00;
        data[15] = 8'h00;

        // First VF Offset (offset+0x14, data[16..17])
        data[16] = first_vf_offset[7:0];
        data[17] = first_vf_offset[15:8];

        // VF Stride (offset+0x16, data[18..19])
        data[18] = vf_stride[7:0];
        data[19] = vf_stride[15:8];

        // Reserved (offset+0x18, data[20..21])
        data[20] = 8'h00;
        data[21] = 8'h00;

        // VF Device ID (offset+0x1A, data[22..23])
        data[22] = vf_device_id[7:0];
        data[23] = vf_device_id[15:8];

        // Supported Page Sizes (offset+0x1C, data[24..27])
        data[24] = supported_page_sizes[7:0];
        data[25] = supported_page_sizes[15:8];
        data[26] = supported_page_sizes[23:16];
        data[27] = supported_page_sizes[31:24];

        // System Page Size (offset+0x20, data[28..31])
        data[28] = system_page_size[7:0];
        data[29] = system_page_size[15:8];
        data[30] = system_page_size[23:16];
        data[31] = system_page_size[31:24];

        // VF BARs (offset+0x24, data[32..55])
        for (int i = 0; i < 6; i++) begin
            data[32 + i*4 + 0] = vf_bar[i][7:0];
            data[32 + i*4 + 1] = vf_bar[i][15:8];
            data[32 + i*4 + 2] = vf_bar[i][23:16];
            data[32 + i*4 + 3] = vf_bar[i][31:24];
        end

        // Remaining bytes (data[56..59]) = VF Migration State Array Offset
        data[56] = 8'h00;
        data[57] = 8'h00;
        data[58] = 8'h00;
        data[59] = 8'h00;
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_sriov_cap.sv
git commit -m "feat: add SR-IOV Extended Capability register model"
```

---

### Task 5: Create Function Manager

**Files:**
- Create: `pcie_tl_vip/src/shared/pcie_tl_func_manager.sv`

- [ ] **Step 1: Create the Function Context class and Function Manager**

```systemverilog
//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Function Manager
// Manages PF/VF contexts with BDF lookup for SR-IOV support
//-----------------------------------------------------------------------------

//=============================================================================
// Function Context: per-PF or per-VF state
//=============================================================================
class pcie_tl_func_context extends uvm_object;
    `uvm_object_utils(pcie_tl_func_context)

    int                        pf_index;
    int                        vf_index;      // -1 = PF itself
    bit [15:0]                 bdf;
    bit                        is_vf;
    bit                        enabled;

    pcie_tl_cfg_space_manager  cfg_mgr;

    // Address space
    bit [63:0]                 bar_base[6];
    bit [63:0]                 bar_size[6];
    bit                        bar_enable[6];
    bit                        bus_master_en;

    function new(string name = "pcie_tl_func_context");
        super.new(name);
        vf_index  = -1;
        is_vf     = 0;
        enabled   = 1;
        bus_master_en = 0;
        foreach (bar_enable[i]) bar_enable[i] = 0;
        foreach (bar_base[i])   bar_base[i]   = 0;
        foreach (bar_size[i])   bar_size[i]   = 0;
    endfunction

    function void init_cfg_space(bit [15:0] vendor_id, bit [15:0] device_id,
                                  bit [7:0] header_type = 8'h00);
        cfg_mgr = pcie_tl_cfg_space_manager::type_id::create(
            $sformatf("cfg_mgr_pf%0d_vf%0d", pf_index, vf_index));
        cfg_mgr.init_type0_header(vendor_id, device_id, 8'h01, 24'h020000, header_type);
        cfg_mgr.init_pcie_capability();
    endfunction

endclass

//=============================================================================
// Function Manager
//=============================================================================
class pcie_tl_func_manager extends uvm_object;
    `uvm_object_utils(pcie_tl_func_manager)

    //--- Configuration ---
    int              num_pfs          = 1;
    int              max_vfs_per_pf   = 256;
    bit [15:0]       pf_vendor_id     = 16'hABCD;
    bit [15:0]       pf_device_id     = 16'h1234;
    bit [15:0]       vf_device_id     = 16'h1235;
    bit [7:0]        pf_base_bus      = 8'h01;
    bit [4:0]        pf_base_dev      = 5'h00;

    //--- PF contexts ---
    pcie_tl_func_context  pf_ctx[];

    //--- VF contexts per PF ---
    pcie_tl_func_context  vf_ctx[][];   // [pf_idx][vf_idx]

    //--- SR-IOV capability per PF ---
    pcie_tl_sriov_cap     sriov_caps[];

    //--- BDF -> Context lookup ---
    pcie_tl_func_context  bdf_lut[bit [15:0]];

    function new(string name = "pcie_tl_func_manager");
        super.new(name);
    endfunction

    //=========================================================================
    // Build: create all PF contexts and pre-allocate VF arrays
    //=========================================================================
    function void build(int n_pfs, int max_vfs,
                        bit [15:0] vendor_id = 16'hABCD,
                        bit [15:0] device_id = 16'h1234,
                        bit [15:0] vf_dev_id = 16'h1235);
        num_pfs        = n_pfs;
        max_vfs_per_pf = max_vfs;
        pf_vendor_id   = vendor_id;
        pf_device_id   = device_id;
        vf_device_id   = vf_dev_id;

        pf_ctx     = new[n_pfs];
        vf_ctx     = new[n_pfs];
        sriov_caps = new[n_pfs];

        for (int pf = 0; pf < n_pfs; pf++) begin
            bit [15:0] pf_bdf;
            // PF BDF: bus=pf_base_bus, dev=pf_base_dev, func=pf
            pf_bdf = {pf_base_bus, pf_base_dev, pf[2:0]};

            // Create PF context
            pf_ctx[pf] = pcie_tl_func_context::type_id::create(
                $sformatf("pf_ctx_%0d", pf));
            pf_ctx[pf].pf_index = pf;
            pf_ctx[pf].vf_index = -1;
            pf_ctx[pf].bdf      = pf_bdf;
            pf_ctx[pf].is_vf    = 0;
            pf_ctx[pf].enabled  = 1;
            pf_ctx[pf].init_cfg_space(vendor_id, device_id);

            // Register PF in BDF lookup
            bdf_lut[pf_bdf] = pf_ctx[pf];

            // Create SR-IOV capability for this PF
            sriov_caps[pf] = pcie_tl_sriov_cap::type_id::create(
                $sformatf("sriov_cap_%0d", pf));
            sriov_caps[pf].pf_bdf         = pf_bdf;
            sriov_caps[pf].total_vfs      = max_vfs;
            sriov_caps[pf].initial_vfs    = max_vfs;
            sriov_caps[pf].vf_device_id   = vf_dev_id;
            sriov_caps[pf].first_vf_offset = 1;
            sriov_caps[pf].vf_stride      = 1;
            sriov_caps[pf].offset         = 12'h200;  // Extended config space
            sriov_caps[pf].build_data();
            pf_ctx[pf].cfg_mgr.register_ext_capability(sriov_caps[pf]);

            // Pre-allocate VF context array (disabled by default)
            vf_ctx[pf] = new[max_vfs];
            for (int vf = 0; vf < max_vfs; vf++) begin
                bit [15:0] vf_bdf = sriov_caps[pf].get_vf_rid(vf);
                vf_ctx[pf][vf] = pcie_tl_func_context::type_id::create(
                    $sformatf("vf_ctx_%0d_%0d", pf, vf));
                vf_ctx[pf][vf].pf_index = pf;
                vf_ctx[pf][vf].vf_index = vf;
                vf_ctx[pf][vf].bdf      = vf_bdf;
                vf_ctx[pf][vf].is_vf    = 1;
                vf_ctx[pf][vf].enabled  = 0;  // disabled until VF Enable
                vf_ctx[pf][vf].init_cfg_space(vendor_id, vf_dev_id);
            end
        end

        `uvm_info("FUNC_MGR", $sformatf("Built %0d PFs, max %0d VFs each", n_pfs, max_vfs), UVM_MEDIUM)
    endfunction

    //=========================================================================
    // Enable VFs for a specific PF
    //=========================================================================
    function void enable_vfs(int pf_idx, int num_vfs);
        if (pf_idx >= num_pfs) begin
            `uvm_error("FUNC_MGR", $sformatf("Invalid PF index: %0d", pf_idx))
            return;
        end
        if (num_vfs > max_vfs_per_pf) num_vfs = max_vfs_per_pf;

        sriov_caps[pf_idx].vf_enable = 1;
        sriov_caps[pf_idx].num_vfs   = num_vfs;

        for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
            if (vf < num_vfs) begin
                vf_ctx[pf_idx][vf].enabled = 1;
                bdf_lut[vf_ctx[pf_idx][vf].bdf] = vf_ctx[pf_idx][vf];
            end else begin
                vf_ctx[pf_idx][vf].enabled = 0;
                bdf_lut.delete(vf_ctx[pf_idx][vf].bdf);
            end
        end

        `uvm_info("FUNC_MGR", $sformatf("PF%0d: enabled %0d VFs", pf_idx, num_vfs), UVM_MEDIUM)
    endfunction

    //=========================================================================
    // Disable all VFs for a specific PF
    //=========================================================================
    function void disable_vfs(int pf_idx);
        if (pf_idx >= num_pfs) return;

        sriov_caps[pf_idx].vf_enable = 0;
        sriov_caps[pf_idx].num_vfs   = 0;

        for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
            vf_ctx[pf_idx][vf].enabled = 0;
            bdf_lut.delete(vf_ctx[pf_idx][vf].bdf);
        end

        `uvm_info("FUNC_MGR", $sformatf("PF%0d: disabled all VFs", pf_idx), UVM_MEDIUM)
    endfunction

    //=========================================================================
    // Lookup Function context by BDF
    //=========================================================================
    function pcie_tl_func_context lookup_by_bdf(bit [15:0] bdf);
        if (bdf_lut.exists(bdf))
            return bdf_lut[bdf];
        return null;
    endfunction

    //=========================================================================
    // Config space read via BDF dispatch
    //=========================================================================
    function bit [31:0] cfg_read(bit [15:0] target_bdf, bit [11:0] addr);
        pcie_tl_func_context ctx = lookup_by_bdf(target_bdf);
        if (ctx == null || !ctx.enabled) return 32'hFFFFFFFF;  // UR
        return ctx.cfg_mgr.read(addr);
    endfunction

    //=========================================================================
    // Config space write via BDF dispatch
    //=========================================================================
    function void cfg_write(bit [15:0] target_bdf, bit [11:0] addr,
                           bit [31:0] data, bit [3:0] be);
        pcie_tl_func_context ctx = lookup_by_bdf(target_bdf);
        if (ctx == null || !ctx.enabled) return;
        ctx.cfg_mgr.write(addr, data, be);
    endfunction

    //=========================================================================
    // Get total active function count
    //=========================================================================
    function int get_active_count();
        int count = num_pfs;
        for (int pf = 0; pf < num_pfs; pf++)
            count += sriov_caps[pf].num_vfs;
        return count;
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_func_manager.sv
git commit -m "feat: add Function Manager with PF/VF context and BDF lookup"
```

---

### Task 6: Extend Codec for Prefix Encode/Decode

**Files:**
- Modify: `pcie_tl_vip/src/shared/pcie_tl_codec.sv:16-120`

- [ ] **Step 1: Add prefix encoding in `encode()` method**

In the `encode` function (line 16), after `int idx = 0;` (line 19) and before `// Build header DWords` (line 21), add prefix DW encoding. Replace lines 21-25 with:

```systemverilog
        // Encode prefix DWs first
        int prefix_bytes = tlp.prefixes.size() * 4;

        // Build header DWords
        build_header(tlp, header);

        // Total bytes = prefixes + header + payload + optional ECRC(4 bytes)
        bytes = new[prefix_bytes + (header.size() * 4) + tlp.payload.size() + (tlp.td ? 4 : 0)];

        // Pack prefix DWs (big-endian)
        foreach (tlp.prefixes[i]) begin
            bit [31:0] pdw = tlp.prefixes[i].raw_dw;
            bytes[idx++] = pdw[31:24];
            bytes[idx++] = pdw[23:16];
            bytes[idx++] = pdw[15:8];
            bytes[idx++] = pdw[7:0];
        end
```

- [ ] **Step 2: Add prefix decoding in `decode()` method**

In the `decode` function (line 64), add `pcie_tl_prefix tlp_prefixes[$];` to the local variable declarations. Before `// Parse first DW` (line 73), add prefix DW scanning. Replace lines 73-83 with:

```systemverilog
        // Scan for TLP Prefix DWs (Fmt[2:0] == 100b in byte 0 bits [7:5])
        int offset = 0;
        while (offset + 4 <= bytes.size() && bytes[offset][7:5] == 3'b100) begin
            pcie_tl_prefix pfx = new($sformatf("prefix_%0d", tlp_prefixes.size()));
            pfx.raw_dw = {bytes[offset], bytes[offset+1], bytes[offset+2], bytes[offset+3]};
            pfx.prefix_type = tlp_prefix_type_e'(pfx.raw_dw[31:24]);
            tlp_prefixes.push_back(pfx);
            offset += 4;
        end

        // Parse first DW of main TLP header (starts at offset)
        dw0 = {bytes[offset+0], bytes[offset+1], bytes[offset+2], bytes[offset+3]};
        dw1 = {bytes[offset+4], bytes[offset+5], bytes[offset+6], bytes[offset+7]};
        dw2 = {bytes[offset+8], bytes[offset+9], bytes[offset+10], bytes[offset+11]};

        fmt    = tlp_fmt_e'(dw0[31:29]);
        type_f = tlp_type_e'(dw0[28:24]);

        hdr_len = (fmt == FMT_4DW_NO_DATA || fmt == FMT_4DW_WITH_DATA) ? 16 : 12;
        if (hdr_len == 16)
            dw3 = {bytes[offset+12], bytes[offset+13], bytes[offset+14], bytes[offset+15]};
```

Update `payload_start` to account for prefix offset:

```systemverilog
        payload_start = offset + hdr_len;
```

After `fill_type_specific()` and before `return tlp;`, assign prefixes:

```systemverilog
        tlp.prefixes = tlp_prefixes;
        tlp.has_prefix = (tlp_prefixes.size() > 0);
```

- [ ] **Step 3: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_codec.sv
git commit -m "feat: add TLP Prefix encode/decode in codec"
```

---

### Task 7: Extend FC Manager for Prefix Credit Overhead

**Files:**
- Modify: `pcie_tl_vip/src/shared/pcie_tl_fc_manager.sv:39-71`

- [ ] **Step 1: Update `check_credit()` to account for prefix DWs**

In `check_credit()` (line 39), change the `hdr_needed` calculation from `int hdr_needed = 1;` (line 40) to:

```systemverilog
        // Header credits include prefix DW overhead
        // Each prefix is 1 DW; header credit unit = 4 DW (per PCIe spec)
        int prefix_dw = tlp.prefixes.size();
        int base_dw = tlp.is_4dw() ? 4 : 3;
        int hdr_needed = (base_dw + prefix_dw + 3) / 4;  // ceil to credit units
```

- [ ] **Step 2: Update `consume_credit()` similarly**

In `consume_credit()` (line 57), replace the hard-coded `1` in `hdr_credit.current -= 1;` (line 67) with:

```systemverilog
        int prefix_dw = tlp.prefixes.size();
        int base_dw = tlp.is_4dw() ? 4 : 3;
        int hdr_credits = (base_dw + prefix_dw + 3) / 4;

        hdr_credit.current  -= hdr_credits;
```

- [ ] **Step 3: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_fc_manager.sv
git commit -m "feat: include TLP Prefix DW overhead in FC credit calculation"
```

---

### Task 8: Extend EP Driver for BDF-based Function Dispatch

**Files:**
- Modify: `pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv:1-277`

- [ ] **Step 1: Add func_manager reference**

After `bit [7:0] io_space[bit [31:0]];` (line 21), add:

```systemverilog
    //--- Function Manager (set by env when sriov_enable=1) ---
    pcie_tl_func_manager  func_manager;
```

- [ ] **Step 2: Modify handle_request() for BDF dispatch**

Replace the existing `handle_request` task (lines 30-50) with:

```systemverilog
    virtual task handle_request(pcie_tl_tlp req);
        int delay;

        if (!auto_response_enable) return;

        // Random response delay
        delay = $urandom_range(response_delay_max, response_delay_min);
        if (delay > 0) #(delay * 1ns);

        // SR-IOV mode: dispatch config requests by BDF
        if (func_manager != null) begin
            if (req.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) begin
                handle_cfg_read_sriov(req);
                return;
            end
            if (req.kind inside {TLP_CFG_WR0, TLP_CFG_WR1}) begin
                handle_cfg_write_sriov(req);
                return;
            end
        end

        case (req.kind)
            TLP_CFG_RD0, TLP_CFG_RD1:  handle_cfg_read(req);
            TLP_CFG_WR0, TLP_CFG_WR1:  handle_cfg_write(req);
            TLP_MEM_RD, TLP_MEM_RD_LK: handle_mem_read(req);
            TLP_MEM_WR:                 handle_mem_write(req);
            TLP_IO_RD:                  handle_io_read(req);
            TLP_IO_WR:                  handle_io_write(req);
            default: begin
                `uvm_info("EP_DRV", $sformatf("Unhandled TLP type: %s", req.kind.name()), UVM_MEDIUM)
            end
        endcase
    endtask
```

- [ ] **Step 3: Add SR-IOV config read/write handlers**

After `handle_io_write` task (line 206), add:

```systemverilog
    //=========================================================================
    // SR-IOV Config Read handler (dispatches by target BDF)
    //=========================================================================
    protected task handle_cfg_read_sriov(pcie_tl_tlp req);
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_func_context ctx;
        bit [31:0] data;

        $cast(cfg_req, req);
        ctx = func_manager.lookup_by_bdf(cfg_req.completer_id);

        if (ctx == null || !ctx.enabled) begin
            // Unsupported Request
            cpl = generate_completion(req, CPL_STATUS_UR);
            send_tlp(cpl);
            return;
        end

        data = ctx.cfg_mgr.read(cfg_req.get_cfg_addr());

        cpl = generate_completion(req, CPL_STATUS_SC);
        cpl.kind    = TLP_CPLD;
        cpl.fmt     = FMT_3DW_WITH_DATA;
        cpl.length  = 1;
        cpl.payload = new[4];
        cpl.payload[0] = data[7:0];
        cpl.payload[1] = data[15:8];
        cpl.payload[2] = data[23:16];
        cpl.payload[3] = data[31:24];
        cpl.completer_id = ctx.bdf;

        send_tlp(cpl);
    endtask

    //=========================================================================
    // SR-IOV Config Write handler (dispatches by target BDF)
    //=========================================================================
    protected task handle_cfg_write_sriov(pcie_tl_tlp req);
        pcie_tl_cfg_tlp cfg_req;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_func_context ctx;
        bit [31:0] data;

        $cast(cfg_req, req);
        ctx = func_manager.lookup_by_bdf(cfg_req.completer_id);

        if (ctx == null || !ctx.enabled) begin
            cpl = generate_completion(req, CPL_STATUS_UR);
            send_tlp(cpl);
            return;
        end

        if (req.payload.size() >= 4)
            data = {req.payload[3], req.payload[2], req.payload[1], req.payload[0]};

        ctx.cfg_mgr.write(cfg_req.get_cfg_addr(), data, cfg_req.first_be);

        cpl = generate_completion(req, CPL_STATUS_SC);
        cpl.completer_id = ctx.bdf;
        send_tlp(cpl);
    endtask
```

- [ ] **Step 4: Commit**

```bash
git add pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv
git commit -m "feat: add BDF-based config dispatch in EP driver for SR-IOV"
```

---

### Task 9: Wire Function Manager in EP Agent and Environment

**Files:**
- Modify: `pcie_tl_vip/src/agent/pcie_tl_ep_agent.sv:1-28`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env_config.sv:60-86`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv:50-542`

- [ ] **Step 1: Add func_manager to EP Agent**

In `pcie_tl_ep_agent` (line 9), after `pcie_tl_ep_driver ep_driver;`, add:

```systemverilog
    //--- Function Manager (set by env when sriov_enable=1) ---
    pcie_tl_func_manager  func_manager;
```

At the end of `build_phase()` (line 25, after `$cast(ep_driver, driver);`), add:

```systemverilog
            if (func_manager != null)
                ep_driver.func_manager = func_manager;
```

- [ ] **Step 2: Add config fields to env_config**

In `pcie_tl_env_config`, after the existing `switch_cfg` field (line 80), add:

```systemverilog
    //--- SR-IOV / Function ---
    bit              sriov_enable         = 0;
    int              num_pfs              = 1;
    int              max_vfs_per_pf       = 256;
    int              default_num_vfs      = 0;
    bit [15:0]       pf_vendor_id         = 16'hABCD;
    bit [15:0]       pf_device_id         = 16'h1234;
    bit [15:0]       vf_device_id         = 16'h1235;
    bit              ari_enable           = 0;

    //--- TLP Prefix ---
    bit              prefix_enable        = 0;
    bit              pasid_enable         = 0;
    int              pasid_width          = 20;
    bit              pasid_exe_supported  = 0;
    bit              pasid_priv_supported = 0;
    bit              ext_tph_enable       = 0;
    bit              ide_enable           = 0;
    bit              mriov_enable         = 0;
    int              max_e2e_prefix       = 4;
```

- [ ] **Step 3: Create func_manager in env build_phase**

In `pcie_tl_env.sv`, add a `func_manager` field declaration after the multi-EP fields (line 38):

```systemverilog
    //--- Function Manager (SR-IOV) ---
    pcie_tl_func_manager   func_mgr_sriov;
```

In `build_phase()`, after the ep_agent creation (line 83) and before the switch mode section (line 86), add:

```systemverilog
        // 4c. SR-IOV mode: create function manager
        if (cfg.sriov_enable) begin
            func_mgr_sriov = pcie_tl_func_manager::type_id::create("func_mgr_sriov");
            func_mgr_sriov.build(cfg.num_pfs, cfg.max_vfs_per_pf,
                                  cfg.pf_vendor_id, cfg.pf_device_id, cfg.vf_device_id);
            if (cfg.default_num_vfs > 0) begin
                for (int pf = 0; pf < cfg.num_pfs; pf++)
                    func_mgr_sriov.enable_vfs(pf, cfg.default_num_vfs);
            end
        end
```

- [ ] **Step 4: Wire func_manager in connect_phase**

In `connect_phase()`, inside the `if (ep_agent != null)` block (line 137-149), after the `ep_agent.ep_driver.rcb_bytes` line (148), add:

```systemverilog
                if (cfg.sriov_enable && func_mgr_sriov != null) begin
                    ep_agent.func_manager = func_mgr_sriov;
                    ep_agent.ep_driver.func_manager = func_mgr_sriov;
                end
```

Similarly in the switch mode wiring (line 183-201), after `ep_agents[i].ep_driver.rcb_bytes` (line 195), add:

```systemverilog
                    if (cfg.sriov_enable && func_mgr_sriov != null)
                        ep_agents[i].ep_driver.func_manager = func_mgr_sriov;
```

- [ ] **Step 5: Commit**

```bash
git add pcie_tl_vip/src/agent/pcie_tl_ep_agent.sv pcie_tl_vip/src/env/pcie_tl_env_config.sv pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat: wire Function Manager through EP Agent and Environment"
```

---

### Task 10: Extend Scoreboard for Prefix Checks

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_scoreboard.sv:1-310`

- [ ] **Step 1: Add prefix check enable and statistics**

After `bit data_integrity_enable = 1;` (line 32), add:

```systemverilog
    bit prefix_check_enable     = 0;

    int prefix_format_errors    = 0;
    int prefix_integrity_errors = 0;
```

- [ ] **Step 2: Add prefix format check method**

Before the `report_phase` function (line 285), add:

```systemverilog
    //=========================================================================
    // Check: TLP Prefix format legality
    //=========================================================================
    protected function void check_prefix_format(pcie_tl_tlp tlp);
        int local_count = 0;
        bit seen_e2e = 0;

        if (!prefix_check_enable) return;
        if (tlp.prefixes.size() == 0) return;

        // Rule: max 4 prefixes
        if (tlp.prefixes.size() > 4) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "TLP has %0d prefixes (max 4): tag=0x%03h",
                tlp.prefixes.size(), tlp.tag))
            prefix_format_errors++;
        end

        foreach (tlp.prefixes[i]) begin
            // Rule: Local before E2E
            if (tlp.prefixes[i].is_local()) begin
                local_count++;
                if (seen_e2e) begin
                    `uvm_error("SCB_PREFIX", $sformatf(
                        "Local prefix at position %0d after E2E prefix: tag=0x%03h",
                        i, tlp.tag))
                    prefix_format_errors++;
                end
            end else begin
                seen_e2e = 1;
            end
        end

        // Rule: at most 1 Local
        if (local_count > 1) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "Multiple Local prefixes (%0d) found: tag=0x%03h",
                local_count, tlp.tag))
            prefix_format_errors++;
        end
    endfunction

    //=========================================================================
    // Check: E2E Prefix integrity (content unchanged after switch traversal)
    //=========================================================================
    function void check_prefix_integrity(pcie_tl_tlp sent, pcie_tl_tlp received);
        int sent_e2e = 0;
        int recv_e2e = 0;

        if (!prefix_check_enable) return;

        // Count E2E prefixes
        foreach (sent.prefixes[i])
            if (sent.prefixes[i].is_e2e()) sent_e2e++;
        foreach (received.prefixes[i])
            if (received.prefixes[i].is_e2e()) recv_e2e++;

        if (sent_e2e != recv_e2e) begin
            `uvm_error("SCB_PREFIX", $sformatf(
                "E2E prefix count mismatch: sent=%0d received=%0d tag=0x%03h",
                sent_e2e, recv_e2e, sent.tag))
            prefix_integrity_errors++;
            return;
        end

        // Compare E2E prefix raw_dw values
        begin
            int si = 0, ri = 0;
            while (si < sent.prefixes.size() && ri < received.prefixes.size()) begin
                if (sent.prefixes[si].is_local()) begin si++; continue; end
                if (received.prefixes[ri].is_local()) begin ri++; continue; end
                if (sent.prefixes[si].raw_dw != received.prefixes[ri].raw_dw) begin
                    `uvm_error("SCB_PREFIX", $sformatf(
                        "E2E prefix content mismatch at index %0d: sent=0x%08h received=0x%08h tag=0x%03h",
                        si, sent.prefixes[si].raw_dw, received.prefixes[ri].raw_dw, sent.tag))
                    prefix_integrity_errors++;
                end
                si++;
                ri++;
            end
        end
    endfunction
```

- [ ] **Step 3: Call prefix check in write_rc and write_ep**

In `write_rc()` (line 65), after the `rc_sent_history.push_back(tlp);` line (96), add:

```systemverilog
        check_prefix_format(tlp);
```

In `write_ep()` (line 104), after the `ep_sent_history.push_back(tlp);` line (127), add:

```systemverilog
        check_prefix_format(tlp);
```

- [ ] **Step 4: Update report_phase to include prefix stats**

In `report_phase()` (line 285), add prefix stats to the report, after `Timed Out`:

```systemverilog
        if (prefix_check_enable)
            `uvm_info("SCB", $sformatf("  Prefix Format Errors:   %0d\n  Prefix Integrity Errors: %0d",
                prefix_format_errors, prefix_integrity_errors), UVM_LOW)
```

- [ ] **Step 5: Commit**

```bash
git add pcie_tl_vip/src/env/pcie_tl_scoreboard.sv
git commit -m "feat: add TLP Prefix format and integrity checks in scoreboard"
```

---

### Task 11: Extend Coverage Collector

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_coverage_collector.sv:1-208`

- [ ] **Step 1: Add new enable flags and covergroups**

After `bit mps_mrrs_enable = 0;` (line 15), add:

```systemverilog
    bit sriov_enable        = 0;
    bit prefix_cov_enable   = 0;
```

After the `mps_mrrs_cg` covergroup (line 121), add:

```systemverilog
    //--- Sampled prefix state ---
    int sampled_prefix_count;
    bit sampled_has_local;
    bit sampled_has_e2e;
    tlp_prefix_type_e sampled_prefix_type;

    covergroup prefix_cg;
        cp_prefix_count: coverpoint sampled_prefix_count {
            bins none  = {0};
            bins one   = {1};
            bins two   = {2};
            bins three = {3};
            bins four  = {4};
        }
        cp_has_local: coverpoint sampled_has_local;
        cp_has_e2e:   coverpoint sampled_has_e2e;
        cp_prefix_type: coverpoint sampled_prefix_type {
            bins mriov     = {PREFIX_MRIOV};
            bins ext_tph   = {PREFIX_EXT_TPH};
            bins pasid     = {PREFIX_PASID};
            bins ide       = {PREFIX_IDE};
            bins local_vnd = {PREFIX_LOCAL_VENDOR};
            bins e2e_vnd   = {PREFIX_E2E_VENDOR};
        }
        cx_type_count: cross cp_prefix_type, cp_prefix_count;
    endgroup
```

- [ ] **Step 2: Construct new covergroup in new()**

In the `new()` function (line 126-135), after `mps_mrrs_cg = new();` (line 134), add:

```systemverilog
        prefix_cg = new();
```

- [ ] **Step 3: Sample prefix covergroup in write()**

In `write()` (line 170), after the `mps_mrrs_cg.sample()` line (192), add:

```systemverilog
        if (prefix_cov_enable && prefix_cg != null && t.prefixes.size() > 0) begin
            sampled_prefix_count = t.prefixes.size();
            sampled_has_local = 0;
            sampled_has_e2e   = 0;
            foreach (t.prefixes[i]) begin
                if (t.prefixes[i].is_local()) sampled_has_local = 1;
                if (t.prefixes[i].is_e2e())   sampled_has_e2e   = 1;
                sampled_prefix_type = t.prefixes[i].prefix_type;
                prefix_cg.sample();  // sample once per prefix for type coverage
            end
        end else if (prefix_cov_enable && prefix_cg != null) begin
            sampled_prefix_count = 0;
            sampled_has_local = 0;
            sampled_has_e2e   = 0;
            prefix_cg.sample();
        end
```

- [ ] **Step 4: Update enable_all/disable_all**

In `enable_all()` (line 147), add:

```systemverilog
        sriov_enable      = 1;
        prefix_cov_enable = 1;
```

In `disable_all()` (line 157), add:

```systemverilog
        sriov_enable      = 0;
        prefix_cov_enable = 0;
```

- [ ] **Step 5: Commit**

```bash
git add pcie_tl_vip/src/env/pcie_tl_coverage_collector.sv
git commit -m "feat: add TLP Prefix and SR-IOV covergroups"
```

---

### Task 12: Update Package Includes

**Files:**
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv:1-80`

- [ ] **Step 1: Add new file includes**

After `include "types/pcie_tl_tlp.sv"` (line 12), add:

```systemverilog
    `include "types/pcie_tl_prefix.sv"
```

After `include "shared/pcie_tl_link_delay_model.sv"` (line 21), add:

```systemverilog
    `include "shared/pcie_tl_sriov_cap.sv"
    `include "shared/pcie_tl_func_manager.sv"
```

- [ ] **Step 2: Commit**

```bash
git add pcie_tl_vip/src/pcie_tl_pkg.sv
git commit -m "feat: add prefix, sriov_cap, func_manager to package includes"
```

---

### Task 13: Add Tests 23, 28, 32, 33, 35

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`

- [ ] **Step 1: Add Test 23 — SR-IOV Basic Enable**

Append at end of file:

```systemverilog
//=============================================================================
// Test 23: SR-IOV Basic Enable
//=============================================================================
class pcie_tl_sriov_basic_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_sriov_basic_test)
    function new(string name = "pcie_tl_sriov_basic_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.sriov_enable     = 1;
        cfg.num_pfs          = 2;
        cfg.max_vfs_per_pf   = 4;
        cfg.default_num_vfs  = 2;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TEST23", "=== SR-IOV Basic Enable: 2 PFs, 2 VFs each ===", UVM_LOW)

        // Verify PF0 config read
        begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd_pf0");
            cfg_rd.completer_id = 16'h0100;  // PF0 BDF
            cfg_rd.start(env.rc_agent.sequencer);
            #100ns;
        end

        // Verify VF0 of PF0 config read
        begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd_vf0");
            cfg_rd.completer_id = 16'h0101;  // VF0 BDF = PF0 + offset(1) + 0*stride(1)
            cfg_rd.start(env.rc_agent.sequencer);
            #100ns;
        end

        // Verify VF1 of PF0 config read
        begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd_vf1");
            cfg_rd.completer_id = 16'h0102;  // VF1 BDF
            cfg_rd.start(env.rc_agent.sequencer);
            #100ns;
        end

        // Verify PF1 config read
        begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create("cfg_rd_pf1");
            cfg_rd.completer_id = 16'h0108;  // PF1 BDF (bus=01, dev=00, func=1)
            cfg_rd.start(env.rc_agent.sequencer);
            #100ns;
        end

        #500ns;
        `uvm_info("TEST23", "=== SR-IOV Basic Enable DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 2: Add Test 28 — PASID Prefix Basic**

```systemverilog
//=============================================================================
// Test 28: PASID Prefix Basic
//=============================================================================
class pcie_tl_pasid_prefix_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_pasid_prefix_test)
    function new(string name = "pcie_tl_pasid_prefix_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.prefix_enable = 1;
        cfg.pasid_enable  = 1;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TEST28", "=== PASID Prefix Basic ===", UVM_LOW)

        // Memory Write with PASID prefix
        for (int i = 0; i < 10; i++) begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create($sformatf("wr_%0d", i));
            pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(
                20'(i * 100), .exe(i[0]), .pmr(i[1]));
            wr.addr     = 64'h0000_0001_0000_0000 + (i * 256);
            wr.length   = 4;
            wr.first_be = 4'hF;
            wr.last_be  = 4'hF;
            wr.is_64bit = 1;
            wr.prefixes.push_back(pasid_pfx);
            wr.has_prefix = 1;
            wr.start(env.rc_agent.sequencer);
            #20ns;
        end

        // Memory Read with PASID prefix
        for (int i = 0; i < 5; i++) begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create($sformatf("rd_%0d", i));
            pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(20'(i * 200));
            rd.addr     = 64'h0000_0001_0000_0000 + (i * 128);
            rd.length   = 4;
            rd.first_be = 4'hF;
            rd.last_be  = 4'hF;
            rd.is_64bit = 1;
            rd.prefixes.push_back(pasid_pfx);
            rd.has_prefix = 1;
            rd.start(env.rc_agent.sequencer);
            #50ns;
        end

        #1000ns;
        `uvm_info("TEST28", "=== PASID Prefix Basic DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 3: Add Test 32 — Multi-Prefix Combo**

```systemverilog
//=============================================================================
// Test 32: Multi-Prefix Combo (Local + multiple E2E)
//=============================================================================
class pcie_tl_multi_prefix_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_multi_prefix_test)
    function new(string name = "pcie_tl_multi_prefix_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.prefix_enable  = 1;
        cfg.pasid_enable   = 1;
        cfg.mriov_enable   = 1;
        cfg.ide_enable     = 1;
        cfg.ext_tph_enable = 1;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TEST32", "=== Multi-Prefix Combo ===", UVM_LOW)

        // TLP with MR-IOV (local) + PASID (e2e) + IDE (e2e)
        begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr_combo");
            pcie_tl_prefix mriov_pfx = pcie_tl_prefix::create_mriov(8'h05);
            pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(20'h12345);
            pcie_tl_prefix ide_pfx   = pcie_tl_prefix::create_ide(1, 8'h0A, 0, 1, 0);
            wr.addr     = 64'h0000_0002_0000_0000;
            wr.length   = 8;
            wr.first_be = 4'hF;
            wr.last_be  = 4'hF;
            wr.is_64bit = 1;
            // Local first, then E2E (correct ordering)
            wr.prefixes.push_back(mriov_pfx);
            wr.prefixes.push_back(pasid_pfx);
            wr.prefixes.push_back(ide_pfx);
            wr.has_prefix = 1;
            wr.start(env.rc_agent.sequencer);
            #50ns;
        end

        // TLP with PASID + Extended TPH (two E2E, no local)
        begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr_e2e_only");
            pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(20'hABCDE);
            pcie_tl_prefix tph_pfx   = pcie_tl_prefix::create_ext_tph(8'hFF);
            wr.addr     = 64'h0000_0003_0000_0000;
            wr.length   = 4;
            wr.first_be = 4'hF;
            wr.last_be  = 4'hF;
            wr.is_64bit = 1;
            wr.prefixes.push_back(pasid_pfx);
            wr.prefixes.push_back(tph_pfx);
            wr.has_prefix = 1;
            wr.start(env.rc_agent.sequencer);
            #50ns;
        end

        // Single prefix: just IDE
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd_ide_only");
            pcie_tl_prefix ide_pfx = pcie_tl_prefix::create_ide(0, 8'h03, 1, 1, 1);
            rd.addr     = 64'h0000_0001_0000_0000;
            rd.length   = 2;
            rd.first_be = 4'hF;
            rd.last_be  = 4'hF;
            rd.is_64bit = 1;
            rd.prefixes.push_back(ide_pfx);
            rd.has_prefix = 1;
            rd.start(env.rc_agent.sequencer);
            #50ns;
        end

        #1000ns;
        `uvm_info("TEST32", "=== Multi-Prefix Combo DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 4: Add Test 33 — VF + PASID Combined**

```systemverilog
//=============================================================================
// Test 33: VF + PASID Combined
//=============================================================================
class pcie_tl_vf_pasid_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_vf_pasid_test)
    function new(string name = "pcie_tl_vf_pasid_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.sriov_enable     = 1;
        cfg.num_pfs          = 2;
        cfg.max_vfs_per_pf   = 4;
        cfg.default_num_vfs  = 4;
        cfg.prefix_enable    = 1;
        cfg.pasid_enable     = 1;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TEST33", "=== VF + PASID Combined ===", UVM_LOW)

        // Write to each VF with unique PASID
        for (int pf = 0; pf < 2; pf++) begin
            for (int vf = 0; vf < 4; vf++) begin
                pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                    $sformatf("wr_pf%0d_vf%0d", pf, vf));
                pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(
                    20'(pf * 1000 + vf * 100));
                wr.addr     = 64'h0000_0010_0000_0000 + (pf * 64'h1000) + (vf * 64'h100);
                wr.length   = 4;
                wr.first_be = 4'hF;
                wr.last_be  = 4'hF;
                wr.is_64bit = 1;
                wr.prefixes.push_back(pasid_pfx);
                wr.has_prefix = 1;
                wr.start(env.rc_agent.sequencer);
                #20ns;
            end
        end

        #2000ns;
        `uvm_info("TEST33", "=== VF + PASID Combined DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 5: Add Test 35 — SR-IOV Stress**

```systemverilog
//=============================================================================
// Test 35: SR-IOV Stress (8 PF x 64 VF, concurrent traffic)
//=============================================================================
class pcie_tl_sriov_stress_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_sriov_stress_test)
    function new(string name = "pcie_tl_sriov_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.sriov_enable     = 1;
        cfg.num_pfs          = 8;
        cfg.max_vfs_per_pf   = 64;
        cfg.default_num_vfs  = 64;
        cfg.init_ph_credit   = 128;
        cfg.init_pd_credit   = 1024;
        cfg.init_nph_credit  = 128;
        cfg.init_npd_credit  = 512;
        cfg.init_cplh_credit = 128;
        cfg.init_cpld_credit = 1024;
        cfg.cpl_timeout_ns   = 100000;
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("TEST35", "=== SR-IOV Stress: 8 PFs x 64 VFs ===", UVM_LOW)

        // Config reads across all PFs
        for (int pf = 0; pf < 8; pf++) begin
            pcie_tl_cfg_rd_seq cfg_rd = pcie_tl_cfg_rd_seq::type_id::create(
                $sformatf("cfg_rd_pf%0d", pf));
            cfg_rd.completer_id = {8'h01, 5'h00, pf[2:0]};
            cfg_rd.start(env.rc_agent.sequencer);
            #10ns;
        end

        // Memory writes spread across VFs
        for (int i = 0; i < 200; i++) begin
            int pf_idx = i % 8;
            int vf_idx = (i / 8) % 64;
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create(
                $sformatf("wr_%0d", i));
            wr.addr     = 64'h0000_1000_0000_0000 + (pf_idx * 64'h100000) + (vf_idx * 64'h1000) + (i * 64);
            wr.length   = 1 + (i % 16);
            wr.first_be = 4'hF;
            wr.last_be  = (wr.length > 1) ? 4'hF : 4'h0;
            wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
            #5ns;
        end

        // Memory reads spread across VFs
        for (int i = 0; i < 100; i++) begin
            int pf_idx = i % 8;
            int vf_idx = (i / 8) % 64;
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create(
                $sformatf("rd_%0d", i));
            rd.addr     = 64'h0000_1000_0000_0000 + (pf_idx * 64'h100000) + (vf_idx * 64'h1000);
            rd.length   = 4;
            rd.first_be = 4'hF;
            rd.last_be  = 4'hF;
            rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
            #10ns;
        end

        #20000ns;
        `uvm_info("TEST35", "=== SR-IOV Stress DONE ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
```

- [ ] **Step 6: Commit**

```bash
git add pcie_tl_vip/tests/pcie_tl_advanced_test.sv
git commit -m "feat: add Tests 23, 28, 32, 33, 35 for SR-IOV and TLP Prefix"
```

---

### Task 14: Wire Prefix and SR-IOV Config in Environment

**Files:**
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv:484-542`

- [ ] **Step 1: Wire scoreboard prefix_check_enable in apply_config()**

In `apply_config()`, after the existing scoreboard config block (line 517-521), add:

```systemverilog
            scb.prefix_check_enable = cfg.prefix_enable;
```

- [ ] **Step 2: Wire coverage prefix and sriov enables**

After the existing coverage config block (line 509-514), add:

```systemverilog
        cov.sriov_enable      = cfg.sriov_enable;
        cov.prefix_cov_enable = cfg.prefix_enable;
```

- [ ] **Step 3: Commit**

```bash
git add pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat: wire prefix and SR-IOV config to scoreboard and coverage"
```

---

### Task 15: Backward Compatibility Verification

- [ ] **Step 1: Verify that all new config fields default to 0/OFF**

Check `pcie_tl_env_config.sv`: `sriov_enable=0`, `prefix_enable=0`. When both are 0, no new components are created and no existing behavior changes.

- [ ] **Step 2: Verify package compile order**

Check `pcie_tl_pkg.sv`:
- `pcie_tl_prefix.sv` after `pcie_tl_tlp.sv` (prefix class used by TLP)
- `pcie_tl_sriov_cap.sv` after `pcie_tl_cfg_space_manager.sv` (extends ext_capability)
- `pcie_tl_func_manager.sv` after `pcie_tl_sriov_cap.sv` (uses sriov_cap)

- [ ] **Step 3: Verify TLP default constraint**

Check `c_default_no_prefix` uses `soft` so existing tests that don't set prefixes get `has_prefix=0` by default.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete PF/VF Management and TLP Prefix integration"
```
