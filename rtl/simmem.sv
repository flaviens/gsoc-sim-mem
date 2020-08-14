// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller top-level

import simmem_pkg::*;

module simmem (
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

    input raddr_req_t raddr_i,
    input waddr_req_t waddr_i,
    input wdata_req_t wdata_i,
    input rdata_t     rdata_i,
    input wresp_t     wresp_i,

    output raddr_req_t raddr_o,
    output waddr_req_t waddr_o,
    output wdata_req_t wdata_o,
    output rdata_t     rdata_o,
    output wresp_t     wresp_o
);

  logic [WriteRespBanksCapacity-1:0] wresp_release_en;
  logic [ReadDataBanksCapacity-1:0] rdata_release_en;


  // TODO Adapt this title
  /////////////////////////
  // Reservation signals //
  /////////////////////////

  // Reservation identifier
  logic [NumIds-1:0] wrsv_req_id_onehot;
  logic [NumIds-1:0] rrsv_req_id_onehot;

  for (genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1) begin : rsv_req_id_to_onehot
    assign wrsv_req_id_onehot[i_bit] = i_bit == waddr_i.id;
    assign rrsv_req_id_onehot[i_bit] = i_bit == raddr_i.id;
  end : rsv_req_id_to_onehot

  // Reserved address, aka. iid
  logic [WriteRespBankAddrWidth-1:0] wrsv_iid;
  logic [ReadDataBankAddrWidth-1:0] rrsv_iid;

  // Reservation handshakes
  logic wrsv_valid_in;
  logic rrsv_valid_in;
  logic wrsv_ready_out;
  logic rrsv_ready_out;

  assign wrsv_valid_in =
      wrsv_ready_out & waddr_ready_out & wrsv_ready_out & waddr_out_ready_i & waddr_in_valid_i;
  assign rrsv_valid_in =
      rrsv_ready_out & raddr_ready_out & rrsv_ready_out & raddr_out_ready_i & raddr_in_valid_i;

  // Address handshakes on delay calculator
  logic waddr_valid_in;
  logic raddr_valid_in;
  logic waddr_ready_out;
  logic raddr_ready_out;

  assign waddr_valid_in = wrsv_valid_in;
  assign raddr_valid_in = rrsv_valid_in;

  // Data handshakes
  logic wdata_ready_in_delay_calc;

  logic wdata_valid_in;
  logic rdata_valid_in;
  logic wdata_ready_out;
  logic rdata_ready_out;

  assign wdata_valid_in = wdata_ready_in_delay_calc & wdata_out_ready_i & wdata_in_valid_i;
  assign rdata_valid_in = rdata_ready_in_delay_calc & rdata_out_ready_i & rdata_in_valid_i;

  // Release enable signals
  logic wresp_release_en_onehot;
  logic rdata_release_en_onehot;

  // Released addresses feedback
  logic wresp_released_onehot;
  logic rdata_released_onehot;

  assign wresp_release_en_onehot

  // Response banks instance
  simmem_resp_banks i_simmem_resp_banks (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .wrsv_req_id_onehot_i     (wrsv_req_id_onehot),
      .rrsv_req_id_onehot_i     (rrsv_req_id_onehot),
      .wrsv_iid_o               (wrsv_iid),
      .rrsv_addr_o              (rrsv_iid),
      .rrsv_burst_len_i         (MaxRBurstLenWidth'(raddr_i.burst_length)),
      .wrsv_valid_i             (wrsv_valid_in),
      .wrsv_ready_o             (wrsv_ready_out),
      .rrsv_valid_i             (rrsv_valid_in),
      .rrsv_ready_o             (rrsv_ready_out),
      .w_release_en_i           (wresp_release_en_onehot),
      .r_release_en_i           (rdata_release_en_onehot),
      .w_released_addr_onehot_o (wresp_released_onehot),
      .r_released_addr_onehot_o (rdata_released_onehot),
      .wresp_i                  (wresp_i),
      .wresp_o                  (wresp_o),
      .rdata_i                  (rdata_i),
      .rdata_o                  (rdata_o),
      .w_in_rsp_valid_i         (wresp_in_valid_i),
      .w_in_rsp_ready_o         (wresp_in_ready_o),
      .r_in_data_valid_i        (rdata_in_valid_i),
      .r_in_data_ready_o        (rdata_in_ready_o),
      .w_out_rsp_ready_i        (wresp_out_ready_i),
      .w_out_rsp_valid_o        (wresp_out_valid_o),
      .r_out_data_ready_i       (rdata_out_ready_i),
      .r_out_data_valid_o       (rdata_out_valid_o)
  );

  simmem_delay_calculator i_simmem_delay_calculator (
      .clk_i                        (clk_i),
      .rst_ni                       (rst_ni),
      .waddr_i                      (waddr_i),
      .waddr_iid_i                  (wrsv_iid),
      .waddr_valid_i                (waddr_valid_in),
      .waddr_ready_o                (waddr_ready_out),
      .wdata_valid_i                (wdata_in_valid_i),
      .wdata_ready_o                (wdata_ready_in_delay_calc),
      .raddr_i                      (raddr_i),
      .raddr_iid_i                  (rrsv_iid),
      .raddr_valid_i                (raddr_valid_in),
      .raddr_ready_o                (raddr_ready_out),
      .wresp_release_en_onehot_o    (wresp_release_en_onehot),
      .rdata_release_en_onehot_o    (rdata_release_en_onehot),
      .wresp_released_addr_onehot_i (wresp_released_onehot),
      .rdata_released_addr_onehot_i (rdata_released_onehot)
  );



endmodule
