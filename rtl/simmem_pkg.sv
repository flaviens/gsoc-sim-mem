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

  localparam int unsigned GlobalMemCapa = 65536;  // Bytes.
  localparam int unsigned GlobalMemCapaW = $clog2(GlobalMemCapa);

  // The log2 of the width of a row in the banks.
  localparam int unsigned RowBufLenW = 8;
  // The number of MSBs that uniquely define a bank row in an address.
  localparam int unsigned RowIdWidth = GlobalMemCapaW - RowBufLenW;

  // TODO: 10, 50, 45
  localparam int unsigned RowHitCost = 4;  // Cycles (must be at least 3)
  localparam int unsigned PrechargeCost = 2;  // Cycles
  localparam int unsigned ActivationCost = 1;  // Cycles

  // Log2 of the boundary that cannot be crossed by bursts.
  localparam int unsigned BurstAddrLSBs = 12;


  /////////////////
  // AXI signals //
  /////////////////

  localparam int unsigned IDWidth = 2;
  localparam int unsigned NumIds = 2 ** IDWidth;

  // Address field widths
  localparam int unsigned AxAddrWidth = GlobalMemCapaW;
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
    logic [AxLenWidth-1:0] burst_len;
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
    logic [AxLenWidth-1:0] burst_len;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } raddr_t;

  typedef struct packed {
    // logic [WUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] strobes;
    logic [MaxBurstSizeBytes-1:0] data;
  // logic [IDWidth-1:0] id; AXI4 does not allocate identifiers in write data messages
  } wdata_t;

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
  } wrsp_merged_payload_t;

  // For the write response, the union is only a wrapper helping generic response bank implementation
  typedef union packed {wrsp_merged_payload_t merged_payload;} wrsp_t;

  localparam int unsigned MaxRBurstLen = 8;
  localparam int unsigned MaxWBurstLen = 4;

  localparam int unsigned MaxRBurstLenW = $clog2(MaxRBurstLen);
  localparam int unsigned MaxWBurstLenW = $clog2(MaxWBurstLen);

  ////////////////////////////
  // Dimensions for modules //
  ////////////////////////////

  localparam int unsigned WRspBankCapa = 32;
  localparam int unsigned RDataBankCapa = 16;

  localparam int unsigned WRspBankAddrW = $clog2(WRspBankCapa);
  localparam int unsigned RDataBankAddrW = $clog2(RDataBankCapa);

  // Internal identifier types
  typedef logic [WRspBankAddrW-1:0] write_iid_t;
  typedef logic [RDataBankAddrW-1:0] read_iid_t;

  // Delay calculator slot constants definition.
  localparam int unsigned NumWSlots = 6;
  localparam int unsigned NumRSlots = 3;

  // Maximal width on which to encode a delay.
  localparam int unsigned DelayW = 6;  // bits


endpackage
