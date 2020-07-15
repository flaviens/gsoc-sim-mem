// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// simmem package

package simmem_pkg;

  /////////////////
  // AXI signals //
  /////////////////

  localparam IDWidth = 4;
  localparam NumIds = 2 ** IDWidth;

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
  localparam XRespWidth = 10;  // TODO: Set to 3
  localparam WUserWidth = 0;
  localparam RUserWidth = 0;
  localparam BUserWidth = 0;

  localparam WStrbWidth = XDataWidth / 8;

  typedef struct packed {
    // logic [AwUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    logic [AxBurstWidth-1:0] burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } waddr_req_t;

  typedef struct packed {
    // logic [ArUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    logic [AxBurstWidth-1:0] burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } raddr_req_t;

  typedef struct packed {
    // logic [WUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] strobes;
    logic [XDataWidth-1:0] data;
    logic [IDWidth-1:0] id;
  } wdata_req_t;

  typedef struct packed {
    // logic [RUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] response;
    logic [XDataWidth-1:0] data;
    logic [IDWidth-1:0] id;
  } rdata_resp_t;

  localparam ReadDataRespWidth = IDWidth + XDataWidth + WStrbWidth + XLastWidth;

  typedef struct packed {
    // logic [BUserWidth-1:0] user_signal;
    logic [XRespWidth-1:0] content;
    logic [IDWidth-1:0] id;
  } wresp_t;

  localparam WriteRespWidth = IDWidth + XRespWidth;


  ////////////////////////////
  // Dimensions for modules //
  ////////////////////////////

  localparam WriteRespBankTotalCapacity = 32;
  localparam ReadDataBankTotalCapacity = 32;

  localparam WriteRespBankAddrWidth = $clog2(WriteRespBankTotalCapacity);
  localparam ReadDataBankAddrWidth = $clog2(ReadDataBankTotalCapacity);

  localparam MaxBurstLength = 4;

  localparam DelayWidth = 6;


  ////////////////////////////
  // Enumerations for banks //
  ////////////////////////////

  typedef struct packed {logic [WriteRespBankAddrWidth-1:0] nxt_elem;} wresp_metadata_e;

  localparam WriteRespMetadataWidth = WriteRespBankAddrWidth;

endpackage
