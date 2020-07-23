// Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0, see LICENSE for
// details. SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

// Response banks provide a FIFO storage with reservation functionality for response messages coming
// from the real memory controller. The FIFOs are implemented as linked lists, sharing the same
// memory space.
//
// Response structure: The terms 'response' is used to refer to the
//  AXI response coming back from the real memory controller, excluding handshake signals. Each
//  response is made of an AXI identifier of a specific length IDWidth (on the LSB side). The rest of
//  the response bits is referred to as 'payload'. As there is one linked list per AXI identifier,
//  only the payload is stored in RAM.
//
// A response bank uses three RAMs:
//  * The payload RAM, containing the response response payloads.
//  * The metadata RAM, containing pointers that form the concurrent linkedlists (there is one
//    linkedlist per AXI identifier). The metadata RAM is duplicated to make concurrent input and
//    output possible.
//
// Linked list implementation: Each linked list is supported by four pointers, which, outside of
//   corner cases, can be described as follows:
//   * Reservation head (rsv_heads_q):  Points to the last reserved address.
//   * Response head (rsp_heads):        Points to the next RAM address where a payload of the
//     corresponding AXI identifier will be stored.
//   * Tail (tails): Points to the next RAM address to release to the requester,
//     when there is no current output handshake implying this specific AXI identifier.
//   * Pre_tail (pre_tails): Points to the next RAM address to release to the requester,
//     when there is a current output handshake implying this specific AXI identifier.
//
// Reservation flow: When the reservation handshake succeeds, a new RAM cell is reserved and the
//  corresponding address is advertised, as it is externally used as a request/response identifier.
//  The reservation head pointer of the corresponding head is moved to the next free RAM entry, and
//  the corresponding linkedlist pointer is written into the metadata RAM.
//
// Response input flow: When the input handshake succeeds, the RAM cell pointed by the response head
//  of the corresponding AXI identifier stores the response payload. The response head pointer follows
//  the pointer in the metadata RAM (except for some corner cases).
//
// Response output flow: When the output handshake succeeds, the RAM output is transmitted to the
//  requester. The pre_tail pointer follows the pointer in the metadata RAM and the tail takes
//  the value of the pre_tail (except for some corner cases)
//
// Tail vs. pre_tail: The two distinct tail pointers are required to dynamically manage the two
//  following cases:
//    * The pre_tail address is given as input to the payload RAM if there is a successful
//      output handshake and the value at the output has an AXI id corresponding to the AXI id of
//      the considered linked list.
//    * The tail address is given as input to the payload RAM in all other cases. This case
//      disjunction prevents an output data from being output twice, and prevents any bandwidth drop
//      at the output.
//
//  Corner cases and vector piggybacking: Several corner cases appear when linked list pointers
//    cannot be updated in the regular way. In this case, a process called pointer piggybacking is
//    implemented. For two pointers a and b, the signal 'pgbk_a_with_b' or 'pgbk_a_with_b_q' means,
//    at level 1'b1, that if the pointer b is updated during the current clock cycle, then the
//    pointer a must be updated with the same value.

