/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2024-2024. All rights reserved.
 *
 * vxpu_meminfo_shim — unified memory virtualization + core rate limiting.
 *
 * Capabilities:
 *   1. ACL memory query interception (aclrtGetMemInfo + aclrtGetMemInfoImpl)
 *      — baseline-tracking quota virtualisation so each Pod sees its own
 *      memory slice.  Both the public API (libascendcl.so) and the internal
 *      implementation (libascendcl_impl.so) are intercepted; a thread-local
 *      counter prevents double quota application when the public wrapper
 *      forwards into the impl entry.
 *   2. Runtime memory query interception (rtMemGetInfo / rtMemGetInfoEx /
 *      rtMemGetInfoByType) — same quota logic on the CANN runtime layer.
 *   3. Kernel-launch rate limiting — shared-memory timeslice scheduler
 *      compatible with NpuTimesliceScheduler, so multiple Pods on the same
 *      physical NPU fairly share AI Core time.
 *
 * This single .so replaces both libmeminfo_shim.so (memory only) and
 * libruntime_preload.so (full hook suite).  It deliberately avoids linking
 * libdcmi / libruntime to prevent the ACL 500001 init conflict.
 *
 * Build:  cmake .. -DBUILD_PRELOAD=ON && cmake --build . --target meminfo_shim
 * Load:   LD_PRELOAD=/opt/xpu/lib/libmeminfo_shim.so
 * Config: env VXPU_MEM_LIMIT_MIB=<MiB>  VXPU_CORE_LIMIT_PERCENT=<0-100>
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <acl/acl.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <fcntl.h>
#include <mutex>
#include <sstream>
#include <strings.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

// DCMI is loaded dynamically (dlopen) to avoid hard-linking libdcmi.so.
// The header is used only for struct layout and function signatures.
#include <dcmi_interface_api.h>

/* ================================================================
 * Runtime type forward-declarations.
 * We avoid #include <runtime/rt.h> to keep this truly self-contained.
 * All types below are ABI-compatible with CANN's definitions.
 * ================================================================ */
#ifndef VXPU_SHIM_RT_TYPES
#define VXPU_SHIM_RT_TYPES
extern "C" {
typedef void *rtStream_t;
typedef void *rtContext_t;
typedef void *rtModel_t;
typedef void *rtFuncHandle;
typedef void *rtLaunchArgsHandle;
typedef int32_t rtMemInfoType_t;
typedef int32_t rtCmoOpCode_t;
typedef int32_t rtMemType_t;
typedef char char_t;
struct rtSmDesc_t;
struct rtArgsEx_t;
struct rtTaskCfgInfo_t;
struct rtFftsPlusTaskInfo_t;
struct rtFftsTaskInfo_t;
struct rtBarrierTaskInfo_t;
struct rtCmoTaskInfo_t;
struct rtKernelLaunchNames_t;
struct rtAicpuArgsEx_t;
struct rtMemInfo_t;
}
#endif

static constexpr uint32_t kRtOk = 0;
static constexpr uint32_t kRtStreamCaptured = 107027;

/* ================================================================
 *  SECTION 1 — Memory-quota virtualisation (ACL + runtime layers)
 * ================================================================ */

/* ---------- 1.0 Optional DCMI-backed "own used memory" sampling ---------- */

static constexpr const char *kPidsConfigPath = "/etc/xpu/pids.config";
static constexpr uint64_t kDcmiMaxStalenessMs = 1500;
static constexpr uint64_t kDcmiSamplePeriodMs = 300;

static std::atomic<bool>   g_dcmiEnabled{true};
static std::atomic<bool>   g_dcmiReady{false};
static std::atomic<size_t> g_dcmiOwnUsedBytes{0};
static std::atomic<uint64_t> g_dcmiLastUpdateMs{0};

static uint64_t NowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

static bool EnvTruthy(const char *name, bool defaultVal)
{
    const char *v = getenv(name);
    if (!v || !v[0]) return defaultVal;
    if (strcmp(v, "0") == 0 || strcasecmp(v, "false") == 0 || strcasecmp(v, "off") == 0) return false;
    if (strcmp(v, "1") == 0 || strcasecmp(v, "true") == 0 || strcasecmp(v, "on") == 0) return true;
    return defaultVal;
}

static bool TryReadPidsConfig(std::vector<int> &hostPids)
{
    hostPids.clear();
    std::ifstream file(kPidsConfigPath);
    if (!file.is_open()) {
        return false;
    }
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty()) continue;
        std::istringstream iss(line);
        long hostPid = -1;
        if (!(iss >> hostPid)) continue;
        if (hostPid > 0 && hostPid < INT32_MAX) {
            hostPids.push_back(static_cast<int>(hostPid));
        }
    }
    return true;
}

static bool HostPidAllowed(int hostPid, const std::vector<int> &hostPids)
{
    if (hostPids.empty()) return true; // no filter file → count all processes (non-privileged container)
    for (int p : hostPids) {
        if (p == hostPid) return true;
    }
    return false;
}

// Resolve a CANN runtime symbol via RTLD_NEXT (no link-time dependency).
template <typename T>
static T ResolveRtNext(const char *sym)
{
    return reinterpret_cast<T>(dlsym(RTLD_NEXT, sym));
}

struct DcmiApi {
    void *handle = nullptr;
    int (*init)() = nullptr;
    int (*shutdown)() = nullptr;
    int (*get_card_dev_from_logic)(int *cardId, int *deviceId, int logicId) = nullptr;
    int (*get_dev_res)(uint32_t cardId, uint32_t deviceId, dcmi_proc_mem_info *info, int *procNum) = nullptr;
};

