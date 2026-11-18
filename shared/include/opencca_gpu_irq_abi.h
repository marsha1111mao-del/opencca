/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef OPENCCA_GPU_IRQ_ABI_H
#define OPENCCA_GPU_IRQ_ABI_H

#include <stdint.h>

/* One wire definition shared by EL3 and RMM. No Guest pointer or register
 * script crosses this interface. The mailbox is the fixed EL3/RMM page.
 */
#define OGI_ABI 2U
#define OGI_FAST_MAGIC UINT64_C(0x4f47495649455732)
#define OGI_CSGS 16U
#define OGI_AS_COUNT 16U
#define OGI_CAPACITY 128U
#define OGI_BATCH 16U
#define OGI_NO_SLOT UINT32_MAX
#define OGI_JOB_INTID 124U
#define OGI_MMU_INTID 125U
#define OGI_GPU_INTID 126U
#define OGI_SOURCE_EL3_IRQ 1U
#define OGI_SOURCE_ROOT_SAMPLE 2U
#define OGI_SOURCE_SIMULATION 4U
#define OGI_EVENT_FAULT 8U
#define OGI_EVENT_UNBOUND 16U
#define OGI_CLAIM_PROGRESS 1U
#define OGI_CLAIM_FAULT 2U
#define OGI_CLAIM_COMPLETE 3U

enum ogi_command {
	OGI_START = 1, OGI_STOP, OGI_BIND, OGI_UNBIND,
	OGI_DRAIN, OGI_STATS, OGI_SIM_CAPTURE, OGI_DRAIN_QUIET, OGI_VIEW_REGISTER
};
enum ogi_status {
	OGI_OK = 0, OGI_INPUT = 1, OGI_STATE = 2, OGI_LOST = 3,
	OGI_EMPTY = 4, OGI_STALE = 5
};

struct ogi_binding {
	uint64_t owner, context, group, epoch;
	uint32_t csg, as;
};

struct ogi_record {
	uint64_t sequence, device_epoch, binding_epoch;
	uint64_t owner, context, group, timestamp, fault_address;
	uint32_t intid, cpu, flags, csg, as;
	uint32_t gpu_raw, job_raw, mmu_raw, fault_status;
};

struct ogi_snapshot {
	uint64_t timestamp;
	uint64_t fault_address[OGI_AS_COUNT];
	uint32_t fault_status[OGI_AS_COUNT];
	uint32_t intid, cpu, flags, gpu_raw, job_raw, mmu_raw;
};

struct ogi_statistics {
	uint64_t produced, consumed, device_epoch, binding_generation;
	uint64_t physical_deliveries, root_samples, simulated, overflows;
	uint32_t queued, active, lost, simulation;
};

/* Root-written, RMM-private, fixed-size state view. Sequence is odd
 * before any Root capture/mask/W1C mutation and even only after PoC commit.
 * It is never Guest-shared or a task-completion certificate.
 */
struct ogi_fast_view {
	uint64_t sequence;
	uint32_t abi, reserved;
	uint64_t magic;
	struct ogi_statistics stats;
	uint32_t masks[3], masks_valid;
	uint64_t padding[1];
};
_Static_assert(sizeof(struct ogi_fast_view) == 128U, "Two private cache lines");

struct ogi_mailbox {
	uint32_t abi, command, status, count;
	uint64_t acknowledge;
	struct ogi_binding binding;
	struct ogi_statistics stats;
	struct ogi_snapshot snapshot;
	uint64_t view_pa;
	struct ogi_record records[OGI_BATCH];
};

_Static_assert(sizeof(struct ogi_mailbox) <= 4096U, "GPU event mailbox page");

#endif
