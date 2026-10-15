#include "CMetrics.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <libproc.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/time.h>

#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureBase (15u << 16)

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDServiceClientRef;
typedef void *IOHIDEventRef;

typedef CFDictionaryRef (*fn_copy_all)(uint64_t, uint64_t);
typedef CFMutableDictionaryRef (*fn_copy_group)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*fn_merge)(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef void *(*fn_create_sub)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_create_samples)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*fn_create_delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*fn_ch_group)(CFDictionaryRef);
typedef CFStringRef (*fn_ch_sub)(CFDictionaryRef);
typedef CFStringRef (*fn_ch_name)(CFDictionaryRef);
typedef CFStringRef (*fn_ch_unit)(CFDictionaryRef);
typedef long (*fn_get_int)(CFDictionaryRef, int *);
typedef int (*fn_state_count)(CFDictionaryRef);
typedef CFStringRef (*fn_state_name)(CFDictionaryRef, int);
typedef uint64_t (*fn_state_res)(CFDictionaryRef, int);
typedef int (^ior_block)(CFDictionaryRef);
typedef void (*fn_iterate)(CFDictionaryRef, ior_block);

typedef IOHIDEventSystemClientRef (*fn_hid_create)(CFAllocatorRef);
typedef CFArrayRef (*fn_hid_copy_services)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*fn_hid_copy_prop)(IOHIDServiceClientRef, CFStringRef);
typedef IOHIDEventRef (*fn_hid_copy_event)(IOHIDServiceClientRef, int, int, int);
typedef double (*fn_hid_get_float)(IOHIDEventRef, uint32_t);
typedef void (*fn_hid_set_matching)(IOHIDEventSystemClientRef, CFDictionaryRef);

typedef struct {
    fn_copy_all copy_all;
    fn_copy_group copy_group;
    fn_merge merge;
    fn_create_sub create_sub;
    fn_create_samples create_samples;
    fn_create_delta create_delta;
    fn_ch_group get_group;
    fn_ch_sub get_sub;
    fn_ch_name get_name;
    fn_ch_unit get_unit;
    fn_get_int get_int;
    fn_state_count state_count;
    fn_state_name state_name;
    fn_state_res state_res;
    fn_iterate iterate;
    void *handle;
    int ready;
} IOReportAPI;

typedef struct {
    fn_hid_create create;
    fn_hid_copy_services copy_services;
    fn_hid_copy_prop copy_prop;
    fn_hid_copy_event copy_event;
    fn_hid_get_float get_float;
    fn_hid_set_matching set_matching;
    int ready;
} HIDAPI;

struct CMSampler {
    processor_info_array_t prev_ticks;
    mach_msg_type_number_t prev_tick_count;
    unsigned int prev_ncpu;
    int have_prev_cpu;

    CFMutableDictionaryRef ior_channels;
    void *ior_sub;
    CFMutableDictionaryRef ior_subbed;
    CFDictionaryRef ior_prev_samples;
    uint64_t ior_prev_mach;
    double prev_cpu_e, prev_gpu_e, prev_ane_e, prev_dram_e;
    int have_prev_energy;
    double last_gpu_watts;

    uint64_t prev_rx, prev_tx;
    int have_prev_net;

    uint64_t prev_diskio;
    int have_prev_diskio;

    uint64_t prev_proc_ns[CM_MAX_PROCS];
    int prev_proc_pid[CM_MAX_PROCS];
    int prev_proc_count;

    uint64_t prev_mach;
    int have_prev_time;

    int cached_drive_failing;
    uint64_t drive_checked_mach;

    IOReportAPI ior;
    HIDAPI hid;
};

static mach_timebase_info_data_t g_timebase;
static pthread_once_t g_timebase_once = PTHREAD_ONCE_INIT;

static void init_timebase(void) {
    mach_timebase_info(&g_timebase);
}

static double mach_to_sec(uint64_t delta) {
    pthread_once(&g_timebase_once, init_timebase);
    return (double)delta * (double)g_timebase.numer / (double)g_timebase.denom / 1e9;
}

