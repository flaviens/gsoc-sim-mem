// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// TODO: Add the management of read data

module simmem_delay_calculator (
  // input logic clk_i,
  // input logic rst_ni,
  
  input logic [simmem_pkg::WriteRespBankAddrWidth-1:0] wresp_local_id_i,
  input logic in_valid_i,
  
  output logic [simmem_pkg::WriteRespBankAddrWidth-1:0] local_id_o,
  output logic [simmem_pkg::DelayWidth-1:0] delay_o,
  output logic out_valid_o
);

  import simmem_pkg::*;

  assign delay_o = 30;  // Fixed delay of 10 cycles for now
  assign local_id_o = wresp_local_id_i;
  assign out_valid_o = in_valid_i;

endmodule
