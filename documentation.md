# Simulated memory controller

Copyright lowRISC contributors.
Licensed under the Apache License, Version 2.0, see [LICENSE](https://github.com/lowRISC/gsoc-sim-mem/blob/master/LICENSE) for details.
SPDX-License-Identifier: Apache-2.0

## Table of Contents

[TOC]

## Outline

This project has been initiated as a [Google Summer of Code](https::/summerofcode.withgoogle.com) 2020 project at lowRISC CIC.

As the gap between CPU and main memory frequency has dramatically increased in the past decades, a CPU typically interacts with a relatively slow main memory, which requires a considerable number of cycles to output data.

This is one reason why benchmarking a CPU core on a FPGA is a delicate task. As the soft core frequency is reduced compared to an ASIC implementation, its main memory may respond much faster than in typical ASIC operation. Additionally, there is no straightforward way to emulate a specific main memory configuration.

This project aims at responding to this demand.

## Features

The simulated memory controller, compatible with AXI 4, allows the user to slow down the interaction with the main memory and configure it with realistic delays. No changes are required neither in the real memory controller, nor in the CPU.

The simulated memory controller enforces response ordering per write AXI channel and read AXI channel, but treats read and write AXI identifiers independently. For example, a read request on a given AXI identifier can be answered after a subsequent write on the same AXI identifier, but must be answered earlier than any subsequent read request on the same AXI identifier.

## Overview

The simulated memory controller module is inserted between the _requester_ (typically the CPU) and the (real) _memory controller_.

<figure class="image">
  <img src="https://i.imgur.com/d8Mdtiu.png" alt="Simulated memory controller integration overview">
  <figcaption>Fig: Simulated memory controller overview</figcaption>
</figure>

### Requests

The simulated memory controller transparently lets the requests (upward in the figure) pass from the requester to the memory controller. Only if some internal data structures are full, then the simulated memory controller may temporarily block some requests.

### Responses

The simulated memory controller is designed to emulate a memory controller, controlling a much slower memory than the one driven by the real memory controller behind it. Therefore, it is assumed that the responses are available from the real memory controller earlier than they should be released to the requester.

The responses are then stored in the simulated memory controller while waiting a certain calculated delay, after which they are released if the previous responses with the same AXI id have been released.

### Top-level overview

#### Top-level microarchitecture

The simulated memory controller is made of two major blocks:

- The delay calculator, which has as major responsibility to look at the request traffic and to deduce, according to the simulated memory controller parameters.
- The response banks, which have as major responsibilities to:
  a. Store the responses from the real memory controller until they can be released.
  b. Enforce the ordering per AXI identifier, letting the delay calculator be agnostic of the AXI identifier.

The delay calculator identifies address requests by internal identifiers (_iids_), which are not correlated with AXI identifiers. Precisely, write responses and read data use separate iid spaces: each response to an address request is therefore identified by the pair (read/write, iid), although the first entry of the pair is always implicit.

<figure class="image">
  <img src="https://i.imgur.com/ri0Ej2o.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Simulated memory controller overview</figcaption>
</figure>



#### Top-level flow

The top-level flow happens as follows:

0. The response banks constantly advertise the identifier that will be allocated to the next address request.
1. When the address request comes in:
   - The delay calculator and the response banks are notified when an address request happens.
   - The delay calculator stores metadata for its delay computation.
   - The response banks reserve space for the corresponding responses that will subsequently come back from the real memory controller.
2. When the corresponding responses comes back from the real memory controller, they are stored by the message banks.
3. When the delay enables the release of some response and all the previous responses of the same AXI are released, the response banks transmit the response to the requester.
4. When all the responses corresponding to a given address request have been transmitted to the requester, the response banks free the allocated memory for reuse.
5. 

<figure class="image">
  <img src="https://i.imgur.com/pbbpy0Y.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Simulated memory controller top-level flow</figcaption>
</figure>



## Response banks

### High-level design

The _simmem_resp_banks_ module is made of two distinct _simmem_resp_bank_ modules:

- The write response bank, responsible for storing write responses.
- The read data bank, responsible for storing read data. As read data can come back as burst data, this bank has to additionally support bursts, which is the essential difference with the write response bank.

The two banks act independently.

Each response bank has a FIFO interface with reservations, and stores messages in RAMs. FIFOs are implemented as linked lists to make best use of the RAM space.

<figure class="image">
  <img src="https://i.imgur.com/BpU4aZz.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Response bank top-level interface</figcaption>
</figure>


### Reservations

The reservation mechanism built in the response banks provides simultaneously two features:

1. It ensures that the responses to an address request will have space to be stored aas soon as they are produced. This prevents inflated delays between request address acceptation and its response in the case of congestion in the response banks. This also prevents any deadlock situation.
2. It provides internal identifiers, as soon as the address requests are made. This allows the delay calculator to immediately label the request metadata, for immediate processing. As the real memory controller may require multiple cycles to provide a response to an address request, producing an internal identifier as early as possible is a necessary feature.

### RAMs

Each response bank uses three dual-port RAM banks:

- _i_payload_ram_, responsible for storing the responses before they are transmitted to the requester. As there is one linked list per AXI identifier, the AXI identifier is not stored in the RAM, but deduced from its linked list identifier when it is released.
- _i_meta_ram_out_tail_ and _i_meta_ram_out_head_, responsible for storing the linked list states: for each linked list element, they store the pointer to the next element in the payload RAM.

Two RAM banks are used to hold pointer to next elements, as three ports are needed (which is explained by the linked list implementation below). Their content is therefore maintained identical, but they may be read at different addresses simultaneously.

Using RAMs is efficient as it does not require a massive amount of flip-flops to store data, but incurs one cycle latency for the output.

<figure class="image">
  <img src="https://i.imgur.com/mH3dPLo.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Response banks RAMs</figcaption>
</figure>

### Extended RAM cells

Two options have been explored to store burst responses, while keeping a single internal identifier per address (and, therefore, per full burst of responses):

1. _In-width burst storage_: Storing all the responses corresponding to the same burst in the same physical RAM cell, using masks to write and retrieve them.
2. _In-depth burst storage_: Storing all the responses corresponding to the same burst in consecutive physical RAM cells.

<figure class="image">
  <img src="https://i.imgur.com/1yWktlc.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: In-width burst storage (not chosen as implementation), for a burst length of 4</figcaption>
</figure>

The burst support has been implemented _in-depth_, because the block RAMs are typically narrow and deep, and do not always propose write masks, which makes in-width storage difficult.

The _MaxBurstLen_ (maximum read burst length, or 1 for write responses) consecutive RAM cells dedicated to the same burst are referred to as _extended RAM cells_. On a high level, extended RAM cells are the elementary data structures in linked lists. BY opposition to extended RAM cells, the actual physical RAM cells are called _elementary RAM cells_.

We additionally introduce two address spaces:

- _address_: refers to the address of the extended cells, viewing them as elementary storage elements. This matches with addresses as defined by the metadata RAM.
- _full address_: refers to the full address of an elementary cell in the payload RAM.

<figure class="image">
  <img src="https://i.imgur.com/VzySGSn.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: In-depth burst storage, for a burst length of 4</figcaption>
</figure>


<figure class="image">
  <img src="https://i.imgur.com/fzaWZ6v.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: In-depth burst storage addressing</figcaption>
</figure>


Therefore, there are _MaxBurstLen_ times as many elementary RAM cells in _i_payload_ram_ than there are in each of _i_meta_ram_out_tail_ and _i_meta_ram_out_head_.

An extended cell is called _active_ if it has already acquired a response and has not acquired and released all the responses corresponding to the allocated burst.

### Linked list implementation

Linked lists enforce the ordering of the response release as defined by the AXI identifier.

#### Linked list pointers

Linked lists are logical structures maintained by the _i_meta_ram_out_tail_ and _i_meta_ram_out_head_ RAMs as well as four pointers:

- Reservation head (_rsv_heads_q_): Points to the most recently reserved extended cell.
- Response head (_rsp_heads_): Points to the next RAM address where a response of the corresponding AXI identifier will be stored.
- Pre_tail (_pre_tails_): Points to the second-to-last cell hosting or awaiting a response in the linked list.
- Tail (_tails_): Points to the oldest cell hosting or awaiting a response in the linked list.

The order of the pointers must always be respected. They can be equal but never overtake each other, in the order defined by the linked list.

Two distinct tail pointers are required to dynamically manage the two following cases:

- The pre_tail address is given as input to the payload RAM if there is a successful output handshake and the value at the output has an AXI id corresponding to the AXI id of the considered linked list. It must point to:
  - The second-to-last element of the linked list if the list contains two reponses or more,
  - The last element element of the linked list if the list contains just one response,
  - rsp_head if the list contains no responses.
- The tail address is given as input to the payload RAM in all other cases. This case disjunction prevents an output data from being output twice, and prevents any bandwidth drop at the output. It must point to:
  - The last element element of the linked list if the list contains one response or more,
  - pre_tail if the list contains no responses.
  
<figure class="image">
  <img src="https://i.imgur.com/Y7XwICc.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Linked list representation. t: tail, pt: pre_tail, rsp: response head, rsv: reservation head. Arrows between extended cells represent the linked list structure (cells must not have consecutive addresses)</figcaption>
</figure>
 
 
#### Lengths

In addition to the pointers, lengths of sub-segments of linked lists are stored to maintain the state of each linked lists, which is not fully defined by the four pointer and metadata RAMs only:

- _rsv_len_: Holds the number of extended cells that have been reserved, but have not received any response yet.
- _rsp_len_: Holds the number of active extended cells.

<figure class="image">
  <img src="https://i.imgur.com/gj5IPNo.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Example of rsv_len and rsp_len</figcaption>
</figure>

Additionally, another length is combinatorially inferred:
- _rsp_len_after_out_: Determines what will be _rsp_len_, considering the release of responses but not the acquisition of new data. This signal is helpful in many regular and corner cases as it helps to manage the latency cycle at the output.

#### Extended cell state

##### Internal counters

For each extended RAM cells, additional memory is dedicated to maintaining the extended RAM cell state:

- _rsv_cnt_: Counts the number of responses that are still awaited in the burst. When reserving an extended cell, this counter is set to the address request burst length. The counter is decremented every time a burst response is transmitted from this extended RAM cell to the requester.
- _rsp_cnt_: Counts the number of responses that are currently stored in the extended cell. The counter is incremented everytime a response is acquired and decremented everytime a response is released.
- _burst_len_: Stores the burst length of the address request corresponding to this extended RAM cell.

The following relationship always holds:
$$burst\_len \ge rsv\_cnt + rsp\_cnt$$

Additionally, the number of released responses in a burst is given by:
$$burst\_len - rsv\_cnt - rsp\_cnt$$

And the number of already released responses in a burst is given by:
$$burst\_len - rsv\_cnt$$

An extended cell is said to be valid (_ram_v_) (in a terminology similar to a cache line for instance) if _rsv_cnt_ is non-zero or _rsp_cnt_ is non-zero.

##### Elementary cell offset

These three elements maintain full information of the extended cell state and give the offset of an elementary RAM cell inside an extended cell:

- The offset for data output is given by $tail\_burst\_len - tail\_rsv\_cnt - tail\_rsv\_cnt$, which corresponds to the number of burst responses already released. The offset may be taken from the _pre_tail_ instead of the _tail_ in the cases described further above.
- The offset for data input is given by $rsp\_burst\_len - rsp\_rsv\_cnt$, which corresponds to the number of burst responses already acquired (regardless of whether they have been already released).

#### Linked list detailed operation

A pointer _pA_ is said to be _piggybacked with_ another pointer _pB_ when we impose that _pA_ takes the same value as _pB_. Typically, this happens when _pA_ needs to be updated, but has to stay behind or equal to _pB_.

<figure class="image">
  <img src="https://i.imgur.com/qmJwLMn.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Piggybacking example, for pA piggybacked with pB </figcaption>
</figure>

This part depicts the linked list operation on different events: reservation, response acquisition and response transmission. Those events can all occur simultaneously, or any simultaneous combination of them is possible.

##### Reservation

Reservation is possible if there is some non-valid extended cell in the payload RAM.

On reservation,

- _Reservation head_: The reservation head of the linked list corresponding to the address request's AXI identifier (_rsv_req_id_onehot_i_) is moved to the address of a free extended RAM cell.
- _Response head_: If the response head used to point to an extended cell which already had received data (implying that is was equal to the reservation pointer), then the response head is piggybacked with the response head. This means, that if the reservation head is updated, then the response head is also updated with the same value. Else, they both remain untouched. Additionally, the response head is piggybacked with the reservation head if the linked list was empty.
- _Pre_tail_: The pre_tail is piggybacked with the reservation head on one of the conditions:
  - The linked list was empty.
  - The reservation length was 0 and the response length after possible output (_rsp_len_after_out_) is equal to 1.
- _Tail_: The tail is piggybacked with the reservation head if the linked list was empty.
- _Meta RAMs_: The metadata RAM is updated to let the previous reservation head point to the new reservation head, if the linked list was not empty.
- _Payload RAM_: Remains untouched.

##### Response acquisition

On response acquisition, if the extended cell is not becoming full (i.e., $rsv\_cnt > 1$), then no pointer or metadata RAM is updated. Only the burst counters are updated. If however $rsv\_cnt > 1$, then:

- _Reservation head_: Remains untouched.
- _Response head_:
  - If the response head is different from the reservation head, then it is updated from the metadata RAM.
  - Else, it is piggybacked with the reservation head (informally, it should be updated, but can only if the reservation head itself is updated, and additionally the linked list chain is not up to date in the RAM yet if the response head is updated).
- _Pre_tail_: The pre_tail is piggybacked with the response head the pre-tail used to be equal to the response head and one of the conditions:
  - $rsp\_len\_after\_out == 0$: when there is no no response stored or awaited in the linked list, then the pre_tail must be equal to the response head.
  - $rsp\_len\_after\_out == 1$: the pre_tail must be one cell ahead of the tail in the linked list, provided the response head is advanced enough.
- _Tail_: Remains untouched.
- _Meta RAMs_: Is read at the address _rsp_heads_, to possibly update the response head from the linked list pointers stored in RAM (see the _Response head_ point above).
- _Payload RAM_: The acquired response is stored in the payload RAM.

##### Response release

On response release, if the extended cell still holds or awaits data (i.e., $tail\_rsv\_cnt > 0 || tail\_rsp\_cnt > 0$), then no pointer or metadata RAM is updated. Only the burst counters are updated. Else:

- _Reservation head_: Remains untouched.
- _Response head_: Remains untouched.
- _Pre_tail_: If the pre_tail is different from (i.e., strictly behind) the response head, then it is updated from the metadata RAM. Else, it is piggybacked with the response head.
- _Tail_: Takes the previous value of the pre_tail.
- _Meta RAMs_: Is read at the address _pre_tails_, to possibly update the pre*tail from the linked list pointers stored in RAM (see the \_Pre_tail* point above).
- _Payload RAM_: The response is read from the RAM.

#### Output data

As there is one cycle latency between the output response selection and output response supply, some signals need to be stored over this clock cycle to identify which response is currently output:
- _cur_out_id_: Identifies the AXI identifier currently released. This helps updating the linked list pointers.
- _cur_out_addr_: Identifies the extended cell address currently released. This is involved in the release feedback signal to the delay calculator (_released_addr_).
- _cur_out_valid_: Identifies whether the output was intended in the previous clock cycle.

#### Additional response bank features

##### Release enable double-check

The release enable signal is read twice:

- During the cycle before the corresponding output, to select which signal to read from the RAMs.
- During the output cycle, to make sure that the release enable signal is still set. Else, the output is cancelled. The cancellation is done implicitly by unsetting the output ready signal.

## Delay calculator

### Scheduling strategy

The delay calculator emulates a memory request scheduler and applies a FR-FCFS scheme (First Ready, First Come First Served) scheduling strategy. For each parallel rank, if it is ready to take a new request, among all the memory requests mapping to this rank, consider the subset of those that has a minimal request cost (in terms of latency). Among this subset, take the oldest entry.

It favors write requests over read requests when all things are equal, but this have a very low impact. To favor read requests, follow the instructions in the three comment lines starting with _To favor read requests_.

Other scheduling strategies can be implemented without major architectural changes in the delay calculator core module, and without changes in any other module.

### Design

The _simmem_delay_calculator_ module observes and the requests coming from the requester. When address requests are detected, metadata is stored in _slots_. It then emulates a memory request scheduler to estimate the delay of the request in the simulated setting.

The _simmem_delay_calculator_ module is a wrapper around the _simmem_delay_calculator_core_ module. The wrapper's role is related to the write data requests ordering relatively to write address requests:

- It ensures that write data requests always reach the _simmem_delay_calculator_core_ module after the corresponding write address request.
- When a write address request is observed, if the wrapper had seen write data in advance, it sends this count (bounded by the burst length of the observed write address signal) to the core module using the _wdata_immediate_cnt_i_ signal. Fundamentally, only the count of write data, and not their content, is relevant for delay calculation.

To count the write data awaited or received in advance, the wrapper maintains a signed counter, incremented when write data is observed in advance, and when a write address is observed, it is decreased by the corresponding burst length.

<figure class="image">
  <img src="https://i.imgur.com/H1FLUsu.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Delay calculator wrapper. The blue arrow is taken if the delay calculator core currently expects write data for a previous write address request. Else, the black arrow is taken. Additionally, the red arrow gives the number of write data for the potentially incoming write address request</figcaption>
</figure>


#### Address request slots

_Slots_ are used to store address request metadata, as well as the status of the elementary requests in the bursts. Write and read slots are disjoint, because of the chronology of write and read elementary burst request arrival:

- Read elementary burst requests all arrive at once: when the read address request is opened.
- Write elementary burst requests may arrive progressively, when write data requests arrive later than the corresponding write address request.

_Write slots_ are memory structures defined as follows:

- Valid (_v_): Is set iff the slot is currently occupied.
- Internal identifier (_iid_): Contains the identifier that will be used to identify the extended cell where to release some response.
- Address (_addr_): Contains the base address of the address request. It is used to estimate the delay caused by the requests contained in the burst.
- Burst size (_burst_size_): Contains the burst size of the address request. It is used to calculate the address of the subsequent. It may also be used in the future for improved delay estimation.
- Data valid (_data_v_): Contains one bit per elementary burst request. Each bit is unset iff the corresponding elementary burst request is awaited.
- Memory pending (_mem_pending_): Contains one bit per elementary burst request. Each bit is set iff there is currently a simulated memory operation pending.
- Memory done (_mem_done_): Contains one bit per elementary burst request. Each bit is set iff the corresponding simulated memory operation is done, or this is an entry beyond the burst length.

_Read slots_ are defined identically, except that:

- There is no _data_v_ field, since elementary burst read requests arrive simultanously with the read address request.
- There internal identifier for read and write address requests do not need to be of equal width, which depends on the maximal number of pending requests.

The burst length does not need to be stored explicitly, as the _data_v_ and _mem_done_ bit arrays are set accordingly during the slot allocation.

#### Delay estimation

The delay estimation is performed using a decrementing counter (_rank_delay_cnt_) per rank (currently, only one rank is supported). When a simulated memory operation starts, the decrementing counter is set to a value corresponding to the situation:

1. If this is a row hit.
2. If this is a row miss, and there was no row in the buffer.
3. If this is a row miss, and there was another row in the buffer.

Rank states are represented by two additional elements (in addition to the decrementing counter):

- _is_row_open_: Is set iff there is a row stored in the simulated row buffer. Currently, this signal is only unset before the first memory request.
- _row_start_addr_: Stores the identifier of the currently open row, if any. The row identifier corresponds to all the most significant bits, that are not used for intra-row addressing.

#### Release enable structures

Write responses have a release enable structure made of one flip-flop per internal identifier. When the flip-flop is set, then the corresponding release eanble signal is propagated to the write response bank, which releases the signal if the requester is ready and if the signal is at the response head of its linked list.

As read data come as a burst, and to allow the progressive release of the data in the burst, small counters are used to maintain the number of read data that can currently be released per internal identifier (i.e., per extended cell). The multi-hot release enable signal, similar to the one used for the write responses but with a possibly different width, has each bit set iff the corresponding counter is non-zero.

When data is effectively released, the response banks notify this event using the _wrsp_released_iid_onehot_ and _rdata_released_iid_onehot_ one-hot signals. In the case of read data, the corresponding counter is decremented. In the case of write responses, the corresponding flip-flop is unset.

<figure class="image">
  <img src="https://i.imgur.com/zbh9VpO.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Delay calculator core: slots and release signals</figcaption>
</figure>



### Age management

Age management is used in two point of the delay calculator core:

- As many common scheduling strategies consider request relative age at some point, including the currently implemented strategy, the relative age between elementary burst entries must be (at least partially) maintained.
- The oldest write slots must receive write data information first, as in AXI, write data requests correspond in order with the write address requests: the earlier write data requests correspond to the earlier write address requests.

#### Write slot age matrix

The write slot age matrix is a simple example of an age matrix. An element at index (i,j) is set iff the write slot j is older than i. Only the top-right part above the diagonal is stored.

Each row is then masked with the _free_wslt_for_data_mhot_ multi-hot signal, which indicates whether each write slot is valid and able to host new write data entries, which is the case iff there is at least one unset bit in the corresponding _data_v_ signal.

<figure class="image">
  <img src="https://i.imgur.com/zRb7Ptp.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Generic age matrix: the blue cells are stored in flip-flops</figcaption>
</figure>


#### Main age matrix

The main age matrix side is the concatenation of two types of entries:

- The $NumWSlots * MaxWBurstLen$ elementary write burst entries, addressed as (slotId << log2(MaxWBurstLen)) | eid, where eid is a notation, convenient here but not used in the source code.
- The $NumRSlots$ read data slots / read address requests.

We have taken into account the fact that all read elementary burst entries in the same burst share the same age.

### Finding optimal entries

To find optimal the optimal entries to simulate new memory operations, the entries are first grouped by rank. All these groups, quotiented by rank, work in parallel without interaction.

Entries are then regrouped by cost categories (which are representations of memory operation latency on fewer bits), depending on the memory operation address and on the current corresponding rank row buffer state.

The oldest candidate entry for each cost category is determined by masking the main age matrix rows with the _matches_cond_ signal.

The lowest cost category where there is at least one candidate entry is determined. The oldest candidate within this cost category

Additionally, the cost and row buffer identifier corresponding to the optimal entry are determined (resp. on the signals _opti_cost_cat_ and _opti_rbuf_). This row buffer identifier helps updating the simulated rank state.

### Detailed slot operation

#### Request acceptance

##### Write requests

When a write slot is free (_~v_), a new write address request can be accepted. The allocated free slot fields takes the following values:

- _v_ is set.
- _iid_ takes the value held by the _waddr_iid_i_ signal, which is the write reservation output signal from the response banks.
- _addr_ takes the value held by the address request.
- _burst_size_ takes the value held by the address request.
- _burst_fixed_ takes the value 1 iff the burst type is fixed.
- _data_v_ takes the value, for each bit:
  - 1 for the first _wdata_immediate_cnt_i_ bits, which correspond to the number of write data requests that had arrived not later than the write address request.
  - 0 for the next bits corresponding to entries in the burst.
  - 1 for the last entries, which correspond to entries beyond the burst length.
- _mem_pending_ takes the value '0, as no simulated memory operation has started for any of these new entries.
- _mem_done_ is set to zero, except for the last bits, which correspond to entries beyond the burst length. The latter bits are set, because an unset bit in the _mem_done_ array represents an entry which must be eventually completed.

<figure class="image">
  <img src="https://i.imgur.com/eUkYbI9.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Read slot state just after acceptance of a new write address of burst length 2 and 1 immediate wdata (write data arrived not after the write address request)</figcaption>
</figure>



##### Read requests

Read request acceptance is identical to write address acceptance, except that:

- Read and write slots are disjoint.
- The _data_v_ field is absent from read slots. Virtually, all the bits would be set to 1 when a read slot is allocated.

#### Entry and slot liberation

For each write or read slot, for each entry, if the corresponding _mem_pending_ bit is set, then it is swapped with the _mem_done_ bit when the corresponding rank decrementing counter reaches 3. This accommodates the propagation delay until the requester, assuming the latter is ready. This is referred as _three-cycles-early_ _mem_done_ setting.

This forces, in particular, all the simulated memory delays to be at least 3 cycles This lower bound is much lower than typical main memory access delays.

##### Write requests

As there is a single write response per write address request, the release of the write response corresponding to write slot is enabled when all the entries (i.e., all the write data requests) of the slot are completed: when the _mem_done_ array is full of ones. Precisely, when the _mem_done_ array is full of ones,

- The valid bit of the slot is unset.
- The release enable flip-flop corresponding to the write slot's iid field is unset.

##### Read data

As opposed to write responses, one read data is released for each each data request in the read slot. Everytime a memory request is completed (_mem\_pending_ is being unset and _mem\_done_ is simultaneously being set), the release enable counter associated with the read slot's iid field is incremented. When the _mem_done_ array is full of ones, the valid bit of the slot is unset.

#### Rank state update

The rank decrementing counter (_rank_delay_cnt_) is systematically decreased to zero. The rest of the rank state is only modified if the decrementing counter is zero, as the rank is else considered busy. In the former case, the row buffer identifier (_row_buf_ident_) is set to the row identifier of the optimal entry for the rank.

### Burst support and addressing

#### Burst support

Bursts are not allowed to cross boundaries defined by *BurstAddrLSBs* bits. If a burst does, then it is automatically considered a wrap burst relative to this boundary. Therefore, the simulated memory controller does not make a difference between *incr* and *wrap* bursts. Boundaries must not match with bank row widths.

Fixed bursts, additionally, are supported by setting the *burst_fixed* field of the slot, which will provide the same address to all the entries.

#### Entry addressing

Taking advantage of the boundaries described above, all the entries of a slot share all their address bits, except the *BurstAddrLSBs* least significant bits. The per-entry address is therefore calculated with the slot address as a base, to which the burst size bits are iteratively added, using adders only on the *BurstAddrLSBs* LSBs. The wrap modulo operation is implicitly performed when the adders overflow.

<figure class="image">
  <img src="https://i.imgur.com/H8IVMBk.png" alt="Simulated memory controller internal overview">
  <figcaption>Fig: Individual burst entry address dynamic calculation</figcaption>
</figure>

## Future work

### Delay calculator

#### DRAM refreshing

DRAM refreshing simulation is currently not implemented. It can be implemented by periodically setting rank counters to a large value. One has to be careful in the implementation to not interfere with the three-cycles-early _mem_done_ setting.

#### Rank interleaving

Currently, only one rank is implemented, but the necessary infrastructure to implement different kinds of interleaving are already integrated, notably the optimizations are implemented per-rank (visible through the _for (genvar i\_rk..._ loops).

It remains mostly to define how interleaving is mapped, and to add additional information to the slots in case a memory request entryu is split between several ranks. This situation seems preferable to avoid, by using higher-order bits to select the rank mapping.

#### Request cost precision

So far, all the memory request entries with the same address have the same cost, regardless of the burst size, for instance. To implement finer-grained costs, more cost categories may be necessary, making the physical implementation potentially more expensive in terms of required area and delays.

#### Scheduling strategy

The implemented scheduling strategy is a mainstream and representative strategy. The delay calculator has been designed in a way that the scheduling strategy can reasonably easily be extended: the request ages are explicitly maintained, the outstanding entries are stored and accessible concurrently. This provides support for more complex scheduling strategies implementations.

### Response banks

#### Scalable burst management

So far, we have used 3 counters (_rsp_cnt_, _rsv_cnt_ and _burst_len_) per extended cell to maintain the burst state. This is the most efficient as long as the ratio of AXI identifiers over the number of extended cells is quite large (>= 1). To support much smaller ratios, which typically means, to support larger numbers of outstanding requests, the _rsp_cnt_ and _rsv_cnt_ counters may be implemented per linked list instead of per extended cell.


> View on GitHub: https://github.com/lowRISC/gsoc-sim-mem
