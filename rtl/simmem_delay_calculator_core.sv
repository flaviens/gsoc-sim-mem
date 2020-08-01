// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FUTURE: Add support for wrap bursts
// FUTURE: Improve implementation by using reductions
// FUTURE: Should we gate the changes to the age matrix

module simmem_delay_calculator_core (
  input logic clk_i,
  input logic rst_ni,
  
  // Write address
  input logic [simmem_pkg::WriteRespBankAddrWidth-1:0] waddr_iid_i,
  input simmem_pkg::waddr_req_t waddr_req_i,
  // Number of write data packets that came with the write address
  input logic [simmem_pkg::MaxWBurstLenWidth-1:0] wdata_immediate_cnt_i,
  input logic waddr_valid_i,
  output logic waddr_ready_o,

  // Write data
  input logic wdata_valid_i,
  output logic wdata_ready_o,

  // Read address
  input logic [simmem_pkg::ReadDataBankAddrWidth-1:0] raddr_iid_i,
  input simmem_pkg::raddr_req_t raddr_req_i,
  input logic raddr_valid_i,
  output logic raddr_ready_o,

  // Release enable output signals and released address feedback
  output logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_release_en_onehot_o,
  output logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_release_en_onehot_o,

  input  logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_released_addr_onehot_i,
  input  logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_released_addr_onehot_i
);

  import simmem_pkg::*;

  // Compresses the actual cost to have min reductions on fewer bits
  typedef enum logic [1:0]{
    COST_CAS = 0,
    COST_ACTIVATION_CAS = 1,
    COST_PRECHARGE_ACTIVATION_CAS = 2
  } mem_compressed_cost_e;

  function automatic mem_compressed_cost_e determine_compressed_cost(
      logic [GlobalMemoryCapaWidth-1:0] address, logic is_row_open,
      logic [GlobalMemoryCapaWidth-1:0] open_row_start_address);
    logic [GlobalMemoryCapaWidth-1:0] mask;
    mask = {{(GlobalMemoryCapaWidth - RowBufferLenWidth) {1'b1}}, {RowBufferLenWidth{1'b0}}};
    if (is_row_open && (address & mask) == (open_row_start_address & mask)) begin
      return COST_CAS;
    end else if (!is_row_open) begin
      return COST_ACTIVATION_CAS;
    end else begin
      return COST_PRECHARGE_ACTIVATION_CAS;
    end
  endfunction : determine_compressed_cost

  // Takes a compressed cost and outputs the actual cost in cycles
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

  localparam NumWSlots = 6;
  localparam NumWSlotsWidth = $clog2(NumWSlots);
  localparam NumRSlots = 6;
  localparam NumRSlotsWidth = $clog2(NumRSlots);

  localparam MaxNumWEntries = NumWSlots * MaxWBurstLen;

  // Age matrix constants
  localparam AgeMatrixWSlotStartIndex = MaxNumWEntries;
  localparam AgeMatrixRSlotStartIndex = AgeMatrixWSlotStartIndex + NumRSlots;

  localparam AgeMatrixSide = MaxNumWEntries + NumWSlots + NumRSlots;
  localparam AgeMatrixSideWidth = $clog2(AgeMatrixSide);

  localparam AgeMatrixLen = AgeMatrixSide * (AgeMatrixSide-1) / 2;
  localparam AgeMatrixLenWidth = $clog2(AgeMatrixLen);

  // Slot type definition

  typedef struct packed {
    logic [MaxWBurstLen-1:0] mem_done;
    logic [MaxWBurstLen-1:0] mem_pending;
    logic [MaxWBurstLen-1:0] data_v;  // Data valid
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [WriteRespBankAddrWidth-1:0]
        iid;  // Internal identifier (address in the memory bank's RAM)
    logic v;  // Valid bit
  } w_slot_t;

  typedef struct packed {
    logic [MaxRBurstLen-1:0] mem_done;
    logic [MaxRBurstLen-1:0] mem_pending;
    logic [MaxRBurstLen-1:0] data_v;  // Data valid
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [ReadDataBankAddrWidth-1:0]
        iid;  // Internal identifier (address in the memory bank's RAM)
    logic v;  // Valid bit
  } r_slot_t;

  // Slot management

  w_slot_t w_slt_d[NumWSlots];
  w_slot_t w_slt_q[NumWSlots];
  r_slot_t r_slt_d[NumRSlots];
  r_slot_t r_slt_q[NumRSlots];

  logic [NumWSlots-1:0] free_w_slt_mhot;
  logic [NumWSlots-1:0] nxt_free_w_slot_onehot;
  logic [NumRSlots-1:0] free_r_slt_mhot;
  logic [NumRSlots-1:0] nxt_free_r_slot_onehot;

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_nxt_free_w_slot
    assign free_w_slt_mhot[i_slt] = ~w_slt_q[i_slt].v;
    if (i_slt == 0) begin
      assign nxt_free_w_slot_onehot[0] = free_w_slt_mhot[0];
    end else begin
      assign
          nxt_free_w_slot_onehot[i_slt] = free_w_slt_mhot[i_slt] && !|free_w_slt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_w_slot

  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_nxt_free_r_slot
    assign free_r_slt_mhot[i_slt] = ~r_slt_q[0].v;
    if (i_slt == 0) begin
      assign nxt_free_r_slot_onehot[0] = free_r_slt_mhot[0];
    end else begin
      assign
          nxt_free_r_slot_onehot[i_slt] = free_r_slt_mhot[i_slt] && !|free_r_slt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_r_slot

  assign waddr_ready_o = |nxt_free_w_slot_onehot;
  assign raddr_ready_o = |nxt_free_r_slot_onehot;

  // Age matrix

  logic [AgeMatrixLen-1:0] age_matrix_d;
  logic [AgeMatrixLen-1:0] age_matrix_q;

  // Age matrix is 1 at (x=higher, y=lower) iff higher is older than lower (if both entries/slots
  // valid, else value is irrelevant).

  // lower, higher
  function automatic logic[AgeMatrixLenWidth-1:0] get_age_matrix_entry_coord(logic [AgeMatrixSideWidth-1:0] lower_coord,
      logic [AgeMatrixSideWidth-1:0] higher_coord);
      assert (lower_coord < higher_coord);

    return AgeMatrixLenWidth'(higher_coord) + lower_coord * AgeMatrixLen;
  endfunction : get_age_matrix_entry_coord

  /**
  * Checks in the age matrix whether the write entry pointed by the higher identifier is older than the
  * other.
  *
  * @param w_slt the slot in which to check
  * @param i_lower_bit the lower entry identifier
  * @param i_higher_bit the higher entry identifier
  * @return 1'b1 iff the lower entry is older.
  */
  function automatic logic is_higher_w_entry_older(logic [NumWSlotsWidth-1:0] w_slt,
                                                   logic [MaxWBurstLenWidth-1:0] i_lower_bit,
                                                   logic [MaxWBurstLenWidth-1:0] i_higher_bit);
    return age_matrix_q[get_age_matrix_entry_coord(AgeMatrixSideWidth'(w_slt * NumWSlotsWidth) + AgeMatrixSideWidth'(i_lower_bit),
                                                   AgeMatrixSideWidth'(w_slt * NumWSlotsWidth) + AgeMatrixSideWidth'(i_higher_bit))];
  endfunction : is_higher_w_entry_older

  function automatic logic is_higher_w_slot_older(logic [NumWSlotsWidth-1:0] w_lower_slt,
                                                  logic [NumWSlotsWidth-1:0] w_higher_slt);
    return age_matrix_q[get_age_matrix_entry_coord(AgeMatrixSideWidth'(AgeMatrixWSlotStartIndex) + AgeMatrixSideWidth'(w_lower_slt),
                                                   AgeMatrixSideWidth'(AgeMatrixWSlotStartIndex) + AgeMatrixSideWidth'(w_higher_slt))];
  endfunction : is_higher_w_slot_older

  function automatic logic is_higher_r_slot_older(logic [NumRSlotsWidth-1:0] r_lower_slt,
                                                  logic [NumRSlotsWidth-1:0] r_higher_slt);
    return age_matrix_q[get_age_matrix_entry_coord(AgeMatrixSideWidth'(AgeMatrixRSlotStartIndex) + AgeMatrixSideWidth'(r_lower_slt),
        AgeMatrixSideWidth'(AgeMatrixRSlotStartIndex) + AgeMatrixSideWidth'(r_higher_slt))];
  endfunction : is_higher_r_slot_older

  function automatic logic is_r_slot_older(logic [NumWSlotsWidth-1:0] w_slt,
    logic [NumRSlotsWidth-1:0] r_slt);
      return age_matrix_q[get_age_matrix_entry_coord(AgeMatrixSideWidth'(AgeMatrixWSlotStartIndex) + AgeMatrixSideWidth'(w_slt),
    AgeMatrixSideWidth'(AgeMatrixRSlotStartIndex) + AgeMatrixSideWidth'(r_slt))];
  endfunction : is_r_slot_older

  function automatic logic update_age_matrix_on_input(logic [AgeMatrixSideWidth-1:0] input_coord,
    ref logic [AgeMatrixLen-1:0] age_matrix);
    for (logic [AgeMatrixSideWidth-1:0] k = 0; k < AgeMatrixSide; k++) begin
      if (k < input_coord) begin
        age_matrix[get_age_matrix_entry_coord(k, input_coord)] = 1'b0;
      end else if (k > input_coord) begin
        age_matrix[get_age_matrix_entry_coord(input_coord, k)] = 1'b1;
      end
    end
  endfunction : update_age_matrix_on_input

  // Signals to accept new write data

  logic [NumWSlotsWidth-1:0] free_w_slot_for_data;
  logic [MaxWBurstLen-1:0] nxt_nv_bit_onehot[NumWSlots];  // First non-valid bit  

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_slot_for_in_data
    for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : gen_nxt_nv_bit_inner
      if (i_bit == 0) begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] = ~w_slt_q[i_slt].data_v[0];
      end else begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] =
            ~w_slt_q[i_slt].data_v[i_bit] && &w_slt_q[i_slt].data_v[i_bit - 1:0];
      end
    end : gen_nxt_nv_bit_inner
  end : gen_slot_for_in_data

  // TODO: Improve the age matrix reduction
  always_comb begin : gen_oldest_data_in_candidate
    logic is_opti_valid = 1'b0;
    free_w_slot_for_data = '0;

    for (logic [NumWSlotsWidth-1:0] i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      if (w_slt_q[i_slt].v && !&(w_slt_q[i_slt].data_v) && (
          !is_opti_valid || is_higher_w_slot_older(free_w_slot_for_data, i_slt))) begin
        is_opti_valid = 1'b1;
        free_w_slot_for_data = i_slt;
      end
    end
  end : gen_oldest_data_in_candidate

  assign wdata_ready_o = |free_w_slot_for_data;


  // Generate the addresses for all the data

  logic [GlobalMemoryCapaWidth-1:0] w_addrs_per_slot[NumWSlots-1:0][MaxWBurstLen-1:0];
  logic [GlobalMemoryCapaWidth-1:0] r_addrs_per_slot[NumRSlots-1:0][MaxRBurstLen-1:0];

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_w_addrs
    for (genvar i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin : gen_w_addrs_per_slt
      assign
          w_addrs_per_slot[i_slt][i_bit] = w_slt_q[i_slt].addr + i_bit * w_slt_q[i_slt].burst_size;
    end : gen_w_addrs_per_slt
  end : gen_w_addrs

  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_r_addrs
    for (genvar i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin : gen_r_addrs_per_slt
      assign
          r_addrs_per_slot[i_slt][i_bit] = r_slt_q[i_slt].addr + i_bit * r_slt_q[i_slt].burst_size;
    end : gen_r_addrs_per_slt
  end : gen_r_addrs


  // Select the optimal address for each slot

  logic [MaxWBurstLenWidth-1:0] opti_w_bit_per_slot[NumWSlots];
  logic [MaxRBurstLenWidth-1:0] opti_r_bit_per_slot[NumRSlots];

  mem_compressed_cost_e opti_w_cost_per_slot[NumWSlots];
  mem_compressed_cost_e opti_r_cost_per_slot[NumRSlots];

  logic opti_w_valid_per_slot[NumWSlots];
  logic opti_r_valid_per_slot[NumRSlots];

  // Reduce per slot

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_opti_w_addrs_per_slt
    always_comb begin : gen_opti_w_cost_per_slot

      mem_compressed_cost_e curr_cost;
      
      opti_w_bit_per_slot = '0;
      opti_w_valid_per_slot[i_slt] = 1'b0;
      opti_w_cost_per_slot[i_slt] = ~'0;

      for (logic [MaxWBurstLenWidth-1:0] i_bit = 0; 32'(i_bit) < MaxWBurstLen; i_bit = i_bit + 1) begin
        curr_cost = determine_compressed_cost(w_addrs_per_slot[i_slt][i_bit], is_row_open_q,
                                              open_row_start_address_q);

        // opti_w_valid_per_slot[i_slt] = opti_w_valid_per_slot[i_slt] || (w_slt_q[i_slt].data_v[i_bit] && !w_slt_q[i_slt
        //                                   ].mem_pending[i_bit] && !w_slt_q[i_slt].mem_done[i_bit]);

        if ((w_slt_q[i_slt].data_v[i_bit] && !w_slt_q[i_slt].mem_pending[i_bit] &&
             !w_slt_q[i_slt].mem_done[i_bit]) &&
            (!opti_w_valid_per_slot[i_slt] || curr_cost < opti_w_cost_per_slot[i_slt] || (
             curr_cost == opti_w_cost_per_slot[i_slt] && is_higher_w_entry_older(i_slt, opti_w_bit_per_slot, i_bit)))) begin
          opti_w_valid_per_slot[i_slt] = 1'b1;
          opti_w_cost_per_slot[i_slt] = curr_cost;
          opti_w_bit_per_slot[i_slt] = i_bit;
        end
      end
    end : gen_opti_w_cost_per_slot
  end : gen_opti_w_addrs_per_slt

  // For read requests, individual age for each element in the burst would be irrelevant, as
  // the read request comes as a whole.
  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_opti_r_addrs_per_slt
    always_comb begin : gen_opti_r_cost_per_slot
      mem_compressed_cost_e curr_cost;
      
      opti_r_bit_per_slot = '0;
      opti_r_valid_per_slot[i_slt] = 1'b0;
      opti_r_cost_per_slot[i_slt] = ~'0;

      for (logic [MaxRBurstLenWidth-1:0] i_bit = 0; 32'(i_bit) < MaxRBurstLen; i_bit = i_bit + 1) begin
        curr_cost = determine_compressed_cost(r_addrs_per_slot[i_slt][i_bit], is_row_open_q,
                                              open_row_start_address_q);

        // opti_r_valid_per_slot[i_slt] = opti_r_valid_per_slot[i_slt] || (r_slt_q[i_slt].data_v[i_bit] && !r_slt_q[i_slt
        //                                   ].mem_pending[i_bit] && !r_slt_q[i_slt].mem_done[i_bit]);

        if ((r_slt_q[i_slt].data_v[i_bit] && !r_slt_q[i_slt].mem_pending[i_bit] && !r_slt_q[
             i_slt].mem_done[i_bit]) && (!opti_r_valid_per_slot[i_slt] || curr_cost < opti_r_cost_per_slot[i_slt])
            ) begin
          opti_r_valid_per_slot[i_slt] = 1'b1;
          opti_r_cost_per_slot[i_slt] = curr_cost;
          opti_r_bit_per_slot[i_slt] = i_bit;
        end
      end
    end : gen_opti_r_cost_per_slot
  end : gen_opti_r_addrs_per_slt


  // Reduce among slots

  logic [NumWSlotsWidth-1:0] opti_w_slot;
  logic [NumRSlotsWidth-1:0] opti_r_slot;

  logic opti_w_slot_valid;
  logic opti_r_slot_valid;
  mem_compressed_cost_e opti_w_cost;
  mem_compressed_cost_e opti_r_cost;

  always_comb begin : gen_opti_slot
    mem_compressed_cost_e curr_cost;

    opti_w_slot_valid = 1'b0;
    opti_r_slot_valid = 1'b0;
    opti_w_cost = '0;
    opti_r_cost = '0;

    // Writes
    for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_w_cost_per_slot[i_slt];
      if ((w_slt_q[i_slt].v && opti_w_valid_per_slot[i_slt]) && (
          !opti_w_slot_valid || curr_cost < opti_w_cost || (
              curr_cost == opti_w_cost && is_higher_w_slot_older(opti_w_slot, i_slt)))) begin
        opti_w_slot = i_slt[$clog2(NumWSlots) - 1:0];
        opti_w_cost = curr_cost;
      end
      opti_w_slot_valid =
          opti_w_slot_valid || (w_slt_q[i_slt].v && opti_w_valid_per_slot[i_slt]);
    end

    // Reads
    for (logic [NumRSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumRSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_r_cost_per_slot[i_slt];
      if ((r_slt_q[i_slt].v && opti_r_valid_per_slot[i_slt]) && (
          !opti_r_slot_valid || curr_cost < opti_r_cost || (
              curr_cost == opti_r_cost && is_higher_r_slot_older(opti_r_slot, i_slt)))) begin
        opti_r_slot = i_slt[$clog2(NumRSlots) - 1:0];
        opti_r_cost = curr_cost;
      end
      opti_r_slot_valid =
          opti_r_slot_valid || (r_slt_q[i_slt].v && opti_r_valid_per_slot[i_slt]);
    end
  end : gen_opti_slot

  // Select between read and write

  logic serve_w;

  assign serve_w = opti_w_slot_valid && (!opti_r_slot_valid || opti_w_cost < opti_r_cost || (
                                         opti_w_cost == opti_r_cost && !is_r_slot_older(opti_w_slot, opti_r_slot)));

  // Rank signals
  logic is_row_open_d;
  logic is_row_open_q;

  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_d;
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_q;

  logic [DelayWidth-1:0] rank_delay_cnt_d;
  logic [DelayWidth-1:0] rank_delay_cnt_q;

  // Outputs
  logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_release_en_onehot_d;
  logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_release_en_onehot_d;

  // Delay calculator management logic
  always_comb begin : del_calc_mgmt_comb

    is_row_open_d = is_row_open_q;
    open_row_start_address_d = open_row_start_address_q;
    wresp_release_en_onehot_d = wresp_release_en_onehot_o;
    rdata_release_en_onehot_d = rdata_release_en_onehot_o;

    // Write slot input
    for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
      w_slt_d[i_slt] = w_slt_q[i_slt];

      if (waddr_valid_i && waddr_ready_o && nxt_free_w_slot_onehot[i_slt]) begin
        w_slt_d[i_slt].v = 1'b1;
        w_slt_d[i_slt].iid = waddr_iid_i;
        w_slt_d[i_slt].addr = waddr_req_i.addr;
        w_slt_d[i_slt].burst_size = waddr_req_i.burst_size;
        w_slt_d[i_slt].mem_pending = '0;

        // FUTURE: Implement support for wrap burst here and in the read slot input

        for (logic [MaxWBurstLenWidth-1:0] i_bit = 0; 32'(i_bit) < MaxWBurstLen; i_bit = i_bit + 1) begin
          w_slt_d[i_slt].data_v[i_bit] =
              (AxLenWidth'(i_bit) >= waddr_req_i.burst_length) || (i_bit < wdata_immediate_cnt_i);
          w_slt_d[i_slt].mem_done[i_bit] = AxLenWidth'(i_bit) >= waddr_req_i.burst_length;
          update_age_matrix_on_input(AgeMatrixSideWidth'(i_slt * NumWSlots) + AgeMatrixSideWidth'(i_bit), age_matrix_d);
        end
      end
    end

    // Read slot input
    for (logic [NumRSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumRSlots; i_slt = i_slt + 1) begin
      r_slt_d[i_slt] = r_slt_q[i_slt];

      if (raddr_valid_i && raddr_ready_o && nxt_free_r_slot_onehot[i_slt]) begin
        r_slt_d[i_slt].v = 1'b1;
        r_slt_d[i_slt].iid = raddr_iid_i;
        r_slt_d[i_slt].addr = raddr_req_i.addr;
        r_slt_d[i_slt].burst_size = raddr_req_i.burst_size;
        r_slt_d[i_slt].mem_pending = '0;

        for (logic [MaxRBurstLenWidth-1:0] i_bit = 0; 32'(i_bit) < MaxRBurstLen; i_bit = i_bit + 1) begin
          r_slt_d[i_slt].data_v[i_bit] = AxLenWidth'(i_bit) >= raddr_req_i.burst_length;
          r_slt_d[i_slt].mem_done[i_bit] = AxLenWidth'(i_bit) >= raddr_req_i.burst_length;
        end

        // Done only once per read slot
        update_age_matrix_on_input(AgeMatrixSideWidth'(AgeMatrixRSlotStartIndex)+AgeMatrixSideWidth'(i_slt), age_matrix_d);
      end
    end

    // Acceptance of new write data
    for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
      // The one-hot signal is expanded bit by bit to act as a mask.
      w_slt_d[i_slt].data_v = w_slt_d[i_slt].data_v | (
          nxt_nv_bit_onehot[i_slt] & {
              MaxWBurstLen{free_w_slot_for_data == i_slt && wdata_valid_i && wdata_ready_o}});
      for (logic [MaxWBurstLenWidth-1:0] i_bit = 0; 32'(i_bit) < MaxWBurstLen; i_bit = i_bit + 1) begin
        if (nxt_nv_bit_onehot[i_slt][i_bit]) begin
          update_age_matrix_on_input(AgeMatrixSideWidth'(i_slt * NumWSlots) + AgeMatrixSideWidth'(i_bit), age_matrix_d);
        end
      end
    end

    // Update of the rank counter
    if (rank_delay_cnt_q == 0) begin
      // If there is a request to serve
      if (serve_w) begin
        rank_delay_cnt_d = decompress_mem_cost(opti_w_cost);

        for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
          w_slt_d[i_slt].mem_pending |= opti_w_bit_per_slot == i_slt && {
              MaxWBurstLen{opti_w_slot == i_slt[$clog2(NumWSlots) - 1:0]}};
        end
        is_row_open_d = 1'b1;
      end else if (!serve_w && opti_r_slot_valid) begin
        rank_delay_cnt_d = decompress_mem_cost(opti_r_cost);

        for (logic [NumRSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumRSlots; i_slt = i_slt + 1) begin
          r_slt_d[i_slt].mem_pending |= opti_r_bit_per_slot == i_slt && {
              MaxWBurstLen{opti_r_slot == i_slt[$clog2(NumRSlots) - 1:0]}};
        end
        is_row_open_d = 1'b1;
      end else begin
        // If there is no request to serve, then the counter remains 0.
        rank_delay_cnt_d = 0;
      end
    end else begin
      rank_delay_cnt_d = rank_delay_cnt_q - 1;
    end

    // Updated at delay 3 to accommodate the one-cycle additional latency due to the response bank
    if (rank_delay_cnt_q == 3) begin
      for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done
        w_slt_d[i_slt].mem_done = w_slt_q[i_slt].mem_done | w_slt_q[i_slt].mem_pending;
        w_slt_d[i_slt].mem_pending = '0;
      end
      for (logic [NumRSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumRSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done
        r_slt_d[i_slt].mem_done = r_slt_q[i_slt].mem_done | r_slt_q[i_slt].mem_pending;
        r_slt_d[i_slt].mem_pending = '0;
      end
    end

    // Input signals from message banks about released signals
    wresp_release_en_onehot_d ^= wresp_released_addr_onehot_i;
    rdata_release_en_onehot_d ^= rdata_released_addr_onehot_i;

    // Outputs and entry flushing
    for (logic [NumWSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumWSlots; i_slt = i_slt + 1) begin
      w_slt_d[i_slt].v &= !&w_slt_q[i_slt].mem_done;
      // If all the memory requests of a burst have been satisfied
      for (int unsigned i_iid = 0; i_iid < WriteRespBankCapacity; i_iid = i_iid + 1) begin
        // Updatae the output signal to 
        wresp_release_en_onehot_d[i_iid] |= w_slt_q[i_slt].v && &w_slt_q[i_slt].mem_done &&
            w_slt_q[i_slt].iid == i_iid[WriteRespBankAddrWidth - 1:0];
      end
    end
    for (logic [NumRSlotsWidth-1:0] i_slt = 0; 32'(i_slt) < NumRSlots; i_slt = i_slt + 1) begin
      r_slt_d[i_slt].v &= !&r_slt_q[i_slt].mem_done;
      // If all the memory requests of a burst have been satisfied
      for (int unsigned i_iid = 0; i_iid < ReadDataBankCapacity; i_iid = i_iid + 1) begin
        // Updatae the output signal to 
        rdata_release_en_onehot_d[i_iid] |= r_slt_q[i_slt].v && &r_slt_q[i_slt].mem_done &&
            r_slt_q[i_slt].iid == i_iid[ReadDataBankAddrWidth - 1:0];
      end
    end
  end : del_calc_mgmt_comb


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      age_matrix_q <= '0;
      w_slt_q <= '{default: '0};
      r_slt_q <= '{default: '0};
      is_row_open_q <= 1'b0;
      open_row_start_address_q <= '0;
      rank_delay_cnt_q <= '0;
      wresp_release_en_onehot_o <= '0;
      rdata_release_en_onehot_o <= '0;
    end else begin
      age_matrix_q <= age_matrix_d;
      w_slt_q <= w_slt_d;
      r_slt_q <= r_slt_d;
      is_row_open_q <= is_row_open_d;
      open_row_start_address_q <= open_row_start_address_d;
      rank_delay_cnt_q <= rank_delay_cnt_d;
      wresp_release_en_onehot_o <= wresp_release_en_onehot_d;
      rdata_release_en_onehot_o <= rdata_release_en_onehot_d;
    end
  end

endmodule
