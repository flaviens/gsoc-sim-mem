// Copyright lowRISC contributors. Licensed under the Apache License, Version 2.0, see LICENSE for
// details. SPDX-License-Identifier: Apache-2.0
//
// Wrapper for the write response and read data response banks

module simmem_resp_banks (
    input logic clk_i,
    input logic rst_ni,

    // Reservation interface AXI identifier for which the reseration request is being done.
    input  logic [simmem_pkg::NumIds-1:0] wrsv_req_id_onehot_i,
    input  logic [simmem_pkg::NumIds-1:0] rrsv_req_id_onehot_i,
    // Information about currently reserved address. Will be stored by other modules as an internal
    // identifier to uniquely identify the response (or response burst in case of read data).
    output logic [WriteRespBankAddrWidth-1:0] wrsv_addr_o,
    output logic [ReadDataBankAddrWidth-1:0]  rrsv_addr_o,
    // The number of data elements to reserve in the RAM cell.
    input  logic [MaxRBurstLenWidth-1:0]  rrsv_burst_len_i,
    // Reservation handshake signals
    input  logic                          wrsv_valid_i,
    output logic                          wrsv_ready_o,
    input  logic                          rrsv_valid_i,
    output logic                          rrsv_ready_o,

    // Interface with the releaser Multi-hot signal that enables the release for given internal
    // addresses (i.e., RAM addresses).
    input  logic [TotCapa-1:0] w_release_en_i,
    input  logic [TotCapa-1:0] r_release_en_i,
    // Signals which address has been released, if any. One-hot signal. Is set to one for each
    // released response in a burst.
    output logic [TotCapa-1:0] w_released_addr_onehot_o,
    output logic [TotCapa-1:0] r_released_addr_onehot_o,

    // Interface with the real memory controller AXI response excluding handshake
    input  DataType wresp_i,
    output DataType wresp_o,
    input  DataType rdata_i,
    output DataType rdata_o,
    // Response acquisition handshake signal
    input  logic w_in_rsp_valid_i,
    output logic w_in_rsp_ready_o,
    input  logic r_in_data_valid_i,
    output logic r_in_data_ready_o,

    // Interface with the requester
    input  logic w_out_rsp_ready_i,
    output logic w_out_rsp_valid_o
    input  logic r_out_data_ready_i,
    output logic r_out_data_valid_o
);

  import simmem_pkg::*;

  localparam int PayloadWidth = DataWidth - IDWidth;
  localparam int PayloadRamWidth = MaxBurstLen * PayloadWidth;

  typedef struct packed {logic [BankAddrWidth-1:0] nxt_elem;} metadata_e;

  simmem_resp_bank #(
      .TotCapa(ReadDataBankCapacity),
      .DataType(rdata_t)
  ) i_simmem_rdata_bank (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .rsv_req_id_onehot_i    (rrsv_req_id_onehot_i),
      .rsv_addr_o             (rrsv_addr_o),
      .rsv_burst_len_i        (rrsv_burst_len_i),
      .rsv_valid_i            (rrsv_valid_i),
      .rsv_ready_o            (rrsv_ready_o),
      .release_en_i           (r_release_en_i),
      .released_addr_onehot_o (r_released_addr_onehot_o),
      .rsp_i                  (rdata_i),
      .rsp_o                  (rdata_o),
      .in_rsp_valid_i         (r_in_data_valid_i),
      .in_rsp_ready_o         (r_in_data_ready_o),
      .out_rsp_ready_i        (r_out_data_ready_i),
      .out_rsp_valid_o        (r_out_data_valid_o)
  );

  simmem_resp_bank #(
    .TotCapa(WriteRespBankCapacity),
    .DataType(rdata_t)
  ) i_simmem_wresp_bank (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .rsv_req_id_onehot_i    (wrsv_req_id_onehot_i),
      .rsv_addr_o             (wrsv_addr_o),
      .rsv_burst_len_i        (1),
      .rsv_valid_i            (wrsv_valid_i),
      .rsv_ready_o            (wrsv_ready_o),
      .release_en_i           (w_release_en_i),
      .released_addr_onehot_o (w_released_addr_onehot_o),
      .rsp_i                  (wresp_i),
      .rsp_o                  (wresp_o),
      .in_rsp_valid_i         (w_in_rsp_valid_i),
      .in_rsp_ready_o         (w_in_rsp_ready_o),
      .out_rsp_ready_i        (w_out_rsp_ready_i),
      .out_rsp_valid_o        (w_out_rsp_valid_o)
  );

endmodule
