// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Does not support direct replacement (simultaneous write and read in the RAM)
// Assumes that a message is received by the message bank before it should be released

// FUTURE reserve some slots for each AXI ID to avoid deadlocks
// FUTURE use mono-port struct RAM

// TODO Predict the next output

module simmem_write_resp_bank #(
    parameter int MessageWidth = 32,  // Width of the message including identifier
    parameter int TotalCapacity = 64,
    parameter int IDWidth = 4
) (
    input logic clk_i,
    input logic rst_ni,

    // Reservation signals
    input logic [IDWidth-1:0] reservation_request_id_i,
    output logic [$clog2(TotalCapacity)-1:0] new_reserved_address_o,

    input logic reservation_request_ready_i,
    output logic reservation_request_valid_o,

    // Bank I/O signals
    input  logic [MessageWidth-1:0] data_i,
    output logic [MessageWidth-1:0] data_o,

    input logic [TotalCapacity-1:0] release_en_i, // multi-hot signal
    output logic [TotalCapacity-1:0] address_released_onehot_o,

    input  logic in_valid_i,
    output logic in_ready_o,
  
    input  logic out_ready_i,
    output logic out_valid_o
  );

  // TODO next_id_to_release_d and _q.

  // import simmem_pkg::ram_bank_e;
  // import simmem_pkg::ram_port_e;

  typedef enum logic {
    STRUCT_RAM = 1'b0,
    NEXT_ELEM_RAM = 1'b1
  } ram_bank_e;

  typedef enum logic {
    RAM_IN = 1'b0,
    RAM_OUT = 1'b1
  } ram_port_e;

  // Read the data ID
  logic [IDWidth-1:0] data_in_id_field;
  assign data_in_id_field = data_i[IDWidth - 1:0];

  // Head, tail and length signals
  logic [$clog2(TotalCapacity)-1:0] actual_heads_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] actual_heads_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] actual_heads[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] reservation_heads_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] reservation_heads_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] reservation_heads[2**IDWidth-1:0];
  // logic [$clog2(TotalCapacity)-1:0] reservation_heads_q_q[2**IDWidth-1:0]; // One more cycle lag
  logic [$clog2(TotalCapacity)-1:0] previous_reservation_heads_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] previous_reservation_heads_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] tails_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] tails_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] previous_tails_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] previous_tails_q[2**IDWidth-1:0];
  // logic [$clog2(TotalCapacity)-1:0] next_tail_d;
  // logic [$clog2(TotalCapacity)-1:0] next_tail_d_id[2**IDWidth-1:0];
  // logic [$clog2(TotalCapacity)-1:0][2**IDWidth-1:0] next_tail_d_id_rot90;
  // logic [$clog2(TotalCapacity)-1:0] next_tail_q;
  logic [$clog2(TotalCapacity)-1:0] tails[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] actual_length_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] actual_length_q[2**IDWidth-1:0];

  // Length reserved and not used yet
  logic [$clog2(TotalCapacity)-1:0] reservation_length_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] reservation_length_q[2**IDWidth-1:0];

  logic require_piggyback_actual_head_with_reservation_d[2**IDWidth-1:0];
  logic require_piggyback_actual_head_with_reservation_q[2**IDWidth-1:0];
  logic require_piggyback_tail_with_reservation_d[2**IDWidth-1:0];
  logic require_piggyback_tail_with_reservation_q[2**IDWidth-1:0];
  logic piggyback_actual_head_with_reservation[2**IDWidth-1:0];
  logic piggyback_tail_with_actual_head_d[2**IDWidth-1:0];
  logic piggyback_tail_with_actual_head_q[2**IDWidth-1:0];
  
  logic update_tail_from_ram_d[2**IDWidth-1:0];
  logic update_tail_from_ram_q[2**IDWidth-1:0];
  logic update_tail_from_actual_head[2**IDWidth-1:0];
  logic update_actual_head_from_ram_d[2**IDWidth-1:0];
  logic update_actual_head_from_ram_q[2**IDWidth-1:0];
  logic update_actual_head_from_reservation_head[2**IDWidth-1:0];
  logic update_actual_head_from_previous_reservation_head[2**IDWidth-1:0];
  logic update_reservation_heads[2**IDWidth-1:0];

  // Update heads and tails
  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
    assign actual_heads_d[current_id] = piggyback_actual_head_with_reservation[current_id] ? next_free_ram_entry_binary : (
        update_actual_head_from_reservation_head[current_id] ? reservation_heads_q[current_id] : (
        update_actual_head_from_previous_reservation_head[current_id] ? previous_reservation_heads_q[current_id] : actual_heads[current_id]));
    assign actual_heads[current_id] = update_actual_head_from_ram_q[current_id] ? data_out_next_elem_ram : actual_heads_q[current_id];

    assign previous_tails_d[current_id] = !piggyback_tail_with_actual_head_d[current_id] && !update_actual_head_from_ram_d[current_id] ? previous_tails_q[current_id] : tails_q[current_id];

    assign tails_d[current_id] = update_tail_from_actual_head[current_id] ? actual_heads_q[current_id] : tails[current_id];
    assign tails[current_id] = piggyback_tail_with_actual_head_q[current_id] ? actual_heads[current_id] : (
        update_tail_from_ram_q[current_id] ? data_out_next_elem_ram : tails_q[current_id]);

    assign previous_reservation_heads_d[current_id] = update_reservation_heads[current_id] ? reservation_heads_q[current_id] : previous_reservation_heads_q[current_id]; 
    assign reservation_heads_d[current_id] = update_reservation_heads[current_id] ? next_free_ram_entry_binary : reservation_heads_q[current_id]; 
    
    // assign tails_d[current_id] = piggyback_actual_head_with_reservation[current_id] ? next_free_ram_entry_binary : 
    //     (current_output_valid_q && out_ready_i && current_output_identifier_onehot_q[current_id] ? 
    //     (update_tail_from_ram_q[current_id] ? data_out_next_elem_ram : actual_heads_q[current_id]) : tails_q[current_id]);

    assign reservation_heads[current_id] = reservation_heads_q[current_id];
  end

  // assign next_tail_d = is_fresh_output_request_q ? data_out_next_elem_ram : next_tail_q;

  // Output valid and address
  logic current_output_valid_d;
  logic [2**IDWidth-1:0] current_output_valid_d_id; // TODO Enlever ça et regarder si qn a actuellement (ou dans le futur?) la bonne taille.
  logic current_output_valid_q;
  logic [2**IDWidth-1:0] current_output_identifier_onehot_d;
  logic [2**IDWidth-1:0] current_output_identifier_onehot_q;
  // logic [TotalCapacity-1:0] current_output_address_onehot_id[2**IDWidth-1:0];
  // logic [TotalCapacity-1:0] current_output_address_onehot_id[2**IDWidth-1:0];
  logic [TotalCapacity-1:0] current_output_address_onehot_d;
  logic [TotalCapacity-1:0] current_output_address_onehot_q;
  logic [2**IDWidth-1:0] is_fresh_output_request_d;
  logic is_fresh_output_request_q;

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic ram_valid_d[TotalCapacity-1:0];
  logic ram_valid_q[TotalCapacity-1:0];
  logic [TotalCapacity-1:0] ram_valid_q_packed;
  logic ram_valid_reservation_mask[TotalCapacity-1:0];
  logic [TotalCapacity-1:0] ram_valid_out_mask;

  assign address_released_onehot_o = ram_valid_out_mask;

  // Prepare the next RAM valid bit array
  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign ram_valid_d[current_addr] = ram_valid_q[current_addr] ^
        (ram_valid_reservation_mask[current_addr]) ^ (ram_valid_out_mask[current_addr]);
  end

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic next_free_ram_entry_onehot[TotalCapacity-1:0];  // Can be full zero // TB_ONLY
  logic [TotalCapacity-1:0] next_free_ram_entry_onehot_packed; // TB_ONLY

  logic [$clog2(TotalCapacity)-1:0] next_free_address_binary_masks[TotalCapacity-1:0];
  logic [TotalCapacity-1:0] next_free_address_binary_masks_rot90[$clog2(TotalCapacity)-1:0];
  logic [$clog2(TotalCapacity)-1:0] next_free_ram_entry_binary;

  assign new_reserved_address_o = next_free_ram_entry_binary;

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign next_free_ram_entry_onehot_packed[current_addr] = next_free_ram_entry_onehot[current_addr]; // TB_ONLY

    assign next_free_address_binary_masks[current_addr] = next_free_ram_entry_onehot[current_addr] ? current_addr : '0;

    for (
        genvar current_addr_bit = 0;
        current_addr_bit < $clog2(TotalCapacity);
        current_addr_bit = current_addr_bit + 1
    ) begin
      assign next_free_address_binary_masks_rot90[current_addr_bit][current_addr] =
          next_free_address_binary_masks[current_addr][current_addr_bit];
    end
  end
  for (
      genvar current_addr_bit = 0;
      current_addr_bit < $clog2(TotalCapacity);
      current_addr_bit = current_addr_bit + 1
  ) begin
    assign next_free_ram_entry_binary[current_addr_bit] =
        |next_free_address_binary_masks_rot90[current_addr_bit];
  end

  // RAM instances and management signals
  logic req_ram[1:0][1:0];
  logic write_ram[1:0][1:0];

  logic [MessageWidth-1:0] wmask_struct_ram[1:0];
  logic [$clog2(TotalCapacity)-1:0] wmask_next_elem_ram[1:0];

  logic [MessageWidth-1:0] data_out_struct_ram;
  logic [$clog2(TotalCapacity)-1:0] data_out_next_elem_ram;

  logic req_ram_id[1:0][1:0][2**IDWidth-1:0];
  logic [2**IDWidth-1:0] req_ram_id_packed[1:0][1:0];
  logic [2**IDWidth-1:0] write_ram_id[1:0][1:0];

  logic [$clog2(TotalCapacity)-1:0] write_next_elem_content_ram;
  logic [$clog2(TotalCapacity)-1:0] write_next_elem_content_ram_id[2**IDWidth-1:0];
  logic [2**IDWidth-1:0] write_next_elem_content_ram_masks_rot90[$clog2(TotalCapacity)-1:0];

  logic [$clog2(TotalCapacity)-1:0] addr_ram[1:0][1:0];
  logic [$clog2(TotalCapacity)-1:0] addr_ram_id[1:0][1:0][2**IDWidth-1:0];
  logic [2**IDWidth-1:0] addr_ram_masks_rot90[1:0][1:0][$clog2(TotalCapacity)-1:0];

  for (genvar ram_bank = 0; ram_bank < 2; ram_bank = ram_bank + 1) begin
    for (genvar ram_port = 0; ram_port < 2; ram_port = ram_port + 1) begin
      // Aggregate the RAM requests
      assign req_ram[ram_bank][ram_port] = |req_ram_id_packed[ram_bank][ram_port];
      assign write_ram[ram_bank][ram_port] = |write_ram_id[ram_bank][ram_port];

      for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
        assign req_ram_id_packed[ram_bank][ram_port][current_id] =
            req_ram_id[ram_bank][ram_port][current_id];

        for (
            genvar current_addr_bit = 0;
            current_addr_bit < $clog2(TotalCapacity);
            current_addr_bit = current_addr_bit + 1
        ) begin
          assign addr_ram_masks_rot90[ram_bank][ram_port][current_addr_bit][current_id] =
              addr_ram_id[ram_bank][ram_port][current_id][current_addr_bit];
        end
      end
      for (
          genvar current_addr_bit = 0;
          current_addr_bit < $clog2(TotalCapacity);
          current_addr_bit = current_addr_bit + 1
      ) begin
        assign addr_ram[ram_bank][ram_port][current_addr_bit] =
            |addr_ram_masks_rot90[ram_bank][ram_port][current_addr_bit];
      end
    end
  end

  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
    for (
        genvar current_addr_bit = 0;
        current_addr_bit < $clog2(TotalCapacity);
        current_addr_bit = current_addr_bit + 1
    ) begin
      assign write_next_elem_content_ram_masks_rot90[current_addr_bit][current_id] =
          write_next_elem_content_ram_id[current_id][current_addr_bit];
      // assign next_tail_d_id_rot90[current_addr_bit][current_id] =
      //     next_tail_d_id[current_id][current_addr_bit];
    end
  end
  for (
      genvar current_addr_bit = 0;
      current_addr_bit < $clog2(TotalCapacity);
      current_addr_bit = current_addr_bit + 1
  ) begin
    assign write_next_elem_content_ram[current_addr_bit] =
        |write_next_elem_content_ram_masks_rot90[current_addr_bit];
    // assign next_tail_d[current_addr_bit] =
    //     |next_tail_d_id_rot90[current_addr_bit];
  end

  assign wmask_struct_ram[RAM_IN] = {MessageWidth {1'b1}};
  assign wmask_struct_ram[RAM_OUT] = {MessageWidth {1'b1}};
  assign wmask_next_elem_ram[RAM_IN] = {$clog2(TotalCapacity) {1'b1}};
  assign wmask_next_elem_ram[RAM_OUT] = {$clog2(TotalCapacity) {1'b1}};

  prim_generic_ram_2p #(
    .Width(MessageWidth),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) i_message_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_ram[STRUCT_RAM][RAM_IN]),
    .a_write_i   (write_ram[STRUCT_RAM][RAM_IN]),
    .a_wmask_i   (wmask_struct_ram[RAM_IN]),
    .a_addr_i    (addr_ram[STRUCT_RAM][RAM_IN]),
    .a_wdata_i   (data_i),
    .a_rdata_o   (),
    
    .b_req_i     (req_ram[STRUCT_RAM][RAM_OUT]),
    .b_write_i   (write_ram[STRUCT_RAM][RAM_OUT]),
    .b_wmask_i   (wmask_struct_ram[RAM_OUT]),
    .b_addr_i    (addr_ram[STRUCT_RAM][RAM_OUT]),
    .b_wdata_i   (),
    .b_rdata_o   (data_out_struct_ram)
  );

  prim_generic_ram_2p #(
    .Width($clog2(TotalCapacity)),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) i_next_element_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_write_i   (write_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_wmask_i   (wmask_next_elem_ram[RAM_IN]),
    .a_addr_i    (addr_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_wdata_i   (write_next_elem_content_ram),
    .a_rdata_o   (),
    
    .b_req_i     (req_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_write_i   (write_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_wmask_i   (wmask_next_elem_ram[RAM_OUT]),
    .b_addr_i    (addr_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_wdata_i   (),
    .b_rdata_o   (data_out_next_elem_ram)
  );

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign ram_valid_q_packed[current_addr] = ram_valid_q[current_addr];
  end

  assign next_free_ram_entry_onehot[0] = !ram_valid_q[0];
  for (genvar current_addr = 1; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign next_free_ram_entry_onehot[current_addr] =
        !ram_valid_q[current_addr] && &ram_valid_q_packed[current_addr - 1:0];
  end

  // Next AXI identifier to release

  // All the cells at 1'b1 represent the candidate AXI ids candidate to release
  logic [2**IDWidth-1:0] next_id_to_release_multihot;
  // The unique cell at 1'b1 represents the lowest-order AXI id candidate to release if any
  logic [2**IDWidth-1:0] next_id_to_release_onehot;
  // All the cells at 1'b1 represent (address, AXI id) ready for release
  logic [2**IDWidth-1:0][TotalCapacity-1:0] next_address_to_release_multihot_id;
  // For each AXI id, the unique cell at 1'b1 represents the address ready for release if any
  logic [TotalCapacity-1:0] next_address_to_release_onehot_id[2**IDWidth-1:0];
  logic [TotalCapacity-1:0][2**IDWidth-1:0] next_address_to_release_onehot_rot90_filtered;

  // Next id and address to release from RAM
  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin

    assign next_id_to_release_multihot[current_id] = |next_address_to_release_onehot_id[current_id];
    
    if (current_id == 0) begin
      assign next_id_to_release_onehot[current_id] = next_id_to_release_multihot[current_id];
    end else begin
      assign next_id_to_release_onehot[current_id] = next_id_to_release_multihot[current_id] && !|(next_id_to_release_multihot[current_id-1:0]);
    end

    for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
      assign next_address_to_release_multihot_id[current_id][current_addr] = |(actual_length_d[current_id]) && tails[current_id] == current_addr && release_en_i[current_addr];
      if (current_addr == 0) begin
        assign next_address_to_release_onehot_id[current_id][current_addr] = next_address_to_release_multihot_id[current_id][current_addr];
      end else begin
        assign next_address_to_release_onehot_id[current_id][current_addr] = next_address_to_release_multihot_id[current_id][current_addr] && !|(next_address_to_release_multihot_id[current_id][current_addr-1:0]);
      end
      assign next_address_to_release_onehot_rot90_filtered[current_addr][current_id] = next_address_to_release_onehot_id[current_id][current_addr] && next_id_to_release_onehot[current_id];
    end
  end

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign current_output_address_onehot_d[current_addr] = |next_address_to_release_onehot_rot90_filtered[current_addr];
  end

  // RAM valid masks
  for (
      genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1
  ) begin : ram_valid_masks_generation
    assign ram_valid_reservation_mask[current_addr] = next_free_ram_entry_binary == current_addr && reservation_request_valid_o && reservation_request_ready_i;
    assign ram_valid_out_mask[current_addr] = current_output_address_onehot_q[current_addr] && out_valid_o && out_ready_i;
    // assign ram_valid_out_mask[current_addr] = current_output_valid_q && current_output_address_onehot_q[current_addr] && out_ready_i;
  end

  // Signals for input ready calculation
  logic [2**IDWidth-1:0] is_id_reserved_filtered;
  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
    assign is_id_reserved_filtered[current_id] = data_in_id_field == current_id && |(reservation_length_q[current_id]);
    assign require_piggyback_actual_head_with_reservation_d[current_id] = |reservation_length_q[current_id] ? 1'b0 : require_piggyback_actual_head_with_reservation_q[current_id];
  end

  // Input is ready if there is room and data is not flowing out
  assign in_ready_o = in_valid_i && |is_id_reserved_filtered && !(current_output_valid_q && out_ready_i); // AXI 4 allows ready to depend on the valid signal
  assign out_valid_o = current_output_valid_q;
  assign reservation_request_valid_o = |(~ram_valid_q_packed);


  for (
      genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1
  ) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      actual_length_d[current_id] = actual_length_q[current_id];
      reservation_length_d[current_id] = reservation_length_q[current_id];

      update_tail_from_ram_d[current_id] = 1'b0;
      update_tail_from_actual_head[current_id] = 1'b0;
      update_actual_head_from_reservation_head[current_id] = 1'b0;
      update_actual_head_from_previous_reservation_head[current_id] = 1'b0;
      update_actual_head_from_ram_d[current_id] = 1'b0;
      update_reservation_heads[current_id] = 1'b0;

      // next_tail_d_id[current_id] = '0;
      piggyback_actual_head_with_reservation[current_id] = 1'b0;
      piggyback_tail_with_actual_head_d[current_id] = 1'b0;
      // require_piggyback_actual_head_with_reservation_d[current_id] = 1'b0;

      // Default RAM signals
      for (int ram_bank = 0; ram_bank < 2; ram_bank = ram_bank + 1) begin
        for (int ram_port = 0; ram_port < 2; ram_port = ram_port + 1) begin
          req_ram_id[ram_bank][ram_port][current_id] = 1'b0;
          write_ram_id[ram_bank][ram_port][current_id] = 1'b0;
          addr_ram_id[ram_bank][ram_port][current_id] = '0;
        end
      end
      write_next_elem_content_ram_id[current_id] = '0;

      // Handshakes
      if (next_id_to_release_onehot[current_id]) begin : out_preparation_handshake

        req_ram_id[STRUCT_RAM][RAM_OUT][current_id] = 1'b1;
        write_ram_id[STRUCT_RAM][RAM_OUT][current_id] = 1'b0;
        addr_ram_id[STRUCT_RAM][RAM_OUT][current_id] = tails[current_id];
        
        // Update the tail position
        req_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b1;
        write_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b0;
        addr_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = tails[current_id];
        // write_next_elem_content_ram_id[current_id] = next_free_ram_entry_binary;

      end
      
      // Input handshake
      // If there is a fresh output request running, input can momentarily not be accepted
      // if (!(|is_fresh_output_request_d) && in_ready_o && in_valid_i && data_in_id_field == current_id) begin : in_handshake
      if (!(current_output_valid_q && out_ready_i) && in_ready_o && in_valid_i && data_in_id_field == current_id) begin : in_handshake

        // If the reservation head is just one pointer ahead of the actual head, then the next element RAM
        // is not up to date yet and the actual head will need to read directly from the reservation head address
        
        actual_length_d[current_id] = actual_length_d[current_id] + 1;
        reservation_length_d[current_id] = reservation_length_d[current_id] - 1;

        // if (!|(reservation_length_q[current_id][$clog2(TotalCapacity)-1:1]) && reservation_length_q[current_id][0]) begin
        if (reservation_length_q[current_id] == 2 && |(actual_length_q[current_id])) begin // TODO Merge conditions
          req_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b0;
          update_actual_head_from_reservation_head[current_id] = 1'b1;
        end else if (reservation_length_q[current_id] == 1 || reservation_length_q[current_id] == 2) begin
          req_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b0;
          update_actual_head_from_reservation_head[current_id] = 1'b1;
        end else begin
          req_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b1;
          update_actual_head_from_ram_d[current_id] = 1'b1;
        end

        // Store the data
        req_ram_id[STRUCT_RAM][RAM_IN][current_id] = 1'b1;
        write_ram_id[STRUCT_RAM][RAM_IN][current_id] = 1'b1;
        addr_ram_id[STRUCT_RAM][RAM_IN][current_id] = actual_heads[current_id];

        // Update the actual head position
        write_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b0;
        addr_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = actual_heads[current_id];

        // if (!|reservation_length_q[current_id] && !|actual_length_q[current_id]) begin
        // if (!|reservation_length_q[current_id]) begin
        //   require_piggyback_actual_head_with_reservation_d[current_id] = 1'b1;
        // end

        if (!|(actual_length_q[current_id])) begin
          piggyback_tail_with_actual_head_d[current_id] = 1'b1;
        end
        
      end

      if (reservation_request_ready_i && reservation_request_valid_o && reservation_request_id_i == current_id) begin : reservation

        reservation_length_d[current_id] = reservation_length_d[current_id] + 1;
        update_reservation_heads[current_id] = 1'b1;

        if(|(reservation_length_q[current_id][$clog2(TotalCapacity)-1:1]) || (|(actual_length_q[current_id]) && reservation_length_q[current_id][0])) begin
          // Update the reserved head position
          req_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = 1'b1;
          write_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = 1'b1;
          addr_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = previous_reservation_heads_q[current_id];
          write_next_elem_content_ram_id[current_id] = reservation_heads_q[current_id];

        // end else if((!|(actual_length_q[current_id]) && |(reservation_length_q[current_id])) || require_piggyback_actual_head_with_reservation_q[current_id]) begin
        end

        // if(!|(actual_length_q[current_id]) && !|(reservation_length_q[current_id])) begin
        if(!|(reservation_length_q[current_id])) begin
          piggyback_actual_head_with_reservation[current_id] = 1'b1;
          if(!|(actual_length_q[current_id])) begin
            piggyback_tail_with_actual_head_d[current_id] = 1'b1;
          end
        end

      end
    
      if (current_output_valid_q && out_ready_i && current_output_identifier_onehot_q[current_id]) begin
        
        actual_length_d[current_id] = actual_length_d[current_id] - 1;
        
        if (actual_length_q[current_id] == 1 && !|reservation_length_q[current_id]) begin
          update_tail_from_actual_head[current_id] = 1'b1;
        end else begin
          update_tail_from_ram_d[current_id] = 1'b1;
        end
      end
    end
  end

  // Outputs

  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
    // Determines if a new output will be presented
    assign is_fresh_output_request_d[current_id] = (out_ready_i || !current_output_valid_q) && next_id_to_release_onehot[current_id];

    // assign current_output_valid_d_id[current_id] = (|actual_length_q[current_id][$clog2(TotalCapacity-1):1] || (actual_length_q[current_id][0] && !is_fresh_output_request_d[current_id])) && release_en_i[current_id];
    // assign current_output_valid_d_id[current_id] = |actual_length_q[current_id][$clog2(TotalCapacity-1):0]  && release_en_i[current_id];
    assign current_output_valid_d_id[current_id] = |actual_length_q[current_id][$clog2(TotalCapacity)-1:1] || (actual_length_q[current_id][0] && !current_output_identifier_onehot_q[current_id]);
    
  end

  assign current_output_valid_d = |current_output_valid_d_id || (current_output_valid_q && !out_ready_i);
  assign current_output_identifier_onehot_d = next_id_to_release_onehot;
  assign data_o = data_out_struct_ram; // ImproveMe: Do not store identifiers in RAM

  for (genvar current_id = 0; current_id < 2**IDWidth; current_id = current_id + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        actual_heads_q[current_id] <= '0;
        previous_reservation_heads_q[current_id] <= '0;
        reservation_heads_q[current_id] <= '0;
        previous_tails_q[current_id] <= '0;
        tails_q[current_id] <= '0;
        actual_length_q[current_id] <= '0;
        reservation_length_q[current_id] <= '0;

        update_actual_head_from_ram_q[current_id] <= '0;
        update_tail_from_ram_q[current_id] <= '0;

        piggyback_tail_with_actual_head_q[current_id] <= '0;

        // require_piggyback_actual_head_with_reservation_q[current_id] <= 1'b0;
        // require_piggyback_tail_with_reservation_q[current_id] <= 1'b0;
      end else begin
        actual_heads_q[current_id] <= actual_heads_d[current_id];
        previous_reservation_heads_q[current_id] <= previous_reservation_heads_d[current_id];
        reservation_heads_q[current_id] <= reservation_heads_d[current_id];
        previous_tails_q[current_id] <= previous_tails_d[current_id];
        tails_q[current_id] <= tails_d[current_id];
        actual_length_q[current_id] <= actual_length_d[current_id];
        reservation_length_q[current_id] <= reservation_length_d[current_id];

        update_tail_from_ram_q[current_id] <= update_tail_from_ram_d[current_id];
        update_actual_head_from_ram_q[current_id] <= update_actual_head_from_ram_d[current_id];
        
        piggyback_tail_with_actual_head_q[current_id] <= piggyback_tail_with_actual_head_d[current_id];
        // require_piggyback_actual_head_with_reservation_q[current_id] <= require_piggyback_actual_head_with_reservation_d[current_id];
        // require_piggyback_tail_with_reservation_q[current_id] <= require_piggyback_tail_with_reservation_d[current_id];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      current_output_valid_q <= '0;
      current_output_identifier_onehot_q <= '0;
      current_output_address_onehot_q <= '0;
      // next_tail_q <= '0;
      is_fresh_output_request_q <= 1'b0;
    end else begin
      current_output_valid_q <= current_output_valid_d;
      current_output_identifier_onehot_q <= current_output_identifier_onehot_d;
      current_output_address_onehot_q <= current_output_address_onehot_d;
      // next_tail_q <= next_tail_d;
      is_fresh_output_request_q <= |is_fresh_output_request_d;
    end 
  end

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        ram_valid_q[current_addr] <= 1'b0;
      end else begin
        ram_valid_q[current_addr] <= ram_valid_d[current_addr];
      end
    end
  end

endmodule
