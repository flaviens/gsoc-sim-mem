// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller top-level

module simmem_top (
    input logic clk_i,
    input logic rst_ni,

    input  logic raddr_in_valid_i,
    input  logic raddr_out_ready_i,
    output logic raddr_in_ready_o,
    output logic raddr_out_valid_o,

    input  logic waddr_in_valid_i,
    input  logic waddr_out_ready_i,
    output logic waddr_in_ready_o,
    output logic waddr_out_valid_o,

    input  logic wdata_in_valid_i,
    input  logic wdata_out_ready_i,
    output logic wdata_in_ready_o,
    output logic wdata_out_valid_o,

    input  logic rdata_in_valid_i,
    input  logic rdata_out_ready_i,
    output logic rdata_in_ready_o,
    output logic rdata_out_valid_o,

    input  logic wresp_in_valid_i,
    input  logic wresp_out_ready_i,
    output logic wresp_in_ready_o,
    output logic wresp_out_valid_o,

    input simmem_pkg::raddr_t raddr_i,
    input simmem_pkg::waddr_t waddr_i,
    input simmem_pkg::wdata_t wdata_i,
    input simmem_pkg::rdata_t rdata_i,
    input simmem_pkg::wresp_t wresp_i,

    output simmem_pkg::raddr_t raddr_o,
    output simmem_pkg::waddr_t waddr_o,
    output simmem_pkg::wdata_t wdata_o,
    output simmem_pkg::rdata_t rdata_o,
    output simmem_pkg::wresp_t wresp_o
);

  import simmem_pkg::*;

  // Reservation identifier
  logic [NumIds-1:0] wrsv_req_id_onehot;
  logic [NumIds-1:0] rrsv_req_id_onehot;

  for (genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1) begin : rsv_req_id_to_onehot
    assign wrsv_req_id_onehot[i_bit] = i_bit == waddr_i.id;
    assign rrsv_req_id_onehot[i_bit] = i_bit == raddr_i.id;
  end : rsv_req_id_to_onehot

  // Reserved IID (RAM address)
  logic [WriteRespBankAddrWidth-1:0] wrsv_iid;
  logic [ReadDataBankAddrWidth-1:0] rrsv_iid;

  // Reservation handshakes on the response banks
  logic wrsv_valid_in;
  logic rrsv_valid_in;
  logic wrsv_ready_out;
  logic rrsv_ready_out;

  assign wrsv_valid_in = waddr_out_ready_i & waddr_in_valid_i;
  assign rrsv_valid_in = raddr_out_ready_i & raddr_in_valid_i;

  // Valid and ready signals for addresses on the delay calculator
  logic waddr_valid_in_delay_calc;
  logic raddr_valid_in_delay_calc;
  logic waddr_ready_out_delay_calc;  // Must be equal to wrsv_ready_out
  logic raddr_ready_out_delay_calc;  // Must be equal to rrsv_ready_out

  assign waddr_valid_in_delay_calc = waddr_out_ready_i & waddr_in_valid_i;
  assign raddr_valid_in_delay_calc = raddr_out_ready_i & raddr_in_valid_i;

  // Valid and ready signals for write data on the delay calculator
  logic wdata_valid_in_delay_calc;
  logic wdata_ready_out_delay_calc;

  assign wdata_valid_in_delay_calc = wdata_out_ready_i & wdata_in_valid_i;

  // Release enable signals
  logic [WriteRespBankCapacity-1:0] wresp_release_en_mhot;
  logic [ReadDataBankCapacity-1:0] rdata_release_en_mhot;

  // Released addresses feedback
  logic [WriteRespBankCapacity-1:0] wresp_released_onehot;
  logic [ReadDataBankCapacity-1:0] rdata_released_onehot;

  // Mutual ready signals (directions are given in the point of view of the response banks
  logic w_delay_calc_ready_in;  // From the delay calculator
  logic r_delay_calc_ready_in;  // From the delay calculator
  logic w_delay_calc_ready_out;  // From the response banks
  logic r_delay_calc_ready_out;  // From the response banks

  // Output hanshake signals for upstream signals (from the requester to the real memory controller).
  assign waddr_in_ready_o = waddr_out_ready_i & wrsv_ready_out;
  assign raddr_in_ready_o = raddr_out_ready_i & rrsv_ready_out;
  assign waddr_out_valid_o = waddr_in_valid_i & wrsv_ready_out;
  assign raddr_out_valid_o = raddr_in_valid_i & rrsv_ready_out;
  assign wdata_in_ready_o = wdata_out_ready_i & wdata_ready_out_delay_calc;
  assign wdata_out_valid_o = wdata_in_valid_i & wdata_ready_out_delay_calc;

  // Output upstream signals
  assign wdata_o = wdata_i;
  assign raddr_o = raddr_i;
  assign waddr_o = waddr_i;

  // Response banks instance
  simmem_resp_banks i_simmem_resp_banks (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .wrsv_req_id_onehot_i    (wrsv_req_id_onehot),
      .rrsv_req_id_onehot_i    (rrsv_req_id_onehot),
      .wrsv_iid_o              (wrsv_iid),
      .rrsv_iid_o              (rrsv_iid),
      .rrsv_burst_len_i        ((MaxRBurstLenWidth + 1)'(raddr_i.burst_length)),
      .wrsv_valid_i            (wrsv_valid_in),
      .wrsv_ready_o            (wrsv_ready_out),
      .rrsv_valid_i            (rrsv_valid_in),
      .rrsv_ready_o            (rrsv_ready_out),
      .w_release_en_i          (wresp_release_en_mhot),
      .r_release_en_i          (rdata_release_en_mhot),
      .w_released_addr_onehot_o(wresp_released_onehot),
      .r_released_addr_onehot_o(rdata_released_onehot),
      .wresp_i                 (wresp_i),
      .wresp_o                 (wresp_o),
      .rdata_i                 (rdata_i),
      .rdata_o                 (rdata_o),
      .w_in_rsp_valid_i        (wresp_in_valid_i),
      .w_in_rsp_ready_o        (wresp_in_ready_o),
      .r_in_data_valid_i       (rdata_in_valid_i),
      .r_in_data_ready_o       (rdata_in_ready_o),
      .w_out_rsp_ready_i       (wresp_out_ready_i),
      .w_out_rsp_valid_o       (wresp_out_valid_o),
      .r_out_data_ready_i      (rdata_out_ready_i),
      .r_out_data_valid_o      (rdata_out_valid_o),
      .w_delay_calc_ready_i    (w_delay_calc_ready_in),
      .r_delay_calc_ready_i    (r_delay_calc_ready_in),
      .w_delay_calc_ready_o    (w_delay_calc_ready_out),
      .r_delay_calc_ready_o    (r_delay_calc_ready_out)
  );

  simmem_delay_calculator i_simmem_delay_calculator (
      .clk_i                       (clk_i),
      .rst_ni                      (rst_ni),
      .waddr_i                     (waddr_i),
      .waddr_iid_i                 (wrsv_iid),
      .waddr_valid_i               (waddr_valid_in_delay_calc),
      .waddr_ready_o               (waddr_ready_out_delay_calc),
      .wdata_valid_i               (wdata_valid_in_delay_calc),
      .wdata_ready_o               (wdata_ready_out_delay_calc),
      .raddr_i                     (raddr_i),
      .raddr_iid_i                 (rrsv_iid),
      .raddr_valid_i               (raddr_valid_in_delay_calc),
      .raddr_ready_o               (raddr_ready_out_delay_calc),
      .wresp_release_en_mhot_o     (wresp_release_en_mhot),
      .rdata_release_en_mhot_o     (rdata_release_en_mhot),
      .wresp_released_addr_onehot_i(wresp_released_onehot),
      .rdata_released_addr_onehot_i(rdata_released_onehot),
      .w_resp_bank_ready_o         (w_delay_calc_ready_in),
      .r_resp_bank_ready_o         (r_delay_calc_ready_in),
      .w_resp_bank_ready_i         (w_delay_calc_ready_out),
      .r_resp_bank_ready_i         (r_delay_calc_ready_out)

  );

endmodule
