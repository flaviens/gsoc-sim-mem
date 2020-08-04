// Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0, see LICENSE for
// details. SPDX-License-Identifier: Apache-2.0

// The delay calculator core is responsible for snooping the traffic from the requester and deducing
// the enable signals for the message banks. Wrapped in the delay calculator module, it can assume
// that no write data request arrives before the corresponding write address request.
//
// Overview: The pendin requests are stored in arrays of slots (one array of w_slot_t for write
// requests and one array of r_slot_t for read requests). For burst support, each slot supports
// status information for each of the single corresponding requests:
//  * data_v: 1'b0 iff the corresponding request has not arrived yet.
//  * mem_pending: 1'b1 if the request has been submitted to the corresponding rank, which has not
//    responded yet.
//  * mem_done: 1'b0 iff the request has not been completed yet. A request identifier that exceeds
//    the burst length of the current slot's burst has its mem_done bit immediately set to 1'b1. 
//
// Write slot management:
// * When a write address request is accepted, along with a certain "immediate" number
//   wdata_immediate_cnt_i of write data requests, it occupies the lowest-identifier available write
//   slot. The wdata_immediate_cnt_i first bits of the data_v signal are set to one to indicate that
//   the slots are occupied. As they are to be treated, the corresponding bits of mem_pending and
//   mem_done are set to 0. The next burst_length-wdata_immediate_cnt_i bits, corresponding to the
//   still awaited write data requests, are set to zero in the three signals. The rest of the bits,
//   corresponding to data beyond the burst length, are set to (data_v, mem_pending,
//   mem_done)=(1,0,1).
// * Each slot exposes, per rank, one optimal (as defined by the scheduling strategy) data request,
//   along with the corresponding cost. If there is at least one such candidate data request, then
//   the signal opti_w_valid_per_slot is set to one. Else, it is set to zero.
// * When a data request is the optimal among all across all slots, and if the corresponding rank is
//   ready to take a request, then its mem_pending signal is set to one. When the request treatment
//   simulated duration is completed, its mem_pending bit is reset to zero and its mem_done bit is
//   set to one.
// * When the data_v array of a given slot is complete with ones (actually, some cycles before), the
//   write message bank is allowed to release the corresponding response.
//
// Difference between read and write transactions:
// * There are no separate read data requests. Therefore, the read slots do not have data_v bit
//   arrays.
// * There is one response per read data, as opposed to only one per write slot. Therefore, the read
//   output has counters to hold the number of burst data to be released. Also, the counter is
//   notified everytime a read data completes.
// * As all read data arrives at the same time, they don't require individual ages.
//
// Scheduling strategy: The implemented strategy is aggressive FR-FCFS (first-ready
// first-come-first-served). Priorities are given in the decreasing order:
// * The request and the corresponding rank must be ready.
// * The response time of the response bank must be minimal.
// * Older requests are treated first.
//
// Age management for requests: Age is treated in a relative manner using a binary age matrix. Only
// the exclisive top-right area (i.e., (Aij) for i<j) is considered, to minimize the overhead of the
// circuit. For i<j, the entry indexed by j is older than i iff Aij=1'b1. Age is tracked:
// * For each individual write data request.
// * For each write address request (i.e., one age entry for each write slot).
// * For each read address request (i.e., one age entry for each read slot).
//
// Two distinct age matrices: As write address requests ages are never compared to something else
// than another write address request (or equivalently, write slot age), those are held in a
// separate, smaller age matrix.
//
// Request cost: Three costs (measured in clock cycles) are supported by the delay calculator:
// * Cost of row hit (RowHitCost): if the requested row was in the row buffer.
// * Cost of activation + row hit (RowHitCost + ActivationCost): if no row was in the row buffer.
// * Cost of precharge + activation + row hit (RowHitCost + ActivationCost + PrechargeCost): if the
//   another row was in the row buffer. DRAM refreshing is not simulated.
//
// Cost compression: As the entropy of the cost values is very low (takes only 3 values), they are
// compressed on 2 bits to ease comparisons.
//

// FUTURE: Add support for wrap bursts FUTURE: Improve implementation by using reductions FUTURE:
// Should we gate the changes to the age matrix? FUTURE: Support interleaving