static void cf_str(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (!s || n == 0) return;
    CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static void strip_underscore(const char *in, char *out, size_t n) {
    size_t j = 0;
    for (size_t i = 0; in[i] && j + 1 < n; i++) {
        if (in[i] != '_') out[j++] = in[i];
    }
    out[j] = 0;
}

/// 1 CPU Energy  2 ANE  3 DRAM  4 GPU(mJ)  5 GPU Energy(nJ 回退)  6 ECPU/PCPU 簇回退
static int classify_energy(const char *name) {
    if (!name || !name[0]) return 0;
    if (strcmp(name, "CPU Energy") == 0 || strcmp(name, "_CPU Energy") == 0) return 1;
    if (strncmp(name, "DIE_", 4) == 0 && strstr(name, "CPU Energy")) return 1;
    if (strcmp(name, "ANE") == 0) return 2;
    if (strcmp(name, "DRAM") == 0) return 3;
    if (strcmp(name, "GPU") == 0) return 4;
    if (strcmp(name, "GPU Energy") == 0) return 5;
    if (strcmp(name, "ECPU") == 0 || strcmp(name, "PCPU") == 0 || strcmp(name, "MCPU") == 0) return 6;
    char buf[160];
    strip_underscore(name, buf, sizeof buf);
    if (strcmp(buf, "ANE") == 0) return 2;
    if (strncmp(buf, "DRAM", 4) == 0 && (buf[4] == 0 || buf[4] == ' ')) return 3;
    return 0;
}

static double energy_to_joules(uint64_t raw, const char *unit) {
    if (unit && unit[0]) {
        if (strstr(unit, "nJ")) return (double)raw / 1e9;
        if (strstr(unit, "uJ")) return (double)raw / 1e6;
        if (strstr(unit, "mJ")) return (double)raw / 1e3;
        if (strcmp(unit, "J") == 0) return (double)raw;
    }
    if (raw > 100000000ULL) return (double)raw / 1e8;
    return (double)raw / 1000.0;
}

static void ior_load(IOReportAPI *api) {
    memset(api, 0, sizeof(*api));
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!h) return;
    api->handle = h;
    api->copy_all = (fn_copy_all)dlsym(h, "IOReportCopyAllChannels");
    api->copy_group = (fn_copy_group)dlsym(h, "IOReportCopyChannelsInGroup");
    api->merge = (fn_merge)dlsym(h, "IOReportMergeChannels");
    api->create_sub = (fn_create_sub)dlsym(h, "IOReportCreateSubscription");
    api->create_samples = (fn_create_samples)dlsym(h, "IOReportCreateSamples");
    api->create_delta = (fn_create_delta)dlsym(h, "IOReportCreateSamplesDelta");
    api->get_group = (fn_ch_group)dlsym(h, "IOReportChannelGetGroup");
    api->get_sub = (fn_ch_sub)dlsym(h, "IOReportChannelGetSubGroup");
    api->get_name = (fn_ch_name)dlsym(h, "IOReportChannelGetChannelName");
    api->get_unit = (fn_ch_unit)dlsym(h, "IOReportChannelGetUnitLabel");
    api->get_int = (fn_get_int)dlsym(h, "IOReportSimpleGetIntegerValue");
    api->state_count = (fn_state_count)dlsym(h, "IOReportStateGetCount");
    api->state_name = (fn_state_name)dlsym(h, "IOReportStateGetNameForIndex");
    api->state_res = (fn_state_res)dlsym(h, "IOReportStateGetResidency");
    api->iterate = (fn_iterate)dlsym(h, "IOReportIterate");
    api->ready = (api->copy_all || api->copy_group) && api->create_sub && api->create_samples &&
                 api->get_group && api->get_name && api->get_int;
}

