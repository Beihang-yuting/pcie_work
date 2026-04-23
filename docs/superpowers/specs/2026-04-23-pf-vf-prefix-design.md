# PCIe TL VIP — PF/VF Management & TLP Prefix Design Spec

> Date: 2026-04-23
> Status: Approved
> PCIe Base Spec: Rev 5.0

---

## 1. Overview

Extend the PCIe TL VIP with two major features:

1. **SR-IOV PF/VF Management** — Full SR-IOV Extended Capability modeling with runtime-configurable PF/VF counts (default: 8 PF, 256 VF per PF)
2. **TLP Prefix Support** — Both Local (MR-IOV) and End-to-End (PASID, Extended TPH, IDE, Vendor-Defined) prefixes

Design approach: **Centralized Function Manager** inside EP Agent, with loose coupling between Prefix and SR-IOV.

All new features default to OFF (`sriov_enable=0`, `prefix_enable=0`), preserving full backward compatibility with existing Tests 1-22.

---

## 2. Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| SR-IOV depth | Full Capability modeling | Need VF Enable/NumVFs/Offset/Stride/VF BAR registers |
| PF/VF scale | Runtime configurable, default 8 PF / 256 VF | Max PCIe spec values as default, tunable for smaller tests |
| Switch integration | EP-side SR-IOV only | Switch routes by BDF/address, no VF concept in switch ports |
| Prefix scope | Local + E2E (all defined types) | MR-IOV, PASID, Extended TPH, IDE, Vendor-Defined |
| Prefix-VF coupling | Loose | VIP handles prefix transport/validation, not PASID table semantics |
| Architecture | Centralized Function Manager | Single component in EP Agent, context objects per Function |

---

## 3. TLP Prefix Types (PCIe 5.0)

### 3.1 Encoding Table

| Fmt[2:0] | Type[4:0] | Byte 0 | Name | Category |
|----------|-----------|--------|------|----------|
| 100 | 0_0000 | 0x80 | MR-IOV Routing ID | Local |
| 100 | 0_1110 | 0x8E | Local Vendor-Defined | Local |
| 100 | 1_0000 | 0x90 | Extended TPH | E2E |
| 100 | 1_0001 | 0x91 | PASID | E2E |
| 100 | 1_0010 | 0x92 | IDE | E2E |
| 100 | 1_1110 | 0x9E | E2E Vendor-Defined | E2E |

Classification: Type[4] == 0 → Local, Type[4] == 1 → E2E.

### 3.2 Prefix DW Bit Layouts

**PASID (0x91):**

| Bits | Field |
|------|-------|
| [31:24] | Fmt/Type = 0x91 |
| [23] | Reserved |
| [22] | Privileged Mode Requested (PMR) |
| [21] | Execute Requested (Exe) |
| [20] | Reserved |
| [19:0] | PASID (20-bit) |

**Extended TPH (0x90):**

| Bits | Field |
|------|-------|
| [31:24] | Fmt/Type = 0x90 |
| [23:16] | ST Upper [15:8] (Steering Tag upper byte) |
| [15:0] | Reserved |

**MR-IOV (0x80):**

| Bits | Field |
|------|-------|
| [31:24] | Fmt/Type = 0x80 |
| [23:16] | Reserved |
| [15:8] | VHID (Virtual Hierarchy ID) |
| [7:0] | Reserved |

**IDE (0x92):**

| Bits | Field |
|------|-------|
| [31:24] | Fmt/Type = 0x92 |
| [23] | T (TEE bit) |
| [22] | Reserved |
| [21:14] | Stream ID [7:0] |
| [13] | Reserved |
| [12] | P (PCRC present, valid when M=1) |
| [11] | M (MAC present) |
| [10] | K (Key Set select) |
| [9:0] | Reserved |

**Vendor-Defined (0x8E / 0x9E):**

| Bits | Field |
|------|-------|
| [31:24] | Fmt/Type |
| [23:20] | Vendor sub-field (4-bit) |
| [19:0] | Vendor-defined |

### 3.3 Prefix Rules

1. Maximum 4 prefix DWs per TLP
2. At most 1 Local prefix, must appear before any E2E prefixes
3. Prefix presence does NOT change the main TLP header's Fmt field
4. Prefix identified by scanning DWs: Fmt[2:0]==100b → prefix, else → main TLP header start
5. FC header credit accounting must include prefix DW overhead

