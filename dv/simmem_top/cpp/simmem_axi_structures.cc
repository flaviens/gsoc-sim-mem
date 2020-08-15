// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simmem_axi_structures.h"

// Static constant definition (widths)
const uint64_t WriteAddressRequest::id_w = IDWidth;
const uint64_t WriteAddressRequest::addr_w = AxAddrWidth;
const uint64_t WriteAddressRequest::burst_len_w = AxLenWidth;
const uint64_t WriteAddressRequest::burst_size_w = AxSizeWidth;
const uint64_t WriteAddressRequest::burst_type_w = AxBurstWidth;
const uint64_t WriteAddressRequest::lock_type_w = AxLockWidth;
const uint64_t WriteAddressRequest::mem_type_w = AxCacheWidth;
const uint64_t WriteAddressRequest::prot_w = AxProtWidth;
const uint64_t WriteAddressRequest::qos_w = AxQoSWidth;

const uint64_t ReadAddressRequest::id_w = IDWidth;
const uint64_t ReadAddressRequest::addr_w = AxAddrWidth;
const uint64_t ReadAddressRequest::burst_len_w = AxLenWidth;
const uint64_t ReadAddressRequest::burst_size_w = AxSizeWidth;
const uint64_t ReadAddressRequest::burst_type_w = AxBurstWidth;
const uint64_t ReadAddressRequest::lock_type_w = AxLockWidth;
const uint64_t ReadAddressRequest::mem_type_w = AxCacheWidth;
const uint64_t ReadAddressRequest::prot_w = AxProtWidth;
const uint64_t ReadAddressRequest::qos_w = AxQoSWidth;

const uint64_t WriteResponse::id_w = IDWidth;
const uint64_t WriteResponse::rsp_w = XRespWidth;

const uint64_t WriteData::id_w = IDWidth;
const uint64_t WriteData::data_w = MaxBurstSizeBytes;
const uint64_t WriteData::strb_w = WStrbWidth;
const uint64_t WriteData::last_w = XLastWidth;

const uint64_t ReadData::id_w = IDWidth;
const uint64_t ReadData::data_w = MaxBurstSizeBytes;
const uint64_t ReadData::rsp_w = XRespWidth;
const uint64_t ReadData::last_w = XLastWidth;

// Static constant definition (offsets)
const uint64_t WriteAddressRequest::id_off = 0UL;
const uint64_t WriteAddressRequest::addr_off =
    WriteAddressRequest::id_off + WriteAddressRequest::id_w;
const uint64_t WriteAddressRequest::burst_len_off =
    WriteAddressRequest::addr_off + WriteAddressRequest::addr_w;
const uint64_t WriteAddressRequest::burst_size_off =
    WriteAddressRequest::burst_len_off + WriteAddressRequest::burst_len_w;
const uint64_t WriteAddressRequest::burst_type_off =
    WriteAddressRequest::burst_size_off + WriteAddressRequest::burst_size_w;
const uint64_t WriteAddressRequest::lock_type_off =
    WriteAddressRequest::burst_type_off + WriteAddressRequest::burst_type_w;
const uint64_t WriteAddressRequest::mem_type_off =
    WriteAddressRequest::lock_type_off + WriteAddressRequest::lock_type_w;
const uint64_t WriteAddressRequest::prot_off =
    WriteAddressRequest::mem_type_off + WriteAddressRequest::mem_type_w;
const uint64_t WriteAddressRequest::qos_off =
    WriteAddressRequest::prot_off + WriteAddressRequest::prot_w;

const uint64_t ReadAddressRequest::id_off = 0UL;
const uint64_t ReadAddressRequest::addr_off =
    ReadAddressRequest::id_off + ReadAddressRequest::id_w;
const uint64_t ReadAddressRequest::burst_len_off =
    ReadAddressRequest::addr_off + ReadAddressRequest::addr_w;
const uint64_t ReadAddressRequest::burst_size_off =
    ReadAddressRequest::burst_len_off + ReadAddressRequest::burst_len_w;
const uint64_t ReadAddressRequest::burst_type_off =
    ReadAddressRequest::burst_size_off + ReadAddressRequest::burst_size_w;
const uint64_t ReadAddressRequest::lock_type_off =
    ReadAddressRequest::burst_type_off + ReadAddressRequest::burst_type_w;
const uint64_t ReadAddressRequest::mem_type_off =
    ReadAddressRequest::lock_type_off + ReadAddressRequest::lock_type_w;
const uint64_t ReadAddressRequest::prot_off =
    ReadAddressRequest::mem_type_off + ReadAddressRequest::mem_type_w;
const uint64_t ReadAddressRequest::qos_off =
    ReadAddressRequest::prot_off + ReadAddressRequest::prot_w;

const uint64_t WriteResponse::id_off = 0UL;
const uint64_t WriteResponse::rsp_off =
    WriteResponse::id_off + WriteResponse::id_w;

const uint64_t WriteData::id_off = 0UL;
const uint64_t WriteData::data_off = WriteData::id_off + WriteData::id_w;
const uint64_t WriteData::strb_off = WriteData::data_off + WriteData::data_w;
const uint64_t WriteData::last_off = WriteData::strb_off + WriteData::strb_w;

const uint64_t ReadData::id_off = 0UL;
const uint64_t ReadData::data_off = ReadData::id_off + ReadData::id_w;
const uint64_t ReadData::rsp_off = ReadData::data_off + ReadData::data_w;
const uint64_t ReadData::last_off = ReadData::rsp_off + ReadData::rsp_w;