static void hid_load(HIDAPI *api) {
    memset(api, 0, sizeof(*api));
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return;
    api->create = (fn_hid_create)dlsym(h, "IOHIDEventSystemClientCreate");
    api->copy_services = (fn_hid_copy_services)dlsym(h, "IOHIDEventSystemClientCopyServices");
    api->copy_prop = (fn_hid_copy_prop)dlsym(h, "IOHIDServiceClientCopyProperty");
    api->copy_event = (fn_hid_copy_event)dlsym(h, "IOHIDServiceClientCopyEvent");
    api->get_float = (fn_hid_get_float)dlsym(h, "IOHIDEventGetFloatValue");
    api->set_matching = (fn_hid_set_matching)dlsym(h, "IOHIDEventSystemClientSetMatching");
    api->ready = api->create && api->copy_services && api->copy_prop &&
                 api->copy_event && api->get_float;
}

typedef struct {
    IOReportAPI *api;
    double cpu_e, gpu_e, ane_e, dram_e;
    double cpu_cluster, gpu_energy;
    int has_cpu_energy, has_gpu_mj;
    uint64_t gpu_active, gpu_total;
} EnergyAcc;

static void accumulate_channel(EnergyAcc *acc, CFDictionaryRef ch) {
    char group[96] = {0}, sub[96] = {0}, name[160] = {0}, unit[64] = {0};
    if (acc->api->get_group) cf_str(acc->api->get_group(ch), group, sizeof group);
    if (acc->api->get_sub) cf_str(acc->api->get_sub(ch), sub, sizeof sub);
    if (acc->api->get_name) cf_str(acc->api->get_name(ch), name, sizeof name);
    if (acc->api->get_unit) cf_str(acc->api->get_unit(ch), unit, sizeof unit);

    if (strcmp(group, "Energy Model") == 0 && acc->api->get_int) {
        long raw = acc->api->get_int(ch, NULL);
        if (raw < 0) raw = 0;
        double e = energy_to_joules((uint64_t)raw, unit);
        int kind = classify_energy(name);
        if (kind == 1) { acc->cpu_e += e; acc->has_cpu_energy = 1; }
        else if (kind == 2) acc->ane_e += e;
        else if (kind == 3) acc->dram_e += e;
        else if (kind == 4) { acc->gpu_e += e; acc->has_gpu_mj = 1; }
        else if (kind == 5) acc->gpu_energy += e;
        else if (kind == 6) acc->cpu_cluster += e;
    }

    if (strcmp(sub, "GPU Performance States") == 0 && acc->api->state_count && acc->api->state_res) {
        int n = acc->api->state_count(ch);
        if (n < 0) n = 0;
        for (int i = 0; i < n; i++) {
            uint64_t res = acc->api->state_res(ch, i);
            acc->gpu_total += res;
            char st[64] = {0};
            if (acc->api->state_name) cf_str(acc->api->state_name(ch, i), st, sizeof st);
            if (!(st[0] == 0 || strcasestr(st, "idle") || strcasestr(st, "off") || strcasecmp(st, "min") == 0)) {
                acc->gpu_active += res;
            }
        }
    }
}

static void iterate_samples(IOReportAPI *api, CFDictionaryRef samples, EnergyAcc *acc) {
    if (!samples) return;
    if (api->iterate) {
        api->iterate(samples, ^(CFDictionaryRef ch) {
            if (ch) accumulate_channel(acc, ch);
            return 0;
        });
        return;
    }
    CFArrayRef arr = CFDictionaryGetValue(samples, CFSTR("IOReportChannels"));
    if (arr && CFGetTypeID(arr) == CFArrayGetTypeID()) {
        CFIndex n = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
            if (ch && CFGetTypeID(ch) == CFDictionaryGetTypeID()) {
                accumulate_channel(acc, ch);
            }
        }
    }
}

