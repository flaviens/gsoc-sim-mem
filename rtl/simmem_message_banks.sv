// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module simmem_message_banks (
  input logic clk_i,
  input logic rst_ni,

  input  logic [simmem_pkg::IDWidth-1:0] write_resp_res_req_id_i,
  output logic [simmem_pkg::WriteRespBankAddrWidth-1:0] write_resp_res_addr_o, // Reserved address
  
  input  logic write_resp_res_req_valid_i,
  output logic write_resp_res_req_ready_o,
  
  input  simmem_pkg::write_resp_t write_resp_data_i,
  output simmem_pkg::write_resp_t write_resp_data_o,

  input logic [simmem_pkg::NumIds-1:0] write_resp_release_en_i, // Input from the releaser
  output logic [simemm_pkg::WriteRespBankTotalCapacity-1:0] write_resp_released_addr_onehot_o,

  input  logic write_resp_in_data_valid_i,
  output logic write_resp_in_data_ready_o,

  input  logic write_resp_out_data_ready_i,
  output logic write_resp_out_data_valid_o
);

  import simmem_pkg::*;

  logic [NumIds-1:0] write_resp_res_req_id_onehot;

  simmem_write_resp_bank i_simmem_write_resp_bank (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .res_req_id_onehot_i(write_resp_res_req_id_onehot),
    .res_addr_o(write_resp_res_addr_o), // Reserved address
    // Reservation handshake signals
    .res_req_valid_i(write_resp_res_req_valid_i),
    .res_req_ready_o(write_resp_res_req_ready_o), 

    // Interface with the releaser
    .release_en_i(write_resp_release_en_i),  // Multi-hot signal
    .released_addr_onehot_o(write_resp_released_addr_onehot_o),

    // Interface with the real memory controller
    .data_i(write_resp_i), // AXI message excluding handshake
    .data_o(write_resp_o), // AXI message excluding handshake
    .in_data_valid_i(write_resp_in_data_valid_i),
    .in_data_ready_o(write_resp_in_data_ready_o),

    // Interface with the requester
    .out_ready_i(write_resp_out_ready_i),
    .out_valid_o(write_resp_out_valid_o)
  );

  // Binary to onehot reservation identifiers
  for (
      genvar i_bit = 0; i_bit < NumIds; i_bit = i_bit + 1
  ) begin : write_resp_res_addr_bin_to_onehot
    assign write_resp_res_req_id_onehot[i_bit] = i_bit == write_resp_res_req_id;
  end : write_resp_res_addr_bin_to_onehot

endmodule
