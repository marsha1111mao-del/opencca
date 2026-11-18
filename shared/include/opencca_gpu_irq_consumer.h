/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef OPENCCA_GPU_IRQ_CONSUMER_H
#define OPENCCA_GPU_IRQ_CONSUMER_H
#include <stdbool.h>
#include <opencca_gpu_irq_abi.h>

struct ogi_consumer {
	struct ogi_binding bindings[OGI_CSGS];
	bool faulted[OGI_CSGS];
	struct ogi_record records[OGI_CAPACITY];
	uint64_t device_epoch, received, claimed, rejected, coalesced;
	bool lost, global_fault, simulation;
};

void ogi_consumer_start(struct ogi_consumer *, uint64_t epoch, uint64_t sequence,
		bool simulation);
unsigned int ogi_consumer_bind(struct ogi_consumer *, const struct ogi_binding *);
unsigned int ogi_consumer_close(struct ogi_consumer *, const struct ogi_binding *);
unsigned int ogi_consumer_ingest(struct ogi_consumer *, const struct ogi_record *);
bool ogi_consumer_healthy(const struct ogi_consumer *, const struct ogi_binding *);
unsigned int ogi_consumer_next(struct ogi_consumer *, const struct ogi_binding *,
		uint64_t after, struct ogi_record *);
unsigned int ogi_consumer_claim(struct ogi_consumer *, const struct ogi_binding *,
		uint64_t after, uint64_t sequence, uint64_t epoch, uint64_t device_epoch,
		unsigned int kind, bool completed);
void ogi_consumer_begin(struct ogi_consumer *, const struct ogi_binding *);

#endif