static void poll_chip(CMSampler *s, CMChipSample *out, double dt) {
    memset(out, 0, sizeof(*out));
    IOReportAPI *api = &s->ior;
    if (!api->ready) return;
    if (!s->ior_channels) {
        CFMutableDictionaryRef ch = NULL;
        if (api->copy_group) {
            ch = api->copy_group(CFSTR("Energy Model"), NULL, 0, 0, 0);
            if (ch && api->merge) {
                CFMutableDictionaryRef gpu = api->copy_group(CFSTR("GPU Stats"), NULL, 0, 0, 0);
                if (gpu) {
                    api->merge(ch, gpu, NULL);
                    CFRelease(gpu);
                }
            }
        }
        if (!ch && api->copy_all) {
            CFDictionaryRef all = api->copy_all(0, 0);
            if (all) {
                ch = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all);
                CFRelease(all);
            }
        }
        s->ior_channels = ch;
        if (!s->ior_channels) return;
        s->ior_sub = api->create_sub(NULL, s->ior_channels, &s->ior_subbed, 0, NULL);
    }
    if (!s->ior_sub || !api->create_samples) return;
    CFMutableDictionaryRef use_ch = s->ior_subbed ? s->ior_subbed : s->ior_channels;
    CFDictionaryRef cur = api->create_samples(s->ior_sub, use_ch, NULL);
    if (!cur) return;
    uint64_t now = mach_absolute_time();
    CFDictionaryRef use = cur;
    CFDictionaryRef delta = NULL;
    if (s->ior_prev_samples && api->create_delta) {
        delta = api->create_delta(s->ior_prev_samples, cur, NULL);
        if (delta) use = delta;
    }
    EnergyAcc acc;
    memset(&acc, 0, sizeof acc);
    acc.api = api;
    iterate_samples(api, use, &acc);
    if (!acc.has_cpu_energy) acc.cpu_e = acc.cpu_cluster;
    if (!acc.has_gpu_mj) acc.gpu_e = acc.gpu_energy;

    double edt = dt;
    if (s->ior_prev_mach) {
        double ior_dt = mach_to_sec(now - s->ior_prev_mach);
        if (ior_dt > 0.05) edt = ior_dt;
    }
    if (edt < 0.05) edt = 0.05;

    if (s->have_prev_energy && !delta) {
        out->cpu_watts = fmax(0, (acc.cpu_e - s->prev_cpu_e) / edt);
        out->gpu_watts = fmax(0, (acc.gpu_e - s->prev_gpu_e) / edt);
        out->ane_watts = fmax(0, (acc.ane_e - s->prev_ane_e) / edt);
        out->dram_watts = fmax(0, (acc.dram_e - s->prev_dram_e) / edt);
    } else if (delta) {
        out->cpu_watts = fmax(0, acc.cpu_e / edt);
        out->gpu_watts = fmax(0, acc.gpu_e / edt);
        out->ane_watts = fmax(0, acc.ane_e / edt);
        out->dram_watts = fmax(0, acc.dram_e / edt);
    }
    if (acc.gpu_total > 0) {
        out->gpu_percent = 100.0 * (double)acc.gpu_active / (double)acc.gpu_total;
        if (out->gpu_percent > 100) out->gpu_percent = 100;
    }
    if (out->gpu_watts > 80 && s->last_gpu_watts < 1) {
        out->gpu_watts = s->last_gpu_watts;
    }
    s->last_gpu_watts = out->gpu_watts;
    s->prev_cpu_e = acc.cpu_e;
    s->prev_gpu_e = acc.gpu_e;
    s->prev_ane_e = acc.ane_e;
    s->prev_dram_e = acc.dram_e;
    s->have_prev_energy = 1;
    out->valid = 1;

    if (s->ior_prev_samples) CFRelease(s->ior_prev_samples);
    s->ior_prev_samples = cur;
    s->ior_prev_mach = now;
    if (delta) CFRelease(delta);
}

