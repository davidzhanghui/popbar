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
#define CM_MAX_FANS 4

/// 不随时间变化的硬件信息(创建采样器时读一次)
typedef struct {
    char cpu_brand[96];   // machdep.cpu.brand_string,如 "Apple M1 Pro" / "Intel(R) Core(TM) i7-9750H"
    int pcores;           // 性能核(hw.perflevel0);Intel 没有大小核,为 0
    int ecores;           // 能效核(hw.perflevel1)
    int is_arm;
} CMSystemInfo;

typedef struct {
    int core_count;
    double package_percent;
    double user_percent;
    double system_percent;
    double load_avg[3];
    double per_core[CM_MAX_CORES];
} CMCPUSample;

typedef struct {
    uint64_t used_bytes;
    uint64_t phys_bytes;
    double used_percent;
    int pressure_level;
    uint64_t swap_used;
    uint64_t swap_total;
    uint64_t app_bytes;
    uint64_t wired_bytes;
    uint64_t compressed_bytes;
    uint64_t cached_bytes;   // 文件缓存(external + purgeable),与活动监视器一致
    uint64_t free_bytes;
} CMMemorySample;

typedef struct {
    int valid;
    int has_cpu_power;   // 有真实 CPU 功耗来源(Apple Silicon: IOReport;Intel: SMC PCPC 等)
    int has_gpu_power;
    int has_gpu_util;    // 有 GPU 占用率来源(IOAccelerator 或 IOReport)
    double cpu_watts;
    double gpu_watts;
    double ane_watts;
    double dram_watts;
    double gpu_percent;
    uint64_t gpu_mem_bytes;   // IOAccelerator "In use system memory"
    char gpu_name[64];
} CMChipSample;

/// SMC 传感器:风扇与整机功耗(Intel 与 Apple Silicon 都有,MacBook Air 无风扇)
typedef struct {
    int fan_count;
    double fan_rpm[CM_MAX_FANS];
    double fan_min[CM_MAX_FANS];
    double fan_max[CM_MAX_FANS];
    double system_watts;   // PSTR,0 表示没有
    double dcin_watts;     // PDTR
} CMSensorSample;

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
    double temperature;       // °C,0 表示未知
    double voltage;           // V
    double watts;             // 正:充电;负:放电
    int time_to_empty;        // 分钟,-1 未知
    int time_to_full;         // 分钟,-1 未知
    int adapter_watts;        // 0 表示未接或未知
    int cur_capacity_mah;
    int max_capacity_mah;
    int design_capacity_mah;
} CMBatterySample;

typedef struct {
    uint64_t total_bytes;
    uint64_t available_important;
    uint64_t read_bytes;    // IOBlockStorageDriver 累计读写字节(开机以来)
    uint64_t write_bytes;
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
    CMSensorSample sensors;
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

/// 静态硬件信息
void cm_system_info(CMSampler *s, CMSystemInfo *out);

#ifdef __cplusplus
}
#endif

#endif
