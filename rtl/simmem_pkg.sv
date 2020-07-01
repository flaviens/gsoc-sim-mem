// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// simmem package

package simmem_pkg;

  localparam IDWidth = 8;

  // Address field widths
  localparam AxAddrWidth = 8;
  localparam AxLenWidth = 8;
  localparam AxSizeWidth = 3;
  localparam AxBurstWidth = 2;
  localparam AxLockWidth = 2;
  localparam AxCacheWidth = 4;
  localparam AxProtWidth = 4;
  localparam AxQoSWidth = 4;
  localparam AxRegionWidth = 4;
  localparam AwUserWidth = 0;
  localparam ArUserWidth = 0;

  // Data & response field widths
  localparam XDataWidth = 32;
  localparam XLastWidth = 1;
  localparam XRespWidth = 1;
  localparam WUserWidth = 0;
  localparam RUserWidth = 0;
  localparam BUserWidth = 0;
  
  localparam WStrbWidth = XDataWidth / 8;


  typedef struct packed {
    logic [IDWidth-1:0] id;
    logic [AxAddrWidth-1:0] addr;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxBurstWidth-1:0] burst_type;
    logic [AxLockWidth-1:0] lock_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxQoSWidth-1:0] qos;
    // logic [AwUserWidth-1:0] user_signal;
  } write_addr_req_t;

  typedef struct packed {
    logic [IDWidth-1:0] id;
    logic [AxAddrWidth-1:0] addr;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxBurstWidth-1:0] burst_type;
    logic [AxLockWidth-1:0] lock_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxQoSWidth-1:0] qos;
    // logic [ArUserWidth-1:0] user_signal;
  } read_addr_req_t;

  typedef struct packed {
    logic [IDWidth-1:0] id;
    logic [XDataWidth-1:0] data;
    logic [WStrbWidth-1:0] strobes;
    logic [XLastWidth-1:0] last;
    // logic [WUserWidth-1:0] user_signal;
  } write_data_req_t;

  typedef struct packed {
    logic [IDWidth-1:0] id;
    logic [XDataWidth-1:0] data;
    logic [WStrbWidth-1:0] response;
    logic [XLastWidth-1:0] last;
    // logic [RUserWidth-1:0] user_signal;
  } read_data_resp_t;

  typedef struct packed {
    logic [IDWidth-1:0] id;
    logic [XRespWidth-1:0] response;
    // logic [BUserWidth-1:0] user_signal;
  } write_resp_t;



  typedef enum logic {
    MESSAGE_RAM = 1'b0,
    NEXT_ELEM_RAM = 1'b1
  } ram_bank_e;

  typedef enum logic {
    RAM_IN = 1'b0,
    RAM_OUT = 1'b1
  } ram_port_e;

endpackage
