// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <verilated_fst_c.h>

#include <stdlib.h>
#include <time.h>
#include <iostream>
#include <queue>

#include "Vsimmem_write_resp_bank.h"
#include "verilated.h"

#define RESET_LENGTH 5
#define TRACE_LEVEL 4
#define MESSAGE_WIDTH 32

#define ID_WIDTH 4

typedef Vsimmem_write_resp_bank Module;

struct WriteRespBankTestbench {
	
	vluint32_t m_tick_count;
  vluint32_t m_max_clock_cycles;
  bool m_record_trace;
	Module *m_module;
  VerilatedFstC* m_trace;

  // @param max_clock_cycles set to 0 to disable interruption after a given number of clock cycles
  // @param record_trace set to false to skip trace recording
	WriteRespBankTestbench(vluint32_t max_clock_cycles = 0, bool record_trace = true, const std::string& trace_filename = "sim.fst") {
		m_tick_count = 0l;
    m_max_clock_cycles = max_clock_cycles;
    m_record_trace = record_trace;
		m_module = new Module;

    if (record_trace) {
      m_trace = new VerilatedFstC;
      m_module->trace(m_trace, TRACE_LEVEL);
      m_trace->open(trace_filename.c_str());
    }
  }

	void destruct(void) {
		delete m_module;
	}

	void reset(void) {
		m_module->rst_ni = 0;
    for (int i = 0; i < RESET_LENGTH; i++)
		  this->tick();
		m_module->rst_ni = 1;
	}

  void close_trace(void) {
		m_trace->close();
	}

	void tick(int nbTicks=1) {
    for (int i = 0; i < nbTicks; i++) {

      printf("Running iteration %d.\n", m_tick_count);

      m_tick_count++;

      m_module->clk_i = 0;
      m_module->eval();

      if(m_record_trace)
        m_trace->dump(5*m_tick_count-1);

      m_module->clk_i = 1;
      m_module->eval();

      if(m_record_trace)
        m_trace->dump(5*m_tick_count);

      m_module->clk_i = 0;
      m_module->eval();

      if(m_record_trace) {
        m_trace->dump(5*m_tick_count+2);
        m_trace->flush();
      }
    }
	}

	bool is_done(void) {
    printf("cnt: %u, max: %u\n", m_tick_count, m_max_clock_cycles);
		return (Verilated::gotFinish() || (m_max_clock_cycles && (m_tick_count >= m_max_clock_cycles)));
	}

  void reserve(int axi_id) {
    m_module->reservation_request_ready_i = 1;
    m_module->reservation_request_id_i = axi_id;
  }

  void stop_reserve() {
    m_module->reservation_request_ready_i = 0;
  }

  void apply_input_data(int data_i) {
    m_module->data_i = data_i;
    m_module->in_valid_i = 1;
  }
  bool is_input_data_accepted() {
    m_module->eval();

    return (bool) (m_module->in_ready_o);
  }
  void stop_input_data() {
    m_module->in_valid_i = 0;
  }

  void allow_output_data() {
    m_module->release_en_i = -1;
  }
  void forbid_output_data() {
    m_module->release_en_i = 0;
  }

  void request_output_data() {
    m_module->out_ready_i = 1;
  }
  bool fetch_output_data(u_int32_t& out_data) {
    out_data = (u_int32_t) m_module->data_o;
    return (bool) (m_module->out_valid_o);
  }
  void stop_output_data() {
    m_module->out_ready_i = 0;
  }
};


void single_id_test(WriteRespBankTestbench* tb) {
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

    reserve = (bool) (rand() & 1);
    apply_input = (bool) (rand() & 1);
    request_output_data = (bool) (rand() & 1);

    if (reserve)
      tb->reserve(current_id);
    if (apply_input) {
      tb->apply_input_data(current_input);
      std::cout << "Applied input: " << std::hex << current_input << std::endl;

      if(tb->is_input_data_accepted()) {
        std::cout << "Input accepted: " << std::hex << current_input << std::endl;
        input_queue.push(current_input);
        current_input = current_id | (u_int32_t)(rand() & 0xFFFFFF00);
      }
    }
    if (request_output_data) 
      tb->request_output_data();

    tb->tick();

    if (reserve)
      tb->stop_reserve();
    if (apply_input)
      tb->stop_input_data();
    if (request_output_data) {
      if(tb->fetch_output_data(current_output)) {
        output_queue.push(current_input);
      }
      tb->stop_output_data();
    }
  }

  while (!tb->is_done())
  {		
    tb->tick();
  }

  while(!input_queue.empty() && !output_queue.empty()) {
    current_input = input_queue.front();
    current_output = output_queue.front();

    input_queue.pop();
    output_queue.pop();

    std::cout << current_input << " - " << current_output << std::endl;
  }
}

int main(int argc, char **argv, char **env)
{
	Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

	WriteRespBankTestbench* tb = new WriteRespBankTestbench(100, true, "write_resp_bank.fst");

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
