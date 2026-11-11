// SMC / IOAccelerator / 磁盘 IO / 静态硬件信息。
//
// SMC 协议与键表参考 exelban/stats(SMC/smc.swift、Modules/Sensors/values.swift),
// GPU 占用率参考 Modules/GPU/reader.swift(IOAccelerator 的 PerformanceStatistics)。
// 所有接口失败都静默返回"无数据",由 UI 显示 "—" 或隐藏对应字段。

#include "cm_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MARK: - SMC

#define SMC_KERNEL_INDEX 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData 布局必须与内核一致(80 字节)");

typedef struct {
    uint32_t key;
    uint32_t size;
    uint32_t type;
    int ok;
} SMCKey;

#define MAX_TEMP_KEYS 16

struct CMSMC {
    io_connect_t conn;
    SMCKey cpu_temp[MAX_TEMP_KEYS];
    int n_cpu_temp;
    SMCKey gpu_temp[MAX_TEMP_KEYS];
    int n_gpu_temp;
    int fan_count;
    SMCKey fan_ac[CM_MAX_FANS], fan_mn[CM_MAX_FANS], fan_mx[CM_MAX_FANS];
    SMCKey pstr, pdtr, cpu_pw, gpu_pw;
};

static uint32_t fourcc(const char *k) {
    return ((uint32_t)(uint8_t)k[0] << 24) | ((uint32_t)(uint8_t)k[1] << 16) |
           ((uint32_t)(uint8_t)k[2] << 8) | (uint32_t)(uint8_t)k[3];
}

static kern_return_t smc_call(io_connect_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outsz = sizeof(*out);
    return IOConnectCallStructMethod(conn, SMC_KERNEL_INDEX, in, sizeof(*in), out, &outsz);
}

static int hexdigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// 解码 SMC 数值:flt / ui8 / ui16 / ui32 / si8 / si16 / spXY(有符号定点)/ fpXY(无符号定点)
static int smc_decode(uint32_t type, uint32_t size, const uint8_t *b, double *out) {
    char t[5] = {(char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type, 0};
    if (strcmp(t, "flt ") == 0 && size >= 4) {
        float f;
        memcpy(&f, b, 4);   // SMC 的 flt 是本机字节序
        *out = f;
        return 1;
    }
    if (strcmp(t, "ui8 ") == 0 && size >= 1) { *out = b[0]; return 1; }
    if (strcmp(t, "si8 ") == 0 && size >= 1) { *out = (int8_t)b[0]; return 1; }
    if (strcmp(t, "ui16") == 0 && size >= 2) { *out = (uint16_t)((b[0] << 8) | b[1]); return 1; }
    if (strcmp(t, "si16") == 0 && size >= 2) { *out = (int16_t)((b[0] << 8) | b[1]); return 1; }
    if (strcmp(t, "ui32") == 0 && size >= 4) {
        *out = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
        return 1;
    }
    if (size >= 2 && (t[0] == 's' || t[0] == 'f') && t[1] == 'p') {
        int frac = hexdigit(t[3]);
        if (frac < 0) return 0;
        uint16_t raw = (uint16_t)((b[0] << 8) | b[1]);
        double v = t[0] == 's' ? (double)(int16_t)raw : (double)raw;
        *out = v / (double)(1u << frac);
        return 1;
    }
    return 0;
}

static int smc_probe(io_connect_t conn, const char *name, SMCKey *k) {
    memset(k, 0, sizeof(*k));
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    if (out.keyInfo.dataSize == 0 || out.keyInfo.dataSize > 32 || out.keyInfo.dataType == 0) return 0;
    k->key = in.key;
    k->size = out.keyInfo.dataSize;
    k->type = out.keyInfo.dataType;
    k->ok = 1;
    return 1;
}

static int smc_read(io_connect_t conn, const SMCKey *k, double *v) {
    if (!k->ok) return 0;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = k->key;
    in.keyInfo.dataSize = k->size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    return smc_decode(k->type, k->size, out.bytes, v);
}

static int temp_ok(double t) { return t >= 10.0 && t <= 115.0; }

/// 探测温度键:能读出合理温度的才保留
static int probe_temps(io_connect_t conn, const char *const *names, int n, SMCKey *dst) {
    int m = 0;
    for (int i = 0; i < n && m < MAX_TEMP_KEYS; i++) {
        SMCKey k;
        double v = 0;
        if (smc_probe(conn, names[i], &k) && smc_read(conn, &k, &v) && temp_ok(v)) dst[m++] = k;
    }
    return m;
}

static int probe_first(io_connect_t conn, const char *const *names, int n, SMCKey *dst) {
    for (int i = 0; i < n; i++) {
        double v = 0;
        if (smc_probe(conn, names[i], dst) && smc_read(conn, dst, &v)) return 1;
    }
    memset(dst, 0, sizeof(*dst));
    return 0;
}

CMSMC *cm_smc_open(void) {
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!dev) return NULL;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(dev, mach_task_self(), 0, &conn);
    IOObjectRelease(dev);
    if (kr != KERN_SUCCESS || !conn) return NULL;

    CMSMC *smc = calloc(1, sizeof *smc);
    if (!smc) {
        IOServiceClose(conn);
        return NULL;
    }
    smc->conn = conn;

    // Intel 的 CPU / GPU 温度键(Apple Silicon 优先走 HID 传感器,这里只做兜底)
    static const char *const cpuKeys[] = {
        "TC0D", "TC0E", "TC0F", "TC0P", "TCAD", "TC0H",
        "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C",
    };
    static const char *const gpuKeys[] = {"TCGC", "TG0D", "TGDD", "TG0P", "TG0H", "TG1D"};
    smc->n_cpu_temp = probe_temps(conn, cpuKeys, (int)(sizeof cpuKeys / sizeof *cpuKeys), smc->cpu_temp);
    smc->n_gpu_temp = probe_temps(conn, gpuKeys, (int)(sizeof gpuKeys / sizeof *gpuKeys), smc->gpu_temp);

    SMCKey fnum;
    double nf = 0;
    if (smc_probe(conn, "FNum", &fnum) && smc_read(conn, &fnum, &nf) && nf > 0) {
        int n = (int)nf;
        if (n > CM_MAX_FANS) n = CM_MAX_FANS;
        for (int i = 0; i < n; i++) {
            char ac[5], mn[5], mx[5];
            snprintf(ac, sizeof ac, "F%dAc", i);
            snprintf(mn, sizeof mn, "F%dMn", i);
            snprintf(mx, sizeof mx, "F%dMx", i);
            if (!smc_probe(conn, ac, &smc->fan_ac[smc->fan_count])) continue;
            smc_probe(conn, mn, &smc->fan_mn[smc->fan_count]);
            smc_probe(conn, mx, &smc->fan_mx[smc->fan_count]);
            smc->fan_count++;
        }
    }

    static const char *const pstr[] = {"PSTR"};
    static const char *const pdtr[] = {"PDTR"};
    static const char *const cpuPw[] = {"PCPC", "PCPT", "PCTR", "PC0C", "PCAM"};
    static const char *const gpuPw[] = {"PCPG", "PG0C", "PCGC", "PG0R"};
    probe_first(conn, pstr, 1, &smc->pstr);
    probe_first(conn, pdtr, 1, &smc->pdtr);
    probe_first(conn, cpuPw, (int)(sizeof cpuPw / sizeof *cpuPw), &smc->cpu_pw);
    probe_first(conn, gpuPw, (int)(sizeof gpuPw / sizeof *gpuPw), &smc->gpu_pw);
    return smc;
}

