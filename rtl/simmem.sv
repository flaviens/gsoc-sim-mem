// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller top-level

import simmem_pkg::*;

module simmem #(
  // Width of the messages, including identifier
  parameter int ReadDataBanksCapacity   = 64,
  parameter int WriteRespBanksCapacity  = 64,
  parameter int ReadDataDelayBanksCapacity   = 64,
  parameter int WriteRespDelayBanksCapacity  = 64,
  
  parameter int CounterWidth            = 8,
  )(
  input logic   clk_i,
  input logic   rst_ni,

  input logic   read_addr_in_valid_i,
  input logic   read_addr_out_ready_i,
  output logic  read_addr_in_ready_o,
  output logic  read_addr_out_valid_o,

  input logic   write_addr_in_valid_i,
  input logic   write_addr_out_ready_i,
  output logic  write_addr_in_ready_o,
  output logic  write_addr_out_valid_o,

  input logic   write_data_in_valid_i,
  input logic   write_data_out_ready_i,
  output logic  write_data_in_ready_o,
  output logic  write_data_out_valid_o,

  input logic   read_data_in_valid_i,
  input logic   read_data_out_ready_i,
  output logic  read_data_in_ready_o,
  output logic  read_data_out_valid_o,

  input logic   write_resp_in_valid_i,
  input logic   write_resp_out_ready_i,
  output logic  write_resp_in_ready_o,
  output logic  write_resp_out_valid_o,

  input read_addr_req_t read_addr_req_i,
  input write_addr_req_t write_addr_req_i,
  input write_data_req_t write_data_req_i,
  input read_data_resp_t read_data_resp_i,
  input write_resp_t write_resp_i,

  output read_addr_req_t read_addr_req_o,
  output write_addr_req_t write_addr_req_o,
  output write_data_req_t write_data_req_o,
  output read_data_resp_t read_data_resp_o,
  output write_resp_t write_resp_o
);

  // Releaser instance

  logic [WriteRespBanksCapacity-1:0] write_resp_release_en;
  logic [ReadDataBanksCapacity-1:0] read_data_release_en;

  // Blocks the transactions if the releaser is not ready
  // logic releaser_read_data_ready;
  // logic releaser_write_resp_ready;

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
