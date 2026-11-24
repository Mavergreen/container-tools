/* container-tools-hotplug VMX --memory MB | --cpus N
 *
 * Asks VMware Fusion to hot-add memory or CPUs to the running VM whose .vmx is VMX, through Fusion's
 * own libvix. Its VixVM_HotPlugMemory and VixVM_HotPlugCPU are exported but undocumented (found in
 * Fusion 8.5.10, 2026-11-24); vmrun has no verb for them. Fusion applies the change by a hard
 * suspend-and-resume of a few seconds, and the guest must be able to take it (docker-machine-ctl
 * resize checks that, and checks the guest afterwards).
 *
 * libvix is loaded at run time, so this builds anywhere and fails clearly without Fusion.
 * MAVERICKS_DOCKER_LIBVIX overrides where it is looked for.
 *
 * Exit: 0 Fusion accepted the change; 2 usage; 3 libvix couldn't be loaded; 4 a VIX call failed.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int VixHandle;
typedef uint64_t VixError;
typedef void VixEventProc(VixHandle, int, VixHandle, void *);

#define VIX_API_VERSION (-1)
#define VIX_SERVICEPROVIDER_VMWARE_WORKSTATION 3
#define VIX_INVALID_HANDLE 0
#define VIX_PROPERTY_NONE 0
#define VIX_PROPERTY_JOB_RESULT_HANDLE 3010
#define DEFAULT_LIBVIX "/Applications/VMware Fusion.app/Contents/Frameworks/libvix.dylib"

static VixHandle (*pConnect)(int, int, const char *, int, const char *, const char *, int, VixHandle,
                             VixEventProc *, void *);
static VixHandle (*pOpen)(VixHandle, const char *, VixEventProc *, void *);
static VixHandle (*pHotPlugMemory)(VixHandle, uint32_t, VixEventProc *, void *);
static VixHandle (*pHotPlugCPU)(VixHandle, uint32_t, VixEventProc *, void *);
static VixError (*pWait)(VixHandle, int, ...);
static const char *(*pErrorText)(VixError, const char *);
static void (*pRelease)(VixHandle);
static void (*pDisconnect)(VixHandle);

static int usage(void) {
  fprintf(stderr, "usage: container-tools-hotplug VMX --memory MB | --cpus N\n");
  return 2;
}

static int failed(const char *what, VixError err) {
  const char *text = pErrorText ? pErrorText(err, NULL) : NULL;
  fprintf(stderr, "container-tools-hotplug: %s: %llu %s\n", what, (unsigned long long)(err & 0xFFFF),
          text ? text : "");
  return 4;
}

/* A positive decimal that fits in 32 bits, else 0. */
static uint32_t positive(const char *s) {
  char *end;
  unsigned long long v;
  if (!s || !*s || strspn(s, "0123456789") != strlen(s)) return 0;
  v = strtoull(s, &end, 10);
  return (*end == '\0' && v > 0 && v <= 0xFFFFFFFFull) ? (uint32_t)v : 0;
}

int main(int argc, char **argv) {
  const char *lib, *vmx;
  int memory;
  uint32_t value;
  void *h;
  VixHandle host = VIX_INVALID_HANDLE, vm = VIX_INVALID_HANDLE, job;
  VixError err;

  if (argc != 4) return usage();
  vmx = argv[1];
  if (strcmp(argv[2], "--memory") == 0) memory = 1;
  else if (strcmp(argv[2], "--cpus") == 0) memory = 0;
  else return usage();
  if ((value = positive(argv[3])) == 0) return usage();

  lib = getenv("MAVERICKS_DOCKER_LIBVIX");
  if (!lib || !*lib) lib = DEFAULT_LIBVIX;
  if (!(h = dlopen(lib, RTLD_NOW | RTLD_LOCAL))) {
    fprintf(stderr, "container-tools-hotplug: VMware Fusion's libvix not found at %s\n", lib);
    return 3;
  }
  pConnect = dlsym(h, "VixHost_Connect");
  pOpen = dlsym(h, "VixVM_Open");
  pHotPlugMemory = dlsym(h, "VixVM_HotPlugMemory");
  pHotPlugCPU = dlsym(h, "VixVM_HotPlugCPU");
  pWait = dlsym(h, "VixJob_Wait");
  pErrorText = dlsym(h, "Vix_GetErrorText");
  pRelease = dlsym(h, "Vix_ReleaseHandle");
  pDisconnect = dlsym(h, "VixHost_Disconnect");
  if (!pConnect || !pOpen || !pHotPlugMemory || !pHotPlugCPU || !pWait || !pErrorText || !pRelease ||
      !pDisconnect) {
    fprintf(stderr, "container-tools-hotplug: %s lacks the hot-add calls (not Fusion 8.5's libvix?)\n", lib);
    return 3;
  }

  job = pConnect(VIX_API_VERSION, VIX_SERVICEPROVIDER_VMWARE_WORKSTATION, NULL, 0, NULL, NULL, 0,
                 VIX_INVALID_HANDLE, NULL, NULL);
  err = pWait(job, VIX_PROPERTY_JOB_RESULT_HANDLE, &host, VIX_PROPERTY_NONE);
  pRelease(job);
  if (err) return failed("connect", err);

  job = pOpen(host, vmx, NULL, NULL);
  err = pWait(job, VIX_PROPERTY_JOB_RESULT_HANDLE, &vm, VIX_PROPERTY_NONE);
  pRelease(job);
  if (err) { pDisconnect(host); return failed("open", err); }

  job = memory ? pHotPlugMemory(vm, value, NULL, NULL) : pHotPlugCPU(vm, value, NULL, NULL);
  err = pWait(job, VIX_PROPERTY_NONE);
  pRelease(job);
  pRelease(vm);
  pDisconnect(host);
  return err ? failed("hotplug", err) : 0;
}
