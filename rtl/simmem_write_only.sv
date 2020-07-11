// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller top-level

module simmem_write_only (  
  input logic   clk_i,
  input logic   rst_ni,

  input logic   write_addr_in_valid_i,
  input logic   write_addr_out_ready_i,
  output logic  write_addr_in_ready_o,
  output logic  write_addr_out_valid_o,

  input logic   write_resp_in_valid_i,
  input logic   write_resp_out_ready_i,
  output logic  write_resp_in_ready_o,
  output logic  write_resp_out_valid_o,

  input write_addr_req_t write_addr_req_i,
  input write_resp_t write_resp_i,

  output write_addr_req_t write_addr_req_o,
  output write_resp_t write_resp_o
);

  ///////////////////////////
  // Message bank instance //
  ///////////////////////////

  logic write_resp_res_req_id_onehot;
  logic write_resp_res_addr;

  logic write_resp_res_req_valid;
  logic write_resp_res_req_ready;

  logic write_resp_release_en;
  logic write_resp_released_addr_onehot;

  logic write_resp_bank_in_data;
  logic write_resp_bank_out_data;

  logic write_resp_bank_in_valid;
  logic write_resp_bank_in_ready;

  logic write_resp_bank_out_valid;
  logic write_resp_bank_out_ready;

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

  assign write_resp_res_req_id_onehot = 


  ///////////////////////////////
  // Delay calculator instance //
  ///////////////////////////////



  /////////////////////////
  // Delay bank instance //
  /////////////////////////

  logic

  module simmem_delay_bank (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    
    .local_identifier_i(local_identifier_i),
    .delay_i,
    .in_valid_i,
    
    // Signals at output
    .address_released_onehot_i,
    .release_en_o
  );
  

  logic [WriteRespBanksCapacity-1:0] write_resp_release_en;

  simmem_releaser #(
    // .ReadAddressStructWidth,
    // .WriteAddressStructWidth,
    // .WriteDataStructWidth,
    .ReadDataBanksCapacity,
    .WriteRespBanksCapacity,
    .IDWidth,
    .CounterWidth
  ) simmem_releaser_i (
    .clk_i,
    .rst_ni,

    .read_addr_in_valid_i,
    .read_addr_out_ready_i,

    .write_addr_in_valid_i,
    .write_addr_out_ready_i,

    .write_data_in_valid_i,
    .write_data_out_ready_i,

    .read_data_in_valid_i,
    .read_data_out_ready_i,
    .read_data_in_ready_i(read_data_in_ready_o),
    .read_data_out_valid_i(read_data_out_valid_o),
  
    .write_resp_in_valid_i,
    .write_resp_out_ready_i,
    .write_resp_in_ready_i(write_resp_in_ready_o),
    .write_resp_out_valid_i(write_resp_out_valid_o),

    .read_addr_i,
    .write_addr_i,
    .write_data_i,

    .write_resp_release_en_o(write_resp_release_en),
    .read_data_release_en_o(read_data_release_en)
    // .read_data_ready_o(releaser_read_data_ready)
    // .releaser_write_resp_ready_o(releaser_write_resp_ready)
  );


  // Linkedlist banks instance

  simmem_message_banks #(
    // .ReadDataStructWidth,
    // .WriteRespStructWidth,
    .ReadDataBanksCapacity,
    .WriteRespBanksCapacity,
    .IDWidth
  ) simmem_message_banks_i (
    .clk_i,
    .rst_ni,
  
    .write_resp_release_en_i(write_resp_release_en),
    .read_data_release_en_i(read_data_release_en)
  
    .read_data_i,
    .write_resp_i,
  
    .read_data_o,
    .write_resp_o,
  
    .read_data_in_valid_i,
    .read_data_out_ready_i,
    .read_data_in_ready_o,
    .read_data_out_valid_o,
  
    .write_resp_in_valid_i,
    .write_resp_out_ready_i,
    .write_resp_in_ready_o,
    .write_resp_out_valid_o
  );


  // I/O signals

  assign read_data_in_ready_o = read_data_out_ready_i;
  assign read_addr_in_ready_o = read_addr_out_ready_i;
  assign write_addr_in_ready_o = write_addr_out_ready_i;

endmodule
