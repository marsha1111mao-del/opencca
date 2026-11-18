/* SPDX-License-Identifier: BSD-3-Clause */
#include <opencca_gpu_irq_monitor.h>
#include <string.h>

unsigned int ogi_monitor_start(struct ogi_monitor *m, bool simulation)
{
	if (m == NULL || m->stats.active || m->stats.device_epoch == UINT64_MAX)
		return OGI_STATE;
	/* Sequence, binding generation and device epoch never wrap or restart.
	 * STOP is a trusted device-revocation boundary, not a Guest retry.
	 */
	m->stats.device_epoch++;
	m->stats.active = 1U;
	m->stats.simulation = simulation;
	m->stats.lost = 0U;
	m->stats.queued = 0U;
	m->stats.consumed = m->stats.produced;
	m->offered = m->stats.consumed;
	memset(m->bindings, 0, sizeof(m->bindings));
	memset(m->records, 0, sizeof(m->records));
	return OGI_OK;
}

void ogi_monitor_stop(struct ogi_monitor *m)
{
	if (m == NULL)
		return;
	m->stats.active = 0U;
	memset(m->bindings, 0, sizeof(m->bindings));
}

unsigned int ogi_monitor_bind(struct ogi_monitor *m, struct ogi_binding *b)
{
	struct ogi_binding *slot;
	if (m == NULL || b == NULL || !m->stats.active || m->stats.lost)
		return OGI_STATE;
	if (b->owner == 0U || b->context == 0U || b->group == 0U ||
	    b->csg >= OGI_CSGS || b->as == 0U || b->as >= OGI_AS_COUNT ||
	    b->epoch != 0U)
		return OGI_INPUT;
	slot = &m->bindings[b->csg];
	if (slot->epoch != 0U || m->stats.queued != 0U ||
	    m->stats.binding_generation == UINT64_MAX)
		return OGI_STATE;
	b->epoch = ++m->stats.binding_generation;
	*slot = *b;
	return OGI_OK;
}

unsigned int ogi_monitor_unbind(struct ogi_monitor *m,
		const struct ogi_binding *b)
{
	struct ogi_binding *slot;
	if (m == NULL || b == NULL || !m->stats.active || b->csg >= OGI_CSGS)
		return OGI_INPUT;
	if (m->stats.lost)
		return OGI_LOST;
	slot = &m->bindings[b->csg];
	if (b->epoch == 0U || slot->epoch != b->epoch ||
	    slot->owner != b->owner || slot->context != b->context ||
	    slot->group != b->group || slot->as != b->as)
		return OGI_STALE;
	if (m->stats.queued != 0U)
		return OGI_STATE;
	memset(slot, 0, sizeof(*slot));
	return OGI_OK;
}

static bool affected(const struct ogi_binding *b, const struct ogi_snapshot *s)
{
	return b->epoch != 0U && (s->gpu_raw != 0U || (s->mmu_raw & 1U) != 0U ||
		(s->job_raw & ((1U << b->csg) | (1U << 31U))) != 0U ||
		(s->mmu_raw & (1U << b->as)) != 0U);
}

