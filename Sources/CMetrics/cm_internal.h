#ifndef CM_INTERNAL_H
#define CM_INTERNAL_H

// CMetrics 内部接口(不对 Swift 暴露):SMC、IOAccelerator、磁盘 IO、静态硬件信息。
// 实现在 sensors.c,参考 exelban/stats 的 SMC/smc.swift、Modules/GPU/reader.swift、Modules/Sensors/values.swift。

#include "CMetrics.h"

typedef struct CMSMC CMSMC;

/// 打开 AppleSMC 并探测本机可用的键;失败返回 NULL(调用方全部按"无数据"处理)
CMSMC *cm_smc_open(void);
void cm_smc_close(CMSMC *smc);

/// CPU / GPU 温度(Intel 的 TC0D/TG0D 等键);没有对应键时 have_* 为 0
void cm_smc_temps(CMSMC *smc, CMTempSample *out);
/// 风扇转速与整机功耗
void cm_smc_sensors(CMSMC *smc, CMSensorSample *out);
/// CPU 封装功耗与核显 / 独显功耗(Intel 用;Apple Silicon 走 IOReport)。没有键返回 0
int cm_smc_cpu_power(CMSMC *smc, double *watts);
int cm_smc_gpu_power(CMSMC *smc, double *watts);

/// IOAccelerator 的 PerformanceStatistics:GPU 占用率、显存占用、型号。两种架构都可用
int cm_gpu_accel(CMChipSample *out);

/// IOBlockStorageDriver 累计读写字节
void cm_disk_io(uint64_t *read_bytes, uint64_t *write_bytes);

/// 读 CPU 型号与大小核数量
void cm_read_system_info(CMSystemInfo *out);

#endif
