// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller top-level

module simmem_write_only (  
  input logic   clk_i,
  input logic   rst_ni,

  input logic   waddr_in_valid_i,
  input logic   waddr_out_ready_i,
  output logic  waddr_in_ready_o,
  output logic  waddr_out_valid_o,

  input logic   wresp_in_valid_i,
  input logic   wresp_out_ready_i,
  output logic  wresp_in_ready_o,
  output logic  wresp_out_valid_o,

  input write_addr_req_t waddr_data_i,
  input write_resp_t wresp_data_i,

  output write_addr_req_t waddr_data_o,
  output write_resp_t wresp_data_o
);

  ///////////////////////
  // Handshake signals //
  ///////////////////////

  // Request handshakes

  logic waddr_handshake;

  assign waddr_in_ready_o = wresp_res_req_ready && waddr_out_ready_i;
  assign waddr_out_valid_o = wresp_res_req_ready && waddr_out_valid_i;

  assign waddr_handshake = wresp_res_req_ready && waddr_out_ready_i && waddr_out_valid_i;

  // Response handshakes

  assign write_resp_in_ready_o = wresp_bank_in_data_ready;
  assign write_resp_out_valid_o = wresp_bank_out_data_valid;

  ///////////////////////////
  // Message bank instance //
  ///////////////////////////

  logic wresp_res_req_id;
  logic wresp_res_addr;

  logic wresp_res_req_valid;
  logic wresp_res_req_ready;

  logic wresp_release_en;
  logic wresp_released_addr_onehot;

  logic wresp_bank_in_data;
  logic wresp_bank_out_data;

  logic wresp_bank_in_data_valid;
  logic wresp_bank_in_data_ready;

  logic wresp_bank_out_valid;
  logic wresp_bank_out_ready;

  simmem_message_banks i_simmem_message_banks (
      .clk_i,
      .rst_ni,

      .write_resp_res_req_id_i(wresp_res_req_id),
      .write_resp_res_addr_o(wresp_res_addr), // Reserved address
      // Reservation handshake signals
      .write_resp_res_req_valid_i(wresp_res_req_valid),
      .write_resp_res_req_ready_o(wresp_res_req_ready), 

      // Interface with the releaser
      .write_resp_release_en_i(wresp_release_en),  // Multi-hot signal
      .write_resp_rel_addr_onehot_o(wresp_released_addr_onehot),

      // Interface with the real memory controller
      .write_resp_data_i(wresp_bank_in_data), // AXI message excluding handshake
      .write_resp_data_o(wresp_bank_out_data), // AXI message excluding handshake
      .write_resp_in_data_valid_i(wresp_bank_in_data_valid),
      .write_resp_in_data_ready_o(wresp_bank_in_data_ready),

      // Interface with the requester
      .write_resp_out_ready_i(wresp_bank_out_data_ready),
      .write_resp_out_valid_o(wresp_bank_out_data_valid)
    );

  assign wresp_res_req_id = waddr_req_i.id;
  assign wresp_res_req_valid = waddr_handshake;
  assign wresp_res_release_en = dbank_out_release_en;
  assign wresp_bank_in_data = wresp_data_i;
  assign wresp_bank_in_data_valid = wresp_in_valid_i;
  assign wresp_bank_out_data_ready = wresp_out_ready_i;


  ///////////////////////////////
  // Delay calculator instance //
  ///////////////////////////////

  logic [WriteRespBankAddrWidth-1:0] dcal_wresp_in_local_id;
  logic [WriteRespBankAddrWidth-1:0] dcal_wresp_out_local_id;
  logic dcal_wresp_in_valid;
  logic [DelayWidth-1:0] dcal_wresp_out_delay;
  logic dcal_wresp_out_valid;

  simmem_delay_calculator i_simmem_delay_calculator (
      .clk_i,
      .rst_ni,

      .wresp_local_id_i(dcal_wresp_in_local_id),
      .in_valid_i(dcal_wresp_in_valid),
      
      .local_id_o(dcal_wresp_out_local_id),
      .delay_o(dcal_wresp_out_delay),
      .out_valid_o(dcal_wresp_out_valid)
    );

  assign dcal_wresp_in_local_id = wresp_res_addr;
  assign dcal_wresp_in_valid = waddr_handshake;

  /////////////////////////
  // Delay bank instance //
  /////////////////////////

  logic [IDWidth-1:0] dbank_in_local_id;
  logic [DelayWidth-1:0] dbank_in_delay;
  logic dbank_in_valid;
  logic [NumIds-1:0] dbank_in_released_onehot;
  logic [NumIds-1:0] dbank_out_release_en;

  simmem_delay_bank i_simmem_delay_bank (
      .clk_i,
      .rst_ni,
      
      .local_identifier_i(dbank_in_local_id),
      .delay_i(dbank_in_delay),
      .in_valid_i(dbank_in_valid),
      
      // Signals at output
      .address_released_onehot_i(dbank_in_released_onehot),
      .release_en_o(dbank_out_release_en)
    );

  assign dbank_in_local_id = dcal_wresp_out_local_id;
  assign dbank_in_delay = dcal_wresp_out_delay;
  assign dbank_in_valid = dcal_wresp_out_valid;
  assign dbank_in_released_onehot = dbank_in_released_onehot;

endmodule