static void poll_cpu(CMSampler *s, CMCPUSample *out) {
    memset(out, 0, sizeof(*out));
    natural_t ncpu = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    host_t host = mach_host_self();
    if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &count) != KERN_SUCCESS) {
        return;
    }
    unsigned int cores = ncpu;
    if (cores > CM_MAX_CORES) cores = CM_MAX_CORES;
    out->core_count = (int)cores;

    processor_cpu_load_info_t cur = (processor_cpu_load_info_t)info;
    double sum_used = 0, sum_total = 0;
    if (s->have_prev_cpu && s->prev_ncpu == ncpu && s->prev_ticks) {
        processor_cpu_load_info_t prev = (processor_cpu_load_info_t)s->prev_ticks;
        for (unsigned int i = 0; i < cores; i++) {
            double du = (double)cur[i].cpu_ticks[CPU_STATE_USER] - (double)prev[i].cpu_ticks[CPU_STATE_USER];
            double ds = (double)cur[i].cpu_ticks[CPU_STATE_SYSTEM] - (double)prev[i].cpu_ticks[CPU_STATE_SYSTEM];
            double dn = (double)cur[i].cpu_ticks[CPU_STATE_NICE] - (double)prev[i].cpu_ticks[CPU_STATE_NICE];
            double di = (double)cur[i].cpu_ticks[CPU_STATE_IDLE] - (double)prev[i].cpu_ticks[CPU_STATE_IDLE];
            if (du < 0) du = 0;
            if (ds < 0) ds = 0;
            if (dn < 0) dn = 0;
            if (di < 0) di = 0;
            double used = du + ds + dn;
            double total = used + di;
            if (total > 0) {
                double pct = 100.0 * used / total;
                if (pct > 100) pct = 100;
                out->per_core[i] = pct;
                sum_used += used;
                sum_total += total;
            }
        }
        if (sum_total > 0) out->package_percent = 100.0 * sum_used / sum_total;
    }
    if (s->prev_ticks) {
        vm_deallocate(mach_task_self(), (vm_address_t)s->prev_ticks, s->prev_tick_count * sizeof(integer_t));
    }
    s->prev_ticks = info;
    s->prev_tick_count = count;
    s->prev_ncpu = ncpu;
    s->have_prev_cpu = 1;
}

static void poll_memory(CMMemorySample *out) {
    memset(out, 0, sizeof(*out));
    vm_size_t pagesize = 0;
    host_page_size(mach_host_self(), &pagesize);
    if (pagesize == 0) pagesize = (vm_size_t)sysconf(_SC_PAGESIZE);

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        return;
    }

    uint64_t phys = 0;
    size_t len = sizeof phys;
    int mib[2] = {CTL_HW, HW_MEMSIZE};
    sysctl(mib, 2, &phys, &len, NULL, 0);
    out->phys_bytes = phys;

    int64_t app_pages = (int64_t)vm.internal_page_count - (int64_t)vm.purgeable_count;
    if (app_pages < 0) app_pages = 0;
    uint64_t used = ((uint64_t)vm.wire_count + (uint64_t)vm.compressor_page_count) * (uint64_t)pagesize +
                    (uint64_t)app_pages * (uint64_t)pagesize;
    if (phys > 0 && used > phys) used = phys;
    out->used_bytes = used;
    if (phys > 0) out->used_percent = 100.0 * (double)used / (double)phys;

    int pressure = 3;
    len = sizeof pressure;
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &len, NULL, 0) != 0) {
        pressure = 3;
    }
    if (pressure > 4) pressure = 3;
    if (pressure < 0) pressure = 3;
    out->pressure_level = pressure;

    struct xsw_usage swap;
    memset(&swap, 0, sizeof swap);
    len = sizeof swap;
    if (sysctlbyname("vm.swapusage", &swap, &len, NULL, 0) == 0) {
        out->swap_used = swap.xsu_used;
        out->swap_total = swap.xsu_total;
    }
}

static int temp_in_range(double t) {
    return t >= 10.0 && t <= 115.0;
}

