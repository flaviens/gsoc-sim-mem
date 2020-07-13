// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef SIMMEM_DV_AXI_STRUCTURES
#define SIMMEM_DV_AXI_STRUCTURES

#include "simmem_axi_dimensions.h"

///////////////////////////
// Write address request //
///////////////////////////

struct WriteAddressRequest {
  // Shift offsets and widths in the packed representations
  static const uint64_t id_offset, id_width;
  static const uint64_t addr_offset, addr_width;
  static const uint64_t burst_length_offset, burst_length_width;
  static const uint64_t burst_size_offset, burst_size_width;
  static const uint64_t burst_type_offset, burst_type_width;
  static const uint64_t lock_type_offset, lock_type_width;
  static const uint64_t memory_type_offset, memory_type_width;
  static const uint64_t protection_type_offset, protection_type_width;
  static const uint64_t qos_offset, qos_width;

  uint64_t id;
  uint64_t addr;
  uint64_t burst_length;
  uint64_t burst_size;
  uint64_t burst_type;
  uint64_t lock_type;
  uint64_t memory_type;
  uint64_t protection_type;
  uint64_t qos;

  uint64_t to_packed();
  void from_packed(uint64_t packed_val);
};

////////////////////
// Write response //
////////////////////

struct WriteResponse {
  // Shift offsets and widths in the packed representations
  static const uint64_t id_offset, id_width;
  static const uint64_t content_offset, content_width;

  uint64_t id;
  uint64_t content;

  uint64_t to_packed();
  void from_packed(uint64_t packed_val);
};

#endif  // SIMMEM_DV_AXI_STRUCTURES
