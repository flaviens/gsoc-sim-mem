// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vsimmem_write_resp_bank.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <map>
#include <memory>
#include <queue>
#include <stdlib.h>
#include <vector>
#include <verilated_fst_c.h>

const bool kIterationVerbose = false;
const bool kTransactionsVerbose = false;
const bool kPairsVerbose = false;

const int kResetLength = 5;
const int kTraceLevel = 6;
const int kIdWidth = 4;

typedef Vsimmem_write_resp_bank Module;
typedef std::map<u_int32_t, std::queue<u_int32_t>> queue_map_t;

// This class implements elementary operations for the testbench
class WriteRespBankTestbench {
 public:
  // @param max_clock_cycles set to 0 to disable interruption after a given
  // number of clock cycles
  // @param record_trace set to false to skip trace recording
  WriteRespBankTestbench(vluint32_t max_clock_cycles = 0,
                         bool record_trace = true,
                         const std::string &trace_filename = "sim.fst")
      : tick_count_(0l),
        max_clock_cycles_(max_clock_cycles),
        record_trace_(record_trace),
        module_(new Module) {
    if (record_trace) {
      trace_ = new VerilatedFstC;
      module_->trace(trace_, kTraceLevel);
      trace_->open(trace_filename.c_str());
    }

    identifier_mask_ = (1 << 31) >> (31 - kIdWidth);
  }

  ~WriteRespBankTestbench() { close_trace(); }

  void reset(void) {
    module_->rst_ni = 0;
    for (size_t i = 0; i < kResetLength; i++) {
      this->tick();
    }
    module_->rst_ni = 1;
  }

  void close_trace(void) { trace_->close(); }

  void tick(int nbTicks = 1) {
    for (size_t i = 0; i < nbTicks; i++) {
      if (kIterationVerbose) {
        std::cout << "Running iteration" << tick_count_ << std::endl;
      }

      tick_count_++;

      module_->clk_i = 0;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_ - 1);
      }
      module_->clk_i = 1;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_);
      }
      module_->clk_i = 0;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_ + 2);
        trace_->flush();
      }
    }
  }

  bool is_done(void) {
    return (Verilated::gotFinish() ||
            (max_clock_cycles_ && (tick_count_ >= max_clock_cycles_)));
  }

  void reserve(int axi_id) {
    module_->reservation_req_ready_i = 1;
    module_->reservation_req_id_onehot_i = 1 << axi_id;
  }

  void stop_reserve() { module_->reservation_req_ready_i = 0; }

  void apply_input_data(int data_i) {
    module_->data_i = data_i;
    module_->in_valid_i = 1;
  }
  bool is_input_data_accepted() {
    module_->eval();
    return (bool)(module_->in_ready_o);
  }
  bool is_reservation_accepted() {
    module_->eval();
    return (bool)(module_->reservation_req_valid_o);
  }
  void stop_input_data() { module_->in_valid_i = 0; }

  void allow_output_data() { module_->release_en_i = -1; }

  void forbid_output_data() { module_->release_en_i = 0; }

  void request_output_data() { module_->out_ready_i = 1; }

  bool fetch_output_data(u_int32_t &out_data) {
    module_->eval();
    assert(module_->out_ready_i);

    out_data = (u_int32_t)module_->data_o;
    return (bool)(module_->out_valid_o);
  }

  void stop_output_data() { module_->out_ready_i = 0; }

  u_int32_t get_reserved_address() { return module_->new_reserved_addr_o; }

  unsigned long get_identifier_mask() { return identifier_mask_; }

 private:
  vluint32_t tick_count_;
  vluint32_t max_clock_cycles_;
  bool record_trace_;
  std::unique_ptr<Module> module_;
  u_int32_t identifier_mask_;
  VerilatedFstC *trace_;
};

void sequential_test(WriteRespBankTestbench *tb) {
  tb->reset();

  // Apply reservation requests for 4 ticks
  tb->reserve(4);  // Start issuing reservation requests for AXI ID 4
  tb->tick(4);
  tb->stop_reserve();  // Stop issuing reservation requests

  tb->tick(4);

  // Apply inputs for 6 ticks
  tb->apply_input_data(4 | (9 << kIdWidth));
  tb->tick(6);
  tb->stop_input_data();

  tb->tick(4);

  // Enable data toutput
  tb->allow_output_data();
  tb->tick(4);

  // Express readiness for output data
  tb->request_output_data();
  tb->tick(10);
  tb->stop_output_data();

  while (!tb->is_done()) {
    tb->tick();
  }
}

size_t single_id_test(WriteRespBankTestbench *tb, unsigned int seed) {
  srand(seed);

  u_int32_t current_id = 4;
  int nb_iterations = 1000;

  // Generate inputs
  std::queue<u_int32_t> input_queue;
  std::queue<u_int32_t> output_queue;

  bool reserve;
  bool apply_input;
  bool request_output_data;

  u_int32_t current_input =
      current_id | (u_int32_t)(rand() & tb->get_identifier_mask());
  u_int32_t current_output;

  tb->reset();
  tb->allow_output_data();

  for (size_t i = 0; i < nb_iterations; i++) {
    reserve = (bool)(rand() & 1);
    apply_input = (bool)(rand() & 1);
    request_output_data = (bool)(rand() & 1);

    if (reserve) {
      tb->reserve(current_id);
    }
    if (apply_input) {
      tb->apply_input_data(current_input);
    }
    if (request_output_data) {
      tb->request_output_data();
    }

    // Important: apply all the input first, before any evaluation
    if (tb->is_input_data_accepted()) {
      input_queue.push(current_input);
      current_input =
          current_id | (u_int32_t)(rand() & tb->get_identifier_mask());
    }
    if (request_output_data) {
      if (tb->fetch_output_data(current_output)) {
        output_queue.push(current_output);
      }
    }

    tb->tick();

    if (reserve) {
      tb->stop_reserve();
    }
    if (apply_input) {
      tb->stop_input_data();
    }
    if (request_output_data) {
      tb->stop_output_data();
    }
  }

  while (!tb->is_done()) {
    tb->tick();
  }

  size_t nb_mismatches = 0;
  while (!input_queue.empty() && !output_queue.empty()) {
    current_input = input_queue.front();
    current_output = output_queue.front();

    input_queue.pop();
    output_queue.pop();

    if (kPairsVerbose) {
      std::cout << std::hex << current_input << " - " << current_output
                << std::endl;
    }
    nb_mismatches += (size_t)(current_input != current_output);
  }
  if (kPairsVerbose) {
    std::cout << std::endl
              << "Mismatches: " << std::dec << nb_mismatches << std::endl
              << std::endl;
  }

  return nb_mismatches;
}