static bool LoadDcmi(DcmiApi &api)
{
    // Candidate names/paths observed in deployments. We keep this permissive.
    const char *cands[] = {
        "libdcmi.so",
        "libdcmi_interface.so",
        "/usr/local/dcmi/lib64/libdcmi.so",
        "/usr/local/dcmi/lib/libdcmi.so",
        "/usr/local/Ascend/driver/lib64/common/libdcmi.so",
        nullptr,
    };
    for (int i = 0; cands[i] != nullptr; ++i) {
        api.handle = dlopen(cands[i], RTLD_NOW | RTLD_LOCAL);
        if (api.handle) break;
    }
    if (!api.handle) return false;

    api.init = reinterpret_cast<int (*)()>(dlsym(api.handle, "dcmi_init"));
    api.shutdown = reinterpret_cast<int (*)()>(dlsym(api.handle, "dcmi_shut_down"));
    if (!api.shutdown) {
        api.shutdown = reinterpret_cast<int (*)()>(dlsym(api.handle, "dcmi_shutdown"));
    }
    api.get_card_dev_from_logic =
        reinterpret_cast<int (*)(int *, int *, int)>(dlsym(api.handle, "dcmi_get_card_id_device_id_from_logicid"));
    api.get_dev_res =
        reinterpret_cast<int (*)(uint32_t, uint32_t, dcmi_proc_mem_info *, int *)>(dlsym(api.handle, "dcmi_get_device_resource_info"));

    if (!api.init || !api.get_card_dev_from_logic || !api.get_dev_res) {
        return false;
    }
    return true;
}

static bool ReadLogicDeviceId(int &logicId)
{
    // Prefer rtGetDevice if available; fallback to ASCEND_VISIBLE_DEVICES if provided.
    using RtGetDeviceFn = uint32_t (*)(int32_t *);
    static RtGetDeviceFn rtGetDeviceFn = ResolveRtNext<RtGetDeviceFn>("rtGetDevice");
    if (rtGetDeviceFn) {
        int32_t dev = 0;
        uint32_t ret = rtGetDeviceFn(&dev);
        if (ret == kRtOk || ret == kRtStreamCaptured) {
            logicId = static_cast<int>(dev);
            return true;
        }
    }
    const char *vis = getenv("ASCEND_VISIBLE_DEVICES");
    if (vis && vis[0]) {
        // If list, take the first entry.
        logicId = atoi(vis);
        return true;
    }
    logicId = 0;
    return true;
}

static void DcmiSamplerThread()
{
    DcmiApi api{};
    if (!LoadDcmi(api)) {
        g_dcmiReady.store(false);
        return;
    }
    int initRet = api.init();
    if (initRet != 0) {
        g_dcmiReady.store(false);
        return;
    }
    g_dcmiReady.store(true);

    std::vector<int> hostPids;
    // Always try load filter file; if absent, we will count all procs.
    (void)TryReadPidsConfig(hostPids);

    while (g_dcmiEnabled.load()) {
        // Refresh PID filter periodically (cheap).
        (void)TryReadPidsConfig(hostPids);

        int logicId = 0;
        (void)ReadLogicDeviceId(logicId);
        int cardId = 0, deviceId = 0;
        if (api.get_card_dev_from_logic(&cardId, &deviceId, logicId) != 0) {
            // Keep last good values; don't flip to baseline immediately.
            std::this_thread::sleep_for(std::chrono::milliseconds(kDcmiSamplePeriodMs));
            continue;
        }

        // Query process memory usage for this device.
        std::vector<dcmi_proc_mem_info> procInfo;
        procInfo.resize(1024);
        int procNum = static_cast<int>(procInfo.size());
        int ret = api.get_dev_res(static_cast<uint32_t>(cardId),
                                  static_cast<uint32_t>(deviceId),
                                  procInfo.data(),
                                  &procNum);
        if (ret == 0 && procNum > 0 && procNum <= static_cast<int>(procInfo.size())) {
            size_t sum = 0;
            for (int i = 0; i < procNum; ++i) {
                const int hostPid = procInfo[i].proc_id;
                if (!HostPidAllowed(hostPid, hostPids)) continue;
                sum += static_cast<size_t>(procInfo[i].proc_mem_usage);
            }
            g_dcmiOwnUsedBytes.store(sum);
            g_dcmiLastUpdateMs.store(NowMs());
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(kDcmiSamplePeriodMs));
    }

    if (api.shutdown) (void)api.shutdown();
}

static bool GetOwnUsedBytesDcmi(size_t &ownUsedBytes)
{
    if (!g_dcmiEnabled.load() || !g_dcmiReady.load()) return false;
    const uint64_t now = NowMs();
    const uint64_t ts = g_dcmiLastUpdateMs.load();
    if (ts == 0 || now < ts) return false;
    if (now - ts > kDcmiMaxStalenessMs) return false;
    ownUsedBytes = g_dcmiOwnUsedBytes.load();
    return true;
}

static bool ReadVxpuMemoryQuotaBytes(size_t &quotaBytes)
{
    const char *envMib = getenv("VXPU_MEM_LIMIT_MIB");
    if (envMib != nullptr && envMib[0] != '\0') {
        errno = 0;
        char *end = nullptr;
        unsigned long long mib = strtoull(envMib, &end, 10);
        if (errno == 0 && end != envMib && mib > 0) {
            quotaBytes = static_cast<size_t>(mib) * 1024ULL * 1024ULL;
            return true;
        }
    }

    const char *path = "/etc/xpu/vnpu.config";
    FILE *fp = fopen(path, "r");
    if (!fp) {
        return false;
    }
    char buf[4096];
    bool limitMemory = false;
    size_t memBytes = 0;
    while (fgets(buf, sizeof(buf), fp)) {
        const char *vx = strstr(buf, "VXPU_MEM_LIMIT_MIB=");
        if (vx != nullptr) {
            vx += strlen("VXPU_MEM_LIMIT_MIB=");
            errno = 0;
            char *end = nullptr;
            unsigned long long mib = strtoull(vx, &end, 10);
            if (errno == 0 && end != vx && mib > 0) {
                fclose(fp);
                quotaBytes = static_cast<size_t>(mib) * 1024ULL * 1024ULL;
                return true;
            }
        }

        if (strstr(buf, "limitMemory") != nullptr && strstr(buf, "true") != nullptr) {
            limitMemory = true;
        }
        const char *p = strstr(buf, "memory:");
        if (p != nullptr) {
            p += strlen("memory:");
            errno = 0;
            char *end = nullptr;
            unsigned long long v = strtoull(p, &end, 10);
            if (errno == 0 && end != p && v > 0) {
                memBytes = static_cast<size_t>(v);
            }
        }
    }
    fclose(fp);
    if (!limitMemory || memBytes == 0) {
        return false;
    }
    quotaBytes = memBytes;
    return true;
}

