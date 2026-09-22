/**
 * @file plv_stats.c
 * Counters the MEX reports through the Stats subcommand. Fixed storage, no
 * allocation, so they can stay on in shipping builds.
 */
#include "plv_internal.h"

void plv_stats_add_frame(double dt_seconds)
{
    uint64_t ns = (uint64_t)(dt_seconds * 1e9);
    g_plv.stats.frame_last_ns = ns;
    if(ns > g_plv.stats.frame_max_ns) g_plv.stats.frame_max_ns = ns;
    g_plv.stats.frame_sum_ns += ns;
    g_plv.stats.frame_count++;
}

void plv_stats_add_op(uint32_t opcode, uint64_t ns)
{
    plv_opstat_t * s;
    if(opcode >= PLV_MAX_OPCODES) return;
    s = &g_plv.stats.op[opcode];
    s->calls++;
    s->total_ns += ns;
    if(ns > s->max_ns) s->max_ns = ns;
}
