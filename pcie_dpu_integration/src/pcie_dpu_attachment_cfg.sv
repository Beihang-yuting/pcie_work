//------------------------------------------------------------------------------
// DPU function to physical PCIe attachment mapping.
//
// dpu-common resolves function identity (PF/VF, domain, and BDF), while the
// PCIe environment owns the physical graph.  This object is the explicit
// bridge between those two ownership domains; it never allocates a BDF or BAR.
//------------------------------------------------------------------------------

class pcie_dpu_function_attachment extends uvm_object;
  `uvm_object_utils(pcie_dpu_function_attachment)

  dpu_function_key_t function_key;
  string physical_node_id;
  string link_id;
  bit has_function_number;
  int unsigned function_number;

  function new(string name = "pcie_dpu_function_attachment");
    super.new(name);
    physical_node_id = "";
    link_id = "";
    has_function_number = 1'b0;
    function_number = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_dpu_function_attachment source;

    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("DPU_ATTACH_COPY",
                 "attachment copy source has the wrong type")
      return;
    end
    function_key = source.function_key;
    physical_node_id = source.physical_node_id;
    link_id = source.link_id;
    has_function_number = source.has_function_number;
    function_number = source.function_number;
  endfunction
endclass

class pcie_dpu_attachment_cfg extends uvm_object;
  `uvm_object_utils(pcie_dpu_attachment_cfg)

  // Dynamic records allow one physical Endpoint to expose several PF/VF
  // functions without forcing a fixed maximum into the configuration layer.
  pcie_dpu_function_attachment attachments[$];

  function new(string name = "pcie_dpu_attachment_cfg");
    super.new(name);
    attachments.delete();
  endfunction

  protected function bit same_key(
      dpu_function_key_t lhs,
      dpu_function_key_t rhs);
    return dpu_same_function_key(lhs, rhs);
  endfunction

  function bit add(
      dpu_function_key_t function_key,
      string physical_node_id,
      string link_id,
      bit has_function_number,
      int unsigned function_number,
      output string why);
    pcie_dpu_function_attachment record;

    why = "";
    if (physical_node_id.len() == 0) begin
      why = "physical_node_id must be non-empty";
      return 1'b0;
    end
    if (link_id.len() == 0) begin
      why = "link_id must be non-empty";
      return 1'b0;
    end
    foreach (attachments[i]) begin
      if ((attachments[i] != null) &&
          same_key(attachments[i].function_key, function_key)) begin
        why = {"duplicate DPU function attachment: ",
               dpu_function_key_name(function_key)};
        return 1'b0;
      end
    end

    // Function numbers are local to one physical Endpoint.  They may repeat
    // on different Endpoints because each physical function namespace is
    // independent.
    if (has_function_number) begin
      foreach (attachments[i]) begin
        if ((attachments[i] != null) &&
            (attachments[i].physical_node_id == physical_node_id) &&
            attachments[i].has_function_number &&
            (attachments[i].function_number == function_number)) begin
          why = $sformatf(
            "physical node '%s' already owns function number %0d",
            physical_node_id, function_number);
          return 1'b0;
        end
      end
    end

    record = pcie_dpu_function_attachment::type_id::create(
      $sformatf("attachment_%0d", attachments.size()));
    record.function_key = function_key;
    record.physical_node_id = physical_node_id;
    record.link_id = link_id;
    record.has_function_number = has_function_number;
    record.function_number = function_number;
    attachments.push_back(record);
    return 1'b1;
  endfunction

  function bit find_by_function(
      dpu_function_key_t function_key,
      output string physical_node_id,
      output string link_id,
      output bit has_function_number,
      output int unsigned function_number);
    physical_node_id = "";
    link_id = "";
    has_function_number = 1'b0;
    function_number = 0;
    foreach (attachments[i]) begin
      if ((attachments[i] != null) &&
          same_key(attachments[i].function_key, function_key)) begin
        physical_node_id = attachments[i].physical_node_id;
        link_id = attachments[i].link_id;
        has_function_number = attachments[i].has_function_number;
        function_number = attachments[i].function_number;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  function void validate(output string errors[$]);
    bit seen_function[string];
    string function_owner[string];

    errors.delete();
    foreach (attachments[i]) begin
      string function_name;

      if (attachments[i] == null) begin
        errors.push_back($sformatf("attachment %0d is null", i));
        continue;
      end
      function_name = dpu_function_key_name(attachments[i].function_key);
      if (seen_function.exists(function_name))
        errors.push_back({"duplicate function key ", function_name});
      else
        seen_function[function_name] = 1'b1;
      if (attachments[i].physical_node_id.len() == 0)
        errors.push_back($sformatf(
          "attachment %0d has an empty physical_node_id", i));
      if (attachments[i].link_id.len() == 0)
        errors.push_back($sformatf(
          "attachment %0d has an empty link_id", i));
      if (attachments[i].has_function_number) begin
        string function_owner_key;

        function_owner_key = $sformatf("%s:%0d",
          attachments[i].physical_node_id,
          attachments[i].function_number);
        if (function_owner.exists(function_owner_key))
          errors.push_back($sformatf(
            "physical node '%s' function number %0d is assigned to both %s and %s",
            attachments[i].physical_node_id,
            attachments[i].function_number,
            function_owner[function_owner_key], function_name));
        else
          function_owner[function_owner_key] = function_name;
      end
    end
  endfunction

  virtual function void do_copy(uvm_object rhs);
    pcie_dpu_attachment_cfg source;
    pcie_dpu_function_attachment copy_record;

    super.do_copy(rhs);
    if (!$cast(source, rhs)) begin
      `uvm_fatal("DPU_ATTACH_COPY",
                 "attachment configuration source has the wrong type")
      return;
    end
    attachments.delete();
    foreach (source.attachments[i]) begin
      if (source.attachments[i] == null) begin
        attachments.push_back(null);
      end else begin
        copy_record = pcie_dpu_function_attachment::type_id::create(
          $sformatf("attachment_copy_%0d", i));
        copy_record.copy(source.attachments[i]);
        attachments.push_back(copy_record);
      end
    end
  endfunction
endclass