void cm_smc_close(CMSMC *smc) {
    if (!smc) return;
    if (smc->conn) IOServiceClose(smc->conn);
    free(smc);
}

static int max_temp(CMSMC *smc, const SMCKey *keys, int n, double *out) {
    int found = 0;
    double best = 0;
    for (int i = 0; i < n; i++) {
        double v = 0;
        if (smc_read(smc->conn, &keys[i], &v) && temp_ok(v)) {
            if (!found || v > best) best = v;
            found = 1;
        }
    }
    if (found) *out = best;
    return found;
}

void cm_smc_temps(CMSMC *smc, CMTempSample *out) {
    if (!smc) return;
    double v = 0;
    if (!out->have_cpu && max_temp(smc, smc->cpu_temp, smc->n_cpu_temp, &v)) {
        out->cpu_temp = v;
        out->have_cpu = 1;
    }
    if (max_temp(smc, smc->gpu_temp, smc->n_gpu_temp, &v)) {
        out->gpu_temp = v;
        out->have_gpu = 1;
    }
}

void cm_smc_sensors(CMSMC *smc, CMSensorSample *out) {
    memset(out, 0, sizeof(*out));
    if (!smc) return;
    for (int i = 0; i < smc->fan_count; i++) {
        double rpm = 0, mn = 0, mx = 0;
        if (!smc_read(smc->conn, &smc->fan_ac[i], &rpm)) continue;
        smc_read(smc->conn, &smc->fan_mn[i], &mn);
        smc_read(smc->conn, &smc->fan_mx[i], &mx);
        int k = out->fan_count++;
        out->fan_rpm[k] = rpm < 0 ? 0 : rpm;
        out->fan_min[k] = mn;
        out->fan_max[k] = mx;
    }
    double w = 0;
    if (smc_read(smc->conn, &smc->pstr, &w) && w > 0 && w < 1000) out->system_watts = w;
    if (smc_read(smc->conn, &smc->pdtr, &w) && w > 0 && w < 1000) out->dcin_watts = w;
}

int cm_smc_cpu_power(CMSMC *smc, double *watts) {
    double w = 0;
    if (!smc || !smc_read(smc->conn, &smc->cpu_pw, &w) || w < 0 || w > 500) return 0;
    *watts = w;
    return 1;
}

