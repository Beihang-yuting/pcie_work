// Peer-only self-check entry point.  Production topology filelist remains
// focused on the TL-root/primary environment and does not elaborate peer HDL.
+define+PCIE_USE_SVT_PEER
-f pcie_svt_topology.f
../uvm/tests/pcie_svt_peer_test.sv
