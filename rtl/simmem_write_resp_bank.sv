// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Does not support direct replacement (simultaneous write and read in the RAM)
// Assumes that a message is received by the message bank before it should be released

// FUTURE Reserve some slots for each AXI ID to avoid deadlocks
// FUTURE Name all the generate blocks
// FUTURE Use single port RAMs when possible
// FUTURE Do not store identifiers in RAM

module simmem_write_resp_bank #(
    parameter int MessageWidth = 32,  // FUTURE Refer to package
    parameter int TotalCapacity = 64,
    parameter int IDWidth = 4  // FUTURE Refer to package

) (
    input logic clk_i,
    input logic rst_ni,

    // Reservation signals
    input  logic [NumIds-1:0] reservation_request_id_onehot_i,
    output logic [BankAddrWidth-1:0] new_reserved_address_o,

    input  logic reservation_request_ready_i,
    output logic reservation_request_valid_o,

    // Bank I/O signals
    input  logic [MessageWidth-1:0] data_i,
    output logic [MessageWidth-1:0] data_o,

    input  logic [TotalCapacity-1:0] release_en_i,  // multi-hot signal
    output logic [TotalCapacity-1:0] address_released_onehot_o,

    input  logic in_valid_i,
    output logic in_ready_o,

    input  logic out_ready_i,
    output logic out_valid_o
);

  localparam BankAddrWidth = $clog2(TotalCapacity);
  localparam NumIds = 2 ** IDWidth;  // FUTURE Move to package

  // import simmem_pkg::ram_bank_e;
  // import simmem_pkg::ram_port_e;

  typedef enum logic {
    MESSAGE_RAM = 1'b0,
    METADATA_RAM = 1'b1
  } ram_bank_e;

  typedef enum logic {
    RAM_IN = 1'b0,
    RAM_OUT = 1'b1
  } ram_port_e;

  // Read the data ID
  logic [IDWidth-1:0]
      data_in_id_field;  // Future will be unnecessary when using packed strructures as I/O
  assign data_in_id_field = data_i[IDWidth - 1:0];

  //////////////////
  // RAM pointers //
  //////////////////

  // Head, tail and length signals
  logic [BankAddrWidth-1:0] middles_d[NumIds];
  logic [BankAddrWidth-1:0] middles_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] middles[NumIds];

  logic [BankAddrWidth-1:0] heads_d[NumIds];
  logic [BankAddrWidth-1:0] heads_q[NumIds];

  logic [BankAddrWidth-1:0] tails_d[NumIds];
  logic [BankAddrWidth-1:0] tails_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] tails[NumIds];

  logic [BankAddrWidth-1:0] previous_tails_d[NumIds];
  logic [BankAddrWidth-1:0] previous_tails_q[NumIds];

  // Piggyback signals translate the request that if the piggybacker gets updated in the next cycle, then follow it
  logic piggyback_middle_with_reservation[NumIds];
  logic piggyback_tail_with_reservation[NumIds];
  logic piggyback_tail_with_middle_d[NumIds];
  logic piggyback_tail_with_middle_q[NumIds];

  logic update_tail_from_ram_d[NumIds];
  logic update_tail_from_ram_q[NumIds];

  logic update_middle_from_ram_d[NumIds];
  logic update_middle_from_ram_q[NumIds];

  logic update_heads[NumIds];

  // Update reservation and actual heads, and tails
  for (
      genvar current_id = 0; current_id < NumIds; current_id = current_id + 1
  ) begin : pointers_update
    assign middles_d[current_id] =
        piggyback_middle_with_reservation[current_id] ? heads_d[current_id] : middles[current_id];
    assign middles[current_id] =
        update_middle_from_ram_q[current_id] ? data_metadata_ram_out : middles_q[current_id];

    assign previous_tails_d[current_id] = tails_d[current_id] == tails_q[current_id] ?
        previous_tails_q[current_id] : tails_q[current_id];

    assign tails_d[current_id] =
        piggyback_tail_with_reservation[current_id] ? heads_d[current_id] : tails[current_id];
    assign tails[current_id] = piggyback_tail_with_middle_q[current_id] ? middles[current_id] : (
        update_tail_from_ram_q[current_id] ? data_metadata_ram_out : tails_q[current_id]);

    assign heads_d[current_id] =
        update_heads[current_id] ? next_free_ram_entry_binary : heads_q[current_id];
  end


  ///////////////
  // RAM valid //
  ///////////////

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic [TotalCapacity-1:0] ram_valid_d;
  logic [TotalCapacity-1:0] ram_valid_q;
  logic [TotalCapacity-1:0] ram_valid_reservation_mask;
  logic [TotalCapacity-1:0] ram_valid_out_mask;

  // Prepare the next RAM valid bit array
  for (
      genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1
  ) begin : ram_valid_update

    // Generate the masks
    assign ram_valid_reservation_mask[current_addr] = next_free_ram_entry_binary == current_addr &&
        reservation_request_valid_o && reservation_request_ready_i;
    assign ram_valid_out_mask[current_addr] =
        current_output_address_onehot_q[current_addr] && out_valid_o && out_ready_i;

    always_comb begin
      ram_valid_d[current_addr] = ram_valid_q[current_addr];
      // Mark the newly reserved addressed as valid, if applicable
      ram_valid_d[current_addr] ^= ram_valid_reservation_mask[current_addr];
      // Mark the newly released addressed as invalid, if applicable
      ram_valid_d[current_addr] ^= ram_valid_out_mask[current_addr];
    end
  end
  assign address_released_onehot_o = ram_valid_out_mask;


  /////////////////////////
  // Next free RAM entry //
  /////////////////////////

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic next_free_ram_entry_onehot[TotalCapacity];  // Can be full zero

  logic [BankAddrWidth-1:0] next_free_address_binary_masks[TotalCapacity];
  logic [TotalCapacity-1:0] next_free_address_binary_masks_rot90[BankAddrWidth];
  logic [BankAddrWidth-1:0] next_free_ram_entry_binary;

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    if (current_addr == 0) begin
      assign next_free_ram_entry_onehot[0] = !ram_valid_q[0];
    end else begin
      assign next_free_ram_entry_onehot[current_addr] =
          !ram_valid_q[current_addr] && &ram_valid_q[current_addr - 1:0];
    end

    assign next_free_address_binary_masks[current_addr] =
        next_free_ram_entry_onehot[current_addr] ? current_addr : '0;

    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign next_free_address_binary_masks_rot90[i_bit][current_addr] =
          next_free_address_binary_masks[current_addr][i_bit];
    end
  end
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
    assign next_free_ram_entry_binary[i_bit] = |next_free_address_binary_masks_rot90[i_bit];
  end

  assign new_reserved_address_o = next_free_ram_entry_binary;


  ////////////////////////////
  // RAM management signals //
  ////////////////////////////

  logic req_message_ram_in, req_message_ram_out;
  logic req_metadata_ram_in, req_metadata_ram_out;

  // Determines, for each AXI identifier, whether the queue already exists in RAM
  logic [NumIds-1:0] queue_initiated_id;

  logic write_message_ram_in, write_message_ram_out;
  logic write_metadata_ram_in, write_metadata_ram_out;

  logic [MessageWidth-1:0] wmask_message_ram_in, wmask_message_ram_out;
  logic [BankAddrWidth-1:0] wmask_metadata_ram_in, wmask_metadata_ram_out;

  logic [MessageWidth-1:0] data_message_ram_out;
  logic [BankAddrWidth-1:0] data_metadata_ram_out;

  logic [BankAddrWidth-1:0] write_metadata_content_ram;
  logic [BankAddrWidth-1:0] write_metadata_content_ram_id[NumIds];
  logic [NumIds-1:0] write_metadata_content_ram_masks_rot90[BankAddrWidth];

  logic [BankAddrWidth-1:0] addr_message_ram_in;
  logic [BankAddrWidth-1:0] addr_message_ram_out;
  logic [BankAddrWidth-1:0] addr_metadata_ram_in;
  logic [BankAddrWidth-1:0] addr_metadata_ram_out;
  logic [BankAddrWidth-1:0] addr_message_ram_in_id[NumIds];
  logic [BankAddrWidth-1:0] addr_message_ram_out_id[NumIds];
  logic [BankAddrWidth-1:0] addr_metadata_ram_in_id[NumIds];
  logic [BankAddrWidth-1:0] addr_metadata_ram_out_id[NumIds];
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_message_ram_in_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_message_ram_out_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_metadata_ram_in_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_metadata_ram_out_rot90;

  for (
      genvar current_id = 0; current_id < NumIds; current_id = current_id + 1
  ) begin : rotate_ram_addresses
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign
          addr_message_ram_in_rot90[i_bit][current_id] = addr_message_ram_in_id[current_id][i_bit];
      assign addr_message_ram_out_rot90[i_bit][current_id] =
          addr_message_ram_out_id[current_id][i_bit];
      assign addr_metadata_ram_in_rot90[i_bit][current_id] =
          addr_metadata_ram_in_id[current_id][i_bit];
      assign addr_metadata_ram_out_rot90[i_bit][current_id] =
          addr_metadata_ram_out_id[current_id][i_bit];
    end
  end
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_ram_addresses
    assign addr_message_ram_in[i_bit] = |addr_message_ram_in_rot90[i_bit];
    assign addr_message_ram_out[i_bit] = |addr_message_ram_out_rot90[i_bit];
    assign addr_metadata_ram_in[i_bit] = |addr_metadata_ram_in_rot90[i_bit];
    assign addr_metadata_ram_out[i_bit] = |addr_metadata_ram_out_rot90[i_bit];
  end

  for (
      genvar current_id = 0; current_id < NumIds; current_id = current_id + 1
  ) begin : rotate_metadata_in
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign write_metadata_content_ram_masks_rot90[i_bit][current_id] =
          write_metadata_content_ram_id[current_id][i_bit];
    end
  end
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_metadata_in
    assign write_metadata_content_ram[i_bit] = |write_metadata_content_ram_masks_rot90[i_bit];
  end

  assign wmask_message_ram_in = {MessageWidth{1'b1}};
  assign wmask_message_ram_out = {MessageWidth{1'b1}};
  assign wmask_metadata_ram_in = {BankAddrWidth{1'b1}};
  assign wmask_metadata_ram_out = {BankAddrWidth{1'b1}};

  assign req_message_ram_in = in_ready_o && in_valid_i && !(out_valid_o && out_ready_i);
  assign req_message_ram_out = |next_id_to_release_onehot;
  // assign req_message_ram_out = 1'b1; is also valid, but makes debugging trickier

  assign req_metadata_ram_in =
      reservation_request_ready_i && reservation_request_valid_o && |queue_initiated_id;
  assign req_metadata_ram_out = |next_id_to_release_onehot ||
      |queue_initiated_id;  // Could be more fine-grained, would require aggregation from IDs
  // assign req_metadata_ram_out = 1'b1; is also valid, but makes debugging trickier

  for (
      genvar current_id = 0; current_id < NumIds; current_id = current_id + 1
  ) begin : req_metadata_in_id_assignment
    assign queue_initiated_id[current_id] = reservation_request_id_onehot_i[current_id] &&
        |reservation_length_q[current_id] || |middle_length_q[current_id];
  end : req_metadata_in_id_assignment

  assign write_message_ram_in = 1'b1;
  assign write_message_ram_out = 1'b0;
  assign write_metadata_ram_in = 1'b1;
  assign write_metadata_ram_out = 1'b0;


  ////////////////////////////////////
  // Next AXI identifier to release //
  ////////////////////////////////////

  logic [NumIds-1:0] next_id_to_release_multihot;
  logic [NumIds-1:0] next_id_to_release_onehot;
  logic [NumIds-1:0][TotalCapacity-1:0] next_address_to_release_multihot_id;
  logic [TotalCapacity-1:0] next_address_to_release_onehot_id[NumIds];
  logic [TotalCapacity-1:0][NumIds-1:0] next_address_to_release_onehot_rot90_filtered;

  // Next id and address to release from RAM
  for (genvar current_id = 0; current_id < NumIds; current_id = current_id + 1) begin

    assign next_id_to_release_multihot[current_id] = |next_address_to_release_onehot_id[current_id];

    if (current_id == 0) begin
      assign next_id_to_release_onehot[current_id] = next_id_to_release_multihot[current_id];
    end else begin
      assign next_id_to_release_onehot[current_id] = next_id_to_release_multihot[current_id] &&
          !|(next_id_to_release_multihot[current_id - 1:0]);
    end

    for (
        genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1
    ) begin
      always_comb begin : next_address_to_release_multihot_id_assignment
        next_address_to_release_multihot_id[current_id][current_addr] =
            |(middle_length_after_output[current_id]) && release_en_i[current_addr];

        if (out_ready_i && out_valid_o) begin
          next_address_to_release_multihot_id[current_id][current_addr] &=
              tails[current_id] == current_addr;
        end else begin
          next_address_to_release_multihot_id[current_id][current_addr] &=
              previous_tails_d[current_id] == current_addr;
        end
      end : next_address_to_release_multihot_id_assignment
      if (current_addr == 0) begin
        assign next_address_to_release_onehot_id[current_id][current_addr] =
            next_address_to_release_multihot_id[current_id][current_addr];
      end else begin
        assign next_address_to_release_onehot_id[current_id][current_addr] =
            next_address_to_release_multihot_id[current_id][current_addr] &&
            !|(next_address_to_release_multihot_id[current_id][current_addr - 1:0]);
      end
      assign next_address_to_release_onehot_rot90_filtered[current_addr][current_id] =
          next_address_to_release_onehot_id[current_id][current_addr] &&
          next_id_to_release_onehot[current_id];
    end
  end

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign current_output_address_onehot_d[current_addr] =
        |next_address_to_release_onehot_rot90_filtered[current_addr];
  end

  // Signals for input ready calculation
  logic [NumIds-1:0] is_id_reserved_filtered;
  for (genvar current_id = 0; current_id < NumIds; current_id = current_id + 1) begin
    assign is_id_reserved_filtered[current_id] =
        data_in_id_field == current_id && |(reservation_length_q[current_id]);
  end

  // Input is ready if there is room and data is not flowing out
  assign in_ready_o = in_valid_i && |is_id_reserved_filtered &&
      !(out_valid_o && out_ready_i);  // AXI 4 allows ready to depend on the valid signal
  assign out_valid_o = current_output_valid_q;
  assign reservation_request_valid_o = |(~ram_valid_q);

  logic [BankAddrWidth-1:0] middle_length_d[NumIds];
  logic [BankAddrWidth-1:0] middle_length_q[NumIds];
  logic [BankAddrWidth-1:0] middle_length_after_output[NumIds];

  logic [BankAddrWidth-1:0] reservation_length_d[NumIds];
  logic [BankAddrWidth-1:0] reservation_length_q[NumIds];


  /////////////
  // Outputs //
  /////////////

  // Output valid and address
  logic current_output_valid_d;
  logic [NumIds-1:0] current_output_valid_d_id;
  logic current_output_valid_q;

  logic [NumIds-1:0] current_output_identifier_onehot_d;
  logic [NumIds-1:0] current_output_identifier_onehot_q;

  logic [TotalCapacity-1:0] current_output_address_onehot_d;
  logic [TotalCapacity-1:0] current_output_address_onehot_q;

  for (genvar current_id = 0; current_id < NumIds; current_id = current_id + 1) begin
    assign middle_length_after_output[current_id] =
        out_valid_o && out_ready_i && current_output_identifier_onehot_q[current_id] ?
        middle_length_q[current_id] - 1 : middle_length_q[current_id];

    assign current_output_valid_d_id[current_id] = |middle_length_after_output[current_id];
  end

  assign current_output_valid_d =
      |current_output_valid_d_id || (current_output_valid_q && !out_ready_i);
  assign current_output_identifier_onehot_d = next_id_to_release_onehot;
  assign data_o = data_message_ram_out;

  for (
      genvar current_id = 0; current_id < NumIds; current_id = current_id + 1
  ) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      middle_length_d[current_id] = middle_length_q[current_id];
      reservation_length_d[current_id] = reservation_length_q[current_id];

      update_tail_from_ram_d[current_id] = 1'b0;
      update_middle_from_ram_d[current_id] = 1'b0;
      update_heads[current_id] = 1'b0;
      piggyback_middle_with_reservation[current_id] = 1'b0;
      piggyback_tail_with_reservation[current_id] = 1'b0;
      piggyback_tail_with_middle_d[current_id] = 1'b0;
      addr_message_ram_in_id[current_id] = '0;
      addr_message_ram_out_id[current_id] = '0;
      addr_metadata_ram_in_id[current_id] = '0;
      addr_metadata_ram_out_id[current_id] = '0;
      write_metadata_content_ram_id[current_id] = '0;

      // Handshakes
      if (next_id_to_release_onehot[current_id]) begin : out_preparation_handshake
        // The tail points not to the current output to provide, but to the next.
        // Give the right output according to the output handshake
        if (out_valid_o && out_ready_i) begin
          addr_message_ram_out_id[current_id] = tails[current_id];
        end else begin
          addr_message_ram_out_id[current_id] = previous_tails_d[current_id];
        end

        // Update the tail position
        addr_metadata_ram_out_id[current_id] = tails[current_id];
      end

      // Input handshake
      if (!(out_valid_o && out_ready_i) && in_ready_o && in_valid_i &&
          data_in_id_field == current_id) begin : in_handshake

        middle_length_d[current_id] = middle_length_d[current_id] + 1;
        reservation_length_d[current_id] = reservation_length_d[current_id] - 1;

        if (|reservation_length_q[current_id][BankAddrWidth - 1:1]) begin
          update_middle_from_ram_d[current_id] = 1'b1;
        end else begin
          piggyback_middle_with_reservation[current_id] = 1'b1;

          // Piggyback the tail if necessary
          if (!|(middle_length_q[current_id])) begin
            piggyback_tail_with_middle_d[current_id] = 1'b1;
          end
        end

        // Store the data
        addr_message_ram_in_id[current_id] = middles[current_id];

        // Update the actual head position
        addr_metadata_ram_out_id[current_id] = middles[current_id];
      end

      if (reservation_request_ready_i && reservation_request_valid_o &&
          reservation_request_id_onehot_i[current_id]) begin : reservation

        reservation_length_d[current_id] = reservation_length_d[current_id] + 1;
        update_heads[current_id] = 1'b1;

        // If the queue is already initiated, then update the head position
        if (|reservation_length_q[current_id] || |middle_length_q[current_id]) begin
          addr_metadata_ram_in_id[current_id] = heads_q[current_id];
          write_metadata_content_ram_id[current_id] = next_free_ram_entry_binary;
        end

        if (!|(reservation_length_q[current_id])) begin
          piggyback_middle_with_reservation[current_id] = 1'b1;
          if (!|(middle_length_q[current_id])) begin
            piggyback_tail_with_reservation[current_id] = 1'b1;
          end
        end
      end

      if (out_valid_o && out_ready_i && current_output_identifier_onehot_q[current_id]) begin
        middle_length_d[current_id] = middle_length_d[current_id] - 1;
        if (middles[current_id] != tails_q[current_id]) begin
          update_tail_from_ram_d[current_id] = 1'b1;
        end
      end
    end
  end

  for (genvar current_id = 0; current_id < NumIds; current_id = current_id + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        middles_q[current_id] <= '0;
        heads_q[current_id] <= '0;
        previous_tails_q[current_id] <= '0;
        tails_q[current_id] <= '0;
        middle_length_q[current_id] <= '0;
        reservation_length_q[current_id] <= '0;

        update_middle_from_ram_q[current_id] <= '0;
        update_tail_from_ram_q[current_id] <= '0;

        piggyback_tail_with_middle_q[current_id] <= '0;
      end else begin
        middles_q[current_id] <= middles_d[current_id];
        heads_q[current_id] <= heads_d[current_id];
        previous_tails_q[current_id] <= previous_tails_d[current_id];
        tails_q[current_id] <= tails_d[current_id];
        middle_length_q[current_id] <= middle_length_d[current_id];
        reservation_length_q[current_id] <= reservation_length_d[current_id];

        update_tail_from_ram_q[current_id] <= update_tail_from_ram_d[current_id];
        update_middle_from_ram_q[current_id] <= update_middle_from_ram_d[current_id];

        piggyback_tail_with_middle_q[current_id] <= piggyback_tail_with_middle_d[current_id];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      current_output_valid_q <= '0;
      current_output_identifier_onehot_q <= '0;
      current_output_address_onehot_q <= '0;
    end else begin
      current_output_valid_q <= current_output_valid_d;
      current_output_identifier_onehot_q <= current_output_identifier_onehot_d;
      current_output_address_onehot_q <= current_output_address_onehot_d;
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

  prim_generic_ram_2p #(
    .Width(MessageWidth),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) i_message_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_message_ram_in),
    .a_write_i   (write_message_ram_in),
    .a_wmask_i   (wmask_message_ram_in),
    .a_addr_i    (addr_message_ram_in),
    .a_wdata_i   (data_i),
    .a_rdata_o   (),
    
    .b_req_i     (req_message_ram_out),
    .b_write_i   (write_message_ram_out),
    .b_wmask_i   (wmask_message_ram_out),
    .b_addr_i    (addr_message_ram_out),
    .b_wdata_i   (),
    .b_rdata_o   (data_message_ram_out)
  );

  prim_generic_ram_2p #(
    .Width(BankAddrWidth),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) i_metadata_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_metadata_ram_in),
    .a_write_i   (write_metadata_ram_in),
    .a_wmask_i   (wmask_metadata_ram_in),
    .a_addr_i    (addr_metadata_ram_in),
    .a_wdata_i   (write_metadata_content_ram),
    .a_rdata_o   (),
    
    .b_req_i     (req_metadata_ram_out),
    .b_write_i   (write_metadata_ram_out),
    .b_wmask_i   (wmask_metadata_ram_out),
    .b_addr_i    (addr_metadata_ram_out),
    .b_wdata_i   (),
    .b_rdata_o   (data_metadata_ram_out)
  );

endmodule
