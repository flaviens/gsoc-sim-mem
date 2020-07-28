// Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0, see LICENSE for
// details. SPDX-License-Identifier: Apache-2.0

module simmem_delay_calculator (
  input logic clk_i,
  input logic rst_ni,
  
  // Write address
  input logic [simmem_pkg::WriteRespBankAddrWidth-1:0] waddr_iid_i,
  input simmem_pkg::waddr_req_t waddr_req_i,

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

  localparam MaxPendingWData = MaxWBurstLen * WriteRespBankCapacity;
  localparam MaxPendingWDataWidth = $clog2(MaxPendingWData);

  // Count the pending write data
  logic [MaxPendingWDataWidth-1:0] wdata_cnt_d;
  logic [MaxPendingWDataWidth-1:0] wdata_cnt_q;

  logic core_wdata_valid_i;
  logic core_wdata_ready_o;

  logic [MaxWBurstLenWidth-1:0] wdata_immediate_cnt;

  always_comb begin : input_comb
    wdata_cnt_d = wdata_cnt_q;
    core_wdata_valid_i = 1'b0;

    if (wdata_valid_i && wdata_ready_o) begin
      if (core_wdata_ready_o) begin
        // The priority is to transmit the data to the core if the core is ready for it.
        core_wdata_valid_i = 1'b1;
      end else begin
        // Else, increment the counter of received write data without an address
        wdata_cnt_d = wdata_cnt_d + 1;
      end
    end

    // If there is a write address coming in
    if (waddr_valid_i && waddr_ready_o) begin
      // Considering wdata_cnt_d allows the data coming in during the same cycle to be taken into
      // account. Safety of this operation is granted by the order in which wdata_cnt_d is updated
      // in the combinatorial block.

      // The condition smoothly treats the difference of unsigned integers
      if (wdata_cnt_d >= {{(MaxPendingWDataWidth - MaxWBurstLenWidth) {1'b0}},
                          waddr_req_i.burst_length[MaxWBurstLenWidth - 1:0]}) begin
        // This treats the case where all the data associated with the address has arrived not later
        // than the address.
        wdata_immediate_cnt = waddr_req_i.burst_length[MaxWBurstLenWidth - 1:0];
        wdata_cnt_d = wdata_cnt_d - {{(MaxPendingWDataWidth - MaxWBurstLenWidth) {1'b0}},
                                     wdata_immediate_cnt};
      end else begin
        wdata_immediate_cnt = wdata_cnt_d[MaxWBurstLenWidth - 1:0];
        wdata_cnt_d = '0;
      end
    end
  end : input_comb

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
  
    .wdata_valid_i(core_wdata_valid_i),
    .wdata_ready_o(core_wdata_ready_o),
  
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
