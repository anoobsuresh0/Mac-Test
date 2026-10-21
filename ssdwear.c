// Prints the internal SSD's NVMe health log as KEY=value lines (same IOKit path smartctl uses).
// Build: clang -O2 ssdwear.c -framework IOKit -framework CoreFoundation -o ssdwear
#include <stdio.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

int main(void) {
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"));
    if (!dev) { puts("ERROR=no NVMe drive found"); return 1; }

    IOCFPlugInInterface **plugin = NULL; SInt32 score;
    IONVMeSMARTInterface **smart = NULL;
    if (IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess
        || (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart) != S_OK) {
        puts("ERROR=drive does not expose SMART data"); return 1;
    }

    NVMeSMARTData d = {0};
    if ((*smart)->SMARTReadData(smart, &d) != kIOReturnSuccess) { puts("ERROR=SMART read failed"); return 1; }

    // NVMe "data units" are 1000 x 512 bytes
    printf("PERCENT_USED=%u\nSPARE=%u\nSPARE_THRESHOLD=%u\nCRITICAL_WARNING=%u\n",
           d.PERCENTAGE_USED, d.AVAILABLE_SPARE, d.AVAILABLE_SPARE_THRESHOLD, d.CRITICAL_WARNING);
    printf("TB_WRITTEN=%.1f\nTB_READ=%.1f\n", d.DATA_UNITS_WRITTEN[0] * 512000.0 / 1e12, d.DATA_UNITS_READ[0] * 512000.0 / 1e12);
    printf("POWER_ON_HOURS=%llu\nPOWER_CYCLES=%llu\nUNSAFE_SHUTDOWNS=%llu\nMEDIA_ERRORS=%llu\n",
           d.POWER_ON_HOURS[0], d.POWER_CYCLES[0], d.UNSAFE_SHUTDOWNS[0], d.MEDIA_ERRORS[0]);

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    IOObjectRelease(dev);
    return 0;
}