struct QuotaBaseline {
    size_t used;
    bool   set;
};

static QuotaBaseline g_baselineAcl    = {0, false};   // aclrtGetMemInfoImpl
static QuotaBaseline g_baselineAclPub = {0, false};   // aclrtGetMemInfo (public)
static QuotaBaseline g_baselineRt     = {0, false};
static QuotaBaseline g_baselineRtEx   = {0, false};

/*
 * Thread-local counter incremented every time aclrtGetMemInfoImpl runs to
 * completion (after ApplyQuota).  The aclrtGetMemInfo hook samples this
 * counter before/after invoking the original public API.  If the counter
 * advanced, the impl hook already rewrote the (free,total) pair for this
 * call, so the public hook must NOT apply the quota a second time.  On
 * CANN versions where the public API does not forward into Impl
 * (observed on CANN 25.5 with vLLM-Ascend / torch_npu mem_get_info), the
 * counter stays unchanged and the public hook performs ApplyQuota itself.
 */
static thread_local uint64_t tls_aclImplInvocations = 0;

static void ApplyQuota(size_t *free, size_t *total, QuotaBaseline &bl)
{
    size_t quota = 0;
    if (!ReadVxpuMemoryQuotaBytes(quota) || quota == 0) {
        return;
    }

    size_t ownUsed = 0;
    const bool dcmiOk = GetOwnUsedBytesDcmi(ownUsed);
    if (!dcmiOk) {
        const size_t physTotal = (total != nullptr) ? *total : 0;
        const size_t physFree  = (free  != nullptr) ? *free  : 0;
        const size_t physUsed  = (physTotal > physFree) ? (physTotal - physFree) : 0;

        if (!bl.set && physTotal > 0) {
            bl.used = physUsed;
            bl.set  = true;
        }

        ownUsed = (physUsed > bl.used) ? (physUsed - bl.used) : 0;
    }

    if (total != nullptr) {
        *total = quota;
    }
    if (free != nullptr) {
        *free = (ownUsed < quota) ? (quota - ownUsed) : 0;
    }
}

static void LogMemCall(const char *symName, int attr, int ret, size_t *free, size_t *total)
{
    static int logc = 0;
    const int n = __sync_fetch_and_add(&logc, 1);
    if (n >= 120) {
        return;
    }
    size_t qtmp = 0;
    const bool qok = ReadVxpuMemoryQuotaBytes(qtmp);
    fprintf(stderr,
            "[vxpu_meminfo_shim] %s attr=%d ret=%d free=%zu total=%zu"
            " quota_ok=%d quota=%zu pid=%d\n",
            symName, attr, ret,
            (free != nullptr) ? *free : 0UL,
            (total != nullptr) ? *total : 0UL,
            static_cast<int>(qok), qtmp, static_cast<int>(getpid()));
    fflush(stderr);
}

/* --- ACL layer hook: aclrtGetMemInfoImpl (libascendcl_impl.so) --- */

using AclMemInfoFn = aclError (*)(aclrtMemAttr, size_t *, size_t *);

static AclMemInfoFn ResolveAclMemInfo(const char *dso, const char *sym)
{
    void *handle = dlopen(dso, RTLD_NOW | RTLD_LOCAL);
    AclMemInfoFn fn = nullptr;
    if (handle != nullptr) {
        fn = reinterpret_cast<AclMemInfoFn>(dlsym(handle, sym));
    }
    if (fn == nullptr) {
        fn = reinterpret_cast<AclMemInfoFn>(dlsym(RTLD_NEXT, sym));
    }
    return fn;
}

extern "C" __attribute__((visibility("default")))
aclError aclrtGetMemInfoImpl(aclrtMemAttr attr, size_t *free, size_t *total)
{
    static AclMemInfoFn orig = nullptr;
    if (!orig) {
        orig = ResolveAclMemInfo("libascendcl_impl.so", "aclrtGetMemInfoImpl");
    }
    if (!orig) {
        return ACL_ERROR_FAILURE;
    }
    aclError ret = orig(attr, free, total);
    if (ret != ACL_SUCCESS) {
        return ret;
    }
    size_t rawFree = free ? *free : 0;
    size_t rawTotal = total ? *total : 0;
    ApplyQuota(free, total, g_baselineAcl);
    ++tls_aclImplInvocations;   // signal to public hook that quota was applied
    static int rawLogC = 0;
    if (__sync_fetch_and_add(&rawLogC, 1) < 30) {
        fprintf(stderr,
                "[vxpu_meminfo_shim] aclrtGetMemInfoImpl attr=%d ret=%d"
                " raw_free=%zu raw_total=%zu -> free=%zu total=%zu pid=%d\n",
                (int)attr, (int)ret, rawFree, rawTotal,
                free ? *free : 0UL, total ? *total : 0UL,
                (int)getpid());
        fflush(stderr);
    }
    return ret;
}

/* --- ACL public-API hook: aclrtGetMemInfo (libascendcl.so) ---
 *
 * Some CANN releases (e.g. 25.5) implement aclrtGetMemInfo without forwarding
 * into aclrtGetMemInfoImpl, so the impl-only hook above cannot see those
 * queries — vLLM/torch_npu mem_get_info() then receives the raw card total
 * and over-allocates KV-cache up to 0.9 * 64 GiB instead of the configured
 * 16 GiB quota.  Hooking the public symbol closes that gap.
 */
