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
// Cost categorization: As the entropy of the cost values is very low (takes only 3 values), they are
// categorized on 2 bits to ease comparisons.
//

// TODO: Support fixed bursts.
// TODO: Multiply row width by number of ranks

module simmem_delay_calculator_core #(
    // Must be a power of two, used for address interleaving
    parameter int unsigned NumRanks = 2,

    localparam int unsigned NumRanksWidth = $clog2(NumRanks) // derived parameter
) (
    input logic clk_i,
    input logic rst_ni,

    // Write address request from the requester.
    input simmem_pkg::waddr_req_t waddr_req_i,
    // Internal identifier corresponding to the write address request (issued by the write response
    // bank).
    input simmem_pkg::write_iid_t waddr_iid_i,
    // Number of write data packets that come with the write address (which were buffered buffered by
    // the wrapper, plus potentially one coming concurrently).
    input logic [simmem_pkg::MaxWBurstLenWidth-1:0] wdata_immediate_cnt_i,

    // Write address request valid from the requester.
    input  logic waddr_valid_i,
    // Blocks the write address request if there is no slot in the delay calculator to treat it.
    output logic waddr_ready_o,

    // Write address request valid from the requester.
    input logic wdata_valid_i,

    // Write address request from the requester.
    input simmem_pkg::raddr_req_t raddr_req_i,
    // Internal identifier corresponding to the read address request (issued by the read response
    // bank).
    input simmem_pkg::read_iid_t  raddr_iid_i,

    // Read address request valid from the requester.
    input  logic raddr_valid_i,
    // Blocks the read address request if there is no read slot in the delay calculator to treat it.
    output logic raddr_ready_o,

    // Release enable output signals and released address feedback.
    output logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_release_en_onehot_o,
    output logic [ simmem_pkg::ReadDataBankCapacity-1:0] rdata_release_en_onehot_o,

    // Release confirmations sent by the message banks
    input logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_released_addr_onehot_i,
    input logic [ simmem_pkg::ReadDataBankCapacity-1:0] rdata_released_addr_onehot_i
);

  import simmem_pkg::*;

  /////////////////////////////////
  // Request cost categorization //
  /////////////////////////////////

  // Compresses the actual cost to have comparisons on fewer bits. Therefore, the ordering of the
  // values in the enumeration is important.
  typedef enum logic [1:0] {
    COST_CAS = 0,
    COST_ACTIVATION_CAS = 1,
    COST_PRECHARGE_ACTIVATION_CAS = 2,
    // Special state: if the optimal cost for all the candidates for a rank is COST_NO_CANDIDATE,
    // then it means that the set of candidates for this rank is the empty set.
    COST_NO_CANDIDATE = 3 
  } mem_cost_category_e;
  localparam int NumCostCategories = 3;
  localparam int NumCostCategoriesWidth = $clog2(NumCostCategories);

  localparam logic [GlobalMemoryCapaWidth-1:0] CostCategorizationMask = {
    {(GlobalMemoryCapaWidth - RowBufferLenWidth) {1'b1}}, {RowBufferLenWidth{1'b0}}
  };

  /**
  * Determines and compresses the cost of a request, depending on the requested address and the
  * current status of the corresponding rank.
  *
  * @param address the requested address.
  * @param is_row_open 1'b1 iff a row is currently open in the corresponding rank.
  * @param open_row_start_address the start address of the open row, if applicable.
  * @return the cost of the access, in clock cycles.
  */
  function automatic mem_cost_category_e determine_cost_category(
      logic [GlobalMemoryCapaWidth-1:0] address, logic is_row_open,
      logic [GlobalMemoryCapaWidth-1:0] open_row_start_address);
    if (is_row_open && (address & CostCategorizationMask) == (
        open_row_start_address & CostCategorizationMask)) begin
      return COST_CAS;
    end else if (!is_row_open) begin
      return COST_ACTIVATION_CAS;
    end else begin
      return COST_PRECHARGE_ACTIVATION_CAS;
    end
  endfunction : determine_cost_category

  /**
  * Decategorizes a request cost to retrieve the actual value from its category.
  *
  * @param cost_category the categorized cost.
  * @return the actual cost corresponding to this categorized cost.
  */
  function automatic logic [DelayWidth-1:0] decategorize_mem_cost(
      mem_cost_category_e cost_category);
    case (cost_category)
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
  endfunction : decategorize_mem_cost


  /////////////////////
  // Rank assignment //
  /////////////////////

  /**
  * Determines to which rank a given address is assigned. It uses the least significant bits for
  * interleaving.
  *
  * @param address the input address.
  * @return the rank index to which the address is assigned.
  */
  function automatic logic [NumRanksWidth-1:0] get_assigned_rank_id(
    logic[GlobalMemoryCapaWidth-1:0] address);
    return address[NumRanksWidth-1:0];
  endfunction : get_assigned_rank_id


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
    write_iid_t iid;  // Internal identifier (address in the response bank's RAM)
    logic v;  // Valid bit
  } w_slot_t;

  typedef struct packed {
    logic [MaxRBurstLen-1:0] mem_done;
    logic [MaxRBurstLen-1:0] mem_pending;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    read_iid_t iid;  // Internal identifier (address in the response bank's RAM)
    logic v;  // Valid bit
  } r_slot_t;

  // Slot declarations
  w_slot_t wslt_d[NumWSlots];
  w_slot_t wslt_q[NumWSlots];
  r_slot_t rslt_d[NumRSlots];
  r_slot_t rslt_q[NumRSlots];

  // Candidate signals calculation
  logic [MaxWBurstLen-1:0] is_wdata_candidate_mhot[NumRanks][NumWSlots]
  logic [MaxRBurstLen-1:0] is_rdata_candidate_mhot[NumRanks][NumRSlots]

  for (genvar i_rk; i_rk < NumRanks; i_rk = i_rk + 1) begin : candidates_outer
    for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : candidates_w_inner
      for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : candidates_w_bit
        assign is_wdata_candidate_mhot[i_rk][i_slt] = wslt_q[i_slt].data_v[i_bit] & ~wslt_q[i_slt].mem_pending[i_bit] & ~wslt_q[i_slt].mem_done[i_bit] & NumRanksWidth'(i_rk) == get_assigned_rank_id(w_addrs_per_slot[i_slt][i_bit]);
      end : candidates_w_bit
    end : candidates_w_inner
    for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : candidates_r_inner
      for (genvar i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin : candidates_r_bit
        assign is_rdata_candidate_mhot[i_rk][i_slt] = rslt_q[i_slt].data_v[i_bit] & ~rslt_q[i_slt].mem_pending[i_bit] & ~rslt_q[i_slt].mem_done[i_bit] & NumRanksRidth'(i_rk) == get_assigned_rank_id(r_addrs_per_slot[i_slt][i_bit]);
      end : candidates_r_bit
    end : candidates_r_inner
  end : candidates_outer

  // Find the next candidate read data per slot
  logic [MaxRBurstLen-1:0] nxt_rdata_per_slt_onehot[NumRanks][NumRSlots];
  
  for (genvar i_rk = 0; i_rk < NumRanks; i_rk = i_rk + 1) begin : find_rdata_outer
    for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : find_rdata
      nxt_rdata_per_slt_onehot[i_rk][i_slt][0] = is_rdata_candidate_mhot[i_rk][i_slt][0];
      for (genvar i_bit = 0; i_bit < NumRSlots; i_bit = i_bit + 1) begin : find_rdata_inner
        nxt_rdata_per_slt_onehot[i_rk][i_slt][i_bit] = is_rdata_candidate_mhot[i_rk][i_slt][i_bit];
      end : find_rdata_inner
    end : find_rdata
  end : find_rdata_outer



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

  // An age matrix cell is set at (i=lower, j=higher) iff j is older than i (if both
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
  //  TODO: Remove the write slot matrix completely
  //
  // Write slot age matrix (wslt_main_age_matrix_d/wslt_main_age_matrix_q):
  //
  // *   W W W
  // *
  // * W   x x
  // * W     x
  // * W
  //
  // Only the area marked by 'x' symbols is actually stored.
  //
  //
  // Age matrix splitting:
  //  The main age matrix cannot be split in several disjoint sub-matrices to take advantage of the
  //  partition to different ranks, because this partition is made dynamically and changes during
  //  runtime, depending on the LSBs of entries' addresses.   
  //
  // Auxiliary signals:
  //  * {main|wslt}_new_entry: Indicates whether an entry of the matrix has just been added as a candidate for a
  //    memory request. // TODO: Remove
  //  * {main|wslt}_candidate_entry: Indicates whether an entry of the matrix corresponds to a current candidate for
  //    memory request. // TODO: Remove
  //  * {main|wslt}_release_entry: Indicates whether an entry of the matrix corresponds to an entry that has
  //    been selected to run a memory request.

  // Main age matrix
  localparam MainAgeMatrixRSlotStartIndex = MaxNumWEntries + NumRSlots;

  localparam MainAgeMatrixSide = MaxNumWEntries + NumRSlots;
  localparam MainAgeMatrixSideWidth = $clog2(MainAgeMatrixSide);

  localparam MainAgeMatrixLen = MainAgeMatrixSide * (MainAgeMatrixSide - 1) / 2;
  localparam MainAgeMatrixLenWidth = $clog2(MainAgeMatrixLen);

  // Write slot age matrix
  localparam WSlotAgeMatrixLen = NumWSlots * (NumWSlots - 1) / 2;
  localparam WSlotAgeMatrixLenWidth = $clog2(WSlotAgeMatrixLen);

  // Age matrix instantiations
  logic [MainAgeMatrixLen-1:0] main_age_matrix[MainAgeMatrixLen-1:0];
  logic [WSlotAgeMatrixLen-1:0] wslt_age_matrix[WSlotAgeMatrixLen-1:0];

  // Auxiliary signals
  logic main_new_entry[MainAgeMatrixLen];
  logic wslt_new_entry[WSlotAgeMatrixLen];

  // Main age matrix management
  for (genvar i = 0; i < MainAgeMatrixSide; i = i + 1) begin : gen_main_matrix_outer
    for (genvar j = 0; j < MainAgeMatrixSide; j = j + 1) begin : gen_main_matrix_inner
      if (i < j) begin : gen_main_matrix_flop
        logic matrix_elem_q, matrix_elem_d;
        always @(posedge clk or negedge rst_ni) begin
          if (~rst_ni) begin
            matrix_elem_q <= 1'0;
          end else begin
            matrix_elem_q <= matrix_elem_d;
          end
        end
        // Matrix_elem_q is set when j is older than i
        always_comb begin
          matrix_elem_d = matrix_elem_q;
          if (main_new_entry[i]) begin
            matrix_elem_d = 1'b1;
          end
        end
        assign main_age_matrix[i][j] = matrix_elem_q;
      end else if (i == j) begin : g_matrix_diagonal
        // Diagonal always 0
        assign main_age_matrix[i][j] = 1'b0;
      end else begin
        // Mirror & invert matrix over diagonal
        assign main_age_matrix[i][j] = ~main_age_matrix[j][i];
      end
    end
  end

  // Write slot matrix management
  for (genvar i = 0; i < NumWSlots; i = i + 1) begin : gen_wslt_matrix_outer
    for (genvar j = 0; j < NumWSlots; j = j + 1) begin : gen_wslt_matrix_inner
      if (i < j) begin : gen_wslt_matrix_flop
        logic matrix_elem_q, matrix_elem_d;
        always @(posedge clk or negedge rst_ni) begin
          if (~rst_ni) begin
            matrix_elem_q <= 1'0;
          end else begin
            matrix_elem_q <= matrix_elem_d;
          end
        end
        // Matrix_elem_q is set when j is older than i
        always_comb begin
          matrix_elem_d = matrix_elem_q;
          if (wslt_new_entry[i]) begin
            matrix_elem_d = 1'b1;
          end
        end
        assign wslt_age_matrix[i][j] = matrix_elem_q;
      end else if (i == j) begin : g_matrix_diagonal
        // Diagonal always 0
        assign wslt_age_matrix[i][j] = 1'b0;
      end else begin
        // Mirror & invert matrix over diagonal
        assign wslt_age_matrix[i][j] = ~wslt_age_matrix[j][i];
      end
    end
  end

  // Conditions used for masking in main age matrix reductions
  logic [MainAgeMatrixLen-1:0] matches_cond[NumRanks][NumCostCategories];
  
  // An entry matches the conditions, for a given (rank, cost category) pair, if all of the
  // following conditions are verified:
  //  * Its current cost category corresponds to the given cost category.
  //  * It is a candidate entry for the given rank (i.e., data_v bit set, mem_pending and mem_done
  //    unset, and the entry corresponding address maps to the given rank).
  for (genvar i_rk; i_rk < NumRanks; i_rk = i_rk + 1) begin : cond_check_rnk
    for (genvar i_cat; i_cat < NumCostCategories; i_cat = i_cat + 1) begin : cond_check_cat
      // Check conditions for write data entries
      for (genvar i_wslt = 0; i_wslt < NumWSlots; i_wslt = i_wslt + 1) begin : cond_check_wslt
        for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : cond_check_wd
          matches_cond[i_rk][i_cat][i_wslt*MaxWBurstLen + i_bit] = determine_cost_category(w_addrs_per_slot[i_slt][i_bit], is_row_open_q[i_rk],
          open_row_start_address_q[i_rk]) == NumCostCategoriesWidth'(i_cat) && is_wdata_candidate_mhot[i_rk][i_slt][i_bit];
        end
      end : cond_check_wslt
      // Check conditions for read data entries
      for (genvar i_rslt = 0; i_rslt < NumRSlots; i_rslt = i_rslt + 1) begin : cond_check_rslt
        for (genvar i_rd = 0; i_rd < MaxRBurstLen; i_rd = i_rd + 1) begin : cond_check_rd
          matches_cond[i_rk][i_cat][MainAgeMatrixRSlotStartIndex + i_bit] = determine_cost_category(r_addrs_per_slot[i_slt][i_bit], is_row_open_q[i_rk],
          open_row_start_address_q[i_rk]) == NumCostCategoriesWidth'(i_cat) && is_rdata_candidate_mhot[i_rk][i_slt][i_bit];
        end : cond_check_rd
      end : cond_check_rslt
    end : cond_check_cat

    end : cond_check_cat
  end : cond_check_rnk

  // The reduction is done per rank
  // One-hot signal
  logic [MainAgeMatrixLen-1:0] oldest_entry_of_category[NumRanks][NumCostCategories];
  logic [MainAgeMatrixLen-1:0] opti_entry_onehot[NumRanks];
  logic mem_cost_category_e opti_cost_cat[NumRanks];

  // Matrix reduction
  for (genvar i_rk; i_rk < NumRanks; i_rk = i_rk + 1) begin : reduce_rnk
    for (genvar i_cat; i_cat < NumCostCategories; i_cat = i_cat + 1) begin : reduce_cat
      for (genvar i = 0; i < MainAgeMatrixLen; i = i + 1) begin : reduce_age_per_category
        assign oldest_entry_of_category[i_rk] = matches_cond[i] & ~|(main_age_matrix[i] & matches_cond);
      end
    end
    // Reduce among categories: take the lowest cost category
    always_comb begin
      if (|oldest_entry_of_category[i_rk][COST_CAS]) begin
        opti_cost_cat[i_rk] = COST_CAS;
      end else (|oldest_entry_of_category[i_rk][COST_ACTIVATION_CAS]) begin
        opti_cost_cat[i_rk] = COST_ACTIVATION_CAS;
      end else (|oldest_entry_of_category[i_rk][COST_ACTIVATION_CAS]) begin
        opti_cost_cat[i_rk] = COST_PRECHARGE_ACTIVATION_CAS;
      end else begin
        opti_cost_cat[i_rk] = COST_NO_CANDIDATE;
      end      
    end

    // Using masks, find the optimal entry
    assign opti_entry_onehot = oldest_entry_of_category[i_rk][COST_CAS] | (oldest_entry_of_category[i_rk][COST_ACTIVATION_CAS] & {MainAgeMatrixLen{|oldest_entry_of_category[i_rk][COST_CAS]}}) | (oldest_entry_of_category[i_rk][COST_PRECHARGE_ACTIVATION_CAS] & {MainAgeMatrixLen{|oldest_entry_of_category[i_rk][COST_CAS]}} & {MainAgeMatrixLen{|oldest_entry_of_category[i_rk][COST_ACTIVATION_CAS]}});
  end


  //////////////////////////////////////////
  // Find next slot where write data fits //
  //////////////////////////////////////////

  // In this part, the signals indicating in which slot and in which write data entry, a new write
  // data request should fit. If there is no candidate, then refuse incoming write data requests
  // (they will be counted by the delay counter wrapper).
  //
  // The chosen write slot is the oldest occupied write slot whose write data entries are not all
  // valid, if applicable.

  // Slot where the data should fit (binary representation).
  logic [NumWSlotsWidth-1:0] free_w_slot_for_data_mhot;
  logic [NumWSlotsWidth-1:0] free_w_slot_for_data_onehot;
  // First non-valid bit in the write slot, for each slot.
  logic [MaxWBurstLen-1:0] nxt_nv_bit_onehot[NumWSlots];

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

  // Find the oldest slot where data is expected
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_wslot_for_in_data_onehot
    assign free_w_slot_for_data_mhot[i_slt] = wslt_q[i_slt].v & ~&(wslt_q[i_slt].data_v);
    assign free_w_slot_for_data_onehot[i_slt] = free_w_slot_for_data_mhot[i_slt] & ~|(wslt_age_matrix[i_slt] & free_w_slot_for_data_mhot);
  end : gen_wslot_for_in_data_mhot


  //////////////////////////////////
  // Address calculation in slots //
  //////////////////////////////////

  // In this part, the address corresponding to each entry in each write slot and read slot is
  // calculated from the slot burst base address and burst size.
  // As bursts are aligned, only few bits change between bits of the same burst.

  localparam int unsigned BurstAddrLSBs = 12;

  // Addresses of slot entries.
  logic [GlobalMemoryCapaWidth-1:0] w_addrs_per_slot[NumWSlots-1:0][MaxWBurstLen-1:0];
  logic [GlobalMemoryCapaWidth-1:0] r_addrs_per_slot[NumRSlots-1:0][MaxRBurstLen-1:0];

  // Least significant bits of the addresses.
  logic [BurstAddrLSBs-1:0] w_addrs_lsb_per_slot[NumWSlots-1:0][MaxWBurstLen-1:0];
  logic [BurstAddrLSBs-1:0] r_addrs_lsb_per_slot[NumRSlots-1:0][MaxRBurstLen-1:0];

  // Write data entries address.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_w_addrs
    assign w_addrs_lsb_per_slot[i_slt][0] = wslt_q[i_slt].addr;
    for (genvar i_bit = 1; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : gen_w_addrs_per_slt
      assign w_addrs_lsb_per_slot[i_slt][i_bit] = wslt_q[i_slt].addr +
          BurstAddrLSBs'(w_addrs_lsb_per_slot[i_slt][i_bit - 1] + wslt_q[i_slt].burst_size);
    end : gen_w_addrs_per_slt
  end : gen_w_addrs

  // Read data entries address.
  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_r_addrs
    assign r_addrs_lsb_per_slot[i_slt][0] = rslt_q[i_slt].addr;
    for (genvar i_bit = 1; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin : gen_r_addrs_per_slt
      assign r_addrs_lsb_per_slot[i_slt][i_bit] = rslt_q[i_slt].addr +
          BurstAddrLSBs'(r_addrs_lsb_per_slot[i_slt][i_bit - 1] + rslt_q[i_slt].burst_size);
    end : gen_r_addrs_per_slt
  end : gen_r_addrs

  // Concatenate the MSBs of the base address with the LSBs of each entry to form the whole entries' addresses.
  assign w_addrs_per_slot = {
    wslt_q[i_slt].addr[GlobalMemoryCapaWidth - 1:BurstAddrLSBs],
    w_addrs_lsb_per_slot[BurstAddrLSBs - 1:0]
  };
  assign r_addrs_per_slot = {
    rslt_q[i_slt].addr[GlobalMemoryCapaWidth - 1:BurstAddrLSBs],
    r_addrs_lsb_per_slot[BurstAddrLSBs - 1:0]
  };


  //////////////////
  // Rank signals //
  //////////////////

  // The ranks are simulated by mere counters. These counters are set to a given request cost and
  // constantly decremented to zero.

  // Determines if there is a row open in the rank. So far, this is always true after the first
  // request.
  logic is_row_open_d[NumRanks];
  logic is_row_open_q[NumRanks];

  // Determines the start address of the open row. This is useful for request cost calculation. If
  // no row is open in the rank, then this value is irrelevant.
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_d[NumRanks];
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_q[NumRanks];

  // Decreasing counter that determines the number of cycles in which the rank will be able to take
  // a new request.
  logic [DelayWidth-1:0] rank_delay_cnt_d[NumRanks];
  logic [DelayWidth-1:0] rank_delay_cnt_q[NumRanks];


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
    for (int unsigned i_rk = 0; i_rk < NumWSlots; i_rk = i_rk + 1) begin
      is_row_open_d[i_rk] = is_row_open_q[i_rk];
      open_row_start_address_d[i_rk] = open_row_start_address_q[i_rk];
    end

    wresp_release_en_onehot_d = wresp_release_en_onehot_o;
    rdata_release_en_counters_d = rdata_release_en_counters_q;

    main_new_entry = '{default: '0};
    wslt_new_entry = '{default: '0};
    // main_candidate_entry = '{default: '0}; // TODO: double-check: is the signal useful?
    // main_release_entry = '{default: '0};

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

        // Update the write slot age matrix.
        wslt_new_entry[i_slt] = 1'b1;
        
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
          
          main_new_entry[i_slt * MaxWBurstLen+i_bit] = 1'b1;
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

        main_new_entry[MainAgeMatrixRSlotStartIndex + i_slt] = 1'b1;
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
            wdata_valid_i) begin
          // The data_v signal is OR-masked with a mask determining where the new data should land.
          // Most of the times, the mask is full-zero, as there is no write data input handshake or
          // because this is not the slot where the write data where it should land.

          wslt_d[i_slt].data_v[i_bit] = 1'b1;
          main_new_entry[i_slt * MaxWBurstLen+i_bit] = 1'b1;
        end
      end
    end


    /////////////////////////
    // Rank counter update //
    /////////////////////////

    // This part is dedicated to updating the rank counters.

    // If the rank counter is zero, then simply decrement it.
    for (int unsigned i_rnk = 0; i_rnk < NumWSlots; i_rnk = i_rnk + 1) begin
      if (rank_delay_cnt_q[i_rnk] != 0) begin
        rank_delay_cnt_d[i_rnk] = rank_delay_cnt_q[i_rnk] - 1;
      end else begin
        rank_delay_cnt_d[i_rnk] = decategorize_mem_cost(opti_cost_cat[i_rnk]);

        // Set the memory pending bit in the case of a write data entry
        for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
          for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
            wslt_d[i_slt].mem_pending[i_bit] |= opti_entry_onehot[i_rk][i_slt*MaxWBurstLen + i_bit];
          end
        end
        // Set the memory pending bit in the case of a read data entry
        for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
          for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
            rslt_d[i_slt].mem_pending[i_bit] |= opti_entry_onehot[i_rk][i_slt*MaxWBurstLen + i_bit];
          end
        end

        is_row_open_d[i_rnk] = 0;
        
        // If serve_w is set, then it is certain that there is at least one request for the rank to
        // treat, and that this optimal entry is among the write data entries.
        if (serve_w) begin
          // Decompress the cost representation to obtain the real cost.
          rank_delay_cnt_d[i_rnk] = decategorize_mem_cost(opti_w_cost);

          // Set the mem_pending bit of the optimal entry to one, as its treatment is starting.
          for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
            for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
              wslt_d[i_slt].mem_pending[i_bit] |= opti_w_valid_per_slot[i_slt] && opti_w_bit_per_slot[
                  i_slt] == MaxWBurstLenWidth'(i_bit) && opti_w_slot == NumWSlotsWidth'(i_slt);
            end
          end
          // A row is now opening or open in the corresponding rank. 
          is_row_open_d = 1'b1;
        end else if (!serve_w && opti_r_slot_valid) begin
          // Decompress the cost representation to obtain the real cost.
          rank_delay_cnt_d[i_rnk] = decategorize_mem_cost(opti_r_cost);

          // Set the mem_pending bit of the optimal entry to one, as its treatment is starting.
          for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
            for (int unsigned i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin
              rslt_d[i_slt].mem_pending[i_bit] |= opti_r_valid_per_slot[i_slt] && opti_r_bit_per_slot[
                  i_slt] == MaxRBurstLenWidth'(i_bit) && opti_r_slot == NumRSlotsWidth'(i_slt);
            end
          end
          // A row is now opening or open in the corresponding rank. 
          is_row_open_d = 1'b1;
        end else begin
          // If there is no request to serve, then the counter remains 0.
          rank_delay_cnt_d[i_rnk] = 0;
        end
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
      is_row_open_q <= '{default: '0};
      open_row_start_address_q <= '{default: '0};
      rank_delay_cnt_q <= '{default: '0};
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