unsigned int ogi_monitor_capture(struct ogi_monitor *m,
		const struct ogi_snapshot *s)
{
	unsigned int count = 0U;
	if (m == NULL || s == NULL || !m->stats.active || m->stats.lost)
		return OGI_STATE;
	if ((s->intid != OGI_JOB_INTID && s->intid != OGI_MMU_INTID &&
	     s->intid != OGI_GPU_INTID) ||
	    (s->flags != OGI_SOURCE_EL3_IRQ && s->flags != OGI_SOURCE_ROOT_SAMPLE &&
	     s->flags != OGI_SOURCE_SIMULATION) ||
	    ((s->flags == OGI_SOURCE_SIMULATION) != (m->stats.simulation != 0U)))
		return OGI_INPUT;
	if ((s->gpu_raw | s->job_raw | s->mmu_raw) == 0U)
		return OGI_EMPTY;
	for (unsigned int i = 0U; i < OGI_CSGS; i++)
		count += affected(&m->bindings[i], s);
	if (count == 0U)
		count = 1U;
	/* Reserve the whole capture before modifying the ring. Never retain a
	 * misleading partial set of bindings for a multi-context fault.
	 */
	if (count > OGI_CAPACITY - m->stats.queued ||
	    m->stats.produced > UINT64_MAX - count) {
		m->stats.lost = 1U;
		if (m->stats.overflows != UINT64_MAX)
			m->stats.overflows++;
		return OGI_LOST;
	}
	if (s->flags == OGI_SOURCE_EL3_IRQ)
		m->stats.physical_deliveries++;
	else if (s->flags == OGI_SOURCE_ROOT_SAMPLE)
		m->stats.root_samples++;
	else
		m->stats.simulated++;
	for (unsigned int i = 0U; i <= OGI_CSGS; i++) {
		const struct ogi_binding *b = i < OGI_CSGS ? &m->bindings[i] : NULL;
		if (b != NULL && !affected(b, s))
			continue;
		if (b == NULL && count != 1U)
			break;
		if (b == NULL) {
			bool found = false;
			for (unsigned int j = 0U; j < OGI_CSGS; j++)
				found |= affected(&m->bindings[j], s);
			if (found)
				break;
		}
		uint64_t sequence = ++m->stats.produced;
		struct ogi_record *r = &m->records[(sequence - 1U) % OGI_CAPACITY];
		*r = (struct ogi_record){
			.sequence = sequence, .device_epoch = m->stats.device_epoch,
			.binding_epoch = b != NULL ? b->epoch : 0U,
			.owner = b != NULL ? b->owner : 0U,
			.context = b != NULL ? b->context : 0U,
			.group = b != NULL ? b->group : 0U,
			.timestamp = s->timestamp, .intid = s->intid, .cpu = s->cpu,
			.flags = s->flags | (b == NULL ? OGI_EVENT_UNBOUND : 0U),
			.csg = b != NULL ? b->csg : OGI_NO_SLOT,
			.as = b != NULL ? b->as : OGI_NO_SLOT,
			.gpu_raw = s->gpu_raw, .job_raw = s->job_raw, .mmu_raw = s->mmu_raw
		};
		if (b != NULL) {
			r->fault_status = s->fault_status[b->as];
			r->fault_address = s->fault_address[b->as];
		}
		if ((s->gpu_raw & 3U) != 0U || (s->mmu_raw & 1U) != 0U ||
		    (b != NULL && (s->mmu_raw & (1U << b->as)) != 0U) ||
		    (b == NULL && (s->mmu_raw & 0xffffU) != 0U))
			r->flags |= OGI_EVENT_FAULT;
		m->stats.queued++;
	}
	return OGI_OK;
}

unsigned int ogi_monitor_drain(struct ogi_monitor *m, uint64_t ack,
		struct ogi_record *records, unsigned int *count)
{
	if (m == NULL || records == NULL || count == NULL || !m->stats.active)
		return OGI_INPUT;
	*count = 0U;
	if (ack < m->stats.consumed || ack > m->offered)
		return OGI_STALE;
	/* An ACK can only cover a batch actually offered in the preceding
	 * DRAIN. The adapter supplies the fixed batch; no Proxy controls ACK.
	 */
	if (ack - m->stats.consumed > OGI_BATCH)
		return OGI_INPUT;
	while (m->stats.consumed < ack) {
		struct ogi_record *r = &m->records[m->stats.consumed % OGI_CAPACITY];
		if (r->sequence != m->stats.consumed + 1U) {
			m->stats.lost = 1U;
			return OGI_LOST;
		}
		memset(r, 0, sizeof(*r));
		m->stats.consumed++;
		m->stats.queued--;
	}
	if (m->stats.lost)
		return OGI_LOST;
	for (unsigned int i = 0U; i < m->stats.queued && i < OGI_BATCH; i++)
		records[(*count)++] = m->records[(m->stats.consumed + i) % OGI_CAPACITY];
	m->offered = m->stats.consumed + *count;
	return *count == 0U ? OGI_EMPTY : OGI_OK;
}