extern "C" __attribute__((visibility("default")))
aclError aclrtGetMemInfo(aclrtMemAttr attr, size_t *free, size_t *total)
{
    static AclMemInfoFn orig = nullptr;
    if (!orig) {
        // Public API lives in libascendcl.so; fall back to RTLD_NEXT for
        // hosts where the loader resolves it differently (e.g. libascendcl
        // not directly linked).
        orig = ResolveAclMemInfo("libascendcl.so", "aclrtGetMemInfo");
    }
    if (!orig) {
        return ACL_ERROR_FAILURE;
    }

    const uint64_t before = tls_aclImplInvocations;
    aclError ret = orig(attr, free, total);
    if (ret != ACL_SUCCESS) {
        return ret;
    }
    const uint64_t after = tls_aclImplInvocations;

    size_t rawFree  = free  ? *free  : 0;
    size_t rawTotal = total ? *total : 0;

    bool applied = false;
    if (after == before) {
        // Public API did NOT forward into Impl on this CANN build, so we
        // must apply the quota ourselves.
        ApplyQuota(free, total, g_baselineAclPub);
        applied = true;
    }
    static int pubLogC = 0;
    if (__sync_fetch_and_add(&pubLogC, 1) < 30) {
        fprintf(stderr,
                "[vxpu_meminfo_shim] aclrtGetMemInfo attr=%d ret=%d"
                " raw_free=%zu raw_total=%zu -> free=%zu total=%zu"
                " applied=%d via=%s pid=%d\n",
                (int)attr, (int)ret, rawFree, rawTotal,
                free ? *free : 0UL, total ? *total : 0UL,
                applied ? 1 : 0, applied ? "public" : "impl",
                (int)getpid());
        fflush(stderr);
    }
    return ret;
}

/* --- Runtime layer hooks: rtMemGetInfo / rtMemGetInfoEx / rtMemGetInfoByType --- */

using RtMemGetInfoFn    = uint32_t (*)(size_t *, size_t *);
using RtMemGetInfoExFn  = uint32_t (*)(rtMemInfoType_t, size_t *, size_t *);
using RtMemGetInfoByTypeFn = uint32_t (*)(int32_t, rtMemType_t, rtMemInfo_t *);

extern "C" __attribute__((visibility("default")))
uint32_t rtMemGetInfo(size_t *freeSize, size_t *totalSize)
{
    static RtMemGetInfoFn orig = (RtMemGetInfoFn)dlsym(RTLD_NEXT, "rtMemGetInfo");
    if (!orig) return kRtOk;
    uint32_t ret = orig(freeSize, totalSize);
    if (ret == kRtOk) {
        ApplyQuota(freeSize, totalSize, g_baselineRt);
    }
    return ret;
}

extern "C" __attribute__((visibility("default")))
uint32_t rtMemGetInfoEx(rtMemInfoType_t type, size_t *freeSize, size_t *totalSize)
{
    static RtMemGetInfoExFn orig = (RtMemGetInfoExFn)dlsym(RTLD_NEXT, "rtMemGetInfoEx");
    if (!orig) return kRtOk;
    uint32_t ret = orig(type, freeSize, totalSize);
    if (ret == kRtOk) {
        ApplyQuota(freeSize, totalSize, g_baselineRtEx);
    }
    return ret;
}

/* ================================================================
 *  SECTION 2 — Core rate limiter (timeslice scheduler)
 * ================================================================ */

/* ---------- 2.1  Lightweight in-process semaphore ---------- */
class LiteSem {
public:
    explicit LiteSem(int c = 0) : count_(c) {}
    void Release(int n = 1) {
        std::unique_lock<std::mutex> lk(mu_);
        count_ += n;
        cv_.notify_all();
    }
    void Acquire(int n = 1) {
        std::unique_lock<std::mutex> lk(mu_);
        cv_.wait(lk, [&] { return count_ >= n; });
        count_ -= n;
    }
    int AcquireAll() {
        std::unique_lock<std::mutex> lk(mu_);
        int c = count_;
        count_ = 0;
        return c;
    }
    bool IsZero() {
        std::unique_lock<std::mutex> lk(mu_);
        return count_ == 0;
    }
private:
    std::mutex mu_;
    std::condition_variable cv_;
    int count_;
};

/* ---------- 2.2  Shared-memory context (binary-compatible with NpuTimesliceScheduler) ---------- */
using TsClock = std::chrono::steady_clock;
using AtomicTimePoint = std::atomic<TsClock::time_point>;

static constexpr int    TS_PERIOD_UNITS  = 100;
static constexpr int    TS_MIN_POWER     = 5;
static constexpr int    TS_MAX_NODES     = TS_PERIOD_UNITS / TS_MIN_POWER;  // 20
static constexpr auto   TS_TIME_UNIT     = std::chrono::milliseconds(1);
static constexpr auto   TS_PERIOD_TIMEOUT = TS_TIME_UNIT * TS_PERIOD_UNITS; // 100ms
static constexpr auto   TS_ERR_TIMEOUT    = std::chrono::seconds(1);
static constexpr uint32_t TS_MAGIC_INIT  = ('i' << 24) | ('n' << 16) | ('i' << 8) | 't';
static constexpr uint32_t TS_MAGIC_READY = ('v' << 24) | ('N' << 16) | ('P' << 8) | 'U';

struct TsNode {
    AtomicTimePoint periodCheck;
};

struct TsContext {
    std::atomic<uint32_t> magicNumber;
    TsClock::duration     timeUnit;
    unsigned int          usedUnits;
    std::atomic<int>      current;
    TsNode                nodes[TS_MAX_NODES];
};

static_assert(sizeof(TsContext) <= 4096, "TsContext must fit in one page");

/* ---------- 2.3  Stream-sync removed ---------- */
/*
 * The original NpuTimesliceScheduler synchronised every stream at the end
 * of each time-slice (StreamCache::Clear) to guarantee no NPU work bleeds
 * into the next pod's slot.  However, calling rtStreamSynchronize from the
 * background scheduler thread while vLLM's Worker is performing ACL graph
 * replay causes a fatal runtime conflict (Worker proc dies unexpectedly).
 *
 * Approach: rely on the NPU hardware scheduler to interleave work from
 * concurrent pods.  The semaphore-based token budget still limits the
 * *rate* at which kernels are submitted, providing effective fairness
 * without the dangerous cross-thread stream synchronisation.
 */

