// NVMe SSD SMART / Health 用户态直读（基于 macOS IOKit NVMeSMARTLib）。
// 亚毫秒级响应，无需 root 权限，无需外部 smartmontools 依赖。

#include "CMetrics.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

static double nvme_u128_to_double(const uint64_t v[2]) {
    return (double)v[0] + (double)v[1] * 18446744073709551616.0;
}

static void trim_ascii_copy(char *dst, size_t dst_cap, const uint8_t *src, size_t src_len) {
    if (dst_cap == 0) return;
    size_t len = src_len < (dst_cap - 1) ? src_len : (dst_cap - 1);
    while (len > 0 && (src[len - 1] == ' ' || src[len - 1] == '\0')) {
        len--;
    }
    size_t start = 0;
    while (start < len && src[start] == ' ') {
        start++;
    }
    size_t n = len - start;
    if (n > 0) memcpy(dst, src + start, n);
    dst[n] = '\0';
}

int cm_read_nvme_smart(CMNVMeSmart *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));

    CFMutableDictionaryRef propMatch = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!propMatch) return 0;
    CFDictionarySetValue(propMatch, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);

    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!matching) {
        CFRelease(propMatch);
        return 0;
    }
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), propMatch);
    CFRelease(propMatch);

    io_iterator_t iterator = IO_OBJECT_NULL;
    // IOServiceGetMatchingServices 接管 matching 的所有权，无论成败都无需再 CFRelease(matching)
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) return 0;

    int found = 0;
    io_service_t service = IO_OBJECT_NULL;
    while (!found && (service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOCFPlugInInterface **plugIn = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(
                service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugIn, &score) == KERN_SUCCESS &&
            plugIn != NULL) {
            IONVMeSMARTInterface **smart = NULL;
            HRESULT hr = (*plugIn)->QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
            if (hr == S_OK && smart != NULL) {
                NVMeSMARTData raw;
                memset(&raw, 0, sizeof(raw));
                if ((*smart)->SMARTReadData(smart, &raw) == kIOReturnSuccess) {
                    out->valid = 1;
                    out->critical_warning = raw.CRITICAL_WARNING;
                    out->temperature_celsius = (int)raw.TEMPERATURE - 273;
                    out->available_spare = (int)raw.AVAILABLE_SPARE;
                    out->available_spare_threshold = (int)raw.AVAILABLE_SPARE_THRESHOLD;
                    out->percentage_used = (int)raw.PERCENTAGE_USED;
                    // NVMe 规范：1 Data Unit = 1000 × 512 bytes = 512,000 bytes
                    out->bytes_read = nvme_u128_to_double(raw.DATA_UNITS_READ) * 512000.0;
                    out->bytes_written = nvme_u128_to_double(raw.DATA_UNITS_WRITTEN) * 512000.0;
                    out->power_cycles = raw.POWER_CYCLES[0];
                    out->power_on_hours = raw.POWER_ON_HOURS[0];
                    out->unsafe_shutdowns = raw.UNSAFE_SHUTDOWNS[0];
                    out->media_errors = raw.MEDIA_ERRORS[0];
                    out->error_log_entries = raw.NUM_ERROR_INFO_LOG_ENTRIES[0];

                    // 尝试读取控制器型号与固件版本（失败不影响 SMART 主数据）
                    NVMeIdentifyControllerStruct ctrl;
                    memset(&ctrl, 0, sizeof(ctrl));
                    if ((*smart)->GetIdentifyData(smart, &ctrl, 0) == kIOReturnSuccess) {
                        trim_ascii_copy(out->model, sizeof(out->model),
                                        ctrl.MODEL_NUMBER, kNVMeIdentifyControllerModelNumberLen);
                        trim_ascii_copy(out->firmware, sizeof(out->firmware),
                                        ctrl.FW_REVISION, kNVMeIdentifyControllerFirmwareRevisionLen);
                    }
                    found = 1;
                }
                (*smart)->Release(smart);
            }
            IODestroyPlugInInterface(plugIn);
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return found;
}
