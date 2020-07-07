// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Takes out the data one by one (to perform the binary-to-one-hot translation)

// FUTURE Improve parallelism for the output

module simmem_delay_bank #(
    parameter int BankAddressWidth = 32,  // FUTURE Refer to package
    parameter int DelayBankTotalCapacity = 64,
    parameter int WriteRespBankTotalCapacity = 64,  // FUTURE Refer to package
    parameter int ReadDataBankTotalCapacity = 64,  // FUTURE Refer to package
    parameter int CounterWidth = 16,  // FUTURE Refer to package

    localparam WriteRespBankAddrWidth = $clog2 (WriteRespBankTotalCapacity),
    localparam ReadDataBankAddrWidth = $clog2 (ReadDataBankTotalCapacity),
    //localparam MaxBankTotalCapacity = $max (WriteRespBankTotalCapacity, ReadDataBankTotalCapacity),
    localparam MaxBankTotalCapacity =
        WriteRespBankTotalCapacity >= ReadDataBankTotalCapacity ? WriteRespBankTotalCapacity :
        ReadDataBankTotalCapacity,  // FUTURE There should be a better syntax
    localparam MaxBankAddrWidth = $clog2 (MaxBankTotalCapacity)
) (
  input logic clk_i,
  input logic rst_ni,
  
  input logic [MaxBankAddrWidth-1:0] local_identifier_i, // FUTURE Use a packed structure
  input logic [CounterWidth-1:0] delay_i,
  input logic is_write_resp_i,

  // Signals at input
  input  logic in_valid_i,
  output logic in_ready_o,
  
  // Signals at output
  input logic [WriteRespBankTotalCapacity-1:0] write_resp_address_released_onehot_i,
  input logic [ReadDataBankTotalCapacity-1:0] read_data_address_released_onehot_i,
  output logic [WriteRespBankTotalCapacity-1:0] write_resp_release_en_o,
  output logic [ReadDataBankTotalCapacity-1:0] read_data_release_en_o

);

  /////////////////////////
  // Entry valid signals //
  /////////////////////////

  logic [DelayBankTotalCapacity-1:0] entry_valid_d;
  logic [DelayBankTotalCapacity-1:0] entry_valid_q;
  logic [DelayBankTotalCapacity-1:0] entry_valid_input_onehot;

  // Prepare the next valid bit array
  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : entry_valid_update

    // Generate the masks
    assign entry_valid_input_onehot[curr_entry] =
        next_free_entry_onehot[curr_entry] && in_valid_i && in_ready_o;

    always_comb begin
      entry_valid_d[curr_entry] = entry_valid_q[curr_entry];
      entry_valid_d[curr_entry] ^= entry_valid_input_onehot[curr_entry];
      entry_valid_d[curr_entry] ^= current_entry_to_invalidate_onehot[curr_entry];
    end

    assign in_ready_o = | ~entry_valid_q;
  end


  //////////////////////////////////
  // Entry invalidateable signals //
  //////////////////////////////////

  logic [DelayBankTotalCapacity-1:0] current_entry_to_invalidate_multihot;
  logic [DelayBankTotalCapacity-1:0] current_entry_to_invalidate_onehot;

  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : invalidation_assignments

    assign current_entry_to_invalidate_multihot[curr_entry] =
        entry_valid_q[curr_entry] && !|counters_d[curr_entry];

    if (curr_entry == 0) begin
      assign current_entry_to_invalidate_onehot[0] = current_entry_to_invalidate_multihot[0];
    end else begin
      assign current_entry_to_invalidate_onehot[curr_entry] = current_entry_to_invalidate_multihot[
          curr_entry] && !|current_entry_to_invalidate_multihot[curr_entry - 1:0];
    end
  end : invalidation_assignments


  ///////////////////
  // Entry signals //
  ///////////////////

  logic is_write_resp_d[DelayBankTotalCapacity];
  logic is_write_resp_q[DelayBankTotalCapacity];
  logic [MaxBankAddrWidth-1:0] local_identifier_d[DelayBankTotalCapacity];
  logic [MaxBankAddrWidth-1:0] local_identifier_q[DelayBankTotalCapacity];
  logic [CounterWidth-1:0] counters_d[DelayBankTotalCapacity];
  logic [CounterWidth-1:0] counters_q[DelayBankTotalCapacity];

  // Entry signal management
  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : counter_update
    always_comb begin : counter_update_comb
      is_write_resp_d[curr_entry] = is_write_resp_q[curr_entry];
      local_identifier_d[curr_entry] = local_identifier_q[curr_entry];
      counters_d[curr_entry] = counters_q[curr_entry];

      if (entry_valid_input_onehot[curr_entry]) begin
        is_write_resp_d[curr_entry] = is_write_resp_i;
        local_identifier_d[curr_entry] = local_identifier_i;
        counters_d[curr_entry] = delay_i - 1;
      end else begin
        if (|counters_q[curr_entry]) begin
          counters_d[curr_entry] = counters_q[curr_entry] - 1;
        end
      end
    end : counter_update_comb
  end : counter_update


  /////////////////////
  // Next free entry //
  /////////////////////

  logic [DelayBankTotalCapacity-1:0] next_free_entry_onehot;

  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : next_free_entry_assignment
    if (curr_entry == 0) begin
      assign next_free_entry_onehot[0] = !entry_valid_q[0];
    end else begin
      assign next_free_entry_onehot[curr_entry] =
          !entry_valid_q[curr_entry] && &entry_valid_q[curr_entry - 1:0];
    end
  end : next_free_entry_assignment


  ///////////////////////////////////////////////////////////
  // Find out the type of the currently invalidated signal //
  ///////////////////////////////////////////////////////////

  logic [DelayBankTotalCapacity-1:0]
      is_write_resp_invalidated_masks, is_read_data_invalidated_masks;
  logic is_write_resp_invalidated, is_read_data_invalidated;

  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : currently_invalidated_signal_type
    assign is_write_resp_invalidated_masks[curr_entry] =
        current_entry_to_invalidate_onehot[curr_entry] && is_write_resp_q[curr_entry];
    assign is_read_data_invalidated_masks[curr_entry] =
        current_entry_to_invalidate_onehot[curr_entry] && !is_write_resp_q[curr_entry];
  end : currently_invalidated_signal_type

  assign is_write_resp_invalidated = |is_write_resp_invalidated_masks;
  assign is_read_data_invalidated = |is_read_data_invalidated_masks;


  ////////////////////////////////////////////////////////////////////
  // Find out the local address of the currently invalidated signal //
  ////////////////////////////////////////////////////////////////////

  logic [MaxBankAddrWidth-1:0]
      current_local_identifier_to_invalidate_binary_masks[DelayBankTotalCapacity-1:0];
  logic [MaxBankAddrWidth-1:0][DelayBankTotalCapacity-1:0]
      current_local_identifier_to_invalidate_binary_masks_rot90;
  logic [MaxBankAddrWidth-1:0] current_local_identifier_to_invalidate_binary;

  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : currently_invalidated_signal
    assign current_local_identifier_to_invalidate_binary_masks[curr_entry] =
        {MaxBankAddrWidth{current_entry_to_invalidate_onehot[curr_entry]}} &
        local_identifier_q[curr_entry];

    for (
        genvar i_bit = 0; i_bit < MaxBankAddrWidth; i_bit = i_bit + 1
    ) begin : current_local_identifier_to_invalidate_binary_rotation
      assign current_local_identifier_to_invalidate_binary_masks_rot90[i_bit][curr_entry] =
          current_local_identifier_to_invalidate_binary_masks[curr_entry][i_bit];
    end
  end : currently_invalidated_signal
  for (
      genvar i_bit = 0; i_bit < MaxBankAddrWidth; i_bit = i_bit + 1
  ) begin : current_local_identifier_to_invalidate_binary_aggregation
    assign current_local_identifier_to_invalidate_binary[i_bit] =
        |current_local_identifier_to_invalidate_binary_masks_rot90[i_bit];
  end


  ///////////////////////////////////////////////////
  // Convert local identifier to release to onehot //
  ///////////////////////////////////////////////////

  logic [MaxBankTotalCapacity-1:0] current_local_identifier_to_invalidate_onehot;

  // This conversion may not be optimal
  for (
      genvar curr_address = 0;
      curr_address < DelayBankTotalCapacity;
      curr_address = curr_address + 1
  ) begin : current_local_identifier_to_invalidate_onehot_assignment
    assign current_local_identifier_to_invalidate_onehot[curr_address] =
        curr_address == current_local_identifier_to_invalidate_binary;
  end : current_local_identifier_to_invalidate_onehot_assignment


  /////////////////////////////////////
  // Update the release_en_i signals //
  /////////////////////////////////////

  logic [WriteRespBankTotalCapacity-1:0] write_resp_release_en_d;
  logic [ReadDataBankTotalCapacity-1:0] read_data_release_en_d;

  always_comb begin : update_release_en_signals
    write_resp_release_en_d = write_resp_release_en_o;
    read_data_release_en_d = read_data_release_en_o;

    // Clear the released values
    write_resp_release_en_d &= ~write_resp_address_released_onehot_i;
    read_data_release_en_d &= ~read_data_address_released_onehot_i;

    // Add the new values to release
    if (is_write_resp_invalidated) begin
      write_resp_release_en_d |=
          current_local_identifier_to_invalidate_onehot[WriteRespBankTotalCapacity - 1:0];
    end
    // For now, conditions imply an implicit else
    if (is_read_data_invalidated) begin
      read_data_release_en_d |=
          current_local_identifier_to_invalidate_onehot[ReadDataBankTotalCapacity - 1:0];
    end

  end : update_release_en_signals


  //////////////////////////////////
  // Sequential signal management //
  //////////////////////////////////

  for (
      genvar curr_entry = 0; curr_entry < DelayBankTotalCapacity; curr_entry = curr_entry + 1
  ) begin : sequential_signal_update
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        entry_valid_q[curr_entry] <= '0;
        is_write_resp_q[curr_entry] <= '0;
        local_identifier_q[curr_entry] <= '0;

        write_resp_release_en_o[curr_entry] <= '0;
        read_data_release_en_o[curr_entry] <= '0;
        counters_q[curr_entry] <= '0;
      end else begin
        entry_valid_q[curr_entry] <= entry_valid_d[curr_entry];
        is_write_resp_q[curr_entry] <= is_write_resp_d[curr_entry];
        local_identifier_q[curr_entry] <= local_identifier_d[curr_entry];

        write_resp_release_en_o[curr_entry] <= write_resp_release_en_d[curr_entry];
        read_data_release_en_o[curr_entry] <= read_data_release_en_d[curr_entry];
        counters_q[curr_entry] <= counters_d[curr_entry];
      end
    end
  end : sequential_signal_update

endmodule