using RtCtxGetCurrentFn   = uint32_t (*)(rtContext_t *);

/* ---------- 2.4  Core limiter global state ---------- */

// g_coreConfigured: set in constructor if VXPU_CORE_LIMIT_PERCENT is valid.
// g_coreEnabled:    set to true only after lazy-init on first kernel launch.
// This ensures only processes that actually invoke NPU kernels (the Worker)
// participate in timeslice scheduling.  Other vLLM sub-processes (APIServer,
// EngineCore) load the shim but never launch kernels, so they stay dormant.

static bool          g_coreConfigured = false;
static bool          g_coreEnabled    = false;
static unsigned int  g_corePercent    = 0;
static size_t        g_batchSize      = 10;
static char          g_dieId[256]     = {};
static int           g_hintIdx        = 0;

static LiteSem       g_fwdSem{0};   // scheduler→hooks  (budget tokens)
static LiteSem       g_bckSem{0};   // hooks→scheduler   (completion acks)

static int           g_shmFd    = -1;
static void         *g_shmAddr  = nullptr;
static TsContext    *g_ctx      = nullptr;
static int           g_myIdx    = -1;
static bool          g_schedEnd = false;
static std::thread   g_schedThread;
static std::once_flag g_lazyInitFlag;

/* ---------- 2.5  Shared-memory init ---------- */

static bool ReadCoreConfig(unsigned int &percent)
{
    const char *env = getenv("VXPU_CORE_LIMIT_PERCENT");
    if (env && env[0]) {
        int v = atoi(env);
        if (v > 0 && v < 100) { percent = static_cast<unsigned int>(v); return true; }
    }
    // Fallback: /etc/xpu/vnpu.config
    FILE *fp = fopen("/etc/xpu/vnpu.config", "r");
    if (!fp) return false;
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        const char *p = strstr(line, "VXPU_CORE_LIMIT_PERCENT=");
        if (p) {
            int v = atoi(p + strlen("VXPU_CORE_LIMIT_PERCENT="));
            if (v > 0 && v < 100) { percent = static_cast<unsigned int>(v); fclose(fp); return true; }
        }
    }
    fclose(fp);
    return false;
}

static bool ReadDieIdAndIdx(char *dieId, size_t dieIdSize, int &idx)
{
    FILE *fp = fopen("/etc/xpu/vnpu-ids.config", "r");
    if (fp) {
        char buf[256];
        buf[0] = '\0';
        if (fgets(buf, sizeof(buf), fp)) {
            fclose(fp);
            // Strip trailing newline
            size_t len = strlen(buf);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = '\0';
            // Find last '-'
            char *dash = strrchr(buf, '-');
            if (dash) {
                *dash = '\0';
                snprintf(dieId, dieIdSize, "%s", buf);
                idx = atoi(dash + 1);
                return true;
            }
            snprintf(dieId, dieIdSize, "%s", buf);
            idx = 0;
            return true;
        }
        fclose(fp);
    }
    const char *vis = getenv("ASCEND_VISIBLE_DEVICES");
    if (vis && vis[0]) {
        snprintf(dieId, dieIdSize, "%s", vis);
        idx = 0;
        return true;
    }
    return false;
}

static int ClaimSlot(TsContext *ctx, int hintIdx)
{
    auto now = TsClock::now();
    // Try hint first
    if (hintIdx >= 0 && hintIdx < TS_MAX_NODES) {
        auto ts = ctx->nodes[hintIdx].periodCheck.load();
        if (ts == TsClock::time_point{} || (now - ts) > TS_ERR_TIMEOUT) {
            ctx->nodes[hintIdx].periodCheck.store(now);
            return hintIdx;
        }
    }
    // Scan for a free slot
    for (int i = 0; i < TS_MAX_NODES; ++i) {
        auto ts = ctx->nodes[i].periodCheck.load();
        if (ts == TsClock::time_point{} || (now - ts) > TS_ERR_TIMEOUT) {
            ctx->nodes[i].periodCheck.store(now);
            return i;
        }
    }
    return 0;  // fallback: share slot 0
}

static bool InitSharedMemory(const char *dieId, int hintIdx)
{
    char shmName[300];
    snprintf(shmName, sizeof(shmName), "/%s", dieId);
    g_shmFd = shm_open(shmName, O_CREAT | O_RDWR, S_IWUSR | S_IRUSR);
    if (g_shmFd < 0) {
        fprintf(stderr, "[vxpu_shim] shm_open(%s) failed: %s\n", shmName, strerror(errno));
        return false;
    }
    if (ftruncate(g_shmFd, sizeof(TsContext)) != 0) {
        fprintf(stderr, "[vxpu_shim] ftruncate failed: %s\n", strerror(errno));
        return false;
    }
    g_shmAddr = mmap(nullptr, sizeof(TsContext), PROT_READ | PROT_WRITE, MAP_SHARED, g_shmFd, 0);
    if (g_shmAddr == MAP_FAILED) {
        g_shmAddr = nullptr;
        fprintf(stderr, "[vxpu_shim] mmap failed: %s\n", strerror(errno));
        return false;
    }
    g_ctx = reinterpret_cast<TsContext *>(g_shmAddr);

    // Init shared context (CAS protocol, same as NpuTimesliceScheduler)
    auto begin = TsClock::now();
    while (true) {
        uint32_t state = g_ctx->magicNumber.load();
        if (state == TS_MAGIC_READY) break;
        if (state == TS_MAGIC_INIT) {
            if (TsClock::now() - begin > TS_ERR_TIMEOUT) {
                g_ctx->magicNumber.compare_exchange_strong(state, 0u);
                begin = TsClock::now();
            }
            std::this_thread::yield();
            continue;
        }
        if (!g_ctx->magicNumber.compare_exchange_strong(state, TS_MAGIC_INIT)) continue;
        g_ctx->timeUnit = TS_TIME_UNIT;
        g_ctx->current = 0;
        for (int i = 0; i < TS_MAX_NODES; ++i)
            g_ctx->nodes[i].periodCheck.store(TsClock::time_point{});
        g_ctx->magicNumber.store(TS_MAGIC_READY);
        break;
    }

    g_myIdx = ClaimSlot(g_ctx, hintIdx);
    fprintf(stderr, "[vxpu_shim] core limiter: shm=%s idx=%d quota=%u%% batch=%zu pid=%d\n",
            shmName, g_myIdx, g_corePercent, g_batchSize, (int)getpid());
    return true;
}

