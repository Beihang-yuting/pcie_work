class pcie_svt_cli_parser extends uvm_object;
  `uvm_object_utils(pcie_svt_cli_parser)

  function new(string name = "pcie_svt_cli_parser");
    super.new(name);
  endfunction

  function void parse_tokens(
      input string args[$],
      output string profile_name,
      output int unsigned max_gen,
      output bit fast_link_training,
      output pcie_svt_transport_e transport,
      output pcie_svt_run_mode_e run_mode,
      output pcie_svt_link_override_cfg overrides[$],
      output string errors[$]);
    string parsed_profile;
    int unsigned parsed_gen;
    bit parsed_fast;
    pcie_svt_transport_e parsed_transport;
    pcie_svt_run_mode_e parsed_run_mode;
    pcie_svt_link_override_cfg parsed_overrides[$];
    bit topology_seen;
    bit gen_seen;
    bit transport_seen;
    bit fast_seen;
    bit run_mode_seen;

    profile_name = "";
    max_gen = 0;
    fast_link_training = 1'b0;
    transport = PCIE_SVT_TRANSPORT_SERIAL;
    run_mode = PCIE_SVT_RUN_COMPILE;
    overrides.delete();
    errors.delete();

    parsed_profile = "";
    parsed_gen = 0;
    parsed_fast = 1'b0;
    parsed_transport = PCIE_SVT_TRANSPORT_SERIAL;
    parsed_run_mode = PCIE_SVT_RUN_COMPILE;
    topology_seen = 1'b0;
    gen_seen = 1'b0;
    transport_seen = 1'b0;
    fast_seen = 1'b0;
    run_mode_seen = 1'b0;

    foreach (args[i]) begin
      string key;
      string value;
      bit has_equals;

      split_argument(args[i], key, value, has_equals);
      if ((key == "+PCIE_TOPOLOGY") ||
          starts_with(args[i], "+PCIE_TOPOLOGY=")) begin
        if (topology_seen)
          errors.push_back("duplicate +PCIE_TOPOLOGY argument");
        topology_seen = 1'b1;
        if (!has_equals) begin
          errors.push_back($sformatf("argument '%s' requires '=value'",
                                    args[i]));
        end else if (value.len() == 0) begin
          errors.push_back($sformatf("argument '%s' has an empty value",
                                    args[i]));
        end else if ((value != "EP_X16") && (value != "EP_2X8") &&
                     (value != "SWITCH_1X16_4X4")) begin
          errors.push_back($sformatf(
            "invalid +PCIE_TOPOLOGY value '%s'", value));
        end else begin
          parsed_profile = value;
        end
      end else if ((key == "+PCIE_GEN") ||
                   starts_with(args[i], "+PCIE_GEN=")) begin
        if (gen_seen)
          errors.push_back("duplicate +PCIE_GEN argument");
        gen_seen = 1'b1;
        if (!has_equals) begin
          errors.push_back($sformatf("argument '%s' requires '=value'",
                                    args[i]));
        end else if (value.len() == 0) begin
          errors.push_back($sformatf("argument '%s' has an empty value",
                                    args[i]));
        end else if ((value != "4") && (value != "5")) begin
          errors.push_back($sformatf("invalid +PCIE_GEN value '%s'", value));
        end else begin
          parsed_gen = (value == "4") ? 4 : 5;
        end
      end else if ((key == "+PCIE_TRANSPORT") ||
                   starts_with(args[i], "+PCIE_TRANSPORT=")) begin
        if (transport_seen)
          errors.push_back("duplicate +PCIE_TRANSPORT argument");
        transport_seen = 1'b1;
        if (!has_equals) begin
          errors.push_back($sformatf("argument '%s' requires '=value'",
                                    args[i]));
        end else if (value.len() == 0) begin
          errors.push_back($sformatf("argument '%s' has an empty value",
                                    args[i]));
        end else if (value == "SERIAL") begin
          parsed_transport = PCIE_SVT_TRANSPORT_SERIAL;
        end else if (value == "PIPE") begin
          parsed_transport = PCIE_SVT_TRANSPORT_PIPE;
        end else begin
          errors.push_back($sformatf(
            "invalid +PCIE_TRANSPORT value '%s'", value));
        end
      end else if ((key == "+PCIE_FAST_LINK_TRAIN") ||
                   starts_with(args[i], "+PCIE_FAST_LINK_TRAIN=")) begin
        if (fast_seen)
          errors.push_back("duplicate +PCIE_FAST_LINK_TRAIN argument");
        fast_seen = 1'b1;
        if (!has_equals) begin
          errors.push_back($sformatf("argument '%s' requires '=value'",
                                    args[i]));
        end else if (value.len() == 0) begin
          errors.push_back($sformatf("argument '%s' has an empty value",
                                    args[i]));
        end else if ((value != "0") && (value != "1")) begin
          errors.push_back($sformatf(
            "invalid +PCIE_FAST_LINK_TRAIN value '%s'", value));
        end else begin
          parsed_fast = (value == "1");
        end
      end else if (is_run_mode_token(args[i])) begin
        if (run_mode_seen) begin
          errors.push_back("multiple PCIe run modes specified");
        end else begin
          run_mode_seen = 1'b1;
          case (args[i])
            "+PCIE_COMPILE_ONLY": parsed_run_mode = PCIE_SVT_RUN_COMPILE;
            "+PCIE_CFG_INIT_ONLY": parsed_run_mode = PCIE_SVT_RUN_CFG;
            "+PCIE_LINK_ONLY": parsed_run_mode = PCIE_SVT_RUN_LINK;
            "+PCIE_ENUM_ONLY": parsed_run_mode = PCIE_SVT_RUN_ENUM;
            "+PCIE_TRAFFIC": parsed_run_mode = PCIE_SVT_RUN_TRAFFIC;
          endcase
        end
      end else if (starts_with(args[i], "+PCIE_LINK_")) begin
        parse_link_argument(args[i], key, value, has_equals,
                            parsed_overrides, errors);
      end else if (starts_with(args[i], "+PCIE_")) begin
        errors.push_back($sformatf("unknown PCIe argument '%s'", args[i]));
      end
    end

    if (!topology_seen)
      errors.push_back("missing required +PCIE_TOPOLOGY");
    if (!gen_seen)
      errors.push_back("missing required +PCIE_GEN");
    if (!run_mode_seen)
      errors.push_back("missing required PCIe run mode");

    if (errors.size() != 0)
      return;
    profile_name = parsed_profile;
    max_gen = parsed_gen;
    fast_link_training = parsed_fast;
    transport = parsed_transport;
    run_mode = parsed_run_mode;
    foreach (parsed_overrides[i])
      overrides.push_back(parsed_overrides[i]);
  endfunction

  function void parse_command_line(
      output string profile_name,
      output int unsigned max_gen,
      output bit fast_link_training,
      output pcie_svt_transport_e transport,
      output pcie_svt_run_mode_e run_mode,
      output pcie_svt_link_override_cfg overrides[$],
      output string errors[$]);
    string args[$];
    uvm_cmdline_processor::get_inst().get_args(args);
    parse_tokens(args, profile_name, max_gen, fast_link_training, transport,
                 run_mode, overrides, errors);
  endfunction

  protected function bit starts_with(string value, string prefix);
    if (value.len() < prefix.len())
      return 1'b0;
    return value.substr(0, prefix.len() - 1) == prefix;
  endfunction

  protected function bit ends_with(string value, string suffix);
    if (value.len() < suffix.len())
      return 1'b0;
    return value.substr(value.len() - suffix.len(), value.len() - 1) == suffix;
  endfunction

  protected function void split_argument(
      string argument,
      output string key,
      output string value,
      output bit has_equals);
    int equals_index;

    key = argument;
    value = "";
    has_equals = 1'b0;
    equals_index = -1;
    for (int i = 0; i < argument.len(); i++) begin
      if ((equals_index < 0) && (argument.getc(i) == 8'h3d))
        equals_index = i;
    end
    if (equals_index < 0)
      return;

    has_equals = 1'b1;
    key = (equals_index == 0) ? "" : argument.substr(0, equals_index - 1);
    if (equals_index < (argument.len() - 1))
      value = argument.substr(equals_index + 1, argument.len() - 1);
  endfunction

  protected function bit is_run_mode_token(string argument);
    return (argument == "+PCIE_COMPILE_ONLY") ||
           (argument == "+PCIE_CFG_INIT_ONLY") ||
           (argument == "+PCIE_LINK_ONLY") ||
           (argument == "+PCIE_ENUM_ONLY") ||
           (argument == "+PCIE_TRAFFIC");
  endfunction

  protected function void parse_link_argument(
      string argument,
      string key,
      string value,
      bit has_equals,
      ref pcie_svt_link_override_cfg parsed_overrides[$],
      ref string errors[$]);
    string target;
    string link_id;
    string field;
    string suffix;
    int override_index;
    pcie_svt_link_override_cfg override_cfg;

    if (!has_equals) begin
      errors.push_back($sformatf("argument '%s' requires '=value'", argument));
      return;
    end
    if (value.len() == 0) begin
      errors.push_back($sformatf("argument '%s' has an empty value", argument));
      return;
    end

    target = key.substr(11, key.len() - 1);
    if (ends_with(target, "_FAST_LINK_TRAIN")) begin
      field = "FAST_LINK_TRAIN";
      suffix = "_FAST_LINK_TRAIN";
    end else if (ends_with(target, "_ENABLE")) begin
      field = "ENABLE";
      suffix = "_ENABLE";
    end else if (ends_with(target, "_WIDTH")) begin
      field = "WIDTH";
      suffix = "_WIDTH";
    end else if (ends_with(target, "_GEN")) begin
      field = "GEN";
      suffix = "_GEN";
    end else begin
      int last_underscore;
      last_underscore = -1;
      for (int i = 0; i < target.len(); i++) begin
        if (target.getc(i) == 8'h5f)
          last_underscore = i;
      end
      field = (last_underscore < 0) ? target :
              target.substr(last_underscore + 1, target.len() - 1);
      errors.push_back($sformatf("unknown per-link field '%s'", field));
      return;
    end

    if (target.len() == suffix.len()) begin
      link_id = "";
    end else begin
      link_id = target.substr(0, target.len() - suffix.len() - 1);
    end
    if (link_id.len() == 0) begin
      errors.push_back("per-link argument has an empty link ID");
      return;
    end

    if (((field == "ENABLE") || (field == "FAST_LINK_TRAIN")) &&
        (value != "0") && (value != "1")) begin
      errors.push_back($sformatf("invalid %s value '%s'", field, value));
      return;
    end
    if ((field == "GEN") && (value != "4") && (value != "5")) begin
      errors.push_back($sformatf("invalid GEN value '%s'", value));
      return;
    end
    if ((field == "WIDTH") && (value != "4") && (value != "8") &&
        (value != "16")) begin
      errors.push_back($sformatf("invalid WIDTH value '%s'", value));
      return;
    end

    override_index = -1;
    foreach (parsed_overrides[i]) begin
      if (parsed_overrides[i].link_id == link_id)
        override_index = i;
    end
    if (override_index < 0) begin
      override_cfg = pcie_svt_link_override_cfg::type_id::create(
        $sformatf("link_override_%0d", parsed_overrides.size()));
      override_cfg.link_id = link_id;
      parsed_overrides.push_back(override_cfg);
      override_index = parsed_overrides.size() - 1;
    end
    override_cfg = parsed_overrides[override_index];

    case (field)
      "ENABLE": begin
        if (override_cfg.has_enable) begin
          errors.push_back($sformatf(
            "duplicate per-link field 'ENABLE' for link '%s'", link_id));
          return;
        end
        override_cfg.has_enable = 1'b1;
        override_cfg.enabled = (value == "1");
      end
      "GEN": begin
        if (override_cfg.has_gen) begin
          errors.push_back($sformatf(
            "duplicate per-link field 'GEN' for link '%s'", link_id));
          return;
        end
        override_cfg.has_gen = 1'b1;
        override_cfg.max_gen = (value == "4") ? 4 : 5;
      end
      "WIDTH": begin
        if (override_cfg.has_width) begin
          errors.push_back($sformatf(
            "duplicate per-link field 'WIDTH' for link '%s'", link_id));
          return;
        end
        override_cfg.has_width = 1'b1;
        if (value == "4")
          override_cfg.link_width = 4;
        else if (value == "8")
          override_cfg.link_width = 8;
        else
          override_cfg.link_width = 16;
      end
      "FAST_LINK_TRAIN": begin
        if (override_cfg.has_fast_link_training) begin
          errors.push_back($sformatf(
            "duplicate per-link field 'FAST_LINK_TRAIN' for link '%s'",
            link_id));
          return;
        end
        override_cfg.has_fast_link_training = 1'b1;
        override_cfg.fast_link_training = (value == "1");
      end
    endcase
  endfunction
endclass