static void poll_temp(HIDAPI *hid, CMTempSample *out) {
    memset(out, 0, sizeof(*out));
    if (!hid->ready) return;
    IOHIDEventSystemClientRef client = hid->create(kCFAllocatorDefault);
    if (!client) return;
    if (hid->set_matching) {
        int page = 0xff00;
        int usage = 5;
        CFNumberRef pageN = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
        CFNumberRef usageN = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        if (pageN && usageN) {
            const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
            const void *vals[] = { pageN, usageN };
            CFDictionaryRef matching = CFDictionaryCreate(
                kCFAllocatorDefault, keys, vals, 2,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (matching) {
                hid->set_matching(client, matching);
                CFRelease(matching);
            }
        }
        if (pageN) CFRelease(pageN);
        if (usageN) CFRelease(usageN);
    }
    CFArrayRef services = hid->copy_services(client);
    if (!services) {
        CFRelease(client);
        return;
    }
    CFIndex n = CFArrayGetCount(services);
    double cpu = 0, gpu = 0;
    int ncpu = 0, ngpu = 0;
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef product = (CFStringRef)hid->copy_prop(svc, CFSTR("Product"));
        char name[96] = {0};
        if (product && CFGetTypeID(product) == CFStringGetTypeID()) cf_str(product, name, sizeof name);
        if (product) CFRelease(product);
        IOHIDEventRef ev = hid->copy_event(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        double t = hid->get_float(ev, kIOHIDEventFieldTemperatureBase);
        CFRelease(ev);
        if (!temp_in_range(t)) continue;
        int is_cpu = strncmp(name, "PMU tdie", 8) == 0;
        int is_soc = strncmp(name, "SOC MTR Temp Sensor", 19) == 0;
        if (is_cpu || is_soc) {
            if (ncpu == 0 || t > cpu) cpu = t;
            ncpu++;
        } else if (strcasestr(name, "GPU") || strcasestr(name, "gpu")) {
            if (ngpu == 0 || t > gpu) gpu = t;
            ngpu++;
        }
    }
    if (ncpu > 0) {
        out->cpu_temp = cpu;
        out->have_cpu = 1;
    }
    if (ngpu > 0) {
        out->gpu_temp = gpu;
        out->have_gpu = 1;
    } else if (out->have_cpu) {
        out->gpu_temp = out->cpu_temp;
        out->have_gpu = 1;
    }
    CFRelease(services);
    CFRelease(client);
}

static int64_t cf_int64(CFTypeRef v) {
    if (!v) return -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int64_t n = 0;
        CFNumberGetValue(v, kCFNumberSInt64Type, &n);
        return n;
    }
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        char buf[32];
        cf_str(v, buf, sizeof buf);
        return (int64_t)strtoll(buf, NULL, 10);
    }
    return -1;
}

static void poll_battery(CMBatterySample *out) {
    memset(out, 0, sizeof(*out));
    out->health_percent = 100;
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        CFArrayRef list = IOPSCopyPowerSourcesList(blob);
        if (list) {
            CFIndex n = CFArrayGetCount(list);
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
                if (!d) continue;
                CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
                if (type && CFEqual(type, CFSTR(kIOPSInternalBatteryType))) {
                    out->has_battery = 1;
                    int64_t cur = cf_int64(CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)));
                    int64_t max = cf_int64(CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey)));
                    if (cur >= 0 && max > 0) out->level_percent = 100.0 * (double)cur / (double)max;
                    CFBooleanRef ch = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
                    if (ch) out->is_charging = CFBooleanGetValue(ch);
                    CFStringRef state = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
                    if (state && CFEqual(state, CFSTR(kIOPSACPowerValue))) out->is_ac = 1;
                }
            }
            CFRelease(list);
        }
        CFRelease(blob);
    }

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (svc) {
        out->has_battery = 1;
        CFTypeRef pct = IORegistryEntryCreateCFProperty(svc, CFSTR("MaximumCapacityPercent"), kCFAllocatorDefault, 0);
        if (pct) {
            int64_t v = cf_int64(pct);
            if (v > 0 && v <= 100) out->health_percent = (double)v;
            CFRelease(pct);
        } else {
            CFTypeRef raw = IORegistryEntryCreateCFProperty(svc, CFSTR("AppleRawMaxCapacity"), kCFAllocatorDefault, 0);
            CFTypeRef design = IORegistryEntryCreateCFProperty(svc, CFSTR("DesignCapacity"), kCFAllocatorDefault, 0);
            int64_t r = cf_int64(raw), d = cf_int64(design);
            if (raw) CFRelease(raw);
            if (design) CFRelease(design);
            if (r > 0 && d > 0) {
                double h = 100.0 * (double)r / (double)d;
                if (h > 100) h = 100;
                out->health_percent = h;
            }
        }
        CFTypeRef sp = IORegistryEntryCreateCFProperty(svc, CFSTR("sppower_battery_health_maximum_capacity"), kCFAllocatorDefault, 0);
        if (sp) {
            int64_t v = cf_int64(sp);
            if (v > 0 && v <= 100) out->health_percent = (double)v;
            CFRelease(sp);
        }
        CFTypeRef cycles = IORegistryEntryCreateCFProperty(svc, CFSTR("CycleCount"), kCFAllocatorDefault, 0);
        if (cycles) {
            int64_t v = cf_int64(cycles);
            if (v >= 0) out->cycle_count = (int)v;
            CFRelease(cycles);
        }
        IOObjectRelease(svc);
    }
}