/* ---------- 2.6  Timeslice scheduler thread ---------- */

static TsClock::time_point TsUpdateTimestamp()
{
    auto now = TsClock::now();
    g_ctx->nodes[g_myIdx].periodCheck.store(now);
    return now;
}

static void TsSelectNewCurrent()
{
    int cur = g_ctx->current.load();
    auto curTs = g_ctx->nodes[cur].periodCheck.load();
    auto now   = g_ctx->nodes[g_myIdx].periodCheck.load();
    if (now - curTs <= TS_ERR_TIMEOUT) return;

    int best = g_myIdx;
    auto bestTs = now;
    for (int i = 0; i < TS_MAX_NODES; ++i) {
        auto ts = g_ctx->nodes[i].periodCheck.load();
        if (now - ts > TS_ERR_TIMEOUT) continue;
        if (bestTs < ts) continue;
        best = i;
        bestTs = ts;
    }
    g_ctx->current.compare_exchange_strong(cur, best);
}

static bool TsCheckCurrent()
{
    if (g_ctx->current.load() == g_myIdx) return true;
    TsSelectNewCurrent();
    return false;
}

static void TsReleaseCurrent()
{
    auto now = g_ctx->nodes[g_myIdx].periodCheck.load();
    int cur = g_myIdx;
    for (int i = 1; i < TS_MAX_NODES; ++i) {
        int next = (cur + i) % TS_MAX_NODES;
        auto ts = g_ctx->nodes[next].periodCheck.load();
        if (now - ts > TS_PERIOD_TIMEOUT) continue;
        if (g_ctx->current.compare_exchange_strong(cur, next)) return;
    }
}

static TsClock::time_point TsExecuteSlice(TsClock::time_point begin, TsClock::duration sliceDur)
{
    TsClock::time_point end = begin;
    bool budgetAdded = false;
    while (true) {
        if (!budgetAdded) {
            g_fwdSem.Release(static_cast<int>(g_batchSize));
            budgetAdded = true;
        }
        std::this_thread::yield();
        if (g_fwdSem.IsZero()) {
            // All tokens consumed — wait for completions, then replenish
            int remaining = g_fwdSem.AcquireAll();
            int used = static_cast<int>(g_batchSize) - remaining;
            if (used > 0) g_bckSem.Acquire(used);
            budgetAdded = false;
        }
        end = TsUpdateTimestamp();
        if (end - begin >= sliceDur) break;
    }
    if (budgetAdded) {
        // Drain remaining budget before yielding to next pod
        int remaining = g_fwdSem.AcquireAll();
        int used = static_cast<int>(g_batchSize) - remaining;
        if (used > 0) g_bckSem.Acquire(used);
    }
    return TsUpdateTimestamp();
}

static void TsExecuteIdleTime(unsigned int quotaPct, unsigned int &lastUsed, bool &lastValid)
{
    g_ctx->usedUnits += quotaPct;
    if (!lastValid) {
        lastUsed = g_ctx->usedUnits;
        lastValid = true;
        return;
    }
    unsigned int periodUsed = g_ctx->usedUnits - lastUsed;
    if (periodUsed == 0 || periodUsed > TS_PERIOD_UNITS) return;
    unsigned int periodIdle = TS_PERIOD_UNITS - periodUsed;
    auto idleTime = TS_TIME_UNIT * periodIdle * quotaPct / periodUsed;
    std::this_thread::sleep_for(idleTime);
    lastUsed = g_ctx->usedUnits;
}

static void SchedulerThreadMain()
{
    while (!g_ctx) {
        std::this_thread::yield();
        if (g_schedEnd) return;
    }
    TsClock::duration quota = TS_TIME_UNIT * g_corePercent;
    TsClock::duration currentSlice = quota;
    unsigned int lastUsed = 0;
    bool lastValid = false;

    while (!g_schedEnd) {
        auto begin = TsUpdateTimestamp();
        if (!TsCheckCurrent()) {
            std::this_thread::yield();
            continue;
        }
        auto end = TsExecuteSlice(begin, currentSlice);
        TsClock::duration overdraft = (end - begin) - currentSlice;
        currentSlice = quota - overdraft;
        TsExecuteIdleTime(g_corePercent, lastUsed, lastValid);
        TsReleaseCurrent();
    }
    // Mark slot as dead on exit
    g_ctx->nodes[g_myIdx].periodCheck.store(TsClock::time_point{});
}

/* ---------- 2.7  CoreGuard — RAII for kernel-launch hooks ---------- */

static void LazyInitCoreLimiter()
{
    if (!g_coreConfigured) return;

    if (!InitSharedMemory(g_dieId, g_hintIdx)) {
        fprintf(stderr, "[vxpu_shim] shm init failed in lazy-init; core limiting disabled pid=%d\n",
                (int)getpid());
        fflush(stderr);
        return;
    }

    g_coreEnabled = true;
    g_schedEnd    = false;
    g_schedThread = std::thread(SchedulerThreadMain);
    g_schedThread.detach();

    fprintf(stderr, "[vxpu_shim] core limiter lazy-activated pid=%d\n", (int)getpid());
    fflush(stderr);
}

