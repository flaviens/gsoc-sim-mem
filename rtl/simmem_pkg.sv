// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// simmem package

// Values must match those in simmem_axi_dimensions.h

package simmem_pkg;

  ///////////////////////
  // System parameters //
  ///////////////////////

  localparam int unsigned GlobalMemoryCapa = 65536;  // Bytes.
  localparam int unsigned GlobalMemoryCapaWidth = $clog2(GlobalMemoryCapa);
  localparam int unsigned RowBufferLenWidth = 8;

  localparam int unsigned RowHitCost = 10;  // Cycles (must be at least 3)
  localparam int unsigned PrechargeCost = 50;  // Cycles
  localparam int unsigned ActivationCost = 45;  // Cycles


  /////////////////
  // AXI signals //
  /////////////////

  localparam int unsigned IDWidth = 2;
  localparam int unsigned NumIds = 2 ** IDWidth;

  // Address field widths
  localparam int unsigned AxAddrWidth = GlobalMemoryCapaWidth;
  localparam int unsigned AxLenWidth = 8;
  localparam int unsigned AxSizeWidth = 3;
  localparam int unsigned AxBurstWidth = 2;
  localparam int unsigned AxLockWidth = 2;
  localparam int unsigned AxCacheWidth = 4;
  localparam int unsigned AxProtWidth = 4;
  localparam int unsigned AxQoSWidth = 4;
  localparam int unsigned AxRegionWidth = 4;
  localparam int unsigned AwUserWidth = 0;
  localparam int unsigned ArUserWidth = 0;

  // Data & response field widths
  localparam int unsigned MaxBurstSizeBytes = 4;
  localparam int unsigned MaxBurstSizeBits = MaxBurstSizeBytes * 8;
  localparam int unsigned XLastWidth = 1;
  // TODO: Set XRespWidth to 3 when all tests are passed
  localparam int unsigned XRespWidth = 10;
  localparam int unsigned WUserWidth = 0;
  localparam int unsigned RUserWidth = 0;
  localparam int unsigned BUserWidth = 0;

  localparam int unsigned WStrbWidth = MaxBurstSizeBytes;

  typedef enum logic [AxBurstWidth-1:0] {
    BURST_FIXED = 0,
    BURST_INCR = 1,
    BURST_WRAP = 2,
    BURST_RESERVED = 3
  } burst_type_e;

  typedef struct packed {
    // logic [AwUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    burst_type_e burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } waddr_t;

  typedef struct packed {
    // logic [ArUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    burst_type_e burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_length;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } raddr_req_t;

  typedef struct packed {
    // logic [WUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] strobes;
    logic [MaxBurstSizeBytes-1:0] data;
  // logic [IDWidth-1:0] id; AXI4 does not allocate identifiers in write data messages
  } wdata_req_t;

  typedef struct packed {
    // logic [RUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] response;
    logic [MaxBurstSizeBytes-1:0] data;
    logic [IDWidth-1:0] id;
  } rdata_all_fields_t;

  typedef struct packed {
    logic [$bits(rdata_all_fields_t)-IDWidth-1:0] payload;
    logic [IDWidth-1:0] id;
  } rdata_merged_payload_t;

  typedef union packed {
    rdata_all_fields_t all_fields;
    rdata_merged_payload_t merged_payload;
  } rdata_t;

  typedef struct packed {
    // logic [BUserWidth-1:0] user_signal;
    logic [XRespWidth-1:0] payload;
    logic [IDWidth-1:0] id;
  } wresp_merged_payload_t;

  // For the write response, the union is only a wrapper helping generic response bank implementation
  typedef union packed {wresp_merged_payload_t merged_payload;} wresp_t;

  localparam int unsigned MaxRBurstLen = AxLenWidth >> 1;
  localparam int unsigned MaxWBurstLen = AxLenWidth >> 1;

  localparam int unsigned MaxRBurstLenWidth = $clog2(MaxRBurstLen);
  localparam int unsigned MaxWBurstLenWidth = $clog2(MaxWBurstLen);

  ////////////////////////////
  // Dimensions for modules //
  ////////////////////////////

  localparam int unsigned WriteRespBankCapacity = 32;
  localparam int unsigned ReadDataBankCapacity = 16;

  localparam int unsigned WriteRespBankAddrWidth = $clog2(WriteRespBankCapacity);
  localparam int unsigned ReadDataBankAddrWidth = $clog2(ReadDataBankCapacity);

  // Internal identifier types
  typedef logic [WriteRespBankAddrWidth-1:0] write_iid_t;
  typedef logic [ReadDataBankAddrWidth-1:0] read_iid_t;

  localparam int unsigned DelayWidth = 6;

endpackage
