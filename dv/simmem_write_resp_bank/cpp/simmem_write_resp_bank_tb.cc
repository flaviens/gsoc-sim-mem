// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vsimmem_write_resp_bank.h"
#include "verilated.h"
#include <iostream>
#include <memory>
#include <queue>
#include <stdlib.h>
#include <time.h>
#include <verilated_fst_c.h>

const int kResetLength = 5;
const int kTraceLevel = 6;
const int kMessageWidth = 32;
const int kIdWidth = 4;

typedef Vsimmem_write_resp_bank Module;

// TODO Correctly manage the output fetching

class WriteRespBankTestbench {
 private:
  vluint32_t tick_count_;
  vluint32_t max_clock_cycles_;
  bool record_trace_;
  std::unique_ptr<Module> module_;
  VerilatedFstC *trace_;

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
  }

  ~WriteRespBankTestbench() { close_trace(); }

  void reset(void) {
    module_->rst_ni = 0;
    for (int i = 0; i < kResetLength; i++) {
      this->tick();
    }
    module_->rst_ni = 1;
  }

  void close_trace(void) { trace_->close(); }

  void tick(int nbTicks = 1) {
    for (int i = 0; i < nbTicks; i++) {
      std::cout << "Running iteration" << tick_count_ << std::endl;

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
    printf("cnt: %u, max: %u\n", tick_count_, max_clock_cycles_);
    return (Verilated::gotFinish() ||
            (max_clock_cycles_ && (tick_count_ >= max_clock_cycles_)));
  }

  void reserve(int axi_id) {
    module_->reservation_request_ready_i = 1;
    module_->reservation_request_id_i = axi_id;
  }

  void stop_reserve() { module_->reservation_request_ready_i = 0; }

  void apply_input_data(int data_i) {
    std::cout << "Applied input: " << std::hex << data_i << std::endl;

    module_->data_i = data_i;
    module_->in_valid_i = 1;
  }
  bool is_input_data_accepted() {
    module_->eval();
    return (bool)(module_->in_ready_o);
  }
  void stop_input_data() { module_->in_valid_i = 0; }

  void allow_output_data() { module_->release_en_i = -1; }

  void forbid_output_data() { module_->release_en_i = 0; }

  void request_output_data() { module_->out_ready_i = 1; }

  bool fetch_output_data(u_int32_t &out_data) {
    module_->eval();
    if (!(module_->out_ready_i)) {
      std::cerr << "Fetching output data without manifesting ready signal."
                << std::endl;
      exit(1);
    }

    if ((bool)(module_->out_valid_o))
      std::cout << "Fetching " << std::hex << module_->data_o << std::endl;

    out_data = (u_int32_t)module_->data_o;
    return (bool)(module_->out_valid_o);
  }

  void stop_output_data() { module_->out_ready_i = 0; }
};

void single_id_test(WriteRespBankTestbench *tb) {
  u_int32_t current_id = 4;
  int nb_iterations = 100;

  // Generate inputs

  std::queue<u_int32_t> input_queue;
  std::queue<u_int32_t> output_queue;

  bool reserve;
  bool apply_input;
  bool request_output_data;

  u_int32_t current_input = current_id | (u_int32_t)(rand() & 0xFFFFFF00);
  u_int32_t current_output;

  srand(42);
  tb->reset();
  tb->allow_output_data();

  for (int i = 0; i < nb_iterations; i++) {
    reserve = (bool)(rand() & 1);
    apply_input = (bool)(rand() & 1);
    request_output_data = (bool)(rand() & 1);

    if (reserve)
      tb->reserve(current_id);
    if (apply_input) {
      tb->apply_input_data(current_input);
    }
    if (request_output_data)
      tb->request_output_data();

    // Important: apply all the input first, before any evaluation
    if (tb->is_input_data_accepted()) {
      input_queue.push(current_input);
      current_input = current_id | (u_int32_t)(rand() & 0xFFFFFF00);
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

  while (!input_queue.empty() && !output_queue.empty()) {
    current_input = input_queue.front();
    current_output = output_queue.front();

    input_queue.pop();
    output_queue.pop();

    std::cout << current_input << " - " << current_output << std::endl;
  }
}

int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  WriteRespBankTestbench *tb =
      new WriteRespBankTestbench(100, true, "write_resp_bank.fst");

  single_id_test(tb);
  // tb->reset();
  // tb->reserve(4);

  // tb->tick(4);

  // tb->stop_reserve();

  // tb->tick(4);

  // tb->apply_input_data(4 | (9<<ID_WIDTH));

  // tb->tick(6);

  // tb->stop_input_data();

  // tb->tick(4);

  // tb->allow_output_data();

  // tb->tick(4);

  // tb->request_output_data();
  // tb->tick(10);
  // tb->stop_output_data();

  // while (!tb->is_done())
  // {
  //   tb->tick();
  // }

  tb->close_trace();

  printf("Complete!\n");

  delete tb;
  exit(0);
}