struct CoreGuard {
    CoreGuard(rtStream_t /*stm*/) {
        if (!g_coreConfigured) return;
        // Lazy init: only the process that actually launches kernels joins scheduling
        std::call_once(g_lazyInitFlag, LazyInitCoreLimiter);
        if (!g_coreEnabled) return;
        g_fwdSem.Acquire(1);
    }
    ~CoreGuard() {
        if (!g_coreEnabled) return;
        g_bckSem.Release(1);
    }
    CoreGuard(const CoreGuard &) = delete;
    CoreGuard &operator=(const CoreGuard &) = delete;
};

/* ================================================================
 *  SECTION 3 — Kernel-launch hooks
 * ================================================================ */

#define KL_RESOLVE(name) \
    static auto orig = reinterpret_cast<decltype(&name)>(dlsym(RTLD_NEXT, #name)); \
    if (!orig) return kRtOk;

extern "C" {

__attribute__((visibility("default")))
uint32_t rtKernelLaunch(const void *stubFunc, uint32_t blockDim, void *args,
                        uint32_t argsSize, rtSmDesc_t *smDesc, rtStream_t stm)
{
    KL_RESOLVE(rtKernelLaunch);
    CoreGuard _g(stm);
    return orig(stubFunc, blockDim, args, argsSize, smDesc, stm);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchWithHandle(void *hdl, const uint64_t tilingKey, uint32_t blockDim,
                                  rtArgsEx_t *argsInfo, rtSmDesc_t *smDesc, rtStream_t stm,
                                  const void *kernelInfo)
{
    KL_RESOLVE(rtKernelLaunchWithHandle);
    CoreGuard _g(stm);
    return orig(hdl, tilingKey, blockDim, argsInfo, smDesc, stm, kernelInfo);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchWithHandleV2(void *hdl, const uint64_t tilingKey, uint32_t blockDim,
                                    rtArgsEx_t *argsInfo, rtSmDesc_t *smDesc, rtStream_t stm,
                                    const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtKernelLaunchWithHandleV2);
    CoreGuard _g(stm);
    return orig(hdl, tilingKey, blockDim, argsInfo, smDesc, stm, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchWithFlag(const void *stubFunc, uint32_t blockDim, rtArgsEx_t *argsInfo,
                                rtSmDesc_t *smDesc, rtStream_t stm, uint32_t flags)
{
    KL_RESOLVE(rtKernelLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(stubFunc, blockDim, argsInfo, smDesc, stm, flags);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchWithFlagV2(const void *stubFunc, uint32_t blockDim, rtArgsEx_t *argsInfo,
                                  rtSmDesc_t *smDesc, rtStream_t stm, uint32_t flags,
                                  const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtKernelLaunchWithFlagV2);
    CoreGuard _g(stm);
    return orig(stubFunc, blockDim, argsInfo, smDesc, stm, flags, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchEx(void *args, uint32_t argsSize, uint32_t flags, rtStream_t stm)
{
    KL_RESOLVE(rtKernelLaunchEx);
    CoreGuard _g(stm);
    return orig(args, argsSize, flags, stm);
}

__attribute__((visibility("default")))
uint32_t rtKernelLaunchFwk(const char_t *opName, void *args, uint32_t argsSize,
                           uint32_t flags, rtStream_t stm)
{
    KL_RESOLVE(rtKernelLaunchFwk);
    CoreGuard _g(stm);
    return orig(opName, args, argsSize, flags, stm);
}

__attribute__((visibility("default")))
uint32_t rtCpuKernelLaunch(const void *soName, const void *kernelName, uint32_t blockDim,
                           const void *args, uint32_t argsSize, rtSmDesc_t *smDesc, rtStream_t stm)
{
    KL_RESOLVE(rtCpuKernelLaunch);
    CoreGuard _g(stm);
    return orig(soName, kernelName, blockDim, args, argsSize, smDesc, stm);
}

__attribute__((visibility("default")))
uint32_t rtCpuKernelLaunchWithFlag(const void *soName, const void *kernelName, uint32_t blockDim,
                                   const rtArgsEx_t *argsInfo, rtSmDesc_t *smDesc, rtStream_t stm,
                                   uint32_t flags)
{
    KL_RESOLVE(rtCpuKernelLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(soName, kernelName, blockDim, argsInfo, smDesc, stm, flags);
}

__attribute__((visibility("default")))
uint32_t rtAicpuKernelLaunch(const rtKernelLaunchNames_t *launchNames, uint32_t blockDim,
                             const void *args, uint32_t argsSize, rtSmDesc_t *smDesc, rtStream_t stm)
{
    KL_RESOLVE(rtAicpuKernelLaunch);
    CoreGuard _g(stm);
    return orig(launchNames, blockDim, args, argsSize, smDesc, stm);
}

__attribute__((visibility("default")))
uint32_t rtAicpuKernelLaunchWithFlag(const rtKernelLaunchNames_t *launchNames, uint32_t blockDim,
                                     const rtArgsEx_t *argsInfo, rtSmDesc_t *smDesc, rtStream_t stm,
                                     uint32_t flags)
{
    KL_RESOLVE(rtAicpuKernelLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(launchNames, blockDim, argsInfo, smDesc, stm, flags);
}

__attribute__((visibility("default")))
uint32_t rtAicpuKernelLaunchExWithArgs(const uint32_t kernelType, const char_t *opName,
                                       const uint32_t blockDim, const rtAicpuArgsEx_t *argsInfo,
                                       rtSmDesc_t *smDesc, const rtStream_t stm, const uint32_t flags)
{
    KL_RESOLVE(rtAicpuKernelLaunchExWithArgs);
    CoreGuard _g(stm);
    return orig(kernelType, opName, blockDim, argsInfo, smDesc, stm, flags);
}

__attribute__((visibility("default")))
uint32_t rtLaunchKernelByFuncHandle(rtFuncHandle funcHandle, uint32_t blockDim,
                                    rtLaunchArgsHandle argsHandle, rtStream_t stm)
{
    KL_RESOLVE(rtLaunchKernelByFuncHandle);
    CoreGuard _g(stm);
    return orig(funcHandle, blockDim, argsHandle, stm);
}

__attribute__((visibility("default")))
uint32_t rtLaunchKernelByFuncHandleV2(rtFuncHandle funcHandle, uint32_t blockDim,
                                      rtLaunchArgsHandle argsHandle, rtStream_t stm,
                                      const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtLaunchKernelByFuncHandleV2);
    CoreGuard _g(stm);
    return orig(funcHandle, blockDim, argsHandle, stm, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtLaunchKernelByFuncHandleV3(rtFuncHandle funcHandle, uint32_t blockDim,
                                      const rtArgsEx_t *argsInfo, rtStream_t stm,
                                      const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtLaunchKernelByFuncHandleV3);
    CoreGuard _g(stm);
    return orig(funcHandle, blockDim, argsInfo, stm, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtVectorCoreKernelLaunchWithHandle(void *hdl, const uint64_t tilingKey, uint32_t blockDim,
                                            rtArgsEx_t *argsInfo, rtSmDesc_t *smDesc, rtStream_t stm,
                                            const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtVectorCoreKernelLaunchWithHandle);
    CoreGuard _g(stm);
    return orig(hdl, tilingKey, blockDim, argsInfo, smDesc, stm, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtVectorCoreKernelLaunch(const void *stubFunc, uint32_t blockDim, rtArgsEx_t *argsInfo,
                                  rtSmDesc_t *smDesc, rtStream_t stm, uint32_t flags,
                                  const rtTaskCfgInfo_t *cfgInfo)
{
    KL_RESOLVE(rtVectorCoreKernelLaunch);
    CoreGuard _g(stm);
    return orig(stubFunc, blockDim, argsInfo, smDesc, stm, flags, cfgInfo);
}

__attribute__((visibility("default")))
uint32_t rtModelExecute(rtModel_t mdl, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtModelExecute);
    CoreGuard _g(stm);
    return orig(mdl, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtFftsPlusTaskLaunch(rtFftsPlusTaskInfo_t *info, rtStream_t stm)
{
    KL_RESOLVE(rtFftsPlusTaskLaunch);
    CoreGuard _g(stm);
    return orig(info, stm);
}

__attribute__((visibility("default")))
uint32_t rtFftsPlusTaskLaunchWithFlag(rtFftsPlusTaskInfo_t *info, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtFftsPlusTaskLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(info, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtFftsTaskLaunch(rtFftsTaskInfo_t *info, rtStream_t stm)
{
    KL_RESOLVE(rtFftsTaskLaunch);
    CoreGuard _g(stm);
    return orig(info, stm);
}

__attribute__((visibility("default")))
uint32_t rtFftsTaskLaunchWithFlag(rtFftsTaskInfo_t *info, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtFftsTaskLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(info, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtStarsTaskLaunch(const void *taskSqe, uint32_t sqeLen, rtStream_t stm)
{
    KL_RESOLVE(rtStarsTaskLaunch);
    CoreGuard _g(stm);
    return orig(taskSqe, sqeLen, stm);
}

__attribute__((visibility("default")))
uint32_t rtStarsTaskLaunchWithFlag(const void *taskSqe, uint32_t sqeLen, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtStarsTaskLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(taskSqe, sqeLen, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtCmoTaskLaunch(rtCmoTaskInfo_t *info, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtCmoTaskLaunch);
    CoreGuard _g(stm);
    return orig(info, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtCmoAddrTaskLaunch(void *cmoAddrInfo, uint64_t destMax, rtCmoOpCode_t opCode,
                             rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtCmoAddrTaskLaunch);
    CoreGuard _g(stm);
    return orig(cmoAddrInfo, destMax, opCode, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtBarrierTaskLaunch(rtBarrierTaskInfo_t *info, rtStream_t stm, uint32_t flag)
{
    KL_RESOLVE(rtBarrierTaskLaunch);
    CoreGuard _g(stm);
    return orig(info, stm, flag);
}

__attribute__((visibility("default")))
uint32_t rtMultipleTaskInfoLaunch(const void *taskInfo, rtStream_t stm)
{
    KL_RESOLVE(rtMultipleTaskInfoLaunch);
    CoreGuard _g(stm);
    return orig(taskInfo, stm);
}

__attribute__((visibility("default")))
uint32_t rtMultipleTaskInfoLaunchWithFlag(const void *taskInfo, rtStream_t stm, const uint32_t flag)
{
    KL_RESOLVE(rtMultipleTaskInfoLaunchWithFlag);
    CoreGuard _g(stm);
    return orig(taskInfo, stm, flag);
}

}  // extern "C"

#undef KL_RESOLVE

/* ================================================================
 *  SECTION 4 — Library constructor
 * ================================================================ */

__attribute__((constructor)) static void VxpuShimCtor()
{
    fprintf(stderr, "[vxpu_meminfo_shim] loaded pid=%d\n", static_cast<int>(getpid()));
    fflush(stderr);

    g_dcmiEnabled.store(EnvTruthy("VXPU_MEMINFO_USE_DCMI", true));
    if (g_dcmiEnabled.load()) {
        // Run DCMI sampling in a background thread; hook path only reads atomics.
        std::thread(DcmiSamplerThread).detach();
    }

    unsigned int pct = 0;
    if (ReadCoreConfig(pct)) {
        g_corePercent = pct;
        g_batchSize   = 10;

        if (!ReadDieIdAndIdx(g_dieId, sizeof(g_dieId), g_hintIdx)) {
            fprintf(stderr, "[vxpu_shim] no dieId found; core limiting will be disabled\n");
            fflush(stderr);
            return;
        }

        g_coreConfigured = true;
        fprintf(stderr, "[vxpu_shim] core limiter configured: quota=%u%% dieId=%s (lazy-init on first kernel) pid=%d\n",
                pct, g_dieId, (int)getpid());
        fflush(stderr);
    }
}

__attribute__((destructor)) static void VxpuShimDtor()
{
    if (!g_coreEnabled) return;

    g_schedEnd = true;
    g_fwdSem.Release(1000);

    if (g_ctx && g_myIdx >= 0) {
        g_ctx->nodes[g_myIdx].periodCheck.store(TsClock::time_point{});
    }
}