size_t multiple_ids_test(WriteRespBankTestbench *tb, size_t num_identifiers,
                         unsigned int seed) {
  srand(seed);

  int nb_iterations = 1000;

  std::vector<u_int32_t> identifiers;

  for (size_t i = 0; i < num_identifiers; i++) {
    identifiers.push_back(i);
  }

  queue_map_t input_queues;
  queue_map_t output_queues;

  for (size_t i = 0; i < num_identifiers; i++) {
    input_queues.insert(std::pair<u_int32_t, std::queue<u_int32_t>>(
        identifiers[i], std::queue<u_int32_t>()));
    output_queues.insert(std::pair<u_int32_t, std::queue<u_int32_t>>(
        identifiers[i], std::queue<u_int32_t>()));
  }

  bool reserve;
  bool apply_input;
  bool request_output_data;
  bool iteration_announced;

  u_int32_t current_input_id = identifiers[rand() % num_identifiers];
  u_int32_t current_input =
      current_input_id | (u_int32_t)(rand() & tb->get_identifier_mask());
  u_int32_t current_reservation_id = identifiers[rand() % num_identifiers];
  u_int32_t current_output;

  tb->reset();
  tb->allow_output_data();

  for (size_t i = 0; i < nb_iterations; i++) {
    iteration_announced = false;

    reserve = (bool)(rand() & 1);
    apply_input = (bool)(rand() & 1);
    request_output_data = (bool)(rand() & 1);

    if (reserve) {
      tb->reserve(current_reservation_id);
    }
    if (apply_input) {
      tb->apply_input_data(current_input);
    }
    if (request_output_data) {
      tb->request_output_data();
    }

    // Important: apply all the input first, before any evaluation
    if (reserve && tb->is_reservation_accepted()) {
      if (kTransactionsVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl << "Step " << std::dec << i << std::endl;
        }
        std::cout << current_reservation_id << " reserves "
                  << tb->get_reserved_address() << std::endl;
      }
      current_reservation_id = identifiers[rand() % num_identifiers];
    }
    if (tb->is_input_data_accepted()) {
      input_queues[current_input_id].push(current_input);
      if (kTransactionsVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl << "Step " << std::dec << i << std::endl;
        }
        std::cout << std::dec << current_input_id << " inputs " << std::hex
                  << current_input << std::endl;
      }
      current_input_id = identifiers[rand() % num_identifiers];
      current_input =
          current_input_id | (u_int32_t)(rand() & tb->get_identifier_mask());
    }
    if (request_output_data) {
      if (tb->fetch_output_data(current_output)) {
        output_queues[identifiers[current_output & ~tb->get_identifier_mask()]]
            .push(current_output);

        if (kTransactionsVerbose) {
          if (!iteration_announced) {
            iteration_announced = true;
            std::cout << std::endl << "Step " << std::dec << i << std::endl;
          }
          std::cout << std::dec
                    << (u_int32_t)(current_output & ~tb->get_identifier_mask())
                    << " outputs " << std::hex << current_output << std::endl;
        }
      }
    }

    tb->tick();

    if (reserve) {
      tb->stop_reserve();
    }
    if (apply_input) {
      tb->stop_input_data();
    }
    if (request_output_data) {
      tb->stop_output_data();
    }

    while (!tb->is_done()) {
      tb->tick();
    }
  }

  size_t nb_mismatches = 0;
  for (size_t i = 0; i < num_identifiers; i++) {
    while (!input_queues[i].empty() && !output_queues[i].empty()) {
      current_input = input_queues[i].front();
      current_output = output_queues[i].front();

      input_queues[i].pop();
      output_queues[i].pop();
      if (kPairsVerbose) {
        std::cout << std::hex << current_input << " - " << current_output
                  << std::endl;
      }
      nb_mismatches += (size_t)(current_input != current_output);
    }
  }
  if (kPairsVerbose) {
    std::cout << std::endl
              << "Mismatches: " << std::dec << nb_mismatches << std::endl
              << std::endl;
  }

  return nb_mismatches;
}

int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  size_t total_nb_mismatches = 0;

  for (int i = 100; i < 1000; i++) {
    size_t local_nb_mismatches;

    WriteRespBankTestbench *tb =
        new WriteRespBankTestbench(100, true, "write_resp_bank.fst");

    // Choose testbench type
    // sequential_test(tb);
    // local_nb_mismatches = single_id_test(tb, i);
    local_nb_mismatches = multiple_ids_test(tb, 5, i);
    total_nb_mismatches += local_nb_mismatches;
    std::cout << "Mismatches for seed " << std::dec << i << ": "
              << local_nb_mismatches << std::hex << std::endl;
    delete tb;
  }

  std::cout << "Testbench complete!" << std::endl;

  exit(0);
}
