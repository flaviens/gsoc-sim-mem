// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module simmem_message_banks (
  input logic clk_i,
  input logic rst_ni,

  input logic [simmem_pkg::NumIds-1:0] write_resp_release_en_i, // Input from the releaser

  input  logic [simmem_pkg::IDWidth-1:0] write_resp_res_req_id_i,
  output logic [simmem_pkg::WriteRespBankAddrWidth-1:0] write_resp_res_addr_o, // Reserved address

  input  logic write_resp_res_req_valid_i,
  output logic write_resp_res_req_ready_o, 

  input  simmem_pkg::write_resp_t write_resp_i,
  output simmem_pkg::write_resp_t write_resp_o,

  input  logic write_resp_in_valid_i,
  output logic write_resp_in_ready_o,

  input  logic write_resp_out_ready_i,
  output logic write_resp_out_valid_o
);

  import simmem_pkg::*;

  logic [NumIds-1:0] write_resp_res_req_id_onehot;

  simmem_write_resp_bank i_simmem_write_resp_bank (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .res_req_id_onehot_i(write_resp_res_req_id_onehot),
    .res_addr_o(write_resp_res_addr), // Reserved address
    // Reservation handshake signals
    .res_req_valid_i(write_resp_res_req_valid),
    .res_req_ready_o(write_resp_res_req_ready), 

    // Interface with the releaser
    .release_en_i(write_resp_release_en),  // Multi-hot signal
    .rel_addr_onehot_o(write_resp_released_addr_onehot),

    // Interface with the real memory controller
    .data_i(write_resp_bank_in_data), // AXI message excluding handshake
    .data_o(write_resp_bank_out_data), // AXI message excluding handshake
    .in_data_valid_i(write_resp_bank_in_valid),
    .in_data_ready_o(write_resp_bank_in_ready),

    // Interface with the requester
    .out_ready_i(write_resp_bank_out_ready),
    .out_valid_o(write_resp_bank_out_valid)
  );

  // Binary to onehot
  write_resp_res_req_id_onehot

endmodule
