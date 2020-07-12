// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simulated memory controller releaser

module simmem_releaser #(
    // Width of the messages, including identifier
    parameter int ReadAddressStructWidth = 64,
    parameter int WriteAddressStructWidth = 64,
    parameter int WriteDataStructWidth = 64,

    parameter int ReadDataBanksCapacity = 64,
    parameter int WriteRespBanksCapacity = 64,
    parameter int ReadDataDelayBanksCapacity = 64,
    parameter int WriteRespDelayBanksCapacity = 64,

    parameter int IDWidth = 8,
    parameter int CounterWidth = 8
) (
    input logic clk_i,
    input logic rst_ni,

    input logic raddr_in_valid_i,
    input logic raddr_out_ready_i,

    input logic waddr_in_valid_i,
    input logic waddr_out_ready_i,

    input logic wdata_in_valid_i,
    input logic wdata_out_ready_i,

    input logic rdata_out_ready_i,
    input logic rdata_out_valid_i,
  
    input logic wresp_out_ready_i,
    input logic wresp_out_valid_i,  

    input logic [ReadAddressStructWidth-1:0]  raddr_i,
    input logic [WriteAddressStructWidth-1:0] waddr_i,
    input logic [WriteDataStructWidth-1:0]    wdata_i,

    output logic [1:0][2**IDWidth-1:0] release_en_o
    // output logic rdata_ready_o,
    // output logic wresp_ready_o
  );


endmodule

