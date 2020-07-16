// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

module simmem_linkedlist_bank #(
    parameter TotCapa = simmem_pkg::WriteRespBankTotalCapacity,
    parameter BankAddrWidth = simmem_pkg::WriteRespBankAddrWidth,
    parameter MsgWidth = WriteRespWidth - IDWidth
) (
    input logic clk_i,
    input logic rst_ni,

    // Interface with the real memory controller
    input  simmem_pkg::waddr_req_t data_i,
    output simmem_pkg::waddr_req_t data_o,

    input  logic in_data_valid_i,
    output logic in_data_ready_o,

    input  logic out_data_ready_i,
    output logic out_data_valid_o
);

  import simmem_pkg::*;

  //////////////////
  // RAM pointers //
  //////////////////

  // Head, tail and length signals

  // Heads are the pointers to the last reserved address
  logic [BankAddrWidth-1:0] heads_d[NumIds];
  logic [BankAddrWidth-1:0] heads_q[NumIds];

  // Previous tails are the pointers to the next addresses to release
  logic [BankAddrWidth-1:0] prev_tails_d[NumIds];
  logic [BankAddrWidth-1:0] prev_tails_q[NumIds];

  // Tails are the pointers to the next next addresses to release. They are used when two
  // successive releases are made on the same AXI identifier, and only in this case
  logic [BankAddrWidth-1:0] tails_d[NumIds];
  logic [BankAddrWidth-1:0] tails_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] tails[NumIds];

  logic update_pt_from_t[NumIds];  // Update previous tail from tail
  logic update_t_from_ram_q[NumIds];
  logic update_t_from_ram_d[NumIds];  // Update tail from RAM

  logic update_heads[NumIds];

  // Signals whether the tail has to stick to the head until the next cycle
  logic pgbk_t_with_h[NumIds];

  // Determines, for each AXI identifier, whether the queue already exists in RAM. If the queue
  // does not exist in RAM, all the pointers should be piggybacked with the head.
  logic [NumIds-1:0] queue_initiated_id;

  // Lengths of the respective linkedlists
  logic [BankAddrWidth-1:0] list_len_d[NumIds];
  logic [BankAddrWidth-1:0] list_len_q[NumIds];

  // Length after the potential output
  logic [BankAddrWidth-1:0] list_len_after_out[NumIds];

  // Update heads, and tails according to the update signals
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : pointers_update
    always_comb begin : prev_tail_d_assignment
      // The next previous tail is either piggybacked with the head, or follows the tail, or keeps
      // its value. If it is piggybacked by the middle pointer, the update is done in the next cycle
      // The order of the conditions is important here.
      if (!|list_len_after_out[i_id]) begin
        prev_tails_d[i_id] = nxt_free_addr;
      end else if (update_pt_from_t[i_id]) begin
        prev_tails_d[i_id] = tails[i_id];
      end else begin
        prev_tails_d[i_id] = prev_tails_q[i_id];
      end
    end : prev_tail_d_assignment

    assign tails_d[i_id] = !|list_len_after_out[i_id] ? heads_d[i_id] : tails[i_id];
    always_comb begin : tail_assignment
      if (update_t_from_ram_q[i_id]) begin
        tails[i_id] = meta_ram_out_data.nxt_elem;
      end else begin
        tails[i_id] = tails_q[i_id];
      end
    end : tail_assignment

    assign heads_d[i_id] = update_heads[i_id] ? nxt_free_addr : heads_q[i_id];
  end


  ///////////////
  // RAM valid //
  ///////////////

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic [TotCapa-1:0] ram_v_d;
  logic [TotCapa-1:0] ram_v_q;
  logic [TotCapa-1:0] ram_v_in_mask;
  logic [TotCapa-1:0] ram_v_out_mask;

  // Prepare the next RAM valid bit array
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : ram_v_update

    // Generate the ram valid masks
    assign ram_v_in_mask[i_addr] = nxt_free_addr == i_addr && in_data_ready_o && in_data_valid_i;
    assign ram_v_out_mask[i_addr] =
        cur_out_addr_onehot_q[i_addr] && out_data_valid_o && out_data_ready_i;

    always_comb begin
      ram_v_d[i_addr] = ram_v_q[i_addr];
      // Mark the newly reserved addressed as valid, if applicable
      ram_v_d[i_addr] ^= ram_v_in_mask[i_addr];
      // Mark the newly released addressed as invalid, if applicable
      ram_v_d[i_addr] ^= ram_v_out_mask[i_addr];
    end
  end


  /////////////////////////
  // Next free RAM entry //
  /////////////////////////

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic nxt_free_addr_onehot[TotCapa];  // Can be full zero
  logic [BankAddrWidth-1:0] nxt_free_addr;

  // Genereate the next free address onehot signal
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_nxt_free_addr_onehot
    if (i_addr == 0) begin
      assign nxt_free_addr_onehot[0] = ~ram_v_q[0];
    end else begin
      assign nxt_free_addr_onehot[i_addr] = ~ram_v_q[i_addr] && &ram_v_q[i_addr - 1:0];
    end
  end : gen_nxt_free_addr_onehot

  // Get the next free address binary signal from the corresponding onehot signal
  always_comb begin : get_nxt_free_addr_from_onehot
    nxt_free_addr = '0;
    for (int unsigned i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin
      if (nxt_free_addr_onehot[i_addr]) begin
        nxt_free_addr = i_addr[BankAddrWidth - 1:0];
      end
    end
  end : get_nxt_free_addr_from_onehot


  ////////////////////////////
  // RAM management signals //
  ////////////////////////////

  logic msg_ram_in_req, msg_ram_out_req;
  logic meta_ram_in_req, meta_ram_out_req;

  logic msg_ram_in_write, msg_ram_out_write;
  logic meta_ram_in_write, meta_ram_out_write;

  logic [MsgWidth-1:0] msg_ram_in_wmask, msg_ram_out_wmask;
  logic [BankAddrWidth-1:0] meta_ram_in_wmask, meta_ram_out_wmask;

  logic [MsgWidth-1:0] msg_out_ram_data;
  wresp_metadata_e meta_ram_out_data;

  wresp_metadata_e meta_ram_in_content;
  wresp_metadata_e meta_ram_in_content_id[NumIds];
  logic [NumIds - 1:0] meta_ram_in_content_msk_rot90[WriteRespMetadataWidth];

  // RAM address and aggregation message
  logic [BankAddrWidth-1:0] msg_in_ram_addr;
  logic [BankAddrWidth-1:0] msg_out_ram_addr;
  logic [BankAddrWidth-1:0] meta_ram_in_addr;
  logic [BankAddrWidth-1:0] meta_ram_out_addr;
  logic [BankAddrWidth-1:0] msg_in_ram_addr_id[NumIds];
  logic [BankAddrWidth-1:0] msg_out_ram_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_in_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_out_addr_id[NumIds];
  logic [BankAddrWidth-1:0][NumIds-1:0] msg_in_ram_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] msg_out_ram_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_in_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_out_addr_rot90;

  // RAM address aggregation
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : rotate_ram_addres
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : rotate_ram_addres_inner
      assign msg_in_ram_addr_rot90[i_bit][i_id] = msg_in_ram_addr_id[i_id][i_bit];
      assign msg_out_ram_addr_rot90[i_bit][i_id] = msg_out_ram_addr_id[i_id][i_bit];
      assign meta_ram_in_addr_rot90[i_bit][i_id] = meta_ram_in_addr_id[i_id][i_bit];
      assign meta_ram_out_addr_rot90[i_bit][i_id] = meta_ram_out_addr_id[i_id][i_bit];
    end : rotate_ram_addres_inner
  end : rotate_ram_addres
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_ram_addres
    assign msg_in_ram_addr[i_bit] = |msg_in_ram_addr_rot90[i_bit];
    assign msg_out_ram_addr[i_bit] = |msg_out_ram_addr_rot90[i_bit];
    assign meta_ram_in_addr[i_bit] = |meta_ram_in_addr_rot90[i_bit];
    assign meta_ram_out_addr[i_bit] = |meta_ram_out_addr_rot90[i_bit];
  end : aggregate_ram_addres

  // RAM address aggregation
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : rotate_meta_in
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : rotate_meta_in_inner
      assign meta_ram_in_content_msk_rot90[i_bit][i_id] = meta_ram_in_content_id[i_id][i_bit];
    end : rotate_meta_in_inner
  end : rotate_meta_in
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_meta_in
    assign meta_ram_in_content[i_bit] = |meta_ram_in_content_msk_rot90[i_bit];
  end : aggregate_meta_in

  // RAM write masks, filled with ones
  assign msg_ram_in_wmask = {MsgWidth{1'b1}};
  assign msg_ram_out_wmask = {MsgWidth{1'b1}};
  assign meta_ram_in_wmask = {BankAddrWidth{1'b1}};
  assign meta_ram_out_wmask = {BankAddrWidth{1'b1}};

  // RAM request signals
  // The message RAM input is triggered iff there is a successful data input handshake
  assign msg_ram_in_req = in_data_ready_o && in_data_valid_i;

  // The message RAM output is triggered iff there is data to output at the next cycle
  assign msg_ram_out_req = |nxt_id_to_release_onehot;

  // Assign the queue_initiated signal, to compute whether the metadata RAM should be requested
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : req_meta_in_id_assignment
    assign queue_initiated_id[i_id] = |list_len_after_out[i_id];
  end : req_meta_in_id_assignment

  // New metadata input is coming when there is a reservation and the queue is already initiated
  assign meta_ram_in_req = in_data_ready_o && in_data_valid_i && |queue_initiated_id;

  // Metadata output is requested when there is output to be released (to potentially update the
  // corresponding tails from RAM) or input data coming (to potentially update the corresponding
  // middle pointer from RAM).
  // This signal could be more fine-grained by excluding cases where the output from RAM will not
  // be taken into account.
  assign meta_ram_out_req = 1;

  assign msg_ram_in_write = 1'b1;
  assign msg_ram_out_write = 1'b0;
  assign meta_ram_in_write = 1'b1;
  assign meta_ram_out_write = 1'b0;


  ////////////////////////////////////
  // Next AXI identifier to release //
  ////////////////////////////////////

  // Next address to release, and intermediate annex signals to compute it
  // Next address to release, multihot and by AXI identifier
  logic [NumIds-1:0][TotCapa-1:0] nxt_addr_mhot_id;
  // Next address to release, multihot, rotated and filtered by next it to release
  logic [TotCapa-1:0][NumIds-1:0] nxt_addr_1hot_rot;
  // Next address to release, onehot and by AXI identifier
  logic [TotCapa-1:0] nxt_addr_1hot_id[NumIds];
  // Next address to release, multihot
  logic [NumIds-1:0] nxt_id_mhot;
  logic [NumIds-1:0] nxt_id_to_release_onehot;

  // Next id and address to release from RAM
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_next_id

    // Calculation of the next address to release
    for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_next_addr
      always_comb begin : nxt_addr_mhot_assignment
        // Fundamentally, the next address to release needs to belong to a non-empty AXI
        // identifier and must be enabled for release
        nxt_addr_mhot_id[i_id][i_addr] = |(list_len_after_out[i_id]);

        // The address must additionally be, depending on the situation, the previous tail or the
        // tail of the corresponding queue
        if (out_data_ready_i && out_data_valid_o && cur_out_id_onehot[i_id]) begin
          nxt_addr_mhot_id[i_id][i_addr] &= tails[i_id] == i_addr;
        end else begin
          nxt_addr_mhot_id[i_id][i_addr] &= prev_tails_q[i_id] == i_addr;
        end
      end : nxt_addr_mhot_assignment

      // Derive onehot from multihot signal
      if (i_addr == 0) begin
        assign nxt_addr_1hot_id[i_id][i_addr] = nxt_addr_mhot_id[i_id][i_addr];
      end else begin
        assign nxt_addr_1hot_id[i_id][i_addr] =
            nxt_addr_mhot_id[i_id][i_addr] && ~|(nxt_addr_mhot_id[i_id][i_addr - 1:0]);
      end
      assign nxt_addr_1hot_rot[i_addr][i_id] =
          nxt_addr_1hot_id[i_id][i_addr] && nxt_id_to_release_onehot[i_id];
    end : gen_next_addr

    // Derive multihot next id to release from next address to release
    assign nxt_id_mhot[i_id] = |nxt_addr_1hot_id[i_id];

    // Derive onehot from multihot signal
    if (i_id == 0) begin
      assign nxt_id_to_release_onehot[i_id] = nxt_id_mhot[i_id];
    end else begin
      assign nxt_id_to_release_onehot[i_id] = nxt_id_mhot[i_id] && ~|(nxt_id_mhot[i_id - 1:0]);
    end
  end : gen_next_id

  // Store the next address to be released
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_next_addr_out
    assign cur_out_addr_onehot_d[i_addr] = |nxt_addr_1hot_rot[i_addr];
  end : gen_next_addr_out


  // Input is ready if there is room and data is not flowing out
  assign in_data_ready_o = in_data_valid_i &&
      !(out_data_valid_o && out_data_ready_i);  // AXI 4 allows ready to depend on the valid signal


  /////////////
  // Outputs //
  /////////////

  // Output identifier and address
  logic [IDWidth-1:0] cur_out_id_bin_d;
  logic [IDWidth-1:0] cur_out_id_bin_q;
  logic [NumIds-1:0] cur_out_id_onehot;
  logic cur_out_valid_d;
  logic cur_out_valid_q;

  logic [TotCapa-1:0] cur_out_addr_onehot_d;
  logic [TotCapa-1:0] cur_out_addr_onehot_q;

  // Output identifier from binary to one-hot
  for (genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1) begin : cur_out_bin_to_onehot
    assign cur_out_id_onehot[i_bit] = i_bit == cur_out_id_bin_q;
  end : cur_out_bin_to_onehot

  // Transform next id to release to binary representation for more compact storage
  logic [IDWidth-1:0] nxt_id_to_release_bin;

  always_comb begin : get_nxt_id_to_release_bin_from_onehot
    nxt_id_to_release_bin = '0;
    for (int unsigned i_id = 0; i_id < NumIds; i_id = i_id + 1) begin
      if (nxt_id_to_release_onehot[i_id]) begin
        nxt_id_to_release_bin = i_id[IDWidth - 1:0];
      end
    end
  end : get_nxt_id_to_release_bin_from_onehot

  // Calculate the length of each AXI identifier queue after the potential output
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_len_after_output
    assign list_len_after_out[i_id] = out_data_valid_o && out_data_ready_i &&
        cur_out_id_onehot[i_id] ? list_len_q[i_id] - 1 : list_len_q[i_id];
  end : gen_len_after_output

  // Recall if the current output is valid
  assign cur_out_valid_d = |nxt_id_to_release_onehot;

  assign cur_out_id_bin_d = nxt_id_to_release_bin;
  assign out_data_valid_o = |cur_out_valid_q;
  assign data_o.id = cur_out_id_bin_q;
  assign data_o.content = msg_out_ram_data;

  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      list_len_d[i_id] = list_len_q[i_id];

      update_t_from_ram_d[i_id] = 1'b0;
      update_heads[i_id] = 1'b0;
      update_pt_from_t[i_id] = 1'b0;

      msg_in_ram_addr_id[i_id] = '0;
      msg_out_ram_addr_id[i_id] = '0;
      meta_ram_in_addr_id[i_id] = '0;
      meta_ram_out_addr_id[i_id] = '0;

      meta_ram_in_content_id[i_id] = '0;

      // Handshakes
      if (nxt_id_to_release_onehot[i_id]) begin : out_preparation_handshake
        // The tail points not to the current output to provide, but to the next.
        // Give the right output according to the output handshake
        if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin
          msg_out_ram_addr_id[i_id] = tails[i_id];
        end else begin
          msg_out_ram_addr_id[i_id] = prev_tails_q[i_id];
        end
      end

      // Input handshake
      if (in_data_ready_o && in_data_valid_i && data_i.id == i_id) begin : in_handshake

        update_heads[i_id] = 1'b1;
        list_len_d[i_id] = list_len_d[i_id] + 1;

        // Store the data
        msg_in_ram_addr_id[i_id] = heads_q[i_id];

        // Update the metadata if the queue was initiated
        if (|queue_initiated_id[i_id]) begin
          meta_ram_in_addr_id[i_id] = heads_q[i_id];
          meta_ram_in_content_id[i_id].nxt_elem = nxt_free_addr;
        end
      end

      if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin : ouptut_handshake
        list_len_d[i_id] = list_len_d[i_id] - 1;
        update_pt_from_t[i_id] = 1'b1;  // Update the previous tail
        if (!|list_len_after_out[i_id]) begin
          // If possible, read the next tail address from RAM
          update_t_from_ram_d[i_id] = 1'b1;
          meta_ram_out_addr_id[i_id] = tails[i_id];
        end else begin
          // Else, stick to the head
          pgbk_t_with_h[i_id] = 1'b1;
        end
      end : ouptut_handshake
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      heads_q <= '{default: '0};
      prev_tails_q <= '{default: '0};
      tails_q <= '{default: '0};
      list_len_q <= '{default: '0};

      update_t_from_ram_q <= '{default: '0};
    end else begin
      heads_q <= heads_d;
      prev_tails_q <= prev_tails_d;
      tails_q <= tails_d;
      list_len_q <= list_len_d;

      update_t_from_ram_q <= update_t_from_ram_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cur_out_valid_q <= '0;
      cur_out_id_bin_q <= '0;
      cur_out_addr_onehot_q <= '0;
    end else begin
      cur_out_valid_q <= cur_out_valid_d;
      cur_out_id_bin_q <= cur_out_id_bin_d;
      cur_out_addr_onehot_q <= cur_out_addr_onehot_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ram_v_q <= '0;
    end else begin
      ram_v_q <= ram_v_d;
    end
  end

  // Message RAM instance
  prim_generic_ram_2p #(
      .Width(MsgWidth),
      .DataBitsPerMask(1),
      .Depth(TotCapa)
    ) i_msg_ram (
      .clk_a_i     (clk_i),
      .clk_b_i     (clk_i),
      
      .a_req_i     (msg_ram_in_req),
      .a_write_i   (msg_ram_in_write),
      .a_wmask_i   (msg_ram_in_wmask),
      .a_addr_i    (msg_in_ram_addr),
      .a_wdata_i   (data_i.content),
      .a_rdata_o   (),
      
      .b_req_i     (msg_ram_out_req),
      .b_write_i   (msg_ram_out_write),
      .b_wmask_i   (msg_ram_out_wmask),
      .b_addr_i    (msg_out_ram_addr),
      .b_wdata_i   (),
      .b_rdata_o   (msg_out_ram_data)
    );

  // Metadata RAM instance
  prim_generic_ram_2p #(
      .Width(WriteRespMetadataWidth),
      .DataBitsPerMask(1),
      .Depth(TotCapa)
    ) i_meta_ram (
      .clk_a_i     (clk_i),
      .clk_b_i     (clk_i),
      
      .a_req_i     (meta_ram_in_req),
      .a_write_i   (meta_ram_in_write),
      .a_wmask_i   (meta_ram_in_wmask),
      .a_addr_i    (meta_ram_in_addr),
      .a_wdata_i   (meta_ram_in_content),
      .a_rdata_o   (),
      
      .b_req_i     (meta_ram_out_req),
      .b_write_i   (meta_ram_out_write),
      .b_wmask_i   (meta_ram_out_wmask),
      .b_addr_i    (meta_ram_out_addr),
      .b_wdata_i   (),
      .b_rdata_o   (meta_ram_out_data)
    );

endmodule
