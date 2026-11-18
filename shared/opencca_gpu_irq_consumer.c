/* SPDX-License-Identifier: BSD-3-Clause */
#include <opencca_gpu_irq_consumer.h>
#include <string.h>

static bool same(const struct ogi_binding *a, const struct ogi_binding *b)
{
	return a->epoch != 0U && a->epoch == b->epoch && a->owner == b->owner &&
		a->context == b->context && a->group == b->group &&
		a->csg == b->csg && a->as == b->as;
}

static bool record_matches(const struct ogi_record *r, const struct ogi_binding *b)
{
	return r->binding_epoch == b->epoch && r->owner == b->owner &&
		r->context == b->context && r->group == b->group &&
		r->csg == b->csg && r->as == b->as;
}

void ogi_consumer_start(struct ogi_consumer *c, uint64_t epoch, uint64_t sequence,
		bool simulation)
{
	memset(c, 0, sizeof(*c));
	c->device_epoch = epoch;
	c->received = sequence;
	c->simulation = simulation;
	c->lost = epoch == 0U;
}

unsigned int ogi_consumer_bind(struct ogi_consumer *c, const struct ogi_binding *b)
{
	if (c == NULL || b == NULL || b->csg >= OGI_CSGS || b->as == 0U ||
	    b->as >= OGI_AS_COUNT || b->epoch == 0U || b->owner == 0U ||
	    b->context == 0U || b->group == 0U)
		return OGI_INPUT;
	if (c->lost || c->global_fault || c->bindings[b->csg].epoch != 0U)
		return OGI_STATE;
	c->bindings[b->csg] = *b;
	c->faulted[b->csg] = false;
	return OGI_OK;
}

void ogi_consumer_begin(struct ogi_consumer *c, const struct ogi_binding *b)
{
	/* A new logical publication explicitly closes old progress hints in the
	 * same retained execution domain. Fault health is never cleared here.
	 */
	for (unsigned int i = 0U; i < OGI_CAPACITY; i++)
		if (c->records[i].sequence != 0U && record_matches(&c->records[i], b))
			memset(&c->records[i], 0, sizeof(c->records[i]));
}

unsigned int ogi_consumer_close(struct ogi_consumer *c, const struct ogi_binding *b)
{
	if (c == NULL || b == NULL || b->csg >= OGI_CSGS ||
	    !same(&c->bindings[b->csg], b))
		return OGI_STALE;
	ogi_consumer_begin(c, b);
	unsigned int csg = b->csg;
	memset(&c->bindings[csg], 0, sizeof(c->bindings[csg]));
	/* A faulted binding cannot be reused without trusted device recovery. */
	if (c->faulted[csg])
		c->global_fault = true;
	return OGI_OK;
}

