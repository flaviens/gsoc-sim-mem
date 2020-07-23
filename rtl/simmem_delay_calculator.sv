// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// TODO: Add the management of read data

module simmem_delay_calculator (
  // input logic clk_i,
  // input logic rst_ni,
  
  // Write address
  input logic [simmem_pkg::WriteRespBankAddrWidth-1:0] waddr_iid_i,
  input simmem_pkg::waddr_req_t waddr_req_i,
  // Number of write data packets that came with the write address
  input logic [simmem_pkg::MaxWBurstLen] wdata_immediate_cnt_i,
  input logic waddr_valid_i,
  output logic waddr_ready_o,

  // Write data
  input logic wdata_v_i,
  output logic wdata_ready_o,

  // Read address
  input logic [simmem_pkg::ReadDataBankAddrWidth-1:0] raddr_iid_i,
  input simmem_pkg::raddr_req_t raddr_req_i,
  input logic raddr_valid_i,
  output logic raddr_ready_o,

  // Release enable output signals and released address feedback
  output logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_release_en_o,
  output logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_release_en_o,

  input  logic [simmem_pkg::WriteRespBankCapacity-1:0] wresp_released_addr_onehot_i,
  input  logic [simmem_pkg::ReadDataBankCapacity-1:0] rdata_released_addr_onehot_i
);

  import simmem_pkg::*;

  function automatic logic [DelayWidth-1:0] determine_cost(logic [GlobalMemoryCapaWidth-1:0] address, logic is_row_open, logic [GlobalMemoryCapaWidth-1:0] open_row_start_address);
    logic [GlobalMemoryCapaWidth-1:0] mask;
    mask = {{(GlobalMemoryCapaWidth-RowBufferLenWidth){1'b0}}, {RowBufferLenWidth{1'b1}}};
    if (is_row_open && address&mask == open_row_start_address&mask) begin
      return RowHitCost;
    end else if (!is_row_open) begin
      return RowHitCost+ActivationCost;
    end else begin
      return RowHitCost+ActivationCost+PrechargeCost;      
    end
  endfunction : determine_cost

  localparam NumWSlots = 6;
  localparam NumRSlots = 6;

  typedef struct packed {
    logic [MaxWBurstLen-1:0] mem_done;
    logic [MaxWBurstLen-1:0] mem_pending;
    logic [MaxWBurstLen-1:0] data_v;  // Data valid
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [TimestampWidth-1:0] timestamp;  // Useful for selecting oldest first
    logic [WriteRespBankAddrWidth-1:0] iid; // Internal identifier (address in the memory bank's RAM)
    logic v; // Valid bit
  } w_slot_t;

  typedef struct packed {
    logic [MaxRBurstLen-1:0] mem_done;
    logic [MaxRBurstLen-1:0] mem_pending;
    logic [MaxRBurstLen-1:0] data_v;  // Data valid
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxAddrWidth-1:0] addr;
    logic [TimestampWidth-1:0] timestamp;  // Useful for selecting oldest first
    logic [ReadRespBankAddrWidth-1:0] iid; // Internal identifier (address in the memory bank's RAM)
    logic v; // Valid bit
  } r_slot_t;

  // RAM slot management

  w_slot_t w_slt_d[NumWSlots];
  w_slot_t w_slt_q[NumWSlots];
  r_slot_t r_slt_d[NumRSlots];
  r_slot_t r_slt_q[NumRSlots];

  logic [NumWSlots-1:0] free_w_slt_mhot;
  logic [NumWSlots-1:0] nxt_free_w_slot_onehot;
  logic [NumRSlots-1:0] free_r_slt_mhot;
  logic [NumRSlots-1:0] nxt_free_r_slot_onehot;

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_nxt_free_w_slot
    assign free_w_slt_mhot[i_slt] = ~w_slt_q[0].v;
    if (i_slt == 0) begin
      assign nxt_free_w_slot_onehot[0] = ~free_w_slt_mhot[0];
    end else begin
      assign
          nxt_free_w_slot_onehot[i_slt] = ~free_w_slt_mhot[i_slt] && &free_w_slt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_w_slot

  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_nxt_free_r_slot
    assign free_r_slt_mhot[i_slt] = ~r_slt_q[0].v;
    if (i_slt == 0) begin
      assign nxt_free_r_slot_onehot[0] = ~free_r_slt_mhot[0];
    end else begin
      assign
          nxt_free_r_slot_onehot[i_slt] = ~free_r_slt_mhot[i_slt] && &free_r_slt_mhot[i_slt - 1:0];
    end
  end : gen_nxt_free_r_slot

  assign waddr_ready_o = |nxt_free_w_slot_onehot;
  assign raddr_ready_o = |nxt_free_r_slot_onehot;


  // Signals to accept new write data

  logic [NumWSlots-1:0] free_w_slot_for_data_onehot;
  logic [MaxWBurstLen-1:0] nxt_nv_bit_onehot[NumWSlots];  // First non-valid bit

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_slot_for_in_data
    assign free_w_slot_for_data_onehot[i_slt] = w_slt_q[i_slt].v & | ~(w_slt_q[i_slt].data_v);
    for (genvar i_bit = 0; i_bit < NumWSlots; i_bit = i_bit + 1) begin : gen_nxt_nv_bit
      if (i_bit == 0) begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] = ~w_slt_q[i_slt].data_v[0];
      end else begin
        assign nxt_nv_bit_onehot[i_slt][i_bit] =
            ~w_slt_q[i_slt].data_v[i_bit] & w_slt_q[i_slt].data_v[i_bit - 1:0];
      end
    end : gen_nxt_nv_bit
  end : gen_slot_for_in_data

  assign wdata_ready_o = |free_w_slot_for_data_onehot;


  // Generate the addresses for all the data

  logic [GlobalMemoryCapaWidth-1:0] w_addrs_per_slot[NumWSlots-1:0][MaxWBurstLen-1:0];
  logic [GlobalMemoryCapaWidth-1:0] r_addrs_per_slot[NumRSlots-1:0][MaxRBurstLen-1:0];

  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_w_addrs
    for (genvar i_data = 0; i_data < MaxWBurstLen; i_data = i_data + 1) begin : gen_w_addrs_per_slt
      if (w_slt_q[i_slt].v) begin
        assign w_addrs_per_slot[i_slt][i_data] =
            w_slt_q[i_slt].addr + i_data * w_slt_q[i_slt].burst_length;
      end else begin
        assign w_addrs_per_slot[i_slt][i_data] = '0;
      end
    end : gen_w_addrs_per_slt
  end : gen_w_addrs

  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_r_addrs
    for (genvar i_data = 0; i_data < MaxRBurstLen; i_data = i_data + 1) begin : gen_r_addrs_per_slt
      if (r_slt_q[i_slt].v) begin
        assign r_addrs_per_slot[i_slt][i_data] =
            r_slt_q[i_slt].addr + i_data * r_slt_q[i_slt].burst_length;
      end else begin
        assign r_addrs_per_slot[i_slt][i_data] = '0;
      end
    end : gen_r_addrs_per_slt
  end : gen_r_addrs


  // Select the optimal address for each slot

  // TODO: Compress the costs during the optimization by using enum types

  logic [MaxWBurstLen-1:0] opti_w_bit_per_slot[NumWSlots-1:0];
  logic [MaxRBurstLen-1:0] opti_r_bit_per_slot[NumRSlots-1:0];

  logic [DelayWidth-1:0] opti_w_cost_per_slot[NumWSlots-1:0];
  logic [DelayWidth-1:0] opti_r_cost_per_slot[NumRSlots-1:0];

  // Reduce per slot

  // FUTURE: The sequential minimization may be favorably replaced by a reduction.
  for (genvar i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin : gen_opti_w_addrs_per_slt
    logic is_opti_valid = 1'b0;
    logic [DelayWidth-1:0] curr_cost;

    for (int unsigned i_data = 0; i_data < MaxWBurstLen; i_data = i_data + 1) begin
      curr_cost = determine_cost(w_addrs_per_slot[i_slt][i_data], is_row_open, open_row_start_address_q);

      is_opti_valid = is_opti_valid || w_slt_q[i_slt].data_v[i_data];

      // FUTURE: The strict inequality may not suffice to guarantee oldest first in wrapped bursts
      
      if (w_slt_q[i_slt].data_v[i_bit] && (!is_opti_valid || curr_cost < opti_w_cost_per_slot[i_slt])) begin
        opti_w_cost_per_slot[i_slt] = curr_cost;
        opti_w_bit_per_slot[i_slt] = i_data;
      end
    end
  end : gen_opti_w_addrs_per_slt

  for (genvar i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin : gen_opti_r_addrs_per_slt
    logic is_opti_valid = 1'b0;
    logic [DelayWidth-1:0] curr_cost;

    for (int unsigned i_data = 0; i_data < MaxRBurstLen; i_data = i_data + 1) begin
      curr_cost = determine_cost(r_addrs_per_slot[i_slt][i_data], is_row_open, open_row_start_address_q);

      is_opti_valid = is_opti_valid || r_slt_q[i_slt].data_v[i_data];

      if (r_slt_q[i_slt].data_v[i_bit] && (!is_opti_valid || curr_cost < opti_r_cost_per_slot[i_slt])) begin
        opti_r_cost_per_slot[i_slt] = curr_cost;
        opti_r_bit_per_slot[i_slt] = i_data;
      end
    end
  end : gen_opti_r_addrs_per_slt

  // Reduce among slots

  logic [$clog2(NumWSlots)-1:0] opti_w_slot;
  logic [$clog2(NumRSlots)-1:0] opti_r_slot;

  // TODO: Add timestamps to all the WRITE data, although may require massive amount of flip-flops
  // logic [TimestampWidth-1:0] opti_w_timestamp;
  // logic [TimestampWidth-1:0] opti_r_timestamp;

  logic [DelayWidth-1:0] opti_w_cost;
  logic [DelayWidth-1:0] opti_r_cost;

  always_comb begin : gen_opti_slot
    logic is_opti_valid = 1'b0;
    logic [DelayWidth-1:0] curr_cost;

    // Writes
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_w_bit_per_slot[i_slt];

      is_opti_valid = is_opti_valid || w_slt_q[i_slt].v;

      if (w_slt_q[i_slt].v && (!is_opti_valid || (curr_cost < opti_w_cost || (curr_cost <= opti_w_cost && curr_cost <= opti_w_cost)))) begin
        opti_w_slot = i_slt;
        opti_w_cost = curr_cost;
      end
    end
    
    // Reads
    is_opti_valid = 1'b0;

    for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
      curr_cost = opti_r_bit_per_slot[i_slt];

      is_opti_valid = is_opti_valid || r_slt_q[i_slt].v;

      if (r_slt_q[i_slt].v && (!is_opti_valid || (curr_cost < opti_r_cost || (curr_cost <= opti_r_cost && )))) begin
        opti_r_slot = i_slt;
        opti_r_cost = curr_cost;
      end
    end

  end : gen_opti_slot

  // Select between read and write

  logic serve_w;

  // TODO: Take timestamp into account
  assign serve_w = |opti_w_slot && (!opti_r_slot || opti_w_cost < opti_r_cost);

  // Rank signals
  
  logic is_row_open_d;
  logic is_row_open_q;
  
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_d;
  logic [GlobalMemoryCapaWidth-1:0] open_row_start_address_q;

  logic [DelayWidth-1:0] rank_delay_cnt_d;
  logic [DelayWidth-1:0] rank_delay_cnt_q;

  // Delay calculator management logic

  // TODO: Update to done when it is relevant to do so.

  always_comb begin : del_calc_mgmt_comb

    is_row_open_d = is_row_open_q;
    open_row_start_address_d = open_row_start_address_q;

    // Write slot input

    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      w_slt_d[i_slt] = w_slt_q[i_slt];

      if (waddr_valid_i && waddr_ready_o && nxt_free_w_slot_onehot[i_slt]) begin
        w_slt_d[i_slt].v = 1'b1;
        w_slt_d[i_slt].iid = waddr_iid_i;
        w_slt_d[i_slt].addr = waddr_req_i.addr;
        w_slt_d[i_slt].burst_size = waddr_req_i.burst_size;

        w_slt_d[i_slt].mem_pending = '0;

        // FUTURE: Implement support for wrap burst here and in the read slot input

        for (int unsigned i_bit = 0; i_bit < MaxWBurstLen; i_bit = i_bit + 1) begin
          w_slt_d[i_slt].data_v[i_bit] =
              (i_bit >= waddr_req_i.burst_length) | (i_bit < waddr_req_i.wdata_immediate_cnt_i);
          w_slt_d[i_slt].mem_done[i_bit] = i_bit >= waddr_req_i.burst_length;
        end
      end
    end

    // Read slot input
    for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
      r_slt_d[i_slt] = r_slt_q[i_slt];

      if (raddr_valid_i && raddr_ready_o && nxt_free_r_slot_onehot[i_slt]) begin
        r_slt_d[i_slt].v = 1'b1;
        r_slt_d[i_slt].iid = raddr_iid_i;
        r_slt_d[i_slt].addr = raddr_req_i.addr;
        r_slt_d[i_slt].burst_size = raddr_req_i.burst_size;

        r_slt_d[i_slt].mem_pending = '0;

        for (int unsigned i_bit = 0; i_bit < MaxRBurstLen; i_bit = i_bit + 1) begin
          r_slt_d[i_slt].data_v[i_bit] = i_bit >= raddr_req_i.burst_length;
          r_slt_d[i_slt].mem_done[i_bit] = i_bit >= raddr_req_i.burst_length;
        end
      end
    end

    // Acceptance of new write data
    for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
      // The one-hot signal is expanded bit by bit to act as a mask.
      w_slt_d[i_slt].data_v = w_slt_q[i_slt].data_v | (nxt_nv_bit_onehot[i_slt] &
          {MaxWBurstLen{free_w_slot_for_data_onehot[i_slt]}});
    end

    // Update of the rank counter    
    if (rank_delay_cnt_q == 0) begin
      // If there is a request to serve
      if (serve_w && |opti_w_slot) begin
        rank_delay_cnt_d = opti_w_cost;

        for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
          w_slt_d[i_slt].mem_pending |= opti_w_bit_per_slot & {MaxWBurstLen{opti_w_slot == i_slt}};
        end
      end else if (!serve_w && |opti_r_slot) begin
        rank_delay_cnt_d = opti_r_cost;

        for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
          r_slt_d[i_slt].mem_pending |= opti_r_bit_per_slot & {MaxWBurstLen{opti_r_slot == i_slt}};
        end else begin
        // If there is no request to serve, then the counter remains 0.
        rank_delay_cnt_d = 0;
      end
    end else begin
      rank_delay_cnt_d = rank_delay_cnt_q - 1;
    end

    // TODO: Update the entries
    // Updated at delay 2 to accommodate the one-cycle additional latency due to the response bank
    if (rank_delay_cnt_q == 2) begin
      for (int unsigned i_slt = 0; i_slt < NumWSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done
        w_slt_d[i_slt].mem_done = w_slt_q[i_slt].mem_done | w_slt_q[i_slt].mem_pending;
        w_slt_d[i_slt].mem_pending = '0;
      end
      for (int unsigned i_slt = 0; i_slt < NumRSlots; i_slt = i_slt + 1) begin
        // Mark memory operation as done
        r_slt_d[i_slt].mem_done = r_slt_q[i_slt].mem_done | r_slt_q[i_slt].mem_pending;
        r_slt_d[i_slt].mem_pending = '0;
      end
    end

    // TODO: Outputs


  end : del_calc_mgmt_comb

endmodule
