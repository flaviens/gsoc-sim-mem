// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Does not support direct replacement (simultaneous write and read in the RAM)

module simmem_read_data_bank #(
    parameter int MaxBurstLen = 1,
    parameter int TotCapa = simmem_pkg::ReadDataBankTotalCapacity,
    parameter type DataType = simmem_pkg::wresp_t

) (
  input logic clk_i,
  input logic rst_ni,

  // Interface with the reservation manager

  // Identifier for which the reseration request is being done
  input  logic [NumIds-1:0] rsv_req_id_onehot_i,
  input  logic [MaxBurstLenWidth-1:0] rsv_burst_len_i, // Should not be zero
  output logic [BankAddrWidth-1:0] rsv_addr_o, // Reserved address
  // Reservation handshake signals
  input  logic rsv_valid_i,
  output logic rsv_ready_o, 

  // Interface with the releaser
  input  logic [TotCapa-1:0] release_en_i,  // Multi-hot signal
  output logic [TotCapa-1:0] released_addr_onehot_o,

  // Interface with the real memory controller
  input  DataType data_i, // AXI message excluding handshake
  output DataType data_o, // AXI message excluding handshake
  input  logic in_data_valid_i,
  output logic in_data_ready_o,

  // Interface with the requester
  input  logic out_data_ready_i,
  output logic out_data_valid_o
);

  import simmem_pkg::*;

  localparam MaxBurstLenWidth = $clog2(MaxBurstLen + 1);
  localparam BankAddrWidth = $clog2(TotCapa);
  localparam DataWidth = $bits(DataType);
  localparam MsgRamWidth = MaxBurstLen * (DataWidth - IDWidth);

  typedef struct packed {logic [BankAddrWidth-1:0] nxt_elem;} metadata_e;


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

  // Tails are the pointers to the next next addresses to release. They are used when two
  // successive releases are made on the same AXI identifier, and only in this case
  logic [BankAddrWidth-1:0] tails_d[NumIds];
  logic [BankAddrWidth-1:0] tails_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] tails[NumIds];

  // Piggyback signals translate that if the piggybacker gets updated in the next cycle, then
  // follow it. They serve the many corner cases where regular update from the RAM or from the
  // current value of the pointer ahead (in the case of the previous tails) is not possible
  logic pgbk_m_with_h[NumIds];  // Piggyback middle with reservation
  logic pgbk_pt_with_h[NumIds];  // Piggyback previous tail with reservation
  logic pgbk_t_w_h[NumIds];  // Piggyback previous tail with reservation
  logic pgbk_pt_with_m_d[NumIds];  // Piggyback previous tail with middle
  logic pgbk_pt_with_m_q[NumIds];
  logic pgbk_t_with_m_d[NumIds];  // Piggyback tail with middle
  logic pgbk_t_with_m_q[NumIds];

  logic update_pt_from_t[NumIds];  // Update previous tail from tail
  logic update_t_from_ram_q[NumIds];
  logic update_t_from_ram_d[NumIds];  // Update tail from RAM
  logic update_m_from_ram_d[NumIds];  // Update middle from RAM
  logic update_m_from_ram_q[NumIds];

  logic is_middle_emptybox_d[NumIds];  // Signal that determines the right piggybacking strategy
  logic is_middle_emptybox_q[NumIds];

  logic update_heads[NumIds];

  // Determines, for each AXI identifier, whether the queue already exists in RAM. If the queue
  // does not exist in RAM, all the pointers should be piggybacked with the head.
  logic [NumIds-1:0] queue_initiated_id;

  // Lengths of reservation and effective lengths
  logic [BankAddrWidth-1:0] rsv_len_d[NumIds];
  logic [BankAddrWidth-1:0] rsv_len_q[NumIds];

  logic [BankAddrWidth-1:0] mid_len_d[NumIds];
  logic [BankAddrWidth-1:0] mid_len_q[NumIds];
  // Length after the potential output
  logic [BankAddrWidth-1:0] mid_len_after_out[NumIds];


  // Update heads, mids and tails according to the piggyback and update signals
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : pointers_update
    assign mids_d[i_id] = pgbk_m_with_h[i_id] ? heads_d[i_id] : mids[i_id];
    assign mids[i_id] = update_m_from_ram_q[i_id] ? meta_ram_out_data_mid.nxt_elem : mids_q[i_id];

    always_comb begin : prev_tail_d_assignment
      // The next previous tail is either piggybacked with the head, or follows the tail, or keeps
      // its value. If it is piggybacked by the middle pointer, the update is done in the next cycle
      if (pgbk_pt_with_h[i_id]) begin
        prev_tails_d[i_id] = nxt_free_addr;
      end else if (update_pt_from_t[i_id]) begin
        prev_tails_d[i_id] = tails[i_id];
      end else begin
        prev_tails_d[i_id] = prev_tails[i_id];
      end
    end : prev_tail_d_assignment
    assign prev_tails[i_id] = pgbk_pt_with_m_q[i_id] ? mids[i_id] : prev_tails_q[i_id];

    assign tails_d[i_id] = pgbk_t_w_h[i_id] ? heads_d[i_id] : tails[i_id];
    always_comb begin : tail_assignment
      if (pgbk_t_with_m_q[i_id]) begin
        tails[i_id] = mids[i_id];
      end else if (update_t_from_ram_q[i_id]) begin
        tails[i_id] = meta_ram_out_data_tail.nxt_elem;
      end else begin
        tails[i_id] = tails_q[i_id];
      end
    end : tail_assignment

    assign heads_d[i_id] = update_heads[i_id] ? nxt_free_addr : heads_q[i_id];
  end


  /////////////////////////
  // Burst count in cell //
  /////////////////////////

  // Counts how many burst elements are reserved or currently present in the cell.
  // Reservation counters are set at reservation time and decrease when messages are acquired.
  // Message counters increase at message input time and decrease when messages are acquired.
  logic [MaxBurstLenWidth-1:0] rsv_cnt_d[TotCapa];
  logic [MaxBurstLenWidth-1:0] rsv_cnt_q[TotCapa];
  logic [MaxBurstLenWidth-1:0] msg_cnt_d[TotCapa];
  logic [MaxBurstLenWidth-1:0] msg_cnt_q[TotCapa];

  // Masks are intermediates for counter updates
  logic [TotCapa-1:0] cnt_rsv_mask;
  logic [TotCapa-1:0][NumIds-1:0] cnt_in_mask_id;
  logic cnt_in_mask[TotCapa];
  logic [TotCapa-1:0] cnt_out_mask;

  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : cnt_update

    // Caculate the masks according to I/O signals
    assign cnt_rsv_mask[i_addr] = nxt_free_addr == i_addr && rsv_ready_o && rsv_valid_i;
    assign cnt_out_mask[i_addr] =
        cur_out_addr_onehot_q[i_addr] && out_data_valid_o && out_data_ready_i;
    for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_cnt_in_mask
      assign
          cnt_in_mask_id[i_addr][i_id] = data_i.merged_content.id == i_id && mids[i_id] == i_addr;
    end : gen_cnt_in_mask
    assign cnt_in_mask[i_addr] = in_data_ready_o && in_data_valid_i && |cnt_in_mask_id[i_addr];

    always_comb begin
      rsv_cnt_d[i_addr] = rsv_cnt_q[i_addr];
      msg_cnt_d[i_addr] = msg_cnt_q[i_addr];

      // Update the counters according to the masks
      if (cnt_rsv_mask[i_addr]) begin
        rsv_cnt_d[i_addr] = rsv_burst_len_i;
      end else if (cnt_in_mask[i_addr]) begin
        rsv_cnt_d[i_addr] = rsv_cnt_q[i_addr] - 1;
        msg_cnt_d[i_addr] = msg_cnt_q[i_addr] + 1;
      end
      if (cnt_out_mask[i_addr]) begin
        msg_cnt_d[i_addr] = msg_cnt_q[i_addr] - 1;
      end
    end
  end : cnt_update
  assign released_addr_onehot_o = cnt_out_mask;

  // Intermediate signals to calculate lengths
  logic [TotCapa-1:0][MaxBurstLenWidth-1:0] rsv_cnt_addr[NumIds];
  logic [TotCapa-1:0][MaxBurstLenWidth-1:0] mid_cnt_addr[NumIds];
  logic [TotCapa-1:0][MaxBurstLenWidth-1:0] tail_cnt_addr[NumIds];
  logic [TotCapa-1:0][MaxBurstLenWidth-1:0] prev_tail_cnt_addr[NumIds];
  logic [MaxBurstLenWidth-1:0][TotCapa-1:0] rsv_cnt_addr_rot90[NumIds];
  logic [MaxBurstLenWidth-1:0][TotCapa-1:0] mid_cnt_addr_rot90[NumIds];
  logic [MaxBurstLenWidth-1:0][TotCapa-1:0] tail_cnt_addr_rot90[NumIds];
  logic [MaxBurstLenWidth-1:0][TotCapa-1:0] prev_tail_cnt_addr_rot90[NumIds];
  logic [MaxBurstLenWidth-1:0] rsv_cnt_id[NumIds];
  logic [MaxBurstLenWidth-1:0] mid_cnt_id[NumIds];
  logic [MaxBurstLenWidth-1:0] tail_cnt_id[NumIds];
  logic [MaxBurstLenWidth-1:0] prev_tail_cnt_id[NumIds];

  // Assign the count intermediate signals
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_cnt
    for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_cnt_addr
      assign rsv_cnt_addr[i_id][i_addr] =
          rsv_cnt_q[i_addr] & {MaxBurstLenWidth{mids[i_id] == i_addr && |rsv_len_q[i_id]}};
      assign mid_cnt_addr[i_id][i_addr] = msg_cnt_q[i_addr] & {
          MaxBurstLenWidth{mids[i_id] == i_addr && (|rsv_len_q[i_id] || |mid_len_q[i_id])}};
      assign tail_cnt_addr[i_id][i_addr] =
          msg_cnt_q[i_addr] & {MaxBurstLenWidth{tails[i_id] == i_addr}};
      assign prev_tail_cnt_addr[i_id][i_addr] =
          msg_cnt_q[i_addr] & {MaxBurstLenWidth{prev_tails[i_id] == i_addr}};

      for (genvar i_bit = 0; i_bit < MaxBurstLenWidth; i_bit = i_bit + 1) begin : gen_cnt_addr_rot
        assign rsv_cnt_addr_rot90[i_id][i_bit][i_addr] = rsv_cnt_addr[i_id][i_addr][i_bit];
        assign mid_cnt_addr_rot90[i_id][i_bit][i_addr] = mid_cnt_addr[i_id][i_addr][i_bit];
        assign tail_cnt_addr_rot90[i_id][i_bit][i_addr] = tail_cnt_addr[i_id][i_addr][i_bit];
        assign
            prev_tail_cnt_addr_rot90[i_id][i_bit][i_addr] = prev_tail_cnt_addr[i_id][i_addr][i_bit];
      end : gen_cnt_addr_rot
    end : gen_cnt_addr

    for (genvar i_bit = 0; i_bit < MaxBurstLenWidth; i_bit = i_bit + 1) begin : gen_cnt_after_rot
      assign rsv_cnt_id[i_id][i_bit] = |rsv_cnt_addr_rot90[i_id][i_bit];
      assign mid_cnt_id[i_id][i_bit] = |mid_cnt_addr_rot90[i_id][i_bit];
      assign tail_cnt_id[i_id][i_bit] = |tail_cnt_addr_rot90[i_id][i_bit];
      assign prev_tail_cnt_id[i_id][i_bit] = |prev_tail_cnt_addr_rot90[i_id][i_bit];
    end : gen_cnt_after_rot
  end : gen_cnt


  ///////////////
  // RAM valid //
  ///////////////

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic [TotCapa-1:0] ram_v;
  // Prepare the next RAM valid bit array
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : ram_v_update
    assign ram_v[i_addr] = |msg_cnt_q[i_addr] || |rsv_cnt_q[i_addr];
  end : ram_v_update


  /////////////////////////
  // Next free RAM entry //
  /////////////////////////

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic nxt_free_addr_onehot[TotCapa];  // Can be full zero
  logic [BankAddrWidth-1:0] nxt_free_addr;

  // Genereate the next free address onehot signal
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_nxt_free_addr_onehot
    if (i_addr == 0) begin
      assign nxt_free_addr_onehot[0] = ~ram_v[0];
    end else begin
      assign nxt_free_addr_onehot[i_addr] = ~ram_v[i_addr] && &ram_v[i_addr - 1:0];
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

  assign rsv_addr_o = nxt_free_addr;


  ////////////////////////////
  // RAM management signals //
  ////////////////////////////

  logic msg_ram_in_req, msg_ram_out_req;
  logic meta_ram_in_req, meta_ram_out_req;

  logic msg_ram_in_write, msg_ram_out_write;
  logic meta_ram_in_write, meta_ram_out_write;

  logic [BankAddrWidth-1:0] meta_ram_in_wmask, meta_ram_out_wmask;
  logic [MaxBurstLen-1:0] msg_ram_in_wmask;
  logic [MaxBurstLen-1:0] msg_ram_out_wmask_d, msg_ram_out_wmask_q;
  logic [MaxBurstLen-1:0] msg_ram_in_wmask_id[NumIds];
  logic [MaxBurstLen-1:0][NumIds-1:0] msg_ram_in_wmask_id_rot90;
  logic [MaxBurstLen-1:0] msg_ram_out_wmask_id[NumIds];
  logic [MaxBurstLen-1:0][NumIds-1:0] msg_ram_out_wmask_id_rot90;
  // The signal to be provided to the message RAM, which requires the wmask to be as long as the  
  logic [MsgRamWidth-1:0] msg_ram_in_wmask_expanded;
  logic [MsgRamWidth-1:0] msg_ram_out_wmask_expanded;

  // Aggregate the read/write masks
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : aggregate_wmask_id
    for (genvar i_bit = 0; i_bit < MaxBurstLen; i_bit = i_bit + 1) begin : aggregate_wmask_id_rot
      assign msg_ram_in_wmask_id_rot90[i_bit][i_id] = msg_ram_in_wmask_id[i_id][i_bit];
      assign msg_ram_out_wmask_id_rot90[i_bit][i_id] = msg_ram_out_wmask_id[i_id][i_bit];
    end : aggregate_wmask_id_rot
  end : aggregate_wmask_id
  for (genvar i_bit = 0; i_bit < MaxBurstLen; i_bit = i_bit + 1) begin : aggregate_wmask
    assign msg_ram_in_wmask[i_bit] = |msg_ram_in_wmask_id_rot90[i_bit];
    assign msg_ram_out_wmask_d[i_bit] = |msg_ram_out_wmask_id_rot90[i_bit];
  end : aggregate_wmask

  logic [DataWidth-IDWidth-1:0] msg_ram_out_data;
  metadata_e meta_ram_out_data_tail, meta_ram_out_data_mid;

  metadata_e meta_ram_in_content;
  metadata_e meta_ram_in_content_id[NumIds];
  logic [NumIds - 1:0] meta_ram_in_content_msk_rot90[BankAddrWidth];

  // RAM address and aggregation
  logic [BankAddrWidth-1:0] msg_ram_in_addr;
  logic [BankAddrWidth-1:0] msg_ram_out_addr;
  logic [BankAddrWidth-1:0] meta_ram_in_addr;
  logic [BankAddrWidth-1:0] meta_ram_out_addr_tail;
  logic [BankAddrWidth-1:0] meta_ram_out_addr_mid;
  logic [BankAddrWidth-1:0] msg_ram_in_addr_id[NumIds];
  logic [BankAddrWidth-1:0] msg_ram_out_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_in_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_out_addr_tail_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_out_addr_mid_id[NumIds];
  logic [BankAddrWidth-1:0][NumIds-1:0] msg_ram_in_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] msg_ram_out_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_in_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_out_addr_tail_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_out_addr_mid_rot90;

  // RAM address aggregation
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : rotate_ram_address
    for (
        genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1
    ) begin : rotate_ram_address_inner
      assign msg_ram_in_addr_rot90[i_bit][i_id] = msg_ram_in_addr_id[i_id][i_bit];
      assign msg_ram_out_addr_rot90[i_bit][i_id] = msg_ram_out_addr_id[i_id][i_bit];
      assign meta_ram_in_addr_rot90[i_bit][i_id] = meta_ram_in_addr_id[i_id][i_bit];
      assign meta_ram_out_addr_tail_rot90[i_bit][i_id] = meta_ram_out_addr_tail_id[i_id][i_bit];
      assign meta_ram_out_addr_mid_rot90[i_bit][i_id] = meta_ram_out_addr_mid_id[i_id][i_bit];
    end : rotate_ram_address_inner
  end : rotate_ram_address
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_ram_address
    assign msg_ram_in_addr[i_bit] = |msg_ram_in_addr_rot90[i_bit];
    assign msg_ram_out_addr[i_bit] = |msg_ram_out_addr_rot90[i_bit];
    assign meta_ram_in_addr[i_bit] = |meta_ram_in_addr_rot90[i_bit];
    assign meta_ram_out_addr_tail[i_bit] = |meta_ram_out_addr_tail_rot90[i_bit];
    assign meta_ram_out_addr_mid[i_bit] = |meta_ram_out_addr_mid_rot90[i_bit];
  end : aggregate_ram_address

  // RAM meta in aggregation
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : rotate_meta_in
    for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : rotate_meta_in_inner
      assign meta_ram_in_content_msk_rot90[i_bit][i_id] = meta_ram_in_content_id[i_id][i_bit];
    end : rotate_meta_in_inner
  end : rotate_meta_in
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_meta_in
    assign meta_ram_in_content[i_bit] = |meta_ram_in_content_msk_rot90[i_bit];
  end : aggregate_meta_in

  // RAM write masks, filled with ones
  assign meta_ram_in_wmask = {BankAddrWidth{1'b1}};
  assign meta_ram_out_wmask = {BankAddrWidth{1'b1}};

  // Msg ram wmask extension
  for (genvar i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin : expand_msg_wmasks
    for (
        genvar i_bit = (DataWidth - IDWidth) * i_burst;
        i_bit < (DataWidth - IDWidth) * (i_burst + 1);
        i_bit = i_bit + 1
    ) begin : expand_msg_wmasks_inner
      assign msg_ram_in_wmask_expanded[i_bit] = msg_ram_in_wmask[i_burst];
      assign msg_ram_out_wmask_expanded[i_bit] = msg_ram_out_wmask_d[i_burst];
    end : expand_msg_wmasks_inner
  end : expand_msg_wmasks

  // RAM request signals
  // The message RAM input is triggered iff there is a successful data input handshake
  assign msg_ram_in_req = in_data_ready_o && in_data_valid_i;

  // The message RAM output is triggered iff there is data to output at the next cycle
  assign msg_ram_out_req = |nxt_id_to_release_onehot;

  // Assign the queue_initiated signal, to compute whether the metadata RAM should be requested
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : req_meta_in_id_assignment
    // The queue is called initiated if the reservation is made for this identifier, and the length
    // condition is satisfied, namely if there is at least one reserved cell in the queue or there
    // will be at least one actual stored element in the queue after the possible output.
    assign queue_initiated_id[i_id] =
        rsv_req_id_onehot_i[i_id] && (|rsv_len_q[i_id] || |mid_len_after_out[i_id]);
  end : req_meta_in_id_assignment

  // New metadata input is coming when there is a reservation and the queue is already initiated
  assign meta_ram_in_req = rsv_valid_i && rsv_ready_o && |queue_initiated_id;

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

  // Message RAM input and output data selection
  logic [MaxBurstLen-1:0][DataWidth-IDWidth-1:0] msg_ram_in_data;
  logic [MaxBurstLen-1:0][DataWidth-IDWidth-1:0] msg_ram_out_burst_data;
  logic [DataWidth-IDWidth-1:0][MaxBurstLen-1:0] msg_ram_out_burst_data_rot90;

  // Fill input with the input message. The irrelevant input will be filtered out using the wmasks
  for (genvar i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin : gen_msg_ram_in_data
    assign msg_ram_in_data[i_burst] = data_i.merged_content.content;
  end : gen_msg_ram_in_data

  // Fill input with the input message. The irrelevant input will be filtered out using the wmasks
  for (genvar i_bit = 0; i_bit < DataWidth - IDWidth; i_bit = i_bit + 1) begin : gen_out_data
    for (
        genvar i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1
    ) begin : gen_out_data_inner
      assign msg_ram_out_burst_data_rot90[i_bit][i_burst] =
          msg_ram_out_burst_data[i_burst][i_bit] & msg_ram_out_wmask_q[i_burst];
    end : gen_out_data_inner
    assign msg_ram_out_data[i_bit] = |msg_ram_out_burst_data_rot90[i_bit];
  end : gen_out_data


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
        nxt_addr_mhot_id[i_id][i_addr] = |(mid_len_after_out[i_id]) && release_en_i[i_addr];

        // The address must additionally be, depending on the situation, the previous tail or the
        // tail of the corresponding queue
        if (out_data_ready_i && out_data_valid_o && cur_out_id_onehot[i_id] &&
            prev_tail_cnt_id[i_id] == 1) begin
          nxt_addr_mhot_id[i_id][i_addr] &= tails[i_id] == i_addr;
        end else begin
          nxt_addr_mhot_id[i_id][i_addr] &= prev_tails[i_id] == i_addr;
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

  // Signals indicating if there is reserved space for a given AXI identifier
  logic [NumIds-1:0] is_id_rsvd;
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_is_id_reserved
    assign is_id_rsvd[i_id] = data_i.merged_content.id == i_id & |(rsv_len_q[i_id]);
  end : gen_is_id_reserved

  // Input is ready if there is room and data is not flowing out
  assign in_data_ready_o =
      in_data_valid_i && |is_id_rsvd;  // AXI 4 allows ready to depend on the valid signal
  assign rsv_ready_o = |(~ram_v);


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
    assign mid_len_after_out[i_id] = out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id
        ] && prev_tail_cnt_id[i_id] == 1 ? mid_len_q[i_id] - 1 : mid_len_q[i_id];
  end : gen_len_after_output

  // Recall if the current output is valid
  assign cur_out_valid_d = |nxt_id_to_release_onehot;

  assign cur_out_id_bin_d = nxt_id_to_release_bin;
  assign out_data_valid_o = |cur_out_valid_q;
  assign data_o.merged_content.id = cur_out_id_bin_q;
  assign data_o.merged_content.content = msg_ram_out_data;

  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      mid_len_d[i_id] = mid_len_q[i_id];
      rsv_len_d[i_id] = rsv_len_q[i_id];
      is_middle_emptybox_d[i_id] = is_middle_emptybox_q[i_id];

      update_t_from_ram_d[i_id] = 1'b0;
      update_m_from_ram_d[i_id] = 1'b0;
      update_heads[i_id] = 1'b0;
      update_pt_from_t[i_id] = 1'b0;

      pgbk_m_with_h[i_id] = 1'b0;
      pgbk_pt_with_h[i_id] = 1'b0;
      pgbk_pt_with_m_d[i_id] = 1'b0;
      pgbk_t_w_h[i_id] = 1'b0;
      pgbk_t_with_m_d[i_id] = 1'b0;

      msg_ram_in_addr_id[i_id] = '0;
      msg_ram_out_addr_id[i_id] = '0;
      msg_ram_in_wmask_id[i_id] = '0;
      msg_ram_out_wmask_id[i_id] = '0;
      meta_ram_in_addr_id[i_id] = '0;
      meta_ram_out_addr_tail_id[i_id] = '0;
      meta_ram_out_addr_mid_id[i_id] = '0;

      meta_ram_in_content_id[i_id] = '0;

      // Handshakes
      if (nxt_id_to_release_onehot[i_id]) begin : out_preparation_handshake
        // The tail points not to the current output to provide, but to the next.
        // Give the right output according to the output handshake
        if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id] &&
            prev_tail_cnt_id[i_id] == 1) begin
          msg_ram_out_addr_id[i_id] = tails[i_id];

          // Set the message RAM output wmask
          for (int unsigned i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin
            msg_ram_out_wmask_id[i_id][i_burst] = tail_cnt_id[i_id] ==
                MaxBurstLen[MaxBurstLenWidth - 1:0] - i_burst[MaxBurstLenWidth - 1:0];
          end
        end else begin
          msg_ram_out_addr_id[i_id] = prev_tails[i_id];

          // Set the message RAM output wmask depending on the number of messages remaining in the
          // read data burst pointed by the previous tail
          if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin
            for (int unsigned i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin
              msg_ram_out_wmask_id[i_id][i_burst] = prev_tail_cnt_id[i_id] ==
                  MaxBurstLen[MaxBurstLenWidth - 1:0] - i_burst[MaxBurstLenWidth - 1:0] + 1;
            end
          end else begin
            for (int unsigned i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin
              msg_ram_out_wmask_id[i_id][i_burst] = prev_tail_cnt_id[i_id] ==
                  MaxBurstLen[MaxBurstLenWidth - 1:0] - i_burst[MaxBurstLenWidth - 1:0];
            end
          end
        end
      end

      // Input handshake
      if (in_data_ready_o && in_data_valid_i && data_i.merged_content.id == i_id
          ) begin : in_handshake

        // If this is the last data of the burst, then update the pointers
        if (rsv_cnt_id[i_id] == 1) begin

          mid_len_d[i_id] = mid_len_d[i_id] + 1;
          rsv_len_d[i_id] = rsv_len_d[i_id] - 1;

          if (mids[i_id] == heads_q[i_id]) begin
            pgbk_m_with_h[i_id] = 1'b1;
            // Fullbox if could not move forward
            is_middle_emptybox_d[i_id] = heads_d[i_id] != heads_q[i_id];
          end else begin
            // If the reservation head is ahead of the middle pointer, then one can follow the
            // pointer from the metadata RAM
            update_m_from_ram_d[i_id] = 1'b1;
          end

          // Manage more piggybacking on input acquisition
          if (tails[i_id] == mids[i_id]) begin
            if (mid_len_after_out[i_id] == 0) begin
              pgbk_t_with_m_d[i_id] = 1'b1;
              if (!is_middle_emptybox_q[i_id]) begin
                pgbk_pt_with_m_d[i_id] = 1'b1;
              end
            end else if (mid_len_after_out[i_id] == 1 && prev_tails[i_id] == tails[i_id]) begin
              pgbk_t_with_m_d[i_id] = 1'b1;
            end
          end
        end

        // Store the data
        msg_ram_in_addr_id[i_id] = mids[i_id];

        // Set the message RAM input wmask
        for (int unsigned i_burst = 0; i_burst < MaxBurstLen; i_burst = i_burst + 1) begin
          msg_ram_in_wmask_id[i_id][i_burst] = mid_cnt_id[i_id] == i_burst[MaxBurstLenWidth - 1:0];
        end

        // Update the middle pointer position
        meta_ram_out_addr_mid_id[i_id] = mids[i_id];
      end

      if (rsv_valid_i && rsv_ready_o && rsv_req_id_onehot_i[i_id]) begin : reservation_handshake

        rsv_len_d[i_id] = rsv_len_d[i_id] + 1;
        update_heads[i_id] = 1'b1;

        // If the queue is already initiated, then update the head position in the RAM and manage
        // the piggybacking properly
        if (|rsv_len_q[i_id] || |mid_len_after_out[i_id]) begin : reservation_initiated_queue
          meta_ram_in_addr_id[i_id] = heads_q[i_id];
          meta_ram_in_content_id[i_id].nxt_elem = nxt_free_addr;

          if (heads_q[i_id] == mids[i_id]) begin
            if (rsv_len_q[i_id] == 0) begin
              if (mid_len_after_out[i_id] == 0) begin
                pgbk_m_with_h[i_id] = 1'b1;
                pgbk_pt_with_h[i_id] = 1'b1;
                pgbk_t_w_h[i_id] = 1'b1;
                is_middle_emptybox_d[i_id] = 1'b1;
              end else if (mid_len_after_out[i_id] == 1) begin
                pgbk_m_with_h[i_id] = 1'b1;
                pgbk_t_w_h[i_id] = 1'b1;
                is_middle_emptybox_d[i_id] = 1'b1;
              end else begin
                pgbk_m_with_h[i_id] = 1'b1;
                is_middle_emptybox_d[i_id] = 1'b1;
              end
            end
          end
        end else begin
          // Else, piggyback everything as a new queue is created from scratch, with no memoryof
          // the past
          pgbk_m_with_h[i_id] = 1'b1;
          pgbk_pt_with_h[i_id] = 1'b1;
          pgbk_t_w_h[i_id] = 1'b1;
          is_middle_emptybox_d[i_id] = 1'b1;
        end
      end : reservation_handshake

      if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin : ouptut_handshake

        // If this is the last burst, then update the pointers
        if (prev_tail_cnt_id[i_id] == 1) begin

          mid_len_d[i_id] = mid_len_d[i_id] - 1;
          update_pt_from_t[i_id] = 1'b1;  // Update the previous tail
          if (mids[i_id] != tails[i_id]) begin
            // If possible, read the next tail address from RAM
            update_t_from_ram_d[i_id] = 1'b1;
            meta_ram_out_addr_tail_id[i_id] = tails[i_id];
          end else begin
            // Else, piggyback
            pgbk_t_with_m_d[i_id] = 1'b1;
          end
        end
      end : ouptut_handshake
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mids_q <= '{default: '0};
      heads_q <= '{default: '0};
      prev_tails_q <= '{default: '0};
      tails_q <= '{default: '0};
      mid_len_q <= '{default: '0};
      rsv_len_q <= '{default: '0};

      rsv_cnt_q <= '{default: '0};
      msg_cnt_q <= '{default: '0};

      update_t_from_ram_q <= '{default: '0};
      update_m_from_ram_q <= '{default: '0};
      msg_ram_out_wmask_q <= '{default: '0};

      is_middle_emptybox_q <= '{default: '1};
      pgbk_pt_with_m_q <= '{default: '0};
      pgbk_t_with_m_q <= '{default: '0};
    end else begin
      mids_q <= mids_d;
      heads_q <= heads_d;
      prev_tails_q <= prev_tails_d;
      tails_q <= tails_d;
      mid_len_q <= mid_len_d;
      rsv_len_q <= rsv_len_d;

      rsv_cnt_q <= rsv_cnt_d;
      msg_cnt_q <= msg_cnt_d;

      update_t_from_ram_q <= update_t_from_ram_d;
      update_m_from_ram_q <= update_m_from_ram_d;
      msg_ram_out_wmask_q <= msg_ram_out_wmask_d;

      is_middle_emptybox_q <= is_middle_emptybox_d;
      pgbk_pt_with_m_q <= pgbk_pt_with_m_d;
      pgbk_t_with_m_q <= pgbk_t_with_m_d;
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

  // Message RAM instance
  prim_generic_ram_2p #(
    .Width(MsgRamWidth),
    .DataBitsPerMask(DataWidth - IDWidth),
    .Depth(TotCapa)
  ) i_msg_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (msg_ram_in_req),
    .a_write_i   (msg_ram_in_write),
    .a_wmask_i   (msg_ram_in_wmask_expanded),
    .a_addr_i    (msg_ram_in_addr),
    .a_wdata_i   (msg_ram_in_data),
    .a_rdata_o   (),
    
    .b_req_i     (msg_ram_out_req),
    .b_write_i   (msg_ram_out_write),
    .b_wmask_i   (msg_ram_out_wmask_expanded),
    .b_addr_i    (msg_ram_out_addr),
    .b_wdata_i   (),
    .b_rdata_o   (msg_ram_out_burst_data)
  );

  // Metadata RAM instance
  prim_generic_ram_2p #(
    .Width(BankAddrWidth),
    .DataBitsPerMask(1),
    .Depth(TotCapa)
  ) i_meta_ram_out_tail (
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
    .b_addr_i    (meta_ram_out_addr_tail),
    .b_wdata_i   (),
    .b_rdata_o   (meta_ram_out_data_tail)
  );

  // Metadata RAM instance
  prim_generic_ram_2p #(
  .Width(BankAddrWidth),
  .DataBitsPerMask(1),
  .Depth(TotCapa)
) i_meta_ram_out_mid (
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
  .b_addr_i    (meta_ram_out_addr_mid),
  .b_wdata_i   (),
  .b_rdata_o   (meta_ram_out_data_mid)
);


endmodule