---

## 4. Data Structures

### 4.1 New Type Definitions (pcie_tl_types.sv)

```systemverilog
// TLP Prefix type (byte 0 of prefix DW)
typedef enum bit [7:0] {
    PREFIX_MRIOV         = 8'h80,
    PREFIX_LOCAL_VENDOR  = 8'h8E,
    PREFIX_EXT_TPH       = 8'h90,
    PREFIX_PASID         = 8'h91,
    PREFIX_IDE           = 8'h92,
    PREFIX_E2E_VENDOR    = 8'h9E
} tlp_prefix_type_e;

// Function locator
typedef struct {
    int        pf_index;    // PF number (0..N-1)
    int        vf_index;    // VF number within PF (-1 = PF itself)
    bit [15:0] bdf;         // Full Bus/Device/Function
    bit        is_vf;
} func_id_t;
```

### 4.2 Prefix Class (new file: pcie_tl_prefix.sv)

```systemverilog
class pcie_tl_prefix extends uvm_object;
    `uvm_object_utils(pcie_tl_prefix)

    rand tlp_prefix_type_e  prefix_type;
    rand bit [31:0]         raw_dw;

    // Type query
    function bit is_local();
        return raw_dw[28] == 0;
    endfunction
    function bit is_e2e();
        return raw_dw[28] == 1;
    endfunction

    // PASID field accessors
    function bit [19:0] get_pasid();       return raw_dw[19:0];   endfunction
    function bit        get_pasid_exe();   return raw_dw[21];     endfunction
    function bit        get_pasid_pmr();   return raw_dw[22];     endfunction

    // Extended TPH accessor
    function bit [7:0]  get_tph_st_upper(); return raw_dw[23:16]; endfunction

    // MR-IOV accessor
    function bit [7:0]  get_mriov_vhid();   return raw_dw[15:8];  endfunction

    // IDE accessors
    function bit        get_ide_tee();       return raw_dw[23];    endfunction
    function bit [7:0]  get_ide_stream_id(); return raw_dw[21:14]; endfunction
    function bit        get_ide_pcrc();      return raw_dw[12];    endfunction
    function bit        get_ide_mac();       return raw_dw[11];    endfunction
    function bit        get_ide_keyset();    return raw_dw[10];    endfunction

    // Factory helpers
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

    function new(string name = "pcie_tl_prefix");
        super.new(name);
    endfunction
endclass
```

### 4.3 TLP Base Class Extension (pcie_tl_tlp.sv)

Add to `pcie_tl_tlp`:

```systemverilog
    // TLP Prefix array (0-4 prefixes)
    rand pcie_tl_prefix prefixes[$];
    rand bit            has_prefix;

    constraint c_prefix_count {
        has_prefix == (prefixes.size() > 0);
        prefixes.size() <= 4;
    }

    // Default: no prefix
    constraint c_default_no_prefix {
        soft has_prefix == 0;
    }
```

Post-randomize validation enforces: Local count <= 1, Local before E2E.

The main TLP's `fmt` field is NOT affected by prefix presence.

---

## 5. Function Manager Architecture

### 5.1 Function Context

```systemverilog
class pcie_tl_func_context extends uvm_object;
    int                        pf_index;
    int                        vf_index;     // -1 = PF itself
    bit [15:0]                 bdf;
    bit                        is_vf;
    bit                        enabled;
    pcie_tl_cfg_space_manager  cfg_mgr;      // independent config space

    // Address space (PF: BAR0-5, VF: VF BAR0-5)
    bit [63:0]                 bar_base[6];
    bit [63:0]                 bar_size[6];
    bit                        bar_enable[6];
    bit                        bus_master_en;