/**
 * Helper function to parse a packed structure representation
 *
 * @param packed the packed structure representation
 * @param field_w the field representation width (bits)
 * @param field_off the field representation offset (bits)
 * @return the field value read from the packed representation
 */
uint64_t single_from_packed(uint64_t packed, uint64_t field_w,
                            uint64_t field_off) {
  uint64_t low_mask;

  if (field_w) {
    low_mask = ~(1L << (PackedW - 1)) >> (PackedW - 1 - field_w);
    return low_mask & ((packed & (low_mask << field_off)) >> field_off);
  }
  return 0;
}

/**
 * Helper function that fills a partial packed structure representation from
 * a single field.
 *
 * @param packed the partial packed structure representation, modified in place
 * @param field the field value
 * @param field_w the field representation width (bits)
 * @param field_off the field representation offset (bits)
 */
void single_to_packed(uint64_t &packed, uint64_t field, uint64_t field_w,
                      uint64_t field_off) {
  uint64_t low_mask;

  if (field_w) {
    low_mask = ~((1L << (PackedW - 1)) >> (PackedW - 1 - field_w));
    // Clean the space dedicated to the field
    packed &= ~(low_mask << field_off);
    // Populate the space dedicated to the field
    packed |= (low_mask & field) << field_off;
  }
}

///////////////////////////
// Write address request //
///////////////////////////

void WriteAddressRequest::from_packed(uint64_t packed) {
  id = single_from_packed(packed, id_w, id_off);
  addr = single_from_packed(packed, addr_w, addr_off);
  burst_len = single_from_packed(packed, burst_len_w, burst_len_off);
  burst_size = single_from_packed(packed, burst_size_w, burst_size_off);
  burst_type = single_from_packed(packed, burst_type_w, burst_type_off);
  lock_type = single_from_packed(packed, lock_type_w, lock_type_off);
  mem_type = single_from_packed(packed, mem_type_w, mem_type_off);
  prot = single_from_packed(packed, prot_w, prot_off);
  qos = single_from_packed(packed, qos_w, qos_off);
}

uint64_t WriteAddressRequest::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, addr, addr_w, addr_off);
  single_to_packed(packed, burst_len, burst_len_w, burst_len_off);
  single_to_packed(packed, burst_size, burst_size_w, burst_size_off);
  single_to_packed(packed, burst_type, burst_type_w, burst_type_off);
  single_to_packed(packed, lock_type, lock_type_w, lock_type_off);
  single_to_packed(packed, mem_type, mem_type_w, mem_type_off);
  single_to_packed(packed, prot, prot_w, prot_off);
  single_to_packed(packed, qos, qos_w, qos_off);

  return packed;
}

///////////////////////////
// Read address request //
///////////////////////////

void ReadAddressRequest::from_packed(uint64_t packed) {
  id = single_from_packed(packed, id_w, id_off);
  addr = single_from_packed(packed, addr_w, addr_off);
  burst_len = single_from_packed(packed, burst_len_w, burst_len_off);
  burst_size = single_from_packed(packed, burst_size_w, burst_size_off);
  burst_type = single_from_packed(packed, burst_type_w, burst_type_off);
  lock_type = single_from_packed(packed, lock_type_w, lock_type_off);
  mem_type = single_from_packed(packed, mem_type_w, mem_type_off);
  prot = single_from_packed(packed, prot_w, prot_off);
  qos = single_from_packed(packed, qos_w, qos_off);
}

uint64_t ReadAddressRequest::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, addr, addr_w, addr_off);
  single_to_packed(packed, burst_len, burst_len_w, burst_len_off);
  single_to_packed(packed, burst_size, burst_size_w, burst_size_off);
  single_to_packed(packed, burst_type, burst_type_w, burst_type_off);
  single_to_packed(packed, lock_type, lock_type_w, lock_type_off);
  single_to_packed(packed, mem_type, mem_type_w, mem_type_off);
  single_to_packed(packed, prot, prot_w, prot_off);
  single_to_packed(packed, qos, qos_w, qos_off);

  return packed;
}

////////////////////
// Write response //
////////////////////

void WriteResponse::from_packed(uint64_t packed) {
  uint64_t low_mask;

  id = single_from_packed(packed, id_w, id_off);
  rsp = single_from_packed(packed, rsp_w, rsp_off);
}

uint64_t WriteResponse::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, rsp, rsp_w, rsp_off);

  return packed;
}

////////////////
// Write data //
////////////////

void WriteData::from_packed(uint64_t packed) {
  uint64_t low_mask;

  id = single_from_packed(packed, id_w, id_off);
  data = single_from_packed(packed, data_w, data_off);
  strb = single_from_packed(packed, strb_w, strb_off);
  last = single_from_packed(packed, last_w, last_off);
}

uint64_t WriteData::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, data, data_w, data_off);
  single_to_packed(packed, strb, strb_w, strb_off);
  single_to_packed(packed, last, last_w, last_off);

  return packed;
}

///////////////
// Read data //
///////////////

void ReadData::from_packed(uint64_t packed) {
  uint64_t low_mask;

  id = single_from_packed(packed, id_w, id_off);
  data = single_from_packed(packed, data_w, data_off);
  rsp = single_from_packed(packed, rsp_w, rsp_off);
  last = single_from_packed(packed, last_w, last_off);
}

uint64_t ReadData::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, data, data_w, data_off);
  single_to_packed(packed, rsp, rsp_w, rsp_off);
  single_to_packed(packed, last, last_w, last_off);

  return packed;
}