module simmem_delay_calculator_core (
  input logic clk_i,
  input logic rst_ni,
  
  // Write address request from the requester.
  input simmem_pkg::waddr_req_t waddr_req_i,
  // Internal identifier corresponding to the write address request (issued by the write response
  // bank).
  input logic [simmem_pkg::WriteRespBankAddrWidth-1:0] waddr_iid_i,
  // Number of write data packets that come with the write address (which were buffered buffered by
  // the wrapper, plus potentially one coming concurrently).
  input logic [simmem_pkg::MaxWBurstLenWidth-1:0] wdata_immediate_cnt_i,

  // Write address request valid from the requester.
  input logic waddr_valid_i,
  // Blocks the write address request if there is no slot in the delay calculator to treat it.
  output logic waddr_ready_o,

  // Write address request valid from the requester.
  input logic wdata_valid_i,
  // Always ready to take write data (the corresponding counter 'wdata_cnt_d/wdata_cnt_q' is
  // supposed never to overflow).
  output logic wdata_ready_o,

  // Write address request from the requester.
  input simmem_pkg::raddr_req_t raddr_req_i,
    // Internal identifier corresponding to the read address request (issued by the read response
  // bank).
  input logic [simmem_pkg::ReadDataBankAddrWidth-1:0] raddr_iid_i,

  // Read address request valid from the requester.
  input logic raddr_valid_i,
  // Blocks the read address request if there is no read slot in the delay calculator to treat it.
  output logic raddr_ready_o,

  // Release enable output signals and released address feedback.
  output logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_release_en_onehot_o,
  output logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_release_en_onehot_o,

  // Release confirmations sent by the message banks
  input  logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_released_addr_onehot_i,
  input  logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_released_addr_onehot_i
);

  import simmem_pkg::*;

  //////////////////////////////
  // Request cost compression //
  //////////////////////////////

  // Compresses the actual cost to have comparisons on fewer bits. Therefore, the ordering of the
  // values in the enumeration is important.
  typedef enum logic [1:0]{
    COST_CAS = 0,
    COST_ACTIVATION_CAS = 1,
    COST_PRECHARGE_ACTIVATION_CAS = 2
  } mem_compressed_cost_e;

  localparam logic [GlobalMemoryCapaWidth-1:0] CostCompressionMask
      = {{(GlobalMemoryCapaWidth - RowBufferLenWidth) {1'b1}}, {RowBufferLenWidth{1'b0}}};

  /**
  * Determines and compresses the cost of a request, depending on the requested address and the
  * current status of the corresponding rank.
  *
  * @param address the requested address.
  * @param is_row_open 1'b1 iff a row is currently open in the corresponding rank.
  * @param open_row_start_address the start address of the open row, if applicable.
  * @return the cost of the access, in clock cycles.
  */
  function automatic mem_compressed_cost_e determine_compressed_cost(
      logic [GlobalMemoryCapaWidth-1:0] address, logic is_row_open,
      logic [GlobalMemoryCapaWidth-1:0] open_row_start_address);
    if (is_row_open && (address & CostCompressionMask) == (
        open_row_start_address & CostCompressionMask)) begin
      return COST_CAS;
    end else if (!is_row_open) begin
      return COST_ACTIVATION_CAS;
    end else begin
      return COST_PRECHARGE_ACTIVATION_CAS;
    end
  endfunction : determine_compressed_cost

  /**
  * Decompresses a request cost.
  *
  * @param compressed_cost the compressed cost.
  *
  * @return the actual cost corresponding to this compressed cost.
  */
  function automatic logic [DelayWidth-1:0] decompress_mem_cost(
      mem_compressed_cost_e compressed_cost);
    case (compressed_cost)
      COST_CAS: begin
        return RowHitCost;
      end
      COST_ACTIVATION_CAS: begin
        return RowHitCost + ActivationCost;
      end
      default: begin
        return RowHitCost + ActivationCost + PrechargeCost;
      end
    endcase
  endfunction : decompress_mem_cost


  ///////////////////////////////////////////
  // Slot constants, types and declaration //
  ///////////////////////////////////////////

  // As their shape and treatment is different, slots for read and write bursts are disjoint: there
  // is one array of slots for read bursts, and one array for write slots.

  // Slot constants definition
  localparam NumWSlots = 6;
  localparam NumWSlotsWidth = $clog2(NumWSlots);
  localparam NumRSlots = 6;
  localparam NumRSlotsWidth = $clog2(NumRSlots);

  // Maximal number of write data entries: at most MaxWBurstLen per slot.
  localparam MaxNumWEntries = NumWSlots * MaxWBurstLen;

  // Slot type definition
  typedef struct packed {
    logic [MaxWBurstLen-1:0] mem_done;
    logic [MaxWBurstLen-1:0] mem_pending;
    logic [MaxWBurstLen-1:0] data_v;  // Data valid
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [WriteRespBankAddrWidth-1:0]
        iid;  // Internal identifier (address in the response bank's RAM)
    logic v;  // Valid bit
  } w_slot_t;

  typedef struct packed {
    logic [MaxRBurstLen-1:0] mem_done;
    logic [MaxRBurstLen-1:0] mem_pending;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [ReadDataBankAddrWidth-1:0]
        iid;  // Internal identifier (address in the response bank's RAM)
    logic v;  // Valid bit
  } r_slot_t;

  // Slot declarations
  w_slot_t wslt_d[NumWSlots];
  w_slot_t wslt_q[NumWSlots];
  r_slot_t rslt_d[NumRSlots];
  r_slot_t rslt_q[NumRSlots];


  //////////////////////////////////
  // Determine the next free slot //
  //////////////////////////////////

  // In this part, the free slot with lowest position in the slots array is determined for both read
  // and write bursts.

  // Intermediate multi-hot signals determining which slots are free.
  logic [NumWSlots-1:0] free_wslt_mhot;
  logic [NumRSlots-1:0] free_rslt_mhot;
  // Intermediate one-hot signals determining the position of the free slot with lowest position in
  // the slots arrays.
  logic [NumWSlots-1:0] nxt_free_w_slot_onehot;
  logic [NumRSlots-1:0] nxt_free_r_slot_onehot;

  // Determine the next free slot for write slots.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_nxt_free_w_slot
    assign free_wslt_mhot[i_slt] = ~wslt_q[i_slt].v;
    if (i_slt == 0) begin
      assign nxt_free_w_slot_onehot[0] = free_wslt_mhot[0];
    end else begin
      assign nxt_free_w_slot_onehot[i_slt] = free_wslt_mhot[i_slt] && !|free_wslt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_w_slot

  // Determine the next free slot for read slots.
  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_nxt_free_r_slot
    assign free_rslt_mhot[i_slt] = ~rslt_q[0].v;
    if (i_slt == 0) begin
      assign nxt_free_r_slot_onehot[0] = free_rslt_mhot[0];
    end else begin
      assign nxt_free_r_slot_onehot[i_slt] = free_rslt_mhot[i_slt] && !|free_rslt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_r_slot

  // The module is ready to accept address requests if there is a free corresponding (write or read)
  // slot. 
  assign waddr_ready_o = |nxt_free_w_slot_onehot;
  assign raddr_ready_o = |nxt_free_r_slot_onehot;


  ////////////////////////////////////////////////////////////
  // Age matrix constants, declaration and helper functions //
  ////////////////////////////////////////////////////////////

  // An age matrix cell is 1 at (x=higher, y=lower) iff higher is older than lower (if both
  // entries/slots are valid, else the cell value is irrelevant).
  //
  // The age matrices are indexed as the following example, for 3 write slots (W), 5 read slots (R)
  // and a maximal write burst length of 2 write data (D) per write address (the x symbols represent
  // boolean values asserting "row is older than column").
  //
  // Main age matrix (main_age_matrix_d/main_age_matrix_q):
  //
  // *   D D D D D D R R R R R
  // *  
  // * D   x x x x x x x x x x
  // * D     x x x x x x x x x
  // * D       x x x x x x x x
  // * D         x x x x x x x
  // * D           x x x x x x
  // * D             x x x x x
  // * R               x x x x
  // * R                 x x x
  // * R                   x x
  // * R                     x
  // * R                      
  //
  // Write slot age matrix (wslt_main_age_matrix_d/wslt_main_age_matrix_q):
  //
  // *   W W W
  // *
  // * W   x x
  // * W     x
  // * W
  //
  // The age matrix is stored flat. Indexing in 2D coordinates is done through the function
  // get_main_age_matrix_entry_coord.

  // Main age matrix
  localparam MainAgeMatrixRSlotStartIndex = MaxNumWEntries + NumRSlots;

  localparam MainAgeMatrixSide = MaxNumWEntries + NumRSlots;
  localparam MainAgeMatrixSideWidth = $clog2(MainAgeMatrixSide);

  localparam MainAgeMatrixLen = MainAgeMatrixSide * (MainAgeMatrixSide - 1) / 2;
  localparam MainAgeMatrixLenWidth = $clog2(MainAgeMatrixLen);

  logic [MainAgeMatrixLen-1:0] main_age_matrix_d;
  logic [MainAgeMatrixLen-1:0] main_age_matrix_q;


  // Write slot
  localparam WSlotAgeMatrixLen = NumWSlots * (NumWSlots - 1) / 2;
  localparam WSlotAgeMatrixLenWidth = $clog2(WSlotAgeMatrixLen);

  logic [WSlotAgeMatrixLen-1:0] wslt_age_matrix_d;
  logic [WSlotAgeMatrixLen-1:0] wslt_age_matrix_q;


  /**
  * Indexes the main age matrix in 2D, by transforming 2D coordinates into the unidimensional
  * coordinate for the flat age matrix. Coordinates must be sorted. This function is mostly called
  * by intermediate functions.
  *
  * @param lower_coord the lower coordinate.
  * @param higher_coord the higher coordinate.
  * @return the corresponding unidirectional coordinate.
  */
  function automatic logic [MainAgeMatrixLenWidth-1:0] get_main_age_matrix_entry_coord(
      logic [MainAgeMatrixSideWidth-1:0] lower_coord,
      logic [MainAgeMatrixSideWidth-1:0] higher_coord);
    // TODO: assert (lower_coord < higher_coord); Assertion apparently not supported by Verilator

    return MainAgeMatrixLenWidth'(higher_coord) + lower_coord * MainAgeMatrixLen;
  endfunction : get_main_age_matrix_entry_coord

  /**
  * Indexes the write slot age matrix in 2D, by transforming 2D coordinates into the unidimensional
  * coordinate for the flat age matrix. Coordinates must be sorted. 
  *
  * @param lower_coord the lower coordinate.
  * @param higher_coord the higher coordinate.
  * @return the corresponding unidirectional coordinate.
  */
  function automatic logic [WSlotAgeMatrixLenWidth-1:0] get_wslt_age_matrix_entry_coord(
      logic [NumWSlotsWidth-1:0] lower_coord, logic [NumWSlotsWidth-1:0] higher_coord);
    // TODO: assert (lower_coord < higher_coord); Assertion apparently not supported by Verilator

    return WSlotAgeMatrixLenWidth'(higher_coord) + lower_coord * MainAgeMatrixLen;
  endfunction : get_wslt_age_matrix_entry_coord

  /**
  * Checks in the age matrix whether the write data entry pointed by the higher identifier is older
  * than the other.
  *
  * @param wslt the slot in which the write data entries are located.
  * @param i_lower_bit the lower entry index in the slot.
  * @param i_higher_bit the higher entry index in the slot.
  * @return 1'b1 iff the lower entry is older.
  */
  function automatic logic is_higher_w_entry_older(logic [NumWSlotsWidth-1:0] wslt,
                                                   logic [MaxWBurstLenWidth-1:0] lower_bit,
                                                   logic [MaxWBurstLenWidth-1:0] higher_bit);
    return main_age_matrix_q[
        get_main_age_matrix_entry_coord
            (MainAgeMatrixSideWidth'(wslt * NumWSlotsWidth) + MainAgeMatrixSideWidth'(lower_bit),
             MainAgeMatrixSideWidth'(wslt * NumWSlotsWidth) + MainAgeMatrixSideWidth'(higher_bit))];
  endfunction : is_higher_w_entry_older

  /**
  * Checks in the age matrix whether the write slot pointed by the higher identifier is older than
  * the other. This is only used for write data acceptance.
  *
  * @param i_lower_bit the lower slot index in the write slots array.
  * @param i_higher_bit the higher slot index in the write slots array.
  * @return 1'b1 iff the lower slot is older.
  */
  function automatic logic is_higher_w_slot_older(logic [NumWSlotsWidth-1:0] w_lower_slt,
                                                  logic [NumWSlotsWidth-1:0] w_higher_slt);
    return wslt_age_matrix_q[get_wslt_age_matrix_entry_coord(w_lower_slt, w_higher_slt)];
  endfunction : is_higher_w_slot_older

  /**
  * Checks in the age matrix whether the read slot pointed by the higher identifier is older than
  * the other.
  *
  * @param i_lower_bit the lower slot index in the read slots array.
  * @param i_higher_bit the higher slot index in the read slots array.
  * @return 1'b1 iff the lower slot is older.
  */
  function automatic logic is_higher_r_slot_older(logic [NumRSlotsWidth-1:0] r_lower_slt,
                                                  logic [NumRSlotsWidth-1:0] r_higher_slt);
    return main_age_matrix_q[
        get_main_age_matrix_entry_coord(MainAgeMatrixSideWidth'(MainAgeMatrixRSlotStartIndex) +
                                        MainAgeMatrixSideWidth'(r_lower_slt),
                                        MainAgeMatrixSideWidth'(MainAgeMatrixRSlotStartIndex) +
                                        MainAgeMatrixSideWidth'(r_higher_slt))];
  endfunction : is_higher_r_slot_older

  /**
  * Checks in the age matrix whether the given read slot is older than the entry in a given write slot. This
  * function is used to determine which will be the older between all the candidate write entries,
  * and all the candidate read entries.
  *
  * @param wslt the write slot index in the write slots array.
  * @param rslt the read slot index in the read slots array.
  * @return 1'b1 iff the read slot is older.
  */
  function automatic logic is_r_slot_older(logic [NumWSlotsWidth-1:0] wslt,
                                           logic [MaxWBurstLenWidth-1:0] w_bit,
                                           logic [NumRSlotsWidth-1:0] rslt);
    return main_age_matrix_q[get_main_age_matrix_entry_coord(
                             MainAgeMatrixSideWidth'(wslt * NumWSlotsWidth) + MainAgeMatrixSideWidth
                                 '(w_bit), MainAgeMatrixSideWidth'(MainAgeMatrixRSlotStartIndex) +
                                 MainAgeMatrixSideWidth'(rslt))];
  endfunction : is_r_slot_older

  /**
  * Updates the main age matrix when a new entry (write data request or read address request) is
  * accepted.
  *
  * @param wslt the write slot index in the write slots array.
  * @param rslt the read slot index in the read slots array.
  * @return 1'b1 iff the read slot is older than the write slot.
  */
  function automatic void update_main_age_matrix_on_input(
      logic [MainAgeMatrixSideWidth-1:0] input_coord,
      ref logic [MainAgeMatrixLen-1:0] main_age_matrix);
    for (int unsigned k = 0; k < MainAgeMatrixSide; k++) begin
      if (MainAgeMatrixSideWidth'(k) < input_coord) begin
        main_age_matrix[get_main_age_matrix_entry_coord(MainAgeMatrixSideWidth'(k), input_coord)] =
            1'b0;
      end else if (MainAgeMatrixSideWidth'(k) > input_coord) begin
        main_age_matrix[get_main_age_matrix_entry_coord(input_coord, MainAgeMatrixSideWidth'(k))] =
            1'b1;
      end
    end
  endfunction : update_main_age_matrix_on_input

  /**
  * Updates the write slot age matrix when a new entry (write data request or read address request)
  * is accepted.
  *
  * @param wslt the write slot index in the write slots array.
  * @param rslt the read slot index in the read slots array.
  * @return 1'b1 iff the read slot is older than the write slot.
  */
  function automatic void update_wslt_age_matrix_on_input(logic [NumWSlotsWidth-1:0] input_coord,
      ref logic [WSlotAgeMatrixLen-1:0] wslt_age_matrix);
    for (int unsigned k = 0; NumWSlotsWidth'(k) < NumWSlots; k++) begin
      if (NumWSlotsWidth'(k) < input_coord) begin
        wslt_age_matrix[get_wslt_age_matrix_entry_coord(NumWSlotsWidth'(k), input_coord)] = 1'b0;
      end else if (NumWSlotsWidth'(k) > input_coord) begin
        wslt_age_matrix[get_wslt_age_matrix_entry_coord(input_coord, NumWSlotsWidth'(k))] = 1'b1;
      end
    end
  endfunction : update_wslt_age_matrix_on_input



  ////////////////////////////////////////////////
  // Find next slot where write data should fit //
  ////////////////////////////////////////////////

  // In this part, the signals indicating in which slot and in which write data entry, a new write
  // data request should fit. If there is no candidate, then refuse incoming write data requests
  // (they will be counted by the delay counter wrapper).
  //
  // The chosen write slot is the oldest occupied write slot whose write data entries are not all
  // valid, if applicable.

  // Slot where the data should fit (binary representation).
  logic [NumWSlotsWidth-1:0] free_w_slot_for_data;
  // First non-valid bit in the write slot, for each slot.
  logic [MaxWBurstLen-1:0] nxt_nv_bit_onehot[NumWSlots];

  // Future: Improve the age matrix reduction here.

  // For each write slot, find the lowest-indexed non-valid write data entry in the slot.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_slot_for_in_data
    for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : gen_nxt_nv_bit_inner
      if (i_bit == 0) begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] = ~wslt_q[i_slt].data_v[0];
      end else begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] =
            ~wslt_q[i_slt].data_v[i_bit] && &wslt_q[i_slt].data_v[i_bit - 1:0];
      end
    end : gen_nxt_nv_bit_inner
  end : gen_slot_for_in_data

  always_comb begin : gen_oldest_wdata_input_candidate
    // The signal wdata_ready_o is set to one when the first candidate is reached.
    wdata_ready_o = 1'b0;
    free_w_slot_for_data = '0;

    // Sequentially, find the oldest occupied write slot whose write data entries are not all valid.
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      if (wslt_q[i_slt].v && !&(wslt_q[i_slt].data_v) && (
          !wdata_ready_o || is_higher_w_slot_older(free_w_slot_for_data, NumWSlotsWidth'(i_slt)))
          ) begin
        wdata_ready_o = 1'b1;
        free_w_slot_for_data = NumWSlotsWidth'(i_slt);
      end
    end
  end : gen_oldest_wdata_input_candidate


  //////////////////////////////////
  // Address calculation in slots //
  //////////////////////////////////

  // In this part, the address corresponding to each entry in each write slot and read slot is
  // calculated from the slot burst base address and burst size.

  // Addresses of slot entries.
  logic [GlobalMemoryCapaWidth-1:0] w_addrs_per_slot[NumWSlots-1:0][MaxWBurstLen-1:0];
  logic [GlobalMemoryCapaWidth-1:0] r_addrs_per_slot[NumRSlots-1:0][MaxRBurstLen-1:0];

  // Write data entries address.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_w_addrs
    for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : gen_w_addrs_per_slt
      assign w_addrs_per_slot[i_slt][i_bit] = wslt_q[i_slt].addr + i_bit * wslt_q[i_slt].burst_size;
    end : gen_w_addrs_per_slt
  end : gen_w_addrs

  // Read data entries address.
  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_r_addrs
    for (genvar i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin : gen_r_addrs_per_slt
      assign r_addrs_per_slot[i_slt][i_bit] = rslt_q[i_slt].addr + i_bit * rslt_q[i_slt].burst_size;
    end : gen_r_addrs_per_slt
  end : gen_r_addrs


  ////////////////////////////////
  // Slot-internal optimization //
  ////////////////////////////////

  // In this part, the optimal entry in each slot is determined. Each slot generates three signals:
  // * opti_x_bit_per_slot: the optimal entry index in the slot (binary representation of the
  //   entry's index in the array).
  // * opti_x_cost_per_slot: the compressed cost corresponding to the optimal entry in the slot.
  // * opti_x_valid_per_slot: 1'b1 iff there is at least one candidate entry in the slot.

  // Future: Do this for multiple ranks.

  logic [MaxWBurstLenWidth-1:0] opti_w_bit_per_slot[NumWSlots];
  logic [MaxRBurstLenWidth-1:0] opti_r_bit_per_slot[NumRSlots];

  mem_compressed_cost_e opti_w_cost_per_slot[NumWSlots];
  mem_compressed_cost_e opti_r_cost_per_slot[NumRSlots];

  logic opti_w_valid_per_slot[NumWSlots];
  logic opti_r_valid_per_slot[NumRSlots];

  // Reduce per slot

  // In each slot, sequentially perform the optimization.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_opti_w_addrs_per_slt
    always_comb begin : gen_opti_w_cost_per_slot

      // Contains the current optimal cost.
      mem_compressed_cost_e curr_cost;

      opti_w_bit_per_slot[i_slt] = '0;
      opti_w_valid_per_slot[i_slt] = 1'b0;
      opti_w_cost_per_slot[i_slt] = ~'0;

      // Iterate through all the entries to find the optimal.
      for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
        curr_cost = determine_compressed_cost(w_addrs_per_slot[i_slt][i_bit], is_row_open_q,
                                              open_row_start_address_q);

        // opti_w_valid_per_slot[i_slt] = opti_w_valid_per_slot[i_slt] ||
        //                                   (wslt_q[i_slt].data_v[i_bit] &&
        //                                   !wslt_q[i_slt].mem_pending[i_bit] &&
        //                                   !wslt_q[i_slt].mem_done[i_bit]);

        // If the write data entry is ready to be submitted.
        if ((wslt_q[i_slt].data_v[i_bit] && !wslt_q[i_slt].mem_pending[i_bit] &&
             !wslt_q[i_slt].mem_done[i_bit]) &&
        // And this is the ready candidate of lowest index in the slot OR has lower cost than the
        // previous candidate OR has same cost as the previous candidate, but is older. Remark: for
        // non-wrap bursts, the condition is_higher_w_entry_older(i_slt, opti_w_bit_per_slot[i_slt],
        // MaxWBurstLenWidth'(i_bit))) is always true. However, all the write data entry bits in the
        // age matrix are anyways required, as those write data entries ages are compared to other
        // entries and slots.
        (!opti_w_valid_per_slot[i_slt] || curr_cost < opti_w_cost_per_slot[i_slt] || (
         curr_cost == opti_w_cost_per_slot[i_slt] && is_higher_w_entry_older(
             i_slt, opti_w_bit_per_slot[i_slt], MaxWBurstLenWidth'(i_bit))))) begin
          opti_w_valid_per_slot[i_slt] = 1'b1;
          opti_w_cost_per_slot[i_slt] = curr_cost;
          opti_w_bit_per_slot[i_slt] = MaxWBurstLenWidth'(i_bit);
        end
      end
    end : gen_opti_w_cost_per_slot
  end : gen_opti_w_addrs_per_slt

  // For read requests, individual age for each element in the burst would be irrelevant, as the
  // read request comes as a whole.
  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_opti_r_addrs_per_slt
    always_comb begin : gen_opti_r_cost_per_slot
      mem_compressed_cost_e curr_cost;

      opti_r_bit_per_slot[i_slt] = '0;
      opti_r_valid_per_slot[i_slt] = 1'b0;
      opti_r_cost_per_slot[i_slt] = ~'0;

      for (int unsigned i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin
        curr_cost = determine_compressed_cost(r_addrs_per_slot[i_slt][i_bit], is_row_open_q,
                                              open_row_start_address_q);

        // opti_r_valid_per_slot[i_slt] = opti_r_valid_per_slot[i_slt] ||
        //                                   (rslt_q[i_slt].data_v[i_bit] &&
        //                                   !rslt_q[i_slt].mem_pending[i_bit] &&
        //                                   !rslt_q[i_slt].mem_done[i_bit]);

        // If the read data entry is ready to be submitted.
        if ((!rslt_q[i_slt].mem_pending[i_bit] && !rslt_q[i_slt].mem_done[i_bit]) && (
        // And this is the ready candidate of lowest index in the slot OR has lower cost than the
        // previous candidate. As a reminder, all read data requests arrive simultaneously.
        // Therefore, no age comparison is needed here.
        !opti_r_valid_per_slot[i_slt] || curr_cost < opti_r_cost_per_slot[i_slt])) begin
          opti_r_valid_per_slot[i_slt] = 1'b1;
          opti_r_cost_per_slot[i_slt] = curr_cost;
          opti_r_bit_per_slot[i_slt] = MaxRBurstLenWidth'(i_bit);
        end
      end
    end : gen_opti_r_cost_per_slot
  end : gen_opti_r_addrs_per_slt


  /////////////////////////////
  // Inter-slot optimization //
  /////////////////////////////

  // In this part, the optimal entry in compared among all slots, after the slot-internal
  // optimization has been performed. Two steps are involved. First, the optimization is performed
  // separately for write slots and read slots. Then, the optima are compared for writes and reads.

  // Optimal write and read slot.
  logic [NumWSlotsWidth-1:0] opti_w_slot;
  logic [NumRSlotsWidth-1:0] opti_r_slot;

  // Boolean signals with value 1'b1 iff the optimization has leveraged at least one candidate.
  logic opti_w_slot_valid;
  logic opti_r_slot_valid;

  // Request cost of the read and the write candidate entries.
  mem_compressed_cost_e opti_w_cost;
  mem_compressed_cost_e opti_r_cost;

  always_comb begin : gen_opti_slot
    mem_compressed_cost_e curr_cost;

    opti_r_slot = '0;
    opti_w_slot = '0;
    opti_w_slot_valid = 1'b0;
    opti_r_slot_valid = 1'b0;
    opti_w_cost = '0;
    opti_r_cost = '0;

    // Sequentially, find the write slot with the optimal entry.
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_w_cost_per_slot[i_slt];
      // If the slot is valid and the slot-internal optimization is valid. 
      if ((wslt_q[i_slt].v && opti_w_valid_per_slot[i_slt]) && (
      // And this is the lowest such candidate slot OR the slot's optimal candidate entry has a
      // lower cost than the previous slot's OR the an equal cost but is older than the previous
      // slot's optimal candidate.
      !opti_w_slot_valid || curr_cost < opti_w_cost || (
          curr_cost == opti_w_cost && is_higher_w_slot_older(opti_w_slot, NumWSlotsWidth'(i_slt))))
          ) begin
        opti_w_slot_valid = 1'b1;
        opti_w_slot = NumWSlotsWidth'(i_slt);
        opti_w_cost = curr_cost;
      end
      opti_w_slot_valid = opti_w_slot_valid || (wslt_q[i_slt].v && opti_w_valid_per_slot[i_slt]);
    end

    // Sequentially, find the read slot with the optimal entry.
    for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_r_cost_per_slot[i_slt];
      // If the slot is valid and the slot-internal optimization is valid. 
      if ((rslt_q[i_slt].v && opti_r_valid_per_slot[i_slt]) && (
      // And this is the lowest such candidate slot OR the slot's optimal candidate entry has a
      // lower cost than the previous slot's OR the an equal cost but is older than the previous
      // slot's optimal candidate.
      !opti_r_slot_valid || curr_cost < opti_r_cost || (
          curr_cost == opti_r_cost && is_higher_r_slot_older(opti_r_slot, NumRSlotsWidth'(i_slt))))
          ) begin
        opti_r_slot_valid = 1'b1;
        opti_r_slot = NumRSlotsWidth'(i_slt);
        opti_r_cost = curr_cost;
      end
    end
  end : gen_opti_slot

  // Aggregates the optimal entry of the optimal write slot. Zero if there is no optimal time slot. This signal
  // is useful to compare the age of write and read requests.
  logic [MaxWBurstLenWidth-1:0][NumWSlots-1:0] opti_w_bit_rot90;
  logic [MaxWBurstLenWidth-1:0] opti_w_bit;

  for (
      genvar i_inbit = 0; i_inbit < MaxRBurstLenWidth; i_inbit = i_inbit + 1
  ) begin : aggreg_opti_w_bit
    for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : aggreg_opti_w_bit_internal
      assign opti_w_bit_rot90[i_inbit][i_slt] =
          opti_w_bit_per_slot[i_slt][i_inbit] && opti_w_slot == NumRSlotsWidth'(i_slt);
    end : aggreg_opti_w_bit_internal
    assign opti_w_bit[i_inbit] = |opti_w_bit_rot90[i_inbit];
  end : aggreg_opti_w_bit

  // Determines if the optimal entry is among writes (1'b1) or reads (1'b0).
  logic serve_w;
  assign serve_w = opti_w_slot_valid && (
      !opti_r_slot_valid || opti_w_cost < opti_r_cost || (
          opti_w_cost == opti_r_cost && !is_r_slot_older(opti_w_slot, opti_w_bit, opti_r_slot)));


  //////////////////
  // Rank signals //
  //////////////////

  // The ranks are simulated by mere counters. These counters are set to a given request cost and
  // constantly decremented to zero.

  // Determines if there is a row open in the rank. So far, this is always true after the first
  // request.
  logic is_row_open_d;
  logic is_row_open_q;

  // Determines the start address of the open row. This is useful for request cost calculation. If
  // no row is open in the rank, then this value is irrelevant.
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_d;
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_q;

  // Decreasing counter that determines the number of cycles in which the rank will be able to take
  // a new request.
  logic [DelayWidth-1:0] rank_delay_cnt_d;
  logic [DelayWidth-1:0] rank_delay_cnt_q;


  /////////////
  // Outputs //
  /////////////

  // The output x_release_en_onehot_o signals enable the release of some addresses (aka. iids) by
  // the response banks. As there is only one output fired per write burst, a single one-hot row of
  // flip-flops is sufficient for the wresp_release_en signal. Counters are useful, however, for
  // read data, which are subject to burst responses.

  logic [WriteRespBankCapacity-1:0] wresp_release_en_onehot_d;
  logic [ReadDataBankCapacity-1:0][MaxRBurstLenWidth-1:0] rdata_release_en_counters_d;
  logic [ReadDataBankCapacity-1:0][MaxRBurstLenWidth-1:0] rdata_release_en_counters_q;

  // Set the read data release_en outputs to one, where the corresponding counter is not zero.
  for (genvar i_iid = 0; i_iid < ReadDataBankCapacity; i_iid = i_iid + 1) begin : en_rdata_release
    assign rdata_release_en_onehot_o[i_iid] = |rdata_release_en_counters_q[i_iid];
  end : en_rdata_release


  ////////////////////////////////////
  // Management combinatorial logic //
  ////////////////////////////////////

  // Delay calculator management logic
  always_comb begin : del_calc_mgmt_comb

    // Default assignments
    is_row_open_d = is_row_open_q;
    open_row_start_address_d = open_row_start_address_q;
    wresp_release_en_onehot_d = wresp_release_en_onehot_o;
    rdata_release_en_counters_d = rdata_release_en_counters_q;


    ////////////////////////////
    // Address requests input //
    ////////////////////////////

    // This part is dedicated to the the acceptation of write or read address requests.

    // Write address request input.
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      // By default, keep the slots' previous value.
      wslt_d[i_slt] = wslt_q[i_slt];

      if (waddr_valid_i && waddr_ready_o && nxt_free_w_slot_onehot[i_slt]) begin
        // If there is a successful write address handshake and i_slt has been determined to be its
        // home slot, then fill the slot with the relevant information from the write address
        // request.
        wslt_d[i_slt].v = 1'b1;
        wslt_d[i_slt].iid = waddr_iid_i;
        wslt_d[i_slt].addr = waddr_req_i.addr;
        wslt_d[i_slt].burst_size = waddr_req_i.burst_size;

        // The mem_pending bits of a new request are always set to zero, until an access to the
        // corresponding rank is simulated.
        wslt_d[i_slt].mem_pending = '0;

        // FUTURE: Implement support for wrap burst here and in the read slot input

        // Update the write slot age matrix.
        update_wslt_age_matrix_on_input(NumWSlotsWidth'(i_slt), wslt_age_matrix_d);

        // Fill the write data entries.
        for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
          // The first wdata_immediate_cnt_i data_v bits are set to 1'b1, as they are occupied by
          // the immediately present write data requests, that come simultaneously with the write
          // address request. Some of the last data_v bits, which correspond to the bits beyond the
          // write address request's burst length, are also set to 1'b1, as they will not expect any
          // write data to come in. The rest of the data_v bits (between the two possibly empty
          // ranges of ones) are set to zero, awaiting further write data requests.
          wslt_d[i_slt].data_v[i_bit] =
              (AxLenWidth'(i_bit) >= waddr_req_i.burst_length) || (i_bit < wdata_immediate_cnt_i);
          // Some of the last mem_done bits, which correspond to the bits beyond the write address
          // request's burst length, are set to 1'b1, as they are considered already treated (will
          // never be treated further, and the slot is considered complete when all the mem_done
          // bits are set to one). The rest of the mem_done bits are set to zero, and will be set to
          // one later when a transaction is complete.
          wslt_d[i_slt].mem_done[i_bit] = AxLenWidth'(i_bit) >= waddr_req_i.burst_length;
          // The age matrix has to be updated for each immediate write data, with the same age
          // relative to the entries external to the slot.
          update_main_age_matrix_on_input(MainAgeMatrixSideWidth'(i_slt * MaxWBurstLen) +
                                          MainAgeMatrixSideWidth'(i_bit), main_age_matrix_d);
        end
      end
    end

    // Read address request input.
    for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
      // By default, keep the slots' previous value.
      rslt_d[i_slt] = rslt_q[i_slt];

      if (raddr_valid_i && raddr_ready_o && nxt_free_r_slot_onehot[i_slt]) begin
        // If there is a successful write address handshake and i_slt has been determined to be its
        // home slot, then fill the slot with the relevant information from the write address
        // request.
        rslt_d[i_slt].v = 1'b1;
        rslt_d[i_slt].iid = raddr_iid_i;
        rslt_d[i_slt].addr = raddr_req_i.addr;
        rslt_d[i_slt].burst_size = raddr_req_i.burst_size;
        // The mem_pending bits of a new request are always set to zero, until an access to the
        // corresponding rank is simulated.
        rslt_d[i_slt].mem_pending = '0;

        for (int unsigned i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin
          // Some of the last mem_done bits, which correspond to the bits beyond the read address
          // request's burst length, are set to 1'b1, as they are considered already treated (will
          // never be treated further, and the slot is considered complete when all the mem_done
          // bits are set to one). The rest of the mem_done bits are set to zero, and will be set to
          // one later when a transaction is complete.
          rslt_d[i_slt].mem_done[i_bit] = AxLenWidth'(i_bit) >= raddr_req_i.burst_length;
        end

        update_main_age_matrix_on_input(MainAgeMatrixSideWidth'(MainAgeMatrixRSlotStartIndex) +
                                        MainAgeMatrixSideWidth'(i_slt), main_age_matrix_d);
      end
    end


    //////////////////////////////
    // Write data request input //
    //////////////////////////////

    // This part is dedicated to the acceptance of write data  requests when there are some occupied
    // but incomplete write slots (i.e., write addresses with some missing write_data corresponding
    // to the burst).

    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
        if (nxt_nv_bit_onehot[i_slt][i_bit] && free_w_slot_for_data == NumWSlotsWidth'(i_slt) &&
            wdata_valid_i && wdata_ready_o) begin
          // The data_v signal is OR-masked with a mask determining where the new data should land.
          // Most of the times, the mask is full-zero, as there is no write data input handshake or
          // because this is not the slot where the write data where it should land.

          wslt_d[i_slt].data_v[i_bit] = 1'b1;
          update_main_age_matrix_on_input(MainAgeMatrixSideWidth'(i_slt * MaxWBurstLen) +
                                          MainAgeMatrixSideWidth'(i_bit), main_age_matrix_d);
        end
      end
    end


    /////////////////////////
    // Rank counter update //
    /////////////////////////

    // This part is dedicated to updating the rank counters.

    // If the rank counter is zero, then simply decrement it.
    if (|rank_delay_cnt_q != 0) begin
      rank_delay_cnt_d = rank_delay_cnt_q - 1;
    end else begin
      // If serve_w is set, then it is certain that there is at least one request for the rank to
      // treat, and that this optimal entry is among the write data entries.
      if (serve_w) begin
        // Decompress the cost representation to obtain the real cost.
        rank_delay_cnt_d = decompress_mem_cost(opti_w_cost);

        // Set the mem_pending bit of the optimal entry to one, as its treatment is starting.
        for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
          for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
            // TODO: opti_w_valid_per_slot should not need to be checked.
            wslt_d[i_slt].mem_pending[i_bit] |= opti_w_valid_per_slot[i_slt] && opti_w_bit_per_slot[
                i_slt] == MaxWBurstLenWidth'(i_bit) && opti_w_slot == NumWSlotsWidth'(i_slt);
          end
        end
        // A row is now opening or open in the corresponding rank. 
        is_row_open_d = 1'b1;
      end else if (!serve_w && opti_r_slot_valid) begin
        // Decompress the cost representation to obtain the real cost.
        rank_delay_cnt_d = decompress_mem_cost(opti_r_cost);

        // Set the mem_pending bit of the optimal entry to one, as its treatment is starting.
        for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
          for (int unsigned i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin
            // TODO: opti_r_valid_per_slot should not need to be checked.
            rslt_d[i_slt].mem_pending[i_bit] |= opti_r_valid_per_slot[i_slt] && opti_r_bit_per_slot[
                i_slt] == MaxRBurstLenWidth'(i_bit) && opti_r_slot == NumRSlotsWidth'(i_slt);
          end
        end
        // A row is now opening or open in the corresponding rank. 
        is_row_open_d = 1'b1;
      end else begin
        // If there is no request to serve, then the counter remains 0.
        rank_delay_cnt_d = 0;
      end
    end


    /////////////////////////////////////////
    // Entry request completion management //
    /////////////////////////////////////////

    // This part is dedicated to managing the completion of requests. A request is said complete
    // when its corresponding mem_done is set to one. It is either completed immediately at slot
    // occupation if this is an excess request (a data request which is beyond the actual address
    // request's burst length). Else, the corresponding mem_done bit is set to one when the mem_done
    // bit is one, and the corresponding rank counter hits zero (plus a certain constant delay to
    // accommodate the non-zero delay until the simulated memory controller's output).

    // Updated at delay 3 to accommodate the one-cycle additional latency due to the response bank.
    if (rank_delay_cnt_q == 3) begin
      for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done if already done, or was pending.
        wslt_d[i_slt].mem_done = wslt_q[i_slt].mem_done | wslt_q[i_slt].mem_pending;
        wslt_d[i_slt].mem_pending = '0;
      end
      for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done if already done, or was pending.
        rslt_d[i_slt].mem_done = rslt_q[i_slt].mem_done | rslt_q[i_slt].mem_pending;
        rslt_d[i_slt].mem_pending = '0;
      end
    end

    // Input signals from message banks about released signals
    wresp_release_en_onehot_d ^= wresp_released_addr_onehot_i;

    // Decrement the rdata_release_en_counters_d if data has been released for this address (aka.
    // iid). If a counter is decremented, it was originally not zero, because a message bank is not
    // allowed to release read responses of the corresponding rdata_release_en_onehot_o bit is zero,
    // which happens iff the corresponding counter is zero.
    for (int unsigned i_iid = 0; i_iid < ReadDataBankCapacity; i_iid = i_iid + 1) begin
      if (rdata_released_addr_onehot_i[i_iid]) begin
        rdata_release_en_counters_d[i_iid] -= 1;
      end
    end


    /////////////////////
    // Slot liberation //
    /////////////////////

    // This part is dedicated to free complete slots and notify the outputs in thiis case.

    // Write slots
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      // If all the memory requests of a burst have been satisfied, then free the slot.
      wslt_d[i_slt].v &= !&wslt_q[i_slt].mem_done;
      for (int unsigned i_iid = 0; i_iid < WriteRespBankCapacity; i_iid = i_iid + 1) begin
        // If all the memory requests of a burst have been satisfied, then notify the output. 
        wresp_release_en_onehot_d[i_iid] |= wslt_q[i_slt].v && &wslt_q[i_slt].mem_done &&
            wslt_q[i_slt].iid == i_iid[WriteRespBankAddrWidth - 1:0];
      end
    end
    // Read slots
    for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
      // If all the memory requests of a burst have been satisfied, then free the slot.

      rslt_d[i_slt].v &= !&rslt_q[i_slt].mem_done;
      for (int unsigned i_iid = 0; i_iid < ReadDataBankCapacity; i_iid = i_iid + 1) begin
        // If all the memory requests of a burst have been satisfied, then notify the output. 
        if (rslt_q[i_slt].v && &rslt_q[i_slt].mem_done &&
            rslt_q[i_slt].iid == i_iid[ReadDataBankAddrWidth - 1:0]) begin
          rdata_release_en_counters_d[i_iid] += 1;
        end
      end
    end
  end : del_calc_mgmt_comb

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      main_age_matrix_q <= '0;
      wslt_age_matrix_q <= '0;
      wslt_q <= '{default: '0};
      rslt_q <= '{default: '0};
      is_row_open_q <= 1'b0;
      open_row_start_address_q <= '0;
      rank_delay_cnt_q <= '0;
      wresp_release_en_onehot_o <= '0;
      rdata_release_en_counters_q <= '0;
    end else begin
      main_age_matrix_q <= main_age_matrix_d;
      wslt_age_matrix_q <= wslt_age_matrix_d;
      wslt_q <= wslt_d;
      rslt_q <= rslt_d;
      is_row_open_q <= is_row_open_d;
      open_row_start_address_q <= open_row_start_address_d;
      rank_delay_cnt_q <= rank_delay_cnt_d;
      wresp_release_en_onehot_o <= wresp_release_en_onehot_d;
      rdata_release_en_counters_q <= rdata_release_en_counters_d;
    end
  end

endmodule
