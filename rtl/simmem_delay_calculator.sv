// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The delay calculator is responsible for snooping the traffic from the requester and deducing the
// enable signals for the message banks. This module is a wrapper for the delay calculator core. It
// makes sure that write data requests are not seen by the delay calculator core before the
// corresponding write address. To ensure this property, and as the write data request content is
// irrelevant to delay estimation (in particular, it does not contain an AXI identifier in the
// targeted stadard AXI 4), this wrapper maintains an unsigned counter of snooped write data
// requests that do not have a write address yet. When the corresponding write address request comes
// in, it is immediately transmitted to the delay calculator core, along with the corresponding
// count of write data requests already (or concurrently) received.

module simmem_delay_calculator (
  input logic clk_i,
  input logic rst_ni,
  
  // Write address request from the requester.
  input simmem_pkg::waddr_req_t waddr_req_i,
  // Internal identifier corresponding to the write address request (issued by the write response
  // bank).
  input simmem_pkg::write_iid_t waddr_iid_i,

  // Write address request valid from the requester.
  input logic waddr_valid_i,
  // Blocks the write address request if there is no write slot in the delay calculator to treat it.
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
  input simmem_pkg::read_iid_t raddr_iid_i,

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

  // MaxPendingWData is the maximum possible number of distinct values taken by the write data.
  localparam int MaxPendingWData = MaxWBurstLen * WriteRespBankCapacity;
  localparam int MaxPendingWDataWidth = $clog2(MaxPendingWData);

  // Counters for the write data without address yet.
  logic [MaxPendingWDataWidth-1:0] wdata_cnt_d;
  logic [MaxPendingWDataWidth-1:0] wdata_cnt_q;

  // Delay calculator core I/O signals for the write data.
  logic core_wdata_valid_input;
  logic core_wdata_ready_ooutput;

  // Counts how many data requests have been received before or with the write address request.
  logic [MaxWBurstLenWidth-1:0] wdata_immediate_cnt;

  always_comb begin : wrapper_comb
    wdata_cnt_d = wdata_cnt_q;
    core_wdata_valid_input = 1'b0;

    if (wdata_valid_i && wdata_ready_o) begin
      if (core_wdata_ready_ooutput) begin
        // If there is an input handshake for write data and the delay calculator core is ready to
        // accept write data, then transmit the write data information to the delay calculator core.
        // This means, that the delay calculator core has recorded a write address request, which is
        // still missing associated write data requests.
        core_wdata_valid_input = 1'b1;
      end else begin
        // Else, increment the counter of received write data without an address yet.
        wdata_cnt_d = wdata_cnt_d + 1;
      end
    end

    if (waddr_valid_i && waddr_ready_o) begin
      // Considering wdata_cnt_d instead of wdata_cnt_q, allows the module to take into account the
      // data coming in during the same cycle as the address. Safety of this operation is granted by
      // the order in which wdata_cnt_d is updated in the combinatorial block.

      if (AxLenWidth'(wdata_cnt_d) >= waddr_req_i.burst_length) begin
        // If all the data associated with the address has arrived not later than the address, then
        // transmit all this data with the address request to the delay calculator core.
        wdata_immediate_cnt = waddr_req_i.burst_length[MaxWBurstLenWidth - 1:0];
        wdata_cnt_d = wdata_cnt_d - MaxPendingWDataWidth'(wdata_immediate_cnt);
      end else begin
        // Else, transmit only the already and currently received write data, and set the counter to
        // zero, as it has been emptied.
        wdata_immediate_cnt = wdata_cnt_d[MaxWBurstLenWidth - 1:0];
        wdata_cnt_d = '0;
      end
    end
  end : wrapper_comb

  // Outputs Write data are always accepted, as the only space they require is in the counter.
  assign wdata_ready_o = 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wdata_cnt_q <= '0;
    end else begin
      wdata_cnt_q <= wdata_cnt_d;
    end
  end

  simmem_delay_calculator_core i_simmem_delay_calculator_core (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    
    .waddr_iid_i(waddr_iid_i),
    .waddr_req_i(waddr_req_i),

    .wdata_immediate_cnt_i(wdata_immediate_cnt),
    .waddr_valid_i(waddr_valid_i),
    .waddr_ready_o(waddr_ready_o),
  
    .wdata_valid_i(core_wdata_valid_input),
    .wdata_ready_o(core_wdata_ready_ooutput),
  
    .raddr_iid_i(raddr_iid_i),
    .raddr_req_i(raddr_req_i),
    .raddr_valid_i(raddr_valid_i),
    .raddr_ready_o(raddr_ready_o),
  
    .wresp_release_en_onehot_o(wresp_release_en_onehot_o),
    .rdata_release_en_onehot_o(rdata_release_en_onehot_o),
  
    .wresp_released_addr_onehot_i(wresp_released_addr_onehot_i),
    .rdata_released_addr_onehot_i(rdata_released_addr_onehot_i)
  );

endmodule
