// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Does not support direct replacement (simultaneous write and read in the RAM)

// FUTURE Reserve some slots for each AXI ID to avoid deadlocks
// FUTURE Name all the generate blocks
// FUTURE Use single port RAMs when possible
// FUTURE Do not store identifiers in RAM

module simmem_write_resp_bank #(
    parameter int MessageWidth = 32,  // FUTURE Refer to package
    parameter int TotCapa = 64,
    parameter int IDWidth = 4  // FUTURE Refer to package

) (
    input logic clk_i,
    input logic rst_ni,

    // Reservation signals
    input  logic [NumIds-1:0] reservation_req_id_onehot_i,
    output logic [BankAddrWidth-1:0] new_reserved_addr_o,

    input  logic reservation_req_ready_i,
    output logic reservation_req_valid_o, 

    // Bank I/O signals
    input  logic [MessageWidth-1:0] data_i,
    output logic [MessageWidth-1:0] data_o,

    input  logic [TotCapa-1:0] release_en_i,  // Multi-hot signal
    output logic [TotCapa-1:0] addr_released_onehot_o,

    input  logic in_valid_i,
    output logic in_ready_o,

    input  logic out_ready_i,
    output logic out_valid_o
);

  localparam BankAddrWidth = $clog2(TotCapa);
  localparam NumIds = 2 ** IDWidth;  // FUTURE Move to package

  // Read the data ID
  logic [IDWidth-1:0]
      data_in_id_field;  // FUTURE will be unnecessary when using packed strructures as I/O
  assign data_in_id_field = data_i[IDWidth - 1:0];

  //////////////////
  // RAM pointers //
  //////////////////

  // Head, tail and length signals

  // mids are the pointers to the next address where the next input of the corresponding AXI
  // identifier will be allocated
  logic [BankAddrWidth-1:0] mids_d[NumIds];
  logic [BankAddrWidth-1:0] mids_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] mids[NumIds];  // Effective middle, after update from RAM

  // Heads are the pointers to the last reserved address
  logic [BankAddrWidth-1:0] heads_d[NumIds];
  logic [BankAddrWidth-1:0] heads_q[NumIds];

  // Previous tails are the pointers to the next addresses to release
  logic [BankAddrWidth-1:0] prev_tails_d[NumIds];
  logic [BankAddrWidth-1:0] prev_tails_q[NumIds];  // Before piggyback from middle
  logic [BankAddrWidth-1:0] prev_tails[NumIds];  // Effective pointer, after piggyback from middle

  // Tails are the pointers to the next next addresses to release. They are only used when two
  // successive releases are made on the same AXI identifier
  logic [BankAddrWidth-1:0] tails_d[NumIds];
  logic [BankAddrWidth-1:0] tails_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] tails[NumIds];

  // Piggyback signals translate that if the piggybacker gets updated in the next
  // cycle, then follow it. They serve the many corner cases to treat
  logic pgbk_m_with_h[NumIds];  // Piggyback middle with reservation
  logic pgbk_pt_with_h[NumIds];  // Piggyback previous tail with reservation
  logic pgbk_t_w_r[NumIds];  // Piggyback previous tail with reservation
  logic pgbk_pt_with_m_d[NumIds];  // Piggyback previous tail with middle
  logic pgbk_pt_with_m_q[NumIds];
  logic pgbk_t_with_m_d[NumIds];  // Piggyback tail with middle
  logic pgbk_t_with_m_q[NumIds];

  logic update_pt_from_t[NumIds];  // Update previous tail from tail
  logic update_t_from_ram_d[NumIds];  // Update tail from RAM
  logic update_t_from_ram_q[NumIds];
  logic update_m_from_ram_d[NumIds];  // Update middle from RAM
  logic update_m_from_ram_q[NumIds];

  logic is_middle_emptybox_d[NumIds];  // Signal that determines the right piggybacking strategy
  logic is_middle_emptybox_q[NumIds];

  logic update_heads[NumIds];

  // Determines, for each AXI identifier, whether the queue already exists in RAM
  logic [NumIds-1:0] queue_initiated_id;


  // Update reservation and actual heads, and tails according to the piggyback and update signals
  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin : pointers_update
    assign mids_d[curr_id] = pgbk_m_with_h[curr_id] ? heads_d[curr_id] : mids[curr_id];
    assign mids[curr_id] = update_m_from_ram_q[curr_id] ? data_meta_ram_out : mids_q[curr_id];

    always_comb begin : prev_tail_d_assignment
      // The next previous tail is either piggybacked with the head, or follows the tail, or keeps
      // its value. If it is piggybacked by the middle pointer, the update is done in the next cycle
      if (pgbk_pt_with_h[curr_id]) begin
        prev_tails_d[curr_id] = nxt_free_addr;
      end else if (update_pt_from_t[curr_id]) begin
        prev_tails_d[curr_id] = tails[curr_id];
      end else begin
        prev_tails_d[curr_id] = prev_tails[curr_id];
      end
    end : prev_tail_d_assignment
    assign prev_tails[curr_id] = pgbk_pt_with_m_q[curr_id] ? mids[curr_id] : prev_tails_q[curr_id];

    assign tails_d[curr_id] = pgbk_t_w_r[curr_id] ? heads_d[curr_id] : tails[curr_id];
    always_comb begin : tail_assignment
      if (pgbk_t_with_m_q[curr_id]) begin
        tails[curr_id] = mids[curr_id];
      end else if (update_t_from_ram_q[curr_id]) begin
        tails[curr_id] = data_meta_ram_out;
      end else begin
        tails[curr_id] = tails_q[curr_id];
      end
    end : tail_assignment

    assign heads_d[curr_id] = update_heads[curr_id] ? nxt_free_addr : heads_q[curr_id];
  end


  ///////////////
  // RAM valid //
  ///////////////

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic [TotCapa-1:0] ram_v_d;
  logic [TotCapa-1:0] ram_v_q;
  logic [TotCapa-1:0] ram_v_rsrvn_mask;
  logic [TotCapa-1:0] ram_v_out_mask;

  // Prepare the next RAM valid bit array
  for (genvar cur_addr = 0; cur_addr < TotCapa; cur_addr = cur_addr + 1) begin : ram_v_update

    // Generate the ram valid masks
    assign ram_v_rsrvn_mask[cur_addr] =
        nxt_free_addr == cur_addr && reservation_req_valid_o && reservation_req_ready_i;
    assign ram_v_out_mask[cur_addr] = cur_out_addr_onehot_q[cur_addr] && out_valid_o && out_ready_i;

    always_comb begin
      ram_v_d[cur_addr] = ram_v_q[cur_addr];
      // Mark the newly reserved addressed as valid, if applicable
      ram_v_d[cur_addr] ^= ram_v_rsrvn_mask[cur_addr];
      // Mark the newly released addressed as invalid, if applicable
      ram_v_d[cur_addr] ^= ram_v_out_mask[cur_addr];
    end
  end
  assign addr_released_onehot_o = ram_v_out_mask;


  /////////////////////////
  // Next free RAM entry //
  /////////////////////////

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic nxt_free_addr_onehot[TotCapa];  // Can be full zero

  // Next free address and annex aggregation signals
  logic [BankAddrWidth-1:0] nxt_free_addr_bin_msk[TotCapa];
  logic [TotCapa-1:0] nxt_free_addr_bin_msk_rot90[BankAddrWidth];
  logic [BankAddrWidth-1:0] nxt_free_addr;

  for (genvar cur_addr = 0; cur_addr < TotCapa; cur_addr = cur_addr + 1) begin : gen_nxt_free_addr
    // Generate next free address
    if (cur_addr == 0) begin
      assign nxt_free_addr_onehot[0] = !ram_v_q[0];
    end else begin
      assign nxt_free_addr_onehot[cur_addr] = !ram_v_q[cur_addr] && &ram_v_q[cur_addr - 1:0];
    end

    // Aggregate next free address
    assign nxt_free_addr_bin_msk[cur_addr] = nxt_free_addr_onehot[cur_addr] ? cur_addr : '0;

    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign nxt_free_addr_bin_msk_rot90[i_bit][cur_addr] = nxt_free_addr_bin_msk[cur_addr][i_bit];
    end
  end : gen_nxt_free_addr
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
    assign nxt_free_addr[i_bit] = |nxt_free_addr_bin_msk_rot90[i_bit];
  end

  assign new_reserved_addr_o = nxt_free_addr;


  ////////////////////////////
  // RAM management signals //
  ////////////////////////////

  logic req_msg_ram_in, req_msg_ram_out;
  logic req_meta_ram_in, req_meta_ram_out;

  logic write_msg_ram_in, write_msg_ram_out;
  logic write_meta_ram_in, write_meta_ram_out;

  logic [MessageWidth-1:0] wmask_msg_ram_in, wmask_msg_ram_out;
  logic [BankAddrWidth-1:0] wmask_meta_ram_in, wmask_meta_ram_out;

  logic [MessageWidth-1:0] data_msg_ram_out;
  logic [BankAddrWidth-1:0] data_meta_ram_out;

  logic [BankAddrWidth-1:0] write_meta_content;
  logic [BankAddrWidth-1:0] write_meta_content_id[NumIds];
  logic [NumIds-1:0] write_meta_content_msk_rot90[BankAddrWidth];

  // RAM address and aggregation message
  logic [BankAddrWidth-1:0] addr_msg_in;
  logic [BankAddrWidth-1:0] addr_msg_out;
  logic [BankAddrWidth-1:0] addr_meta_in;
  logic [BankAddrWidth-1:0] addr_meta_out;
  logic [BankAddrWidth-1:0] addr_msg_in_id[NumIds];
  logic [BankAddrWidth-1:0] addr_msg_out_id[NumIds];
  logic [BankAddrWidth-1:0] addr_meta_in_id[NumIds];
  logic [BankAddrWidth-1:0] addr_meta_out_id[NumIds];
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_msg_in_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_msg_out_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_meta_in_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] addr_meta_out_rot90;

  // RAM address aggregation
  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin : rotate_ram_addres
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign addr_msg_in_rot90[i_bit][curr_id] = addr_msg_in_id[curr_id][i_bit];
      assign addr_msg_out_rot90[i_bit][curr_id] = addr_msg_out_id[curr_id][i_bit];
      assign addr_meta_in_rot90[i_bit][curr_id] = addr_meta_in_id[curr_id][i_bit];
      assign addr_meta_out_rot90[i_bit][curr_id] = addr_meta_out_id[curr_id][i_bit];
    end
  end
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_ram_addres
    assign addr_msg_in[i_bit] = |addr_msg_in_rot90[i_bit];
    assign addr_msg_out[i_bit] = |addr_msg_out_rot90[i_bit];
    assign addr_meta_in[i_bit] = |addr_meta_in_rot90[i_bit];
    assign addr_meta_out[i_bit] = |addr_meta_out_rot90[i_bit];
  end

  // RAM address aggregation
  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin : rotate_meta_in
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin
      assign write_meta_content_msk_rot90[i_bit][curr_id] = write_meta_content_id[curr_id][i_bit];
    end
  end
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_meta_in
    assign write_meta_content[i_bit] = |write_meta_content_msk_rot90[i_bit];
  end

  // RAM write masks, filled with ones
  assign wmask_msg_ram_in = {MessageWidth{1'b1}};
  assign wmask_msg_ram_out = {MessageWidth{1'b1}};
  assign wmask_meta_ram_in = {BankAddrWidth{1'b1}};
  assign wmask_meta_ram_out = {BankAddrWidth{1'b1}};

  // RAM request signals
  // The message RAM input is triggered if there is a successful input handshake
  assign req_msg_ram_in = in_ready_o && in_valid_i;
  assign req_msg_ram_out = |nxt_id_to_release_onehot;

  assign
      req_meta_ram_in = reservation_req_ready_i && reservation_req_valid_o && |queue_initiated_id;
  assign req_meta_ram_out = |nxt_id_to_release_onehot || (in_ready_o && in_valid_i);

  for (
      genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1
  ) begin : req_meta_in_id_assignment
    assign queue_initiated_id[curr_id] = reservation_req_id_onehot_i[curr_id] && (
        |rsrvn_length_q[curr_id] || |middle_length_after_output[curr_id]);
  end : req_meta_in_id_assignment

  assign write_msg_ram_in = 1'b1;
  assign write_msg_ram_out = 1'b0;
  assign write_meta_ram_in = 1'b1;
  assign write_meta_ram_out = 1'b0;


  ////////////////////////////////////
  // Next AXI identifier to release //
  ////////////////////////////////////

  logic [NumIds-1:0] nxt_id_to_release_multihot;
  logic [NumIds-1:0] nxt_id_to_release_onehot;
  logic [NumIds-1:0][TotCapa-1:0] nxt_addr_to_release_multihot_id;
  logic [TotCapa-1:0] nxt_addr_to_release_onehot_id[NumIds];
  logic [TotCapa-1:0][NumIds-1:0] nxt_addr_to_release_onehot_rot90_filtered;

  // Next id and address to release from RAM
  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin

    assign nxt_id_to_release_multihot[curr_id] = |nxt_addr_to_release_onehot_id[curr_id];

    if (curr_id == 0) begin
      assign nxt_id_to_release_onehot[curr_id] = nxt_id_to_release_multihot[curr_id];
    end else begin
      assign nxt_id_to_release_onehot[curr_id] =
          nxt_id_to_release_multihot[curr_id] && !|(nxt_id_to_release_multihot[curr_id - 1:0]);
    end

    for (genvar cur_addr = 0; cur_addr < TotCapa; cur_addr = cur_addr + 1) begin
      always_comb begin : nxt_addr_to_release_multihot_id_assignment
        nxt_addr_to_release_multihot_id[curr_id][cur_addr] =
            |(middle_length_after_output[curr_id]) && release_en_i[cur_addr];

        if (out_ready_i && out_valid_o && cur_output_identifier_onehot_q[curr_id]) begin
          nxt_addr_to_release_multihot_id[curr_id][cur_addr] &= tails[curr_id] == cur_addr;
        end else begin
          nxt_addr_to_release_multihot_id[curr_id][cur_addr] &= prev_tails[curr_id] == cur_addr;
        end
      end : nxt_addr_to_release_multihot_id_assignment
      if (cur_addr == 0) begin
        assign nxt_addr_to_release_onehot_id[curr_id][cur_addr] =
            nxt_addr_to_release_multihot_id[curr_id][cur_addr];
      end else begin
        assign nxt_addr_to_release_onehot_id[curr_id][cur_addr] = nxt_addr_to_release_multihot_id[
            curr_id][cur_addr] && !|(nxt_addr_to_release_multihot_id[curr_id][cur_addr - 1:0]);
      end
      assign nxt_addr_to_release_onehot_rot90_filtered[cur_addr][curr_id] =
          nxt_addr_to_release_onehot_id[curr_id][cur_addr] && nxt_id_to_release_onehot[curr_id];
    end
  end

  for (genvar cur_addr = 0; cur_addr < TotCapa; cur_addr = cur_addr + 1) begin
    assign cur_out_addr_onehot_d[cur_addr] = |nxt_addr_to_release_onehot_rot90_filtered[cur_addr];
  end

  // Signals for input ready calculation
  logic [NumIds-1:0] is_id_rsrvd_filtered;
  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin
    assign
        is_id_rsrvd_filtered[curr_id] = data_in_id_field == curr_id && |(rsrvn_length_q[curr_id]);
  end

  // Input is ready if there is room and data is not flowing out
  assign in_ready_o = in_valid_i && |is_id_rsrvd_filtered &&
      !(out_valid_o && out_ready_i);  // AXI 4 allows ready to depend on the valid signal
  assign reservation_req_valid_o = |(~ram_v_q);

  logic [BankAddrWidth-1:0] middle_length_d[NumIds];
  logic [BankAddrWidth-1:0] middle_length_q[NumIds];
  logic [BankAddrWidth-1:0] middle_length_after_output[NumIds];

  logic [BankAddrWidth-1:0] rsrvn_length_d[NumIds];
  logic [BankAddrWidth-1:0] rsrvn_length_q[NumIds];


  /////////////
  // Outputs //
  /////////////

  // Output valid and address
  logic [NumIds-1:0] cur_output_identifier_onehot_d;
  logic [NumIds-1:0] cur_output_identifier_onehot_q;

  logic [TotCapa-1:0] cur_out_addr_onehot_d;
  logic [TotCapa-1:0] cur_out_addr_onehot_q;

  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin
    assign middle_length_after_output[curr_id] =
        out_valid_o && out_ready_i && cur_output_identifier_onehot_q[curr_id] ?
        middle_length_q[curr_id] - 1 : middle_length_q[curr_id];
  end

  assign cur_output_identifier_onehot_d = nxt_id_to_release_onehot;
  assign out_valid_o = |cur_output_identifier_onehot_q;
  assign data_o = data_msg_ram_out;

  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      middle_length_d[curr_id] = middle_length_q[curr_id];
      rsrvn_length_d[curr_id] = rsrvn_length_q[curr_id];

      is_middle_emptybox_d[curr_id] = is_middle_emptybox_q[curr_id];
      update_t_from_ram_d[curr_id] = 1'b0;
      update_m_from_ram_d[curr_id] = 1'b0;
      update_heads[curr_id] = 1'b0;
      update_pt_from_t[curr_id] = 1'b0;
      pgbk_m_with_h[curr_id] = 1'b0;
      pgbk_pt_with_h[curr_id] = 1'b0;
      pgbk_pt_with_m_d[curr_id] = 1'b0;
      pgbk_t_w_r[curr_id] = 1'b0;
      pgbk_t_with_m_d[curr_id] = 1'b0;
      addr_msg_in_id[curr_id] = '0;
      addr_msg_out_id[curr_id] = '0;
      addr_meta_in_id[curr_id] = '0;
      addr_meta_out_id[curr_id] = '0;
      write_meta_content_id[curr_id] = '0;

      // Handshakes
      if (nxt_id_to_release_onehot[curr_id]) begin : out_preparation_handshake
        // The tail points not to the current output to provide, but to the next.
        // Give the right output according to the output handshake
        if (out_valid_o && out_ready_i && cur_output_identifier_onehot_q[curr_id]) begin
          addr_msg_out_id[curr_id] = tails[curr_id];
        end else begin
          addr_msg_out_id[curr_id] = prev_tails[curr_id];
        end
      end

      // Input handshake
      if (in_ready_o && in_valid_i && data_in_id_field == curr_id) begin : in_handshake

        middle_length_d[curr_id] = middle_length_d[curr_id] + 1;
        rsrvn_length_d[curr_id] = rsrvn_length_d[curr_id] - 1;

        if (mids[curr_id] == heads_q[curr_id]) begin
          pgbk_m_with_h[curr_id] = 1'b1;  // TODO Possibly redundant
          // Fullbox if could not move forward
          is_middle_emptybox_d[curr_id] = heads_d[curr_id] != heads_q[curr_id];
        end else begin
          update_m_from_ram_d[curr_id] = 1'b1;
        end

        if (tails[curr_id] == mids[curr_id]) begin
          if (middle_length_after_output[curr_id] == 0) begin
            pgbk_t_with_m_d[curr_id] = 1'b1;

            if (!is_middle_emptybox_q[curr_id]) begin
              pgbk_pt_with_m_d[curr_id] = 1'b1;
            end
          end else if (middle_length_after_output[curr_id] == 1 &&
                       prev_tails[curr_id] == tails[curr_id]) begin
            pgbk_t_with_m_d[curr_id] = 1'b1;
          end
        end

        // Store the data
        addr_msg_in_id[curr_id] = mids[curr_id];

        // Update the actual head position
        addr_meta_out_id[curr_id] = mids[curr_id];
      end

      if (reservation_req_ready_i && reservation_req_valid_o && reservation_req_id_onehot_i[curr_id]
          ) begin : reservation

        rsrvn_length_d[curr_id] = rsrvn_length_d[curr_id] + 1;
        update_heads[curr_id] = 1'b1;

        // If the queue is already initiated, then update the head position
        if (|rsrvn_length_q[curr_id] || |middle_length_after_output[curr_id]) begin
          addr_meta_in_id[curr_id] = heads_q[curr_id];
          write_meta_content_id[curr_id] = nxt_free_addr;

          if (heads_q[curr_id] == mids[curr_id]) begin
            if (rsrvn_length_q[curr_id] == 0) begin
              if (middle_length_after_output[curr_id] == 0) begin
                pgbk_m_with_h[curr_id] = 1'b1;
                pgbk_pt_with_h[curr_id] = 1'b1;
                pgbk_t_w_r[curr_id] = 1'b1;
                is_middle_emptybox_d[curr_id] = 1'b1;
              end else if (middle_length_after_output[curr_id] == 1) begin
                pgbk_m_with_h[curr_id] = 1'b1;
                pgbk_t_w_r[curr_id] = 1'b1;
                is_middle_emptybox_d[curr_id] = 1'b1;
              end else begin
                pgbk_m_with_h[curr_id] = 1'b1;
                is_middle_emptybox_d[curr_id] = 1'b1;
              end

            end
          end
        end else begin
          pgbk_m_with_h[curr_id] = 1'b1;
          pgbk_pt_with_h[curr_id] = 1'b1;
          pgbk_t_w_r[curr_id] = 1'b1;
          is_middle_emptybox_d[curr_id] = 1'b1;
        end

      end

      if (out_valid_o && out_ready_i && cur_output_identifier_onehot_q[curr_id]) begin
        middle_length_d[curr_id] = middle_length_d[curr_id] - 1;
        update_pt_from_t[curr_id] = 1'b1;
        if (mids[curr_id] != tails[curr_id]) begin
          update_t_from_ram_d[curr_id] = 1'b1;
          addr_meta_out_id[curr_id] = tails[curr_id];
        end else begin
          pgbk_t_with_m_d[curr_id] = 1'b1;
        end

      end
    end
  end

  for (genvar curr_id = 0; curr_id < NumIds; curr_id = curr_id + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        mids_q[curr_id] <= '0;
        heads_q[curr_id] <= '0;
        prev_tails_q[curr_id] <= '0;
        tails_q[curr_id] <= '0;
        middle_length_q[curr_id] <= '0;
        rsrvn_length_q[curr_id] <= '0;

        update_m_from_ram_q[curr_id] <= '0;
        update_t_from_ram_q[curr_id] <= '0;

        is_middle_emptybox_q[curr_id] <= 1'b1;

        pgbk_pt_with_m_q[curr_id] <= '0;
        pgbk_t_with_m_q[curr_id] <= '0;
      end else begin
        mids_q[curr_id] <= mids_d[curr_id];
        heads_q[curr_id] <= heads_d[curr_id];
        prev_tails_q[curr_id] <= prev_tails_d[curr_id];
        tails_q[curr_id] <= tails_d[curr_id];
        middle_length_q[curr_id] <= middle_length_d[curr_id];
        rsrvn_length_q[curr_id] <= rsrvn_length_d[curr_id];

        update_t_from_ram_q[curr_id] <= update_t_from_ram_d[curr_id];
        update_m_from_ram_q[curr_id] <= update_m_from_ram_d[curr_id];

        is_middle_emptybox_q[curr_id] <= is_middle_emptybox_d[curr_id];

        pgbk_pt_with_m_q[curr_id] <= pgbk_pt_with_m_d[curr_id];
        pgbk_t_with_m_q[curr_id] <= pgbk_t_with_m_d[curr_id];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      // cur_output_valid_q <= '0;
      cur_output_identifier_onehot_q <= '0;
      cur_out_addr_onehot_q <= '0;
    end else begin
      // cur_output_valid_q <= cur_output_valid_d;
      cur_output_identifier_onehot_q <= cur_output_identifier_onehot_d;
      cur_out_addr_onehot_q <= cur_out_addr_onehot_d;
    end
  end

  for (genvar cur_addr = 0; cur_addr < TotCapa; cur_addr = cur_addr + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        ram_v_q[cur_addr] <= 1'b0;
      end else begin
        ram_v_q[cur_addr] <= ram_v_d[cur_addr];
      end
    end
  end

  prim_generic_ram_2p #(
    .Width(MessageWidth),
    .DataBitsPerMask(1),
    .Depth(TotCapa)
  ) i_msg_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_msg_ram_in),
    .a_write_i   (write_msg_ram_in),
    .a_wmask_i   (wmask_msg_ram_in),
    .a_addr_i    (addr_msg_in),
    .a_wdata_i   (data_i),
    .a_rdata_o   (),
    
    .b_req_i     (req_msg_ram_out),
    .b_write_i   (write_msg_ram_out),
    .b_wmask_i   (wmask_msg_ram_out),
    .b_addr_i    (addr_msg_out),
    .b_wdata_i   (),
    .b_rdata_o   (data_msg_ram_out)
  );

  prim_generic_ram_2p #(
    .Width(BankAddrWidth),
    .DataBitsPerMask(1),
    .Depth(TotCapa)
  ) i_meta_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_meta_ram_in),
    .a_write_i   (write_meta_ram_in),
    .a_wmask_i   (wmask_meta_ram_in),
    .a_addr_i    (addr_meta_in),
    .a_wdata_i   (write_meta_content),
    .a_rdata_o   (),
    
    .b_req_i     (req_meta_ram_out),
    .b_write_i   (write_meta_ram_out),
    .b_wmask_i   (wmask_meta_ram_out),
    .b_addr_i    (addr_meta_out),
    .b_wdata_i   (),
    .b_rdata_o   (data_meta_ram_out)
  );

endmodule
