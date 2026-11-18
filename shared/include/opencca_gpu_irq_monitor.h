/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef OPENCCA_GPU_IRQ_MONITOR_H
#define OPENCCA_GPU_IRQ_MONITOR_H

#include <stdbool.h>
#include <opencca_gpu_irq_abi.h>

/* Private EL3 state; only snapshots are copied into the shared mailbox. */
struct ogi_monitor {
	struct ogi_binding bindings[OGI_CSGS];
	struct ogi_record records[OGI_CAPACITY];
	struct ogi_statistics stats;
	uint64_t offered;
};

unsigned int ogi_monitor_start(struct ogi_monitor *monitor, bool simulation);
void ogi_monitor_stop(struct ogi_monitor *monitor);
unsigned int ogi_monitor_bind(struct ogi_monitor *monitor,
		struct ogi_binding *binding);
unsigned int ogi_monitor_unbind(struct ogi_monitor *monitor,
		const struct ogi_binding *binding);
unsigned int ogi_monitor_capture(struct ogi_monitor *monitor,
		const struct ogi_snapshot *snapshot);
unsigned int ogi_monitor_drain(struct ogi_monitor *monitor,
		uint64_t acknowledge, struct ogi_record *records, unsigned int *count);

#endif
