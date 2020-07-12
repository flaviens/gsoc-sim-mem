// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0


module simmem_message_banks (
  input logic clk_i,
  input logic rst_ni,

  input  logic [simmem_pkg::IDWidth-1:0] wresp_res_req_id_i,
  output logic [simmem_pkg::WriteRespBankAddrWidth-1:0] wresp_res_addr_o, // Reserved address
  
  input  logic wresp_res_req_valid_i,
  output logic wresp_res_req_ready_o,
  
  input  simmem_pkg::wresp_t wresp_data_i,
  output simmem_pkg::wresp_t wresp_data_o,

  input logic [simmem_pkg::WriteRespBankTotalCapacity-1:0] wresp_release_en_i, // Input from the releaser
  output logic [simmem_pkg::WriteRespBankTotalCapacity-1:0] wresp_released_addr_onehot_o,

  input  logic wresp_in_data_valid_i,
  output logic wresp_in_data_ready_o,

  input  logic wresp_out_data_ready_i,
  output logic wresp_out_data_valid_o
);

  import simmem_pkg::*;

  logic [NumIds-1:0] wresp_res_req_id_onehot;

  simmem_write_resp_bank i_simmem_write_resp_bank (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .res_req_id_onehot_i(wresp_res_req_id_onehot),
    .res_addr_o(wresp_res_addr_o), // Reserved address
    // Reservation handshake signals
    .res_req_valid_i(wresp_res_req_valid_i),
    .res_req_ready_o(wresp_res_req_ready_o), 

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
  for (genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1) begin : wresp_res_addr_bin_to_onehot
    assign wresp_res_req_id_onehot[i_bit] = i_bit == wresp_res_req_id_i;
  end : wresp_res_addr_bin_to_onehot

endmodule