static void poll_disk(CMDiskSample *out) {
    memset(out, 0, sizeof(*out));
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFSTR("/"), kCFURLPOSIXPathStyle, true);
    if (!url) return;
    CFNumberRef total = NULL, avail = NULL;
    CFURLCopyResourcePropertyForKey(url, kCFURLVolumeTotalCapacityKey, &total, NULL);
    CFURLCopyResourcePropertyForKey(url, kCFURLVolumeAvailableCapacityForImportantUsageKey, &avail, NULL);
    if (total) {
        int64_t v = 0;
        CFNumberGetValue(total, kCFNumberSInt64Type, &v);
        if (v > 0) out->total_bytes = (uint64_t)v;
        CFRelease(total);
    }
    if (avail) {
        int64_t v = 0;
        CFNumberGetValue(avail, kCFNumberSInt64Type, &v);
        if (v > 0) out->available_important = (uint64_t)v;
        CFRelease(avail);
    }
    CFRelease(url);
}

static void poll_net(CMSampler *s, CMNetCounters *out) {
    memset(out, 0, sizeof(*out));
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    uint64_t rx = 0, tx = 0;
    const char *chosen = NULL;
    int wifi = 0;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        const char *nm = ifa->ifa_name;
        if (!nm) continue;
        if (strncmp(nm, "lo", 2) == 0 || strncmp(nm, "utun", 4) == 0 ||
            strncmp(nm, "awdl", 4) == 0 || strncmp(nm, "llw", 3) == 0 ||
            strncmp(nm, "bridge", 6) == 0 || strncmp(nm, "ap", 2) == 0) {
            continue;
        }
        struct if_data *data = (struct if_data *)ifa->ifa_data;
        if (!data) continue;
        rx += data->ifi_ibytes;
        tx += data->ifi_obytes;
        if (strncmp(nm, "en", 2) == 0) {
            if (!chosen || !wifi) {
                chosen = nm;
                wifi = 1;
            }
        } else if (!chosen) {
            chosen = nm;
            wifi = 0;
        }
    }
    out->rx_bytes = rx;
    out->tx_bytes = tx;
    out->is_wifi = wifi;
    if (chosen) snprintf(out->iface, sizeof out->iface, "%s", chosen);
    (void)s;
    freeifaddrs(list);
}

static int proc_sort_mem(const void *a, const void *b) {
    const CMProcRow *x = a, *y = b;
    if (x->phys_footprint < y->phys_footprint) return 1;
    if (x->phys_footprint > y->phys_footprint) return -1;
    return 0;
}

static void poll_procs(CMProcSample *out) {
    memset(out, 0, sizeof(*out));
    int bufsize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bufsize <= 0) return;
    pid_t *pids = calloc((size_t)bufsize / (int)sizeof(pid_t) + 8, sizeof(pid_t));
    if (!pids) return;
    int n = proc_listpids(PROC_ALL_PIDS, 0, pids, bufsize) / (int)sizeof(pid_t);
    CMProcRow *tmp = calloc((size_t)n + 1, sizeof(CMProcRow));
    int m = 0;
    uint64_t diskio = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v4 ru;
        memset(&ru, 0, sizeof ru);
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru) != 0) continue;
        char name[72];
        name[0] = 0;
        if (proc_name(pid, name, sizeof name) <= 0) {
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, path, sizeof path) > 0) {
                const char *base = strrchr(path, '/');
                snprintf(name, sizeof name, "%s", base ? base + 1 : path);
            } else {
                snprintf(name, sizeof name, "pid %d", pid);
            }
        }
        tmp[m].pid = pid;
        snprintf(tmp[m].name, sizeof tmp[m].name, "%s", name);
        tmp[m].phys_footprint = ru.ri_phys_footprint;
        tmp[m].cpu_ns = ru.ri_user_time + ru.ri_system_time;
        tmp[m].diskio = ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten;
        diskio += tmp[m].diskio;
        m++;
    }
    qsort(tmp, (size_t)m, sizeof(CMProcRow), proc_sort_mem);
    int keep = m < CM_MAX_PROCS ? m : CM_MAX_PROCS;
    memcpy(out->rows, tmp, (size_t)keep * sizeof(CMProcRow));
    out->count = keep;
    out->diskio_total = diskio;
    free(tmp);
    free(pids);
}