module simmem_resp_bank (
  input logic clk_i,
  input logic rst_ni,

  // Interface with the reservation manager

  // Identifier for which the reseration request is being done
  input  logic [NumIds-1:0] rsv_req_id_onehot_i,
  output logic [BankAddrWidth-1:0] rsv_addr_o, // Reserved address
  // Reservation handshake signals
  input  logic rsv_valid_i,
  output logic rsv_ready_o, 

  // Interface with the releaser
  input  logic [TotCapa-1:0] release_en_i,  // Multi-hot signal
  output logic [TotCapa-1:0] released_addr_onehot_o,

  // Interface with the real memory controller
  input  simmem_pkg::wresp_t data_i, // AXI response excluding handshake
  output simmem_pkg::wresp_t data_o, // AXI response excluding handshake
  input  logic in_data_valid_i,
  output logic in_data_ready_o,

  // Interface with the requester
  input  logic out_data_ready_i,
  output logic out_data_valid_o
);

  import simmem_pkg::*;

  localparam TotCapa = WriteRespBankTotalCapacity;
  localparam BankAddrWidth = WriteRespBankAddrWidth;

  localparam MsgRamWidth = $bits(wresp_t) - IDWidth;

  typedef struct packed {logic [BankAddrWidth-1:0] nxt_elem;} metadata_e;

  //////////////////
  // RAM pointers //
  //////////////////

  //  In this part, the linkedlist related pointers are declared and updated.
  //
  //  Response heads: 
  //    * rsp_heads_d, rsp_heads_q: Next response head, except if the response head will be updated
  //      from RAM.
  //    * rsp_heads: The actual response head, after potential update from RAM.
  //
  //  Reservation heads:
  //    * rsv_heads_d: Next reservation head.
  //    * rsv_heads_q: The actual reservation head.
  //
  //  Tails:
  //    * tails_d, tails_q: Next tail, except that it does not take piggyback
  //      with the response head pointer into account.
  //    * tails: The actual tail.
  //
  //  Pre_tails:
  //    * pre_tails_d, pre_tails_q: Next pre_tail, except that it does not take piggyback with the
  //      response head pointer into account.
  //    * pre_tails: The actual tail.
  //
  //  Linked list lengths: Linked list lengths are maintained, as they help treat corner cases where
  //  lined list pointers are close to each other in the linked list:
  //    * rsv_len_d, rsv_len_q:       The number of entries reserved in the linked list, that are
  //      not occupied by messages yet.
  //    * rsp_len_d, rsp_len_q: The number of RAM cells in the linked list that contain
  //      messagees.
  //    * rsp_len_after_out:       The number of RAM cells in the linked list that contain
  //      messagees, minus one if one of the cells is currently being output.
  //
  //  Miscellaneous signals: Some additional signals are required to smoothly treat corner cases.
  //    * queue_initiated: The linked list is called initiated if the reservation is made for this
  //      identifier, and if there is at least one reserved cell in the queue or there will be at
  //      least one actual stored element in the queue after the possible output.
  //    * is_rsp_head_emptybox_d, is_rsp_head_emptybox_q: The response head pointer is said to point to an
  //      empty box if it has the same value as the reservation head, but the targeted RAM cell does
  //      not contain any response yet.

  // Head, tail and length signals

  // rsp_heads are the pointers to the next address where the next input of the corresponding AXI
  // identifier will be allocated
  logic [BankAddrWidth-1:0] rsp_heads_d[NumIds];
  logic [BankAddrWidth-1:0] rsp_heads_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] rsp_heads[NumIds];  // Effective response, after update from RAM

  // rsv_heads are the pointers to the last reserved address
  logic [BankAddrWidth-1:0] rsv_heads_d[NumIds];
  logic [BankAddrWidth-1:0] rsv_heads_q[NumIds];

  // Tails are the pointers to the next addresses to release
  logic [BankAddrWidth-1:0] tails_d[NumIds];
  logic [BankAddrWidth-1:0] tails_q[NumIds];  // Before piggyback with response
  logic [BankAddrWidth-1:0] tails[NumIds];  // Effective pointer, after piggyback with response

  // Tails are the pointers to the next next addresses to release. They are used when two successive
  // releases are made on the same AXI identifier, and only in this case
  logic [BankAddrWidth-1:0] pre_tails_d[NumIds];
  logic [BankAddrWidth-1:0] pre_tails_q[NumIds];  // Before update from RAM
  logic [BankAddrWidth-1:0] pre_tails[NumIds];

  // Piggyback signals translate that if the piggybacker gets updated in the next cycle, then follow
  // it. They serve the many corner cases where regular update from the RAM or from the current
  // value of the pointer ahead (in the case of the pre_tails) is not possible
  logic pgbk_rsp_with_rsv[NumIds];  // Piggyback response with reservation
  logic pgbk_t_with_rsv[NumIds];  // Piggyback tail with reservation
  logic pgbk_pt_with_rsv[NumIds];  // Piggyback pre_tail with reservation
  logic pgbk_t_with_rsp_d[NumIds];  // Piggyback tail with response
  logic pgbk_t_with_rsp_q[NumIds];
  logic pgbk_pt_with_rsp_d[NumIds];  // Piggyback tail with response
  logic pgbk_pt_with_rsp_q[NumIds];

  logic update_t_from_pt[NumIds];  // Update tail from tail
  logic update_t_from_ram_q[NumIds];
  logic update_t_from_ram_d[NumIds];  // Update tail from RAM
  logic update_m_from_ram_d[NumIds];  // Update response from RAM
  logic update_m_from_ram_q[NumIds];

  logic update_rsv_heads[NumIds];

  // Determines, for each AXI identifier, whether the queue already exists in RAM. If the queue does
  // not exist in RAM, all the pointers should be piggybacked with the head.
  logic [NumIds-1:0] queue_initiated;

  logic is_rsp_head_emptybox_d[NumIds];
  logic is_rsp_head_emptybox_q[NumIds];

  // Lengths of reservation and effective lengths
  logic [BankAddrWidth-1:0] rsv_len_d[NumIds];
  logic [BankAddrWidth-1:0] rsv_len_q[NumIds];

  logic [BankAddrWidth-1:0] rsp_len_d[NumIds];
  logic [BankAddrWidth-1:0] rsp_len_q[NumIds];
  // Length after the potential output
  logic [BankAddrWidth-1:0] rsp_len_after_out[NumIds];

  // Update heads, rsp_heads and pre_tails according to the piggyback and update signals
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : pointers_update
    assign rsp_heads_d[i_id] = pgbk_rsp_with_rsv[i_id] ? rsv_heads_d[i_id] : rsp_heads[i_id];
    assign rsp_heads[i_id] =
        update_m_from_ram_q[i_id] ? meta_ram_out_data_mid.nxt_elem : rsp_heads_q[i_id];

    always_comb begin : prev_tail_d_assignment
      // The next tail is either piggybacked with the head, or follows the pre_tail, or keeps
      // its value. If it is piggybacked by the response head pointer, the update is done in the next cycle
      if (pgbk_t_with_rsv[i_id]) begin
        tails_d[i_id] = nxt_free_addr;
      end else if (update_t_from_pt[i_id]) begin
        tails_d[i_id] = pre_tails[i_id];
      end else begin
        tails_d[i_id] = tails[i_id];
      end
    end : prev_tail_d_assignment
    assign tails[i_id] = pgbk_t_with_rsp_q[i_id] ? rsp_heads[i_id] : tails_q[i_id];

    assign pre_tails_d[i_id] = pgbk_pt_with_rsv[i_id] ? rsv_heads_d[i_id] : pre_tails[i_id];
    always_comb begin : tail_assignment
      if (pgbk_pt_with_rsp_q[i_id]) begin
        pre_tails[i_id] = rsp_heads[i_id];
      end else if (update_t_from_ram_q[i_id]) begin
        pre_tails[i_id] = meta_ram_out_data_tail.nxt_elem;
      end else begin
        pre_tails[i_id] = pre_tails_q[i_id];
      end
    end : tail_assignment

    assign rsv_heads_d[i_id] = update_rsv_heads[i_id] ? nxt_free_addr : rsv_heads_q[i_id];
  end


  ///////////////
  // RAM valid //
  ///////////////

  //  In this part, the RAM valid bits are declared and updated. A RAM cell is set to valid when it
  //  is reserved. The valid bit is reset to zero when the cell is output to the requester (after
  //  having hosted a response after the reservation).
  //
  //  RAM valid bits are updated using two XOR masks:
  //  * ram_v_rsv_mask: contains at most one bit to one, where a new reservation is performed.
  //  * ram_v_out_mask: contains at most one bit to one, where a RAM cell is becoming free.

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic [TotCapa-1:0] ram_v_d;
  logic [TotCapa-1:0] ram_v_q;
  logic [TotCapa-1:0] ram_v_rsv_mask;
  logic [TotCapa-1:0] ram_v_out_mask;

  // Prepare the next RAM valid bit array
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : ram_v_update

    // Generate the ram valid masks
    assign ram_v_rsv_mask[i_addr] = nxt_free_addr == i_addr && rsv_ready_o && rsv_valid_i;
    assign ram_v_out_mask[i_addr] =
        cur_out_addr_onehot_q[i_addr] && out_data_valid_o && out_data_ready_i;

    always_comb begin
      ram_v_d[i_addr] = ram_v_q[i_addr];
      // Mark the newly reserved addressed as valid, if applicable
      ram_v_d[i_addr] ^= ram_v_rsv_mask[i_addr];
      // Mark the newly released addressed as invalid, if applicable
      ram_v_d[i_addr] ^= ram_v_out_mask[i_addr];
    end
  end
  assign released_addr_onehot_o = ram_v_out_mask;


  /////////////////////////
  // Next free RAM entry //
  /////////////////////////

  //  In this part, the free RAM entry of lowest address is found. It is used to update the
  //  reservation head in casae of reservation handshake.
  //
  //  Two signals are used:
  //  * nxt_free_addr_onehot: A one-hot signal indicating the next free entry in the RAM. Can be
  //    full-zero if no entry is free in the RAM.
  //  * nxt_free_addr: The corresponding binary signal.

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

  assign rsv_addr_o = nxt_free_addr;


  ////////////////////////////
  // RAM management signals //
  ////////////////////////////

  //  In this part, RAM management signals are declared and treated.
  //
  //  RAM usage patterns:a) On reservation handshake, write to metadata RAMs. b) On input
  //    handshake, read from response head metadata RAM and write to payload RAM. c) On output
  //    handshake, read from tail metadata RAM and read from payload RAM.
  //
  //  Some signals are set globally, and others are aggregated from all linkedlists. The latter are:
  //    * payload_ram_in_addr_id,         as the address should be the response head pointer value.
  //    * payload_ram_out_addr_id,        as the address should be the pre_tail or tail pointer
  //      value.
  //    * meta_ram_in_addr_id,        as the address may be the reservation head pointer value.
  //    * meta_ram_out_addr_tail_id,  as the address should be the tail pointer value.
  //    * meta_ram_out_addr_rsp_id,   as the address should be the response head pointer value.
  //
  //  Rotated signals are used to aggregate the signals, where the dimensions have to be
  //      transposed.

  logic payload_ram_in_req, payload_ram_out_req;
  logic meta_ram_in_req, meta_ram_out_req;

  logic payload_ram_in_write, payload_ram_out_write;
  logic meta_ram_in_write, meta_ram_out_write;

  logic [MsgRamWidth-1:0] payload_ram_in_wmask, payload_ram_out_wmask;
  logic [BankAddrWidth-1:0] meta_ram_in_wmask, meta_ram_out_wmask;

  logic [MsgRamWidth-1:0] rsp_out_ram_data;
  metadata_e meta_ram_out_data_tail, meta_ram_out_data_mid;

  metadata_e meta_ram_in_content;
  metadata_e meta_ram_in_content_id[NumIds];
  logic [NumIds - 1:0] meta_ram_in_content_msk_rot90[BankAddrWidth];

  // RAM address and aggregation response
  logic [BankAddrWidth-1:0] payload_ram_in_addr;
  logic [BankAddrWidth-1:0] payload_ram_out_addr;
  logic [BankAddrWidth-1:0] meta_ram_in_addr;
  logic [BankAddrWidth-1:0] meta_ram_out_addr_tail;
  logic [BankAddrWidth-1:0] meta_ram_out_addr_mid;
  logic [BankAddrWidth-1:0] payload_ram_in_addr_id[NumIds];
  logic [BankAddrWidth-1:0] payload_ram_out_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_in_addr_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_out_addr_tail_id[NumIds];
  logic [BankAddrWidth-1:0] meta_ram_out_addr_rsp_id[NumIds];
  logic [BankAddrWidth-1:0][NumIds-1:0] payload_ram_in_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] payload_ram_out_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_in_addr_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_out_addr_tail_rot90;
  logic [BankAddrWidth-1:0][NumIds-1:0] meta_ram_out_addr_mid_rot90;

  // RAM address aggregation
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : rotate_ram_address
    for (
        genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1
    ) begin : rotate_ram_address_inner
      assign payload_ram_in_addr_rot90[i_bit][i_id] = payload_ram_in_addr_id[i_id][i_bit];
      assign payload_ram_out_addr_rot90[i_bit][i_id] = payload_ram_out_addr_id[i_id][i_bit];
      assign meta_ram_in_addr_rot90[i_bit][i_id] = meta_ram_in_addr_id[i_id][i_bit];
      assign meta_ram_out_addr_tail_rot90[i_bit][i_id] = meta_ram_out_addr_tail_id[i_id][i_bit];
      assign meta_ram_out_addr_mid_rot90[i_bit][i_id] = meta_ram_out_addr_rsp_id[i_id][i_bit];
    end : rotate_ram_address_inner
  end : rotate_ram_address
  for (genvar i_bit = 0; i_bit < BankAddrWidth; i_bit = i_bit + 1) begin : aggregate_ram_address
    assign payload_ram_in_addr[i_bit] = |payload_ram_in_addr_rot90[i_bit];
    assign payload_ram_out_addr[i_bit] = |payload_ram_out_addr_rot90[i_bit];
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
  assign payload_ram_in_wmask = {MsgRamWidth{1'b1}};
  assign payload_ram_out_wmask = {MsgRamWidth{1'b1}};
  assign meta_ram_in_wmask = {BankAddrWidth{1'b1}};
  assign meta_ram_out_wmask = {BankAddrWidth{1'b1}};

  // RAM request signals The payload RAM input is triggered iff there is a successful data input
  // handshake
  assign payload_ram_in_req = in_data_ready_o && in_data_valid_i;

  // The payload RAM output is triggered iff there is data to output at the next cycle
  assign payload_ram_out_req = |nxt_id_to_release_onehot;

  // Assign the queue_initiated signal, to compute whether the metadata RAM should be requested
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : req_meta_in_id_assignment
    // The queue is called initiated if the reservation is made for this identifier, and the length
    // condition is satisfied, namely if there is at least one reserved cell in the queue or there
    // will be at least one actual stored element in the queue after the possible output.
    assign queue_initiated[i_id] =
        rsv_req_id_onehot_i[i_id] && (|rsv_len_q[i_id] || |rsp_len_after_out[i_id]);
  end : req_meta_in_id_assignment

  // New metadata input is coming when there is a reservation and the queue is already initiated
  assign meta_ram_in_req = rsv_valid_i && rsv_ready_o && |queue_initiated;

  // Metadata output is requested when there is output to be released (to potentially update the
  // corresponding pre_tails from RAM) or input data coming (to potentially update the corresponding
  // response head pointer from RAM). This signal could be more fine-grained by excluding cases where the
  // output from RAM will not be taken into account.
  assign meta_ram_out_req = 1;

  assign payload_ram_in_write = 1'b1;
  assign payload_ram_out_write = 1'b0;
  assign meta_ram_in_write = 1'b1;
  assign meta_ram_out_write = 1'b0;


  ////////////////////////////////////
  // Next AXI identifier to release //
  ////////////////////////////////////

  //  In this part, the next AXI identifier and address to release is computed.
  //
  //  Involved signals are, in order of dependency:
  //    * nxt_addr_mhot_id:   Next addresses to release, multihot and by AXI identifier. Depend on
  //      the input from delay bank and from the response length after output.
  //    * nxt_addr_1hot_id:   Next address to release, onehot and by AXI identifier.
  //    * nxt_id_mhot:   Next address to release, multihot.
  //    * nxt_id_mhot:   Result signal, indicating in a one-hot fashion, which AXI identifier to
  //      release next. Can be full zero.
  //    * nxt_addr_1hot_rot:  Next address to release, one-hot, rotated and filtered by next id to
  //      release. Useful for output calculation below.

  logic [NumIds-1:0][TotCapa-1:0] nxt_addr_mhot_id;
  logic [TotCapa-1:0][NumIds-1:0] nxt_addr_1hot_rot;
  logic [TotCapa-1:0] nxt_addr_1hot_id[NumIds];
  // Next address to release, multihot
  logic [NumIds-1:0] nxt_id_mhot;
  //
  logic [NumIds-1:0] nxt_id_to_release_onehot;

  // Next id and address to release from RAM
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_next_id

    // Calculation of the next address to release
    for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_next_addr
      always_comb begin : nxt_addr_mhot_assignment
        // Fundamentally, the next address to release needs to belong to a non-empty AXI identifier
        // and must be enabled for release
        nxt_addr_mhot_id[i_id][i_addr] = |(rsp_len_after_out[i_id]) && release_en_i[i_addr];

        // The address must additionally be, depending on the situation, the pre_tail or the
        // tail of the corresponding queue
        if (out_data_ready_i && out_data_valid_o && cur_out_id_onehot[i_id]) begin
          nxt_addr_mhot_id[i_id][i_addr] &= pre_tails[i_id] == i_addr;
        end else begin
          nxt_addr_mhot_id[i_id][i_addr] &= tails[i_id] == i_addr;
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

  // Signals indicating if there is reserved space for a given AXI identifier
  logic [NumIds-1:0] is_id_rsvd;
  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : gen_is_id_reserved
    assign is_id_rsvd[i_id] = data_i.merged_payload.id == i_id && |(rsv_len_q[i_id]);
  end : gen_is_id_reserved

  // Input is ready if there is room and data is not flowing out
  assign in_data_ready_o =
      in_data_valid_i && |is_id_rsvd;  // AXI 4 allows ready to depend on the valid signal
  assign rsv_ready_o = |(~ram_v_q);


  /////////////
  // Outputs //
  /////////////

  //  In this part, the output signals are declared and set.
  //
  //  Involved signals are:
  //    * cur_out_id_bin_d, cur_out_id_bin_q, cur_out_id_onehot: Stores which AXI identifier is
  //      currently at the output.
  //    * cur_out_valid_d, cur_out_valid_q: Expresses whether the output is valid.
  //    * cur_out_addr_onehot_d, cur_out_addr_onehot_q: Stores which RAM address is currently at the
  //      output.

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

  // Store the next address to be released
  for (genvar i_addr = 0; i_addr < TotCapa; i_addr = i_addr + 1) begin : gen_next_addr_out
    assign cur_out_addr_onehot_d[i_addr] = |nxt_addr_1hot_rot[i_addr];
  end : gen_next_addr_out

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
    assign rsp_len_after_out[i_id] = out_data_valid_o && out_data_ready_i &&
        cur_out_id_onehot[i_id] ? rsp_len_q[i_id] - 1 : rsp_len_q[i_id];
  end : gen_len_after_output

  // Recall if the current output is valid
  assign cur_out_valid_d = |nxt_id_to_release_onehot;

  assign cur_out_id_bin_d = nxt_id_to_release_bin;
  assign out_data_valid_o = |cur_out_valid_q;
  assign data_o.merged_payload.id = cur_out_id_bin_q;
  assign data_o.merged_payload.payload = rsp_out_ram_data;


  ////////////////
  // Handshakes //
  ////////////////

  //  In this part, four sub-parts are treated: a) Output preparation: if the considered AXI
  //    identifier is the next AXI identifier to release, then: * Assign the payload RAM output to
  //    the pre_tail or the tail pointer. b) Input handshake: if the considered AXI identifier
  //    is the next AXI identifier to release, then: * Update the linked list lengths. * Update the
  //    pointers, including corner cases. * Assign the payload RAM input address. * Assign the
  //    corresponding metadata RAM output address. c) Reservation handshake: if the considered AXI
  //    identifier is the next AXI identifier to release, then: * Update the linked list lengths. *
  //    Update the pointers in some corner cases. * Assign both metadata RAMs input addresses. d)
  //    Output handshake: if the considered AXI identifier is the next AXI identifier to release,
  //    then: * Update the linked list lengths. * Update the pointers, including corner cases. *
  //    Assign the corresponding metadata RAM output address.

  for (genvar i_id = 0; i_id < NumIds; i_id = i_id + 1) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      rsp_len_d[i_id] = rsp_len_q[i_id];
      rsv_len_d[i_id] = rsv_len_q[i_id];
      is_rsp_head_emptybox_d[i_id] = is_rsp_head_emptybox_q[i_id];

      update_t_from_ram_d[i_id] = 1'b0;
      update_m_from_ram_d[i_id] = 1'b0;
      update_rsv_heads[i_id] = 1'b0;
      update_t_from_pt[i_id] = 1'b0;

      pgbk_rsp_with_rsv[i_id] = 1'b0;
      pgbk_t_with_rsv[i_id] = 1'b0;
      pgbk_t_with_rsp_d[i_id] = 1'b0;
      pgbk_pt_with_rsv[i_id] = 1'b0;
      pgbk_pt_with_rsp_d[i_id] = 1'b0;

      payload_ram_in_addr_id[i_id] = '0;
      payload_ram_out_addr_id[i_id] = '0;
      meta_ram_in_addr_id[i_id] = '0;
      meta_ram_out_addr_tail_id[i_id] = '0;
      meta_ram_out_addr_rsp_id[i_id] = '0;

      meta_ram_in_content_id[i_id] = '0;

      // Output preparation
      if (nxt_id_to_release_onehot[i_id]) begin : out_preparation_handshake
        // The pre_tail points not to the current output to provide, but to the next. Give the right
        // output according to the output handshake
        if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin
          payload_ram_out_addr_id[i_id] = pre_tails[i_id];
        end else begin
          payload_ram_out_addr_id[i_id] = tails[i_id];
        end
      end

      // Input handshake
      if (in_data_ready_o && in_data_valid_i && data_i.merged_payload.id == i_id
          ) begin : in_handshake

        rsp_len_d[i_id] = rsp_len_d[i_id] + 1;
        rsv_len_d[i_id] = rsv_len_d[i_id] - 1;

        // If the reservation head is ahead of the response head pointer, then it can follow the pointer
        // from the metadata RAM. Else, the only way to potentially keep it up to date is to
        // piggyback it with the reservation head pointer.
        if (rsp_heads[i_id] != rsv_heads_q[i_id]) begin
          update_m_from_ram_d[i_id] = 1'b1;
        end else begin
          pgbk_rsp_with_rsv[i_id] = 1'b1;
          // Fullbox if could not move forward
          is_rsp_head_emptybox_d[i_id] = rsv_heads_d[i_id] != rsv_heads_q[i_id];
        end

        // In the case where the pre_tail has the same value as the response head, then if the queue
        // will be empty of responses in the next clock cycle, then piggyback the pre_tail with the
        // response head. If additionally the response head is an empty box, then all the pointers
        // will be piggybacked (therefore, piggyback the tail in particular).
        if (pre_tails[i_id] == rsp_heads[i_id]) begin
          if (rsp_len_after_out[i_id] == 0) begin
            pgbk_pt_with_rsp_d[i_id] = 1'b1;
            if (!is_rsp_head_emptybox_q[i_id]) begin
              pgbk_t_with_rsp_d[i_id] = 1'b1;
            end
          end else if (rsp_len_after_out[i_id] == 1 && tails[i_id] == pre_tails[i_id]) begin
            pgbk_pt_with_rsp_d[i_id] = 1'b1;
          end
        end

        // Store the data
        payload_ram_in_addr_id[i_id] = rsp_heads[i_id];

        // Update the response head pointer position
        meta_ram_out_addr_rsp_id[i_id] = rsp_heads[i_id];
      end

      // Reservation handshake
      if (rsv_valid_i && rsv_ready_o && rsv_req_id_onehot_i[i_id]) begin : reservation_handshake

        rsv_len_d[i_id] = rsv_len_d[i_id] + 1;
        update_rsv_heads[i_id] = 1'b1;

        // If the queue is already initiated, then update the head position in the RAM and manage
        // the piggybacking properly
        if (|rsv_len_q[i_id] || |rsp_len_after_out[i_id]) begin : reservation_initiated_queue
          meta_ram_in_addr_id[i_id] = rsv_heads_q[i_id];
          meta_ram_in_content_id[i_id].nxt_elem = nxt_free_addr;

          // Specific cases may happen when the response head and reservation head point to the same
          // address, in the case where the reservation length was zero (in the opposite case, i.e.,
          // if the reservation length were 1, then the response head would already, simply point to the next
          // inoccupied reserved address, which is completely regular).
          if (rsv_heads_q[i_id] == rsp_heads[i_id]) begin
            if (rsv_len_q[i_id] == 0) begin
              // Piggyback the response head with the reservation head, as it is supposed to point
              // to the next inoccupied reserved address.
              pgbk_rsp_with_rsv[i_id] = 1'b1;
              is_rsp_head_emptybox_d[i_id] = 1'b1;

              // Also piggyback the pre_tail if it was blocked behind the response head. If the
              // rsp_len_after_out is zero, it means that a brand new queue is being initiated,
              // therefore all the pointers of this list should be piggybacked with the reservation head.
              if (rsp_len_after_out[i_id] == 0) begin
                pgbk_t_with_rsv[i_id] = 1'b1;
                pgbk_pt_with_rsv[i_id] = 1'b1;
              end else if (rsp_len_after_out[i_id] == 1) begin
                pgbk_pt_with_rsv[i_id] = 1'b1;
              end
            end
          end
        end else begin
          // Else, piggyback everything as a new queue is created from scratch.
          pgbk_rsp_with_rsv[i_id] = 1'b1;
          pgbk_t_with_rsv[i_id] = 1'b1;
          pgbk_pt_with_rsv[i_id] = 1'b1;
          is_rsp_head_emptybox_d[i_id] = 1'b1;
        end
      end : reservation_handshake

      // Output handshake
      if (out_data_valid_o && out_data_ready_i && cur_out_id_onehot[i_id]) begin : ouptut_handshake
        rsp_len_d[i_id] = rsp_len_d[i_id] - 1;
        update_t_from_pt[i_id] = 1'b1;  // Update the tail
        // If the response head is not at the same address as the pre_tail, then the pre_tail can be updated
        // from the RAM. Else, the pre_tail must be updated by piggybacking the response head.
        if (rsp_heads[i_id] != pre_tails[i_id]) begin
          // If possible, update the fail from the linkedlist pointers stored in RAM.
          update_t_from_ram_d[i_id] = 1'b1;
          meta_ram_out_addr_tail_id[i_id] = pre_tails[i_id];
        end else begin
          // Else, piggyback
          pgbk_pt_with_rsp_d[i_id] = 1'b1;
        end
      end : ouptut_handshake
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_heads_q <= '{default: '0};
      rsv_heads_q <= '{default: '0};
      tails_q <= '{default: '0};
      pre_tails_q <= '{default: '0};
      rsp_len_q <= '{default: '0};
      rsv_len_q <= '{default: '0};

      update_t_from_ram_q <= '{default: '0};
      update_m_from_ram_q <= '{default: '0};

      is_rsp_head_emptybox_q <= '{default: '1};

      pgbk_t_with_rsp_q <= '{default: '0};
      pgbk_pt_with_rsp_q <= '{default: '0};
    end else begin
      rsp_heads_q <= rsp_heads_d;
      rsv_heads_q <= rsv_heads_d;
      tails_q <= tails_d;
      pre_tails_q <= pre_tails_d;
      rsp_len_q <= rsp_len_d;
      rsv_len_q <= rsv_len_d;

      update_t_from_ram_q <= update_t_from_ram_d;
      update_m_from_ram_q <= update_m_from_ram_d;

      is_rsp_head_emptybox_q <= is_rsp_head_emptybox_d;

      pgbk_t_with_rsp_q <= pgbk_t_with_rsp_d;
      pgbk_pt_with_rsp_q <= pgbk_pt_with_rsp_d;
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

  // Payload RAM instance
  prim_generic_ram_2p #(
    .Width(MsgRamWidth),
    .DataBitsPerMask(1),
    .Depth(TotCapa)
  ) i_payload_ram (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (payload_ram_in_req),
    .a_write_i   (payload_ram_in_write),
    .a_wmask_i   (payload_ram_in_wmask),
    .a_addr_i    (payload_ram_in_addr),
    .a_wdata_i   (data_i.merged_payload.payload),
    .a_rdata_o   (),
    
    .b_req_i     (payload_ram_out_req),
    .b_write_i   (payload_ram_out_write),
    .b_wmask_i   (payload_ram_out_wmask),
    .b_addr_i    (payload_ram_out_addr),
    .b_wdata_i   (),
    .b_rdata_o   (rsp_out_ram_data)
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
  ) i_meta_ram_out_rsp_head (
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
