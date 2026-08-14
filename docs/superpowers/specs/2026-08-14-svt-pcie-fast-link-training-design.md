# SVT PCIe Fast Link Training Design

## Goal

Add an explicit simulation-only runtime mode that shortens R-2020.12 SVT
Serial link training while preserving the existing standards-oriented path as
the default. The mode applies to every active primary and peer port in the
compiled topology so both ends of each VIP-to-VIP validation link use matching
training behavior.

## Runtime Interface

The optional argument is:

```text
+PCIE_FAST_LINK_TRAIN=1
```

Omitting the argument is equivalent to `+PCIE_FAST_LINK_TRAIN=0`. Exactly one
value is accepted, and the only legal values are `0` and `1`. Duplicate or
invalid values cause `uvm_fatal` before any agent is created.

This argument is independent of the required `+PCIE_GEN=4` or
`+PCIE_GEN=5`. It does not change lane count, topology, BAR configuration, or
the target generation.

## R-2020.12 Mapping

The integration will use only the public
`svt_pcie_pl_configuration::set_link_eq_attribute_values()` API and will apply
it before creating the SVT agent.

When fast training is disabled, the integration leaves the equalization
controls at their SVT defaults.

When fast training is enabled:

- Gen4 uses `LINK_EQ_MODE_FULL_EQUALIZATION_REQUIRED` with
  `enable_direct_speed_up_from_2_5g_to_16g=1` and retains equalization at
  16 GT/s. This produces Gen1 to Gen4 training and bypasses the intermediate
  Gen3 equalization/training step.
- Gen5 uses `LINK_EQ_MODE_EQ_BYPASS_TO_HIGHEST_RATE`. This produces Gen1 to
  Gen5 training while retaining equalization at the highest rate.

PCIe initial link training still begins at Gen1. The mode cannot make a link
start electrically at Gen4 or Gen5 immediately after reset.

The Gen4 direct-speed control is documented by R-2020.12 as non-standard VIP
behavior and must only be used with a DUT that supports it. Keeping it behind
an explicit plusarg prevents accidental use in compliance-oriented runs.

## Configuration Flow

`pcie_svt_env` parses the plusarg once and passes the resulting bit to every
active `pcie_svt_port_env` through `uvm_config_db`. Each port applies the mode
to its independent `svt_pcie_device_configuration` object before its agent is
created. A low-verbosity diagnostic records the port ID, selected generation,
fast-mode value, and resulting equalization mode.

No Synopsys installation source, HDL parameter, force, deposit, or private VIP
state is modified.

## Verification

Verification runs on `10.11.10.53` with a bash login shell.

The existing x16 peer tests remain the behavioral regression:

- Normal Gen4 must still reach READY/L0 at 16 GT/s x16 with final
  W/E/F=0/0/0.
- Fast Gen4 must reach READY/L0 at 16 GT/s x16, must change the Serial bit
  period from 0.400000 ns to 0.062500 ns, and must not report an intermediate
  0.125000 ns clock or 8 Gb/s READY link.
- Normal and fast Gen5 must reach READY/L0 at 32 GT/s x16 with final
  W/E/F=0/0/0. Fast Gen5 must not report intermediate 8 or 16 Gb/s READY
  links.
- Invalid and duplicate `PCIE_FAST_LINK_TRAIN` arguments must fail during
  build with the dedicated command-line diagnostic.

After x16 is green, the same option will be exercised with the 2x8 and Switch
peer topologies as those peer connections are enabled. All links in a run must
reach the requested speed and width simultaneously.