static int walk_drive_failing(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != KERN_SUCCESS) {
        return 0;
    }
    int failing = 0;
    io_object_t obj;
    while ((obj = IOIteratorNext(it))) {
        CFTypeRef smart = IORegistryEntryCreateCFProperty(obj, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (smart && CFGetTypeID(smart) == CFDictionaryGetTypeID()) {
            CFStringRef desc = CFCopyDescription(smart);
            char buf[2048];
            cf_str(desc, buf, sizeof buf);
            if (desc) CFRelease(desc);
            if (strcasestr(buf, "failing")) failing = 1;
        }
        if (smart) CFRelease(smart);
        CFTypeRef st = IORegistryEntryCreateCFProperty(obj, CFSTR("SMART Status"), kCFAllocatorDefault, 0);
        if (st && CFGetTypeID(st) == CFStringGetTypeID()) {
            char buf[64];
            cf_str(st, buf, sizeof buf);
            if (strcasestr(buf, "fail")) failing = 1;
        }
        if (st) CFRelease(st);
        IOObjectRelease(obj);
        if (failing) break;
    }
    IOObjectRelease(it);
    return failing;
}

static double uptime_seconds(void) {
    struct timeval boot;
    size_t len = sizeof boot;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boot, &len, NULL, 0) != 0) return 0;
    struct timeval now;
    gettimeofday(&now, NULL);
    return difftime(now.tv_sec, boot.tv_sec);
}

CMSampler *cm_sampler_create(void) {
    CMSampler *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    ior_load(&s->ior);
    hid_load(&s->hid);
    return s;
}

void cm_sampler_destroy(CMSampler *s) {
    if (!s) return;
    if (s->prev_ticks) {
        vm_deallocate(mach_task_self(), (vm_address_t)s->prev_ticks, s->prev_tick_count * sizeof(integer_t));
    }
    if (s->ior_prev_samples) CFRelease(s->ior_prev_samples);
    if (s->ior_sub) CFRelease(s->ior_sub);
    if (s->ior_subbed) CFRelease(s->ior_subbed);
    if (s->ior_channels) CFRelease(s->ior_channels);
    if (s->ior.handle) dlclose(s->ior.handle);
    free(s);
}

int cm_sampler_poll(CMSampler *s, CMSnapshot *out) {
    if (!s || !out) return -1;
    memset(out, 0, sizeof(*out));
    uint64_t now = mach_absolute_time();
    double dt = 0;
    if (s->have_prev_time) dt = mach_to_sec(now - s->prev_mach);
    s->prev_mach = now;
    s->have_prev_time = 1;
    out->elapsed_sec = dt;

    poll_cpu(s, &out->cpu);
    poll_memory(&out->memory);
    poll_chip(s, &out->chip, dt > 0 ? dt : 0.5);
    poll_temp(&s->hid, &out->temp);
    poll_battery(&out->battery);
    poll_disk(&out->disk);
    poll_net(s, &out->net);
    poll_procs(&out->procs);

    if (!s->drive_checked_mach || mach_to_sec(now - s->drive_checked_mach) > 30) {
        s->cached_drive_failing = walk_drive_failing();
        s->drive_checked_mach = now;
    }
    out->drive_failing = s->cached_drive_failing;
    out->uptime_sec = uptime_seconds();
    return 0;
}