endclass
```

### 5.2 SR-IOV Capability

```systemverilog
class pcie_tl_sriov_cap extends pcie_ext_capability;
    // SR-IOV Capability Register (offset+0x04)
    bit              vf_migration_capable  = 0;
    bit              ari_capable_hierarchy = 0;

    // SR-IOV Control Register (offset+0x08)
    bit              vf_enable             = 0;
    bit              vf_migration_enable   = 0;
    bit              ari_capable           = 0;
    bit              vf_mse               = 0;  // VF Memory Space Enable

    // SR-IOV Status Register (offset+0x0A)
    bit              vf_migration_status   = 0;

    // Core parameters
    bit [15:0]       initial_vfs           = 0;
    bit [15:0]       total_vfs             = 256;
    bit [15:0]       num_vfs               = 0;
    bit [15:0]       vf_offset             = 0;
    bit [15:0]       vf_stride             = 1;
    bit [15:0]       first_vf_offset       = 0;

    // VF BARs
    bit [31:0]       vf_bar[6];

    // Compute VF Routing ID from PF BDF + offset/stride
    function bit [15:0] get_vf_rid(int vf_idx);
        return pf_bdf + first_vf_offset + vf_idx * vf_stride;
    endfunction
endclass
```

### 5.3 Function Manager

```systemverilog
class pcie_tl_func_manager extends uvm_object;
    // Configuration
    int                     num_pfs;          // 1-8
    int                     max_vfs_per_pf;   // up to 256

    // PF contexts
    pcie_tl_func_context    pf_ctx[$];

    // VF contexts: [pf_idx][vf_idx]
    pcie_tl_func_context    vf_ctx[$][$];

    // BDF → Context fast lookup
    pcie_tl_func_context    bdf_lut[bit [15:0]];

    // Core methods
    function void build(int n_pfs, int max_vfs, ...);
    function pcie_tl_func_context lookup_by_bdf(bit [15:0] bdf);
    function void enable_vfs(int pf_idx, int num_vfs);
    function void disable_vfs(int pf_idx);
    function void rebuild_bdf_lut();

    // Config request dispatch
    function bit [31:0] cfg_read(bit [15:0] target_bdf, bit [11:0] addr);
    function void cfg_write(bit [15:0] target_bdf, bit [11:0] addr,
                           bit [31:0] data, bit [3:0] be);
endclass
```

### 5.4 EP Driver Modification

When `sriov_enable=1`, EP driver dispatches by BDF:

```
handle_request(tlp):
    ctx = func_manager.lookup_by_bdf(target_bdf)
    if (ctx == null || !ctx.enabled):
        send UR Completion
        return
    Config request → ctx.cfg_mgr.read/write
    Memory request → match ctx.bar_base/size
    Completion.completer_id = ctx.bdf
```

When `sriov_enable=0`, EP driver uses existing single-function path unchanged.

---

## 6. Integration Points

### 6.1 Switch Integration

No new switch components needed. Existing routing handles VF traffic:

- **ID-based routing**: VF BDF falls within DSP's bus number range → existing logic routes correctly
- **Address-based routing**: VF BAR addresses fall within DSP's memory window → existing logic routes correctly
- **Config Type 1 routing**: Routes by bus number to correct DSP; EP internally dispatches by dev/func to correct Function

### 6.2 Codec Extension

Encode: prefix DWs first (each 4 bytes), then main TLP header + payload.

Decode: scan DWs while `Fmt[2:0]==100b` → collect as prefixes; first non-prefix DW → main TLP header.

### 6.3 FC Credit Adjustment

Header credit calculation includes prefix DW count:

```
header_credits = ceil((header_dw_count + prefix_count) / 4)
```

where `header_dw_count` is 3 (3DW) or 4 (4DW) as before.

### 6.4 Scoreboard Extension

New checks (only when prefix_enable=1):

1. **E2E Prefix integrity**: E2E prefix content unchanged after Switch traversal
2. **Local Prefix boundary**: Local prefix consumed at Switch ingress, not forwarded
3. **Prefix format legality**: Valid Fmt/Type, Local before E2E, count <= 4, Local count <= 1

### 6.5 Coverage Extension

New covergroups (only when cov_enable=1):

- `cg_sriov`: num_pfs x num_vfs cross, vf_enable toggle, config access target
- `cg_prefix`: prefix_type x prefix_count cross, local/e2e presence

---

## 7. Configuration (pcie_tl_env_config)

### 7.1 New Fields

```systemverilog
    // --- SR-IOV / Function ---
    bit              sriov_enable         = 0;
    int              num_pfs              = 1;
    int              max_vfs_per_pf       = 256;
    int              default_num_vfs      = 0;
    bit [15:0]       pf_vendor_id         = 16'hABCD;
    bit [15:0]       pf_device_id         = 16'h1234;
    bit [15:0]       vf_device_id         = 16'h1235;
    bit              ari_enable           = 0;

    // --- TLP Prefix ---
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