int cm_smc_gpu_power(CMSMC *smc, double *watts) {
    double w = 0;
    if (!smc || !smc_read(smc->conn, &smc->gpu_pw, &w) || w < 0 || w > 500) return 0;
    *watts = w;
    return 1;
}

// MARK: - IOAccelerator(GPU)

static int64_t dict_int(CFDictionaryRef d, CFStringRef key, int64_t fallback) {
    CFTypeRef v = CFDictionaryGetValue(d, key);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return fallback;
    int64_t n = 0;
    CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
    return n;
}

/// 型号:AGX 的 accelerator 自带 "model" 字符串;Intel / AMD 在父级 IOPCIDevice 上是 CFData
static void accel_name(io_registry_entry_t e, char *buf, size_t n) {
    buf[0] = 0;
    CFTypeRef m = IORegistryEntrySearchCFProperty(e, kIOServicePlane, CFSTR("model"), kCFAllocatorDefault,
                                                  kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (m) {
        if (CFGetTypeID(m) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)m, buf, (CFIndex)n, kCFStringEncodingUTF8);
        } else if (CFGetTypeID(m) == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength((CFDataRef)m);
            if (len >= (CFIndex)n) len = (CFIndex)n - 1;
            memcpy(buf, CFDataGetBytePtr((CFDataRef)m), (size_t)len);
            buf[len] = 0;
        }
        CFRelease(m);
    }
    if (buf[0]) return;
    io_name_t cls;
    if (IOObjectGetClass(e, cls) != KERN_SUCCESS) return;
    if (strcasestr(cls, "intel")) snprintf(buf, n, "Intel Graphics");
    else if (strcasestr(cls, "amd")) snprintf(buf, n, "AMD Radeon");
    else if (strcasestr(cls, "nv")) snprintf(buf, n, "NVIDIA");
    else if (strcasestr(cls, "agx")) snprintf(buf, n, "Apple GPU");
}

int cm_gpu_accel(CMChipSample *out) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) {
        return 0;
    }
    int found = 0;
    int64_t best = -1;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        CFTypeRef st = IORegistryEntryCreateCFProperty(e, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (st && CFGetTypeID(st) == CFDictionaryGetTypeID()) {
            CFDictionaryRef d = (CFDictionaryRef)st;
            int64_t util = dict_int(d, CFSTR("Device Utilization %"), -1);
            if (util < 0) util = dict_int(d, CFSTR("GPU Activity(%)"), -1);
            if (util >= 0) {
                if (util > 100) util = 100;
                // 双显卡(Intel 核显 + AMD 独显)取更忙的那块
                if (util > best) {
                    best = util;
                    int64_t mem = dict_int(d, CFSTR("In use system memory"), -1);
                    if (mem < 0) mem = dict_int(d, CFSTR("vramUsedBytes"), 0);
                    out->gpu_mem_bytes = mem > 0 ? (uint64_t)mem : 0;
                    accel_name(e, out->gpu_name, sizeof out->gpu_name);
                }
                found = 1;
            }
        }
        if (st) CFRelease(st);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    if (found) {
        out->gpu_percent = (double)best;
        out->has_gpu_util = 1;
    }
    return found;
}

// MARK: - 磁盘 IO

void cm_disk_io(uint64_t *read_bytes, uint64_t *write_bytes) {
    *read_bytes = 0;
    *write_bytes = 0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != KERN_SUCCESS) {
        return;
    }
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        CFTypeRef st = IORegistryEntryCreateCFProperty(e, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (st && CFGetTypeID(st) == CFDictionaryGetTypeID()) {
            int64_t r = dict_int((CFDictionaryRef)st, CFSTR("Bytes (Read)"), 0);
            int64_t w = dict_int((CFDictionaryRef)st, CFSTR("Bytes (Write)"), 0);
            if (r > 0) *read_bytes += (uint64_t)r;
            if (w > 0) *write_bytes += (uint64_t)w;
        }
        if (st) CFRelease(st);
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

// MARK: - 静态信息

static int sysctl_int(const char *name) {
    int v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    return v;
}

void cm_read_system_info(CMSystemInfo *out) {
    memset(out, 0, sizeof(*out));
    size_t len = sizeof out->cpu_brand;
    if (sysctlbyname("machdep.cpu.brand_string", out->cpu_brand, &len, NULL, 0) != 0) out->cpu_brand[0] = 0;
    out->cpu_brand[sizeof out->cpu_brand - 1] = 0;
#if defined(__arm64__)
    out->is_arm = 1;
#else
    out->is_arm = sysctl_int("sysctl.proc_translated") == 1;   // Rosetta 下运行的 x86 包
#endif
    if (sysctl_int("hw.nperflevels") >= 2) {
        out->pcores = sysctl_int("hw.perflevel0.logicalcpu");
        out->ecores = sysctl_int("hw.perflevel1.logicalcpu");
    }
}
