// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef SIMMEM_DV_AXI_DIMENSIONS
#define SIMMEM_DV_AXI_DIMENSIONS

#include <stdint.h>

// TODO: Change the const names to fit with the C++ coding style
// Values must match those in simmem_pkg.sv

const uint64_t GlobalMemoryCapaWidth = 16;

const uint64_t IDWidth = 2;
const uint64_t NumIds = 1 << IDWidth;

// Address field widths
const uint64_t AxAddrWidth = GlobalMemoryCapaWidth;
const uint64_t AxLenWidth = 8;
const uint64_t AxSizeWidth = 3;
const uint64_t AxBurstWidth = 2;
const uint64_t AxLockWidth = 2;
const uint64_t AxCacheWidth = 4;
const uint64_t AxProtWidth = 4;
const uint64_t AxQoSWidth = 4;
const uint64_t AxRegionWidth = 4;
const uint64_t AwUserWidth = 0;
const uint64_t ArUserWidth = 0;

// Data & response field widths
const uint64_t MaxBurstSizeBytes = 4;
const uint64_t MaxBurstSizeBits = MaxBurstSizeBytes << 3;
const uint64_t XLastWidth = 1;
// TODO: Set XRespWidth to 3 when all tests are passed
const uint64_t XRespWidth = 10;
const uint64_t WUserWidth = 0;
const uint64_t RUserWidth = 0;
const uint64_t BUserWidth = 0;

const uint64_t WStrbWidth = MaxBurstSizeBytes;

const unsigned int PackedW = 64;

////////////////////////////
// Dimensions for modules //
////////////////////////////

const uint64_t WriteRespBankCapacity = 32;
const uint64_t ReadDataBankCapacity = 16;

#endif  // SIMMEM_DV_AXI_DIMENSIONS