### 7.2 Backward Compatibility

When `sriov_enable=0` AND `prefix_enable=0`:
- No new components created
- EP Agent single-function behavior identical to current
- Codec, Scoreboard, FC Manager unchanged
- All existing Tests 1-22 pass without modification

---

## 8. New File List

### New Files

| File | Purpose |
|------|---------|
| `src/types/pcie_tl_prefix.sv` | Prefix class with field accessors and factory methods |
| `src/shared/pcie_tl_func_manager.sv` | Function Manager with BDF lookup, VF enable/disable |
| `src/shared/pcie_tl_sriov_cap.sv` | SR-IOV Extended Capability register model |

### Modified Files

| File | Changes |
|------|---------|
| `src/types/pcie_tl_types.sv` | Add `tlp_prefix_type_e`, `func_id_t` |
| `src/types/pcie_tl_tlp.sv` | Add `prefixes[$]`, `has_prefix` to base TLP |
| `src/shared/pcie_tl_codec.sv` | Prefix encode/decode logic |
| `src/shared/pcie_tl_fc_manager.sv` | Credit calculation includes prefix overhead |
| `src/agent/pcie_tl_ep_driver.sv` | BDF-based dispatch to Function context |
| `src/agent/pcie_tl_ep_agent.sv` | Hold func_manager reference |
| `src/env/pcie_tl_env_config.sv` | New SR-IOV and Prefix config fields |
| `src/env/pcie_tl_env.sv` | Conditional func_manager creation |
| `src/env/pcie_tl_scoreboard.sv` | Prefix transparency checks |
| `src/env/pcie_tl_coverage_collector.sv` | New covergroups |
| `src/pcie_tl_pkg.sv` | Include new files |
| `tests/pcie_tl_advanced_test.sv` | Tests 23-35 |

---

## 9. Test Plan

| Test | Name | Verification Target |
|------|------|---------------------|
| 23 | SR-IOV Basic Enable | VF Enable via SR-IOV Control, BDF calculation, VF config space R/W |
| 24 | Multi-PF VF Enumeration | Multiple PFs with different VF counts, Config Read all Functions |
| 25 | VF Memory RW | Memory Read/Write via VF BAR, correct routing and response |
| 26 | VF Disable/Re-enable | Dynamic VF disable → UR response, re-enable → BDF table rebuild |
| 27 | Switch + VF Routing | SR-IOV EP behind Switch DSP, Config Type 1 + Memory routed to correct VF |
| 28 | PASID Prefix Basic | Memory request with PASID Prefix, format check, Scoreboard E2E verification |
| 29 | Extended TPH Prefix | 16-bit Steering Tag (header ST[7:0] + prefix ST[15:8]) integrity |
| 30 | MR-IOV Local Prefix | Local prefix consumed at Switch boundary, not forwarded E2E |
| 31 | IDE Prefix | Stream ID, MAC/PCRC flags, TEE bit correctness |
| 32 | Multi-Prefix Combo | Single TLP with Local + multiple E2E (MR-IOV + PASID + IDE), ordering and integrity |
| 33 | VF + PASID Combined | VF request with PASID Prefix, {BDF, PASID} joint validation |
| 34 | Prefix Error Injection | Illegal prefix order, count > 4, unsupported type → error handling |
| 35 | SR-IOV Stress | 8 PF x 64 VF, concurrent mixed traffic, BDF lookup correctness |

---

## 10. Capability Register Additions

### 10.1 Device Capabilities 2 (PCIe Capability offset 0x24)

- Bit [21]: End-to-End TLP Prefix Supported
- Bits [23:22]: Max End-to-End TLP Prefixes (00=1, 01=2, 10=3, 11=4)

### 10.2 PASID Extended Capability (Cap ID 0x001B)

- PASID Capability Register: Execute/Privilege supported flags, Max PASID Width
- PASID Control Register: PASID Enable, Execute/Privilege Enable

### 10.3 TPH Requester Extended Capability (Cap ID 0x0017)

- TPH Requester Capability: Extended TPH Requester Supported
- TPH Requester Control: Extended TPH Requester Enable

### 10.4 SR-IOV Extended Capability (Cap ID 0x0010)

Full register set as defined in PCIe Spec Section 9.3.3.
