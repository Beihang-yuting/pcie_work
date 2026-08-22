class pcie_svt_real_switch_link_gate;
  static function bit ready(
      int unsigned expected_gen,
      int unsigned expected_width,
      bit pl_link_up,
      bit dl_link_up,
      bit in_l0,
      int unsigned actual_gen,
      int unsigned actual_width);
    return pl_link_up && dl_link_up && in_l0 &&
           (actual_gen == expected_gen) &&
           (actual_width == expected_width);
  endfunction
endclass