unsigned int ogi_consumer_ingest(struct ogi_consumer *c, const struct ogi_record *r)
{
	unsigned int source;
	if (c == NULL || r == NULL || c->lost)
		return OGI_STATE;
	source = r->flags & (OGI_SOURCE_EL3_IRQ | OGI_SOURCE_ROOT_SAMPLE | OGI_SOURCE_SIMULATION);
	if (c->received == UINT64_MAX || r->sequence != c->received + 1U ||
	    r->device_epoch != c->device_epoch || r->cpu >= 8U ||
	    (source != OGI_SOURCE_EL3_IRQ && source != OGI_SOURCE_ROOT_SAMPLE &&
	     source != OGI_SOURCE_SIMULATION) ||
	    ((source == OGI_SOURCE_SIMULATION) != c->simulation) ||
	    (r->flags & ~(OGI_SOURCE_EL3_IRQ | OGI_SOURCE_ROOT_SAMPLE |
		OGI_SOURCE_SIMULATION | OGI_EVENT_FAULT | OGI_EVENT_UNBOUND)) != 0U ||
	    (r->intid != OGI_JOB_INTID && r->intid != OGI_MMU_INTID &&
	     r->intid != OGI_GPU_INTID)) {
		c->lost = true;
		return OGI_LOST;
	}
	bool fault = (r->gpu_raw & 3U) != 0U || (r->mmu_raw & 1U) != 0U ||
		(r->as < OGI_AS_COUNT && (r->mmu_raw & (1U << r->as)) != 0U) ||
		(r->as == OGI_NO_SLOT && (r->mmu_raw & 0xffffU) != 0U);
	if (((r->flags & OGI_EVENT_FAULT) != 0U) != fault) {
		c->lost = true;
		return OGI_LOST;
	}
	c->received = r->sequence;
	if ((r->flags & OGI_EVENT_UNBOUND) != 0U) {
		if (r->binding_epoch != 0U || r->owner != 0U || r->context != 0U ||
		    r->group != 0U || r->csg != OGI_NO_SLOT || r->as != OGI_NO_SLOT) {
			c->lost = true;
			return OGI_LOST;
		}
		c->global_fault |= (r->flags & OGI_EVENT_FAULT) != 0U;
		return OGI_OK;
	}
	if (r->csg >= OGI_CSGS || !record_matches(r, &c->bindings[r->csg])) {
		/* A late old-binding record cannot be attached to a new owner. A
		 * late fault means the cutover evidence is incomplete, not healthy.
		 */
		c->rejected++;
		c->global_fault |= (r->flags & OGI_EVENT_FAULT) != 0U;
		return OGI_STALE;
	}
	c->faulted[r->csg] |= (r->flags & OGI_EVENT_FAULT) != 0U;
	/* Root already captured and sequenced every record. RMM may explicitly
	 * coalesce progress hints for the same binding/source, retaining the FIRST
	 * unclaimed reference. No fault is discarded and no old ID is retagged.
	 */
	if ((r->flags & OGI_EVENT_FAULT) == 0U) {
		for (unsigned int i=0U; i<OGI_CAPACITY; i++) {
			const struct ogi_record *old = &c->records[i];
			if (old->sequence != 0U && old->flags == r->flags &&
			    record_matches(old, &c->bindings[r->csg])) {
				if (c->coalesced != UINT64_MAX)
					c->coalesced++;
				return OGI_OK;
			}
		}
	}
	for (unsigned int i = 0U; i < OGI_CAPACITY; i++) {
		if (c->records[i].sequence == 0U) {
			c->records[i] = *r;
			return OGI_OK;
		}
	}
	c->lost = true;
	return OGI_LOST;
}

bool ogi_consumer_healthy(const struct ogi_consumer *c, const struct ogi_binding *b)
{
	return c != NULL && b != NULL && b->csg < OGI_CSGS &&
		!c->lost && !c->global_fault && !c->faulted[b->csg] &&
		same(&c->bindings[b->csg], b);
}

unsigned int ogi_consumer_next(struct ogi_consumer *c, const struct ogi_binding *b,
		uint64_t after, struct ogi_record *result)
{
	const struct ogi_record *next = NULL;
	if (c == NULL || b == NULL || result == NULL || b->csg >= OGI_CSGS ||
	    !same(&c->bindings[b->csg], b))
		return OGI_STALE;
	if (c->lost)
		return OGI_LOST;
	for (unsigned int i = 0U; i < OGI_CAPACITY; i++) {
		const struct ogi_record *r = &c->records[i];
		if (r->sequence > after && record_matches(r, b) &&
		    (next == NULL || r->sequence < next->sequence))
			next = r;
	}
	if (next == NULL)
		return OGI_EMPTY;
	*result = *next;
	return OGI_OK;
}

unsigned int ogi_consumer_claim(struct ogi_consumer *c, const struct ogi_binding *b,
		uint64_t after, uint64_t sequence, uint64_t epoch, uint64_t device_epoch,
		unsigned int kind, bool completed)
{
	struct ogi_record record;
	unsigned int status = ogi_consumer_next(c, b, after, &record);
	if (status != OGI_OK || record.sequence != sequence ||
	    record.binding_epoch != epoch || record.device_epoch != device_epoch ||
	    (kind != OGI_CLAIM_PROGRESS && kind != OGI_CLAIM_FAULT &&
	     kind != OGI_CLAIM_COMPLETE) ||
	    ((kind == OGI_CLAIM_FAULT) != ((record.flags & OGI_EVENT_FAULT) != 0U))) {
		if (c != NULL)
			c->rejected++;
		return OGI_STALE;
	}
	if (kind == OGI_CLAIM_COMPLETE && (!completed || !ogi_consumer_healthy(c, b)))
		return OGI_STATE;
	for (unsigned int i = 0U; i < OGI_CAPACITY; i++) {
		if (c->records[i].sequence == sequence) {
			memset(&c->records[i], 0, sizeof(c->records[i]));
			c->claimed++;
			return OGI_OK;
		}
	}
	return OGI_STALE;
}
