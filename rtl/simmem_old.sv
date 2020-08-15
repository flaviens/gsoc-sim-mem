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

  input logic   raddr_in_valid_i,
  input logic   raddr_out_ready_i,
  output logic  raddr_in_ready_o,
  output logic  raddr_out_valid_o,

  input logic   waddr_in_valid_i,
  input logic   waddr_out_ready_i,
  output logic  waddr_in_ready_o,
  output logic  waddr_out_valid_o,

  input logic   wdata_in_valid_i,
  input logic   wdata_out_ready_i,
  output logic  wdata_in_ready_o,
  output logic  wdata_out_valid_o,

  input logic   rdata_in_valid_i,
  input logic   rdata_out_ready_i,
  output logic  rdata_in_ready_o,
  output logic  rdata_out_valid_o,

  input logic   wresp_in_valid_i,
  input logic   wresp_out_ready_i,
  output logic  wresp_in_ready_o,
  output logic  wresp_out_valid_o,

  input raddr_t raddr_i,
  input waddr_t waddr_i,
  input wdata_t wdata_i,
  input rdata_t rdata_i,
  input wresp_t wresp_i,

  output raddr_t raddr_o,
  output waddr_t waddr_o,
  output wdata_t wdata_o,
  output rdata_t rdata_o,
  output wresp_t wresp_o
);

  // Releaser instance

  logic [WriteRespBanksCapacity-1:0] wresp_release_en;
  logic [ReadDataBanksCapacity-1:0] rdata_release_en;

  // Blocks the transactions if the releaser is not ready
  // logic releaser_rdata_ready;
  // logic releaser_wresp_ready;

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

    .raddr_in_valid_i,
    .raddr_out_ready_i,

    .waddr_in_valid_i,
    .waddr_out_ready_i,

    .wdata_in_valid_i,
    .wdata_out_ready_i,

    .rdata_in_valid_i,
    .rdata_out_ready_i,
    .rdata_in_ready_i(rdata_in_ready_o),
    .rdata_out_valid_i(rdata_out_valid_o),
  
    .wresp_in_valid_i,
    .wresp_out_ready_i,
    .wresp_in_ready_i(wresp_in_ready_o),
    .wresp_out_valid_i(wresp_out_valid_o),

    .raddr_i,
    .waddr_i,
    .wdata_i,

    .wresp_release_en_o(wresp_release_en),
    .rdata_release_en_o(rdata_release_en)
    // .rdata_ready_o(releaser_rdata_ready)
    // .releaser_wresp_ready_o(releaser_wresp_ready)
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
  
    .wresp_release_en_i(wresp_release_en),
    .rdata_release_en_i(rdata_release_en)
  
    .rdata_i,
    .wresp_i,
  
    .rdata_o,
    .wresp_o,
  
    .rdata_in_valid_i,
    .rdata_out_ready_i,
    .rdata_in_ready_o,
    .rdata_out_valid_o,
  
    .wresp_in_valid_i,
    .wresp_out_ready_i,
    .wresp_in_ready_o,
    .wresp_out_valid_o
  );


  // I/O signals

  assign rdata_in_ready_o = rdata_out_ready_i;
  assign raddr_in_ready_o = raddr_out_ready_i;
  assign waddr_in_ready_o = waddr_out_ready_i;

endmodule
