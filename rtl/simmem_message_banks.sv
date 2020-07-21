// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0


module simmem_message_banks (
  input logic clk_i,
  input logic rst_ni,

  // AXI identifier corresponding to the reservation request
  input  logic [simmem_pkg::IDWidth-1:0] wresp_rsv_req_id_i,
  input  logic [simmem_pkg::IDWidth-1:0] rdata_rsv_req_id_i,
  // Reserved address
  output logic [simmem_pkg::WriteResponseBankAddrWidth-1:0] wresp_rsv_addr_o,
  output logic [simmem_pkg::ReadDataBankAddrWidth-1:0]      rdata_rsv_addr_o, 
  // Reservation handshake signals
  input  logic wresp_rsv_valid_i,
  output logic wresp_rsv_ready_o,
  input  logic rdata_rsv_valid_i,
  output logic rdata_rsv_ready_o,
  
  // Input and output data
  input  simmem_pkg::wresp_t wresp_data_i,
  output simmem_pkg::wresp_t wresp_data_o,
  input  simmem_pkg::rdata_t rdata_data_i,
  output simmem_pkg::rdata_t rdata_data_o,
  // Data handshake signals
  input  logic wresp_in_data_valid_i,
  output logic wresp_in_data_ready_o,
  input  logic wresp_out_data_ready_i,
  output logic wresp_out_data_valid_o

  // Interface with the delay banks
  input logic [simmem_pkg::WriteRespBankTotalCapacity-1:0]  wresp_release_en_i,
  input logic [simmem_pkg::ReadDataBankTotalCapacity-1:0]   rdata_release_en_i,
  output logic [simmem_pkg::WriteRespBankTotalCapacity-1:0] wresp_released_addr_onehot_o,
  output logic [simmem_pkg::ReadDataBankTotalCapacity-1:0]  rdata_released_addr_onehot_o,
);

  import simmem_pkg::*;

  logic [NumIds-1:0] rdata_rsv_req_id_onehot;
  logic [NumIds-1:0] wresp_rsv_req_id_onehot;

  simmem_resp_bank i_simmem_write_resp_bank (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .rsv_req_id_onehot_i(wresp_rsv_req_id_onehot),
    .rsv_addr_o(wresp_rsv_addr_o), // Reserved address
    // Reservation handshake signals
    .rsv_valid_i(wresp_rsv_valid_i),
    .rsv_ready_o(wresp_rsv_ready_o), 

    // Interface with the releaser
    .release_en_i(wresp_release_en_i),  // Multi-hot signal
    .released_addr_onehot_o(wresp_released_addr_onehot_o),

    // Interface with the real memory controller
    .data_i(wresp_data_i), // AXI message excluding handshake
    .data_o(wresp_data_o), // AXI message excluding handshake
    .in_data_valid_i(wresp_in_data_valid_i),
    .in_data_ready_o(wresp_in_data_ready_o),

    // Interface with the requester
    .out_data_ready_i(wresp_out_data_ready_i),
    .out_data_valid_o(wresp_out_data_valid_o)
  );

  // Binary to onehot reservation identifiers
  for (genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1) begin : wresp_rsv_addr_bin_to_onehot
    assign wresp_rsv_req_id_onehot[i_bit] = i_bit == wresp_rsv_req_id_i;
  end : wresp_rsv_addr_bin_to_onehot

endmodule
