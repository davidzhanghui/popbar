#ifndef CMETRICS_H
#define CMETRICS_H

#include <stdint.h>
#include <cups/cups.h>   // 打印管理(PrintIPP.swift)直接调用系统 libcups
#include <cups/ipp.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CM_MAX_CORES 32
#define CM_MAX_PROCS 1024   // 够覆盖绝大多数机器的全部进程,供面板滚动/搜索

typedef struct {
    int core_count;
    double package_percent;
    double per_core[CM_MAX_CORES];
} CMCPUSample;

typedef struct {
    uint64_t used_bytes;
    uint64_t phys_bytes;
    double used_percent;
    int pressure_level;
    uint64_t swap_used;
    uint64_t swap_total;
} CMMemorySample;

typedef struct {
    int valid;
    double cpu_watts;
    double gpu_watts;
    double ane_watts;
    double dram_watts;
    double gpu_percent;
} CMChipSample;

typedef struct {
    int have_cpu;
    int have_gpu;
    double cpu_temp;
    double gpu_temp;
} CMTempSample;

typedef struct {
    int has_battery;
    int is_charging;
    int is_ac;
    double level_percent;
    double health_percent;
    int cycle_count;
} CMBatterySample;

typedef struct {
    uint64_t total_bytes;
    uint64_t available_important;
} CMDiskSample;

typedef struct {
    uint64_t rx_bytes;
    uint64_t tx_bytes;
    int is_wifi;
    char iface[32];
} CMNetCounters;

typedef struct {
    int pid;
    char name[72];
    uint64_t phys_footprint;
    uint64_t cpu_ns;
    uint64_t diskio;
} CMProcRow;

typedef struct {
    int count;
    uint64_t diskio_total;
    CMProcRow rows[CM_MAX_PROCS];
} CMProcSample;

typedef struct {
    CMCPUSample cpu;
    CMMemorySample memory;
    CMChipSample chip;
    CMTempSample temp;
    CMBatterySample battery;
    CMDiskSample disk;
    CMNetCounters net;
    CMProcSample procs;
    int drive_failing;
    int thermal_state;
    double uptime_sec;
    double elapsed_sec;
} CMSnapshot;

typedef struct CMSampler CMSampler;

CMSampler *cm_sampler_create(void);
void cm_sampler_destroy(CMSampler *s);

/// Fill snapshot. Returns 0 on success. First call may have elapsed_sec == 0.
int cm_sampler_poll(CMSampler *s, CMSnapshot *out);

#ifdef __cplusplus
}
#endif

#endif
