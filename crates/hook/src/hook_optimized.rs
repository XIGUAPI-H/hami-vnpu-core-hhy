#![allow(non_snake_case)]
// Full optimized hook (d69787d): core_guard + apply_quota on all meminfo + malloc passthrough.
// LLM mode (NPU_LLM_MODE=1): wait_for_token hot path — avoids CoreLimiter mutex on every kernel.
use crate::{MemInfoHook, NPU_LIMITER, passthrough};
use limiter::externed_api::{RT_ERROR_MEMORY_ALLOCATION, RT_ERROR_NONE};
use once_cell::sync::Lazy;
use std::sync::OnceLock;

use limiter::worker::CoreGuard;
use limiter::worker::{iteration_sched_enabled, kernel_burst_active};

static LLM_HOOK_MODE: OnceLock<bool> = OnceLock::new();
static ORIGIN_COMPAT: OnceLock<bool> = OnceLock::new();
static COMPUTE_HOOK_ENABLED: OnceLock<bool> = OnceLock::new();
static ACL_MEMINFO_HOOK_ENABLED: OnceLock<bool> = OnceLock::new();
static SYNC_HOOK_ENABLED: OnceLock<bool> = OnceLock::new();

fn parse_bool_env(v: &str, default: bool) -> bool {
    let v = v.trim();
    if v.is_empty() {
        return default;
    }
    v == "1"
        || v.eq_ignore_ascii_case("true")
        || v.eq_ignore_ascii_case("on")
        || v.eq_ignore_ascii_case("yes")
}

fn env_bool(name: &str, default: bool) -> bool {
    std::env::var(name)
        .map(|v| parse_bool_env(&v, default))
        .unwrap_or(default)
}

fn origin_compat_enabled() -> bool {
    *ORIGIN_COMPAT.get_or_init(|| env_bool("VXPU_ORIGIN_COMPAT", false))
}

fn compute_hook_enabled() -> bool {
    *COMPUTE_HOOK_ENABLED.get_or_init(|| {
        if origin_compat_enabled() || !env_bool("VXPU_COMPUTE_LIMIT", true) {
            return false;
        }
        std::env::var("NPU_PRIORITY")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .map(|p| p < 100.0)
            .unwrap_or(true)
    })
}

fn acl_meminfo_hook_enabled() -> bool {
    *ACL_MEMINFO_HOOK_ENABLED
        .get_or_init(|| !origin_compat_enabled() && env_bool("VXPU_ACL_MEMINFO_HOOK", true))
}

fn sync_hook_enabled() -> bool {
    *SYNC_HOOK_ENABLED.get_or_init(|| {
        !origin_compat_enabled() && compute_hook_enabled() && env_bool("VXPU_SYNC_HOOK", true)
    })
}

fn llm_hook_use_core_limiter() -> bool {
    NPU_LIMITER.hook_uses_core_limiter()
}

fn llm_hook_mode() -> bool {
    *LLM_HOOK_MODE.get_or_init(|| match std::env::var("NPU_LLM_MODE") {
        Ok(v) => {
            let v = v.trim();
            v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("on")
        }
        Err(_) => false,
    })
}

/// Token (wait_for_token / Gemini burst) path is taken when either the explicit
/// LLM hook mode or the standalone kernel-burst is active.
#[inline(always)]
fn token_burst_mode() -> bool {
    compute_hook_enabled() && (llm_hook_mode() || kernel_burst_active())
}

/// Hold CoreGuard for core_limiter / non-LLM; token path calls wait_for_token.
struct ComputeLimit {
    _core: Option<CoreGuard>,
}

impl ComputeLimit {
    #[inline(always)]
    fn noop() -> Self {
        Self { _core: None }
    }

    #[inline(always)]
    fn enter(stm: u64) -> Self {
        if !compute_hook_enabled() {
            return Self::noop();
        }
        // Hard-sim / explicit CoreLimiter path takes precedence.
        if llm_hook_use_core_limiter() {
            return Self {
                _core: Some(NPU_LIMITER.core_guard(stm)),
            };
        }
        let burst = token_burst_mode();
        // Iteration sched: only rtModelExecute acquires; kernels in burst are free.
        if burst && iteration_sched_enabled() {
            return Self::noop();
        }
        if burst {
            NPU_LIMITER.wait_for_token(stm);
            return Self::noop();
        }
        Self {
            _core: Some(NPU_LIMITER.core_guard(stm)),
        }
    }
}

type AclError = i32;
type AclrtMemAttr = i32;
const ACL_SUCCESS: AclError = 0;

thread_local! {
    static TLS_ACL_IMPL_INVOCATIONS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

static REAL_ACLRT_GET_MEM_INFO_IMPL: Lazy<
    extern "C" fn(AclrtMemAttr, *mut usize, *mut usize) -> AclError,
> = Lazy::new(|| unsafe {
    let h = libc::dlopen(
        b"libascendcl_impl.so\0".as_ptr() as *const libc::c_char,
        libc::RTLD_NOW | libc::RTLD_LOCAL,
    );
    let mut ptr = std::ptr::null_mut();
    if !h.is_null() {
        ptr = libc::dlsym(h, b"aclrtGetMemInfoImpl\0".as_ptr() as *const libc::c_char);
    }
    if ptr.is_null() {
        ptr = libc::dlsym(
            libc::RTLD_NEXT,
            b"aclrtGetMemInfoImpl\0".as_ptr() as *const libc::c_char,
        );
    }
    if ptr.is_null() {
        panic!("cannot find original function: aclrtGetMemInfoImpl");
    }
    std::mem::transmute(ptr)
});

static REAL_ACLRT_GET_MEM_INFO: Lazy<
    extern "C" fn(AclrtMemAttr, *mut usize, *mut usize) -> AclError,
> = Lazy::new(|| unsafe {
    let h = libc::dlopen(
        b"libascendcl.so\0".as_ptr() as *const libc::c_char,
        libc::RTLD_NOW | libc::RTLD_LOCAL,
    );
    let mut ptr = std::ptr::null_mut();
    if !h.is_null() {
        ptr = libc::dlsym(h, b"aclrtGetMemInfo\0".as_ptr() as *const libc::c_char);
    }
    if ptr.is_null() {
        ptr = libc::dlsym(
            libc::RTLD_NEXT,
            b"aclrtGetMemInfo\0".as_ptr() as *const libc::c_char,
        );
    }
    if ptr.is_null() {
        panic!("cannot find original function: aclrtGetMemInfo");
    }
    std::mem::transmute(ptr)
});

fn malloc_quota_enabled() -> bool {
    match std::env::var("VXPU_ENABLE_MALLOC_QUOTA") {
        Ok(v) => {
            let v = v.trim();
            v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("on")
        }
        Err(_) => false,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn rtKernelLaunch(
    stubFunc: u64,
    blockDim: u32,
    args: u64,
    argsSize: u32,
    smDesc: u64,
    stm: u64,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtKernelLaunch",
        (u64, u32, u64, u32, u64, u64),
        stubFunc,
        blockDim,
        args,
        argsSize,
        smDesc,
        stm
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtKernelLaunchEx(args: u64, argsSize: u32, flags: u32, stm: u64) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtKernelLaunchEx",
        (u64, u32, u32, u64),
        args,
        argsSize,
        flags,
        stm
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtKernelLaunchFwk(
    opName: u64,
    args: u64,
    argsSize: u32,
    flags: u32,
    stm: u64,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtKernelLaunchFwk",
        (u64, u64, u32, u32, u64),
        opName,
        args,
        argsSize,
        flags,
        stm
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtAicpuKernelLaunch(
    launchNames: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtAicpuKernelLaunch",
        (u64, u32, u64, u64, u64),
        launchNames,
        blockDim,
        argsInfo,
        smDesc,
        stm
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtAicpuKernelLaunchExWithArgs(
    kernelType: u32,
    opName: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
    flags: u32,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtAicpuKernelLaunchExWithArgs",
        (u32, u64, u32, u64, u64, u64, u32),
        kernelType,
        opName,
        blockDim,
        argsInfo,
        smDesc,
        stm,
        flags
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn aclrtGetMemInfoImpl(
    attr: AclrtMemAttr,
    free: *mut usize,
    total: *mut usize,
) -> AclError {
    let ret = (*REAL_ACLRT_GET_MEM_INFO_IMPL)(attr, free, total);
    if ret != ACL_SUCCESS {
        return ret;
    }
    if acl_meminfo_hook_enabled() && NPU_LIMITER.is_hbm_limited() {
        let phys_free = unsafe { if free.is_null() { 0 } else { *free } };
        let phys_total = unsafe { if total.is_null() { 0 } else { *total } };
        NPU_LIMITER.apply_quota_from_phys_meminfo(
            phys_free,
            phys_total,
            free,
            total,
            MemInfoHook::AclImpl,
        );
    }
    TLS_ACL_IMPL_INVOCATIONS.with(|c| c.set(c.get().wrapping_add(1)));
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn aclrtGetMemInfo(
    attr: AclrtMemAttr,
    free: *mut usize,
    total: *mut usize,
) -> AclError {
    let before = TLS_ACL_IMPL_INVOCATIONS.with(|c| c.get());
    let ret = (*REAL_ACLRT_GET_MEM_INFO)(attr, free, total);
    if ret != ACL_SUCCESS {
        return ret;
    }
    let after = TLS_ACL_IMPL_INVOCATIONS.with(|c| c.get());
    if after == before && acl_meminfo_hook_enabled() && NPU_LIMITER.is_hbm_limited() {
        let phys_free = unsafe { if free.is_null() { 0 } else { *free } };
        let phys_total = unsafe { if total.is_null() { 0 } else { *total } };
        NPU_LIMITER.apply_quota_from_phys_meminfo(
            phys_free,
            phys_total,
            free,
            total,
            MemInfoHook::AclPub,
        );
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtAicpuKernelLaunchWithFlag(
    launchNames: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
    flags: u32,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtAicpuKernelLaunchWithFlag",
        (u64, u32, u64, u64, u64, u32),
        launchNames,
        blockDim,
        argsInfo,
        smDesc,
        stm,
        flags
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtKernelLaunchWithFlagV2(
    stubFunc: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
    flags: u32,
    cfgInfo: u64,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtKernelLaunchWithFlagV2",
        (u64, u32, u64, u64, u64, u32, u64),
        stubFunc,
        blockDim,
        argsInfo,
        smDesc,
        stm,
        flags,
        cfgInfo
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtKernelLaunchWithHandleV2(
    handle: u64,
    tilingKey: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
    cfgInfo: u64,
) -> u64 {
    let _lim = ComputeLimit::enter(stm);
    passthrough!(
        "rtKernelLaunchWithHandleV2",
        (u64, u64, u32, u64, u64, u64, u64),
        handle,
        tilingKey,
        blockDim,
        argsInfo,
        smDesc,
        stm,
        cfgInfo
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtModelExecute(mdl: u64, stm: u64, flag: u32) -> u64 {
    let burst = token_burst_mode();
    if burst && iteration_sched_enabled() {
        NPU_LIMITER.wait_for_iteration_boundary(stm);
    } else {
        let _lim = ComputeLimit::enter(stm);
    }
    let ret = passthrough!("rtModelExecute", (u64, u64, u32), mdl, stm, flag);
    if sync_hook_enabled() && burst && !iteration_sched_enabled() {
        NPU_LIMITER.end_kernel_burst();
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtStreamSynchronize(stm: u64) -> u64 {
    let ret = passthrough!("rtStreamSynchronize", (u64), stm);
    if sync_hook_enabled() && token_burst_mode() {
        NPU_LIMITER.end_kernel_burst();
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtDeviceSynchronize() -> u64 {
    static REAL: Lazy<extern "C" fn() -> u64> = Lazy::new(|| unsafe {
        let ptr = libc::dlsym(
            libc::RTLD_NEXT,
            b"rtDeviceSynchronize\0".as_ptr() as *const libc::c_char,
        );
        if ptr.is_null() {
            panic!("cannot find original function: rtDeviceSynchronize");
        }
        std::mem::transmute(ptr)
    });
    let ret = (*REAL)();
    if sync_hook_enabled() && token_burst_mode() {
        NPU_LIMITER.end_kernel_burst();
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtMalloc(devPtr: u64, size: u64, t: u32, moduleId: u16) -> u64 {
    if malloc_quota_enabled() && NPU_LIMITER.is_hbm_limited() {
        if NPU_LIMITER.check_memory_quota(size) == 0 {
            let ret = passthrough!("rtMalloc", (u64, u64, u32, u16), devPtr, size, t, moduleId);
            if ret == RT_ERROR_NONE {
                let actual_ptr = unsafe { *(devPtr as *const u64) };
                NPU_LIMITER.post_alloc_hbm(actual_ptr, size, ret);
                return RT_ERROR_NONE;
            }
            NPU_LIMITER.post_alloc_hbm(0, size, ret);
            return RT_ERROR_MEMORY_ALLOCATION;
        }
        return RT_ERROR_MEMORY_ALLOCATION;
    }
    passthrough!("rtMalloc", (u64, u64, u32, u16), devPtr, size, t, moduleId)
}

#[unsafe(no_mangle)]
pub extern "C" fn rtMallocPhysical(handle: u64, size: u64, prop: u64, flags: u64) -> u64 {
    if malloc_quota_enabled() && NPU_LIMITER.is_hbm_limited() {
        if NPU_LIMITER.check_memory_quota(size) == 0 {
            let ret = passthrough!(
                "rtMallocPhysical",
                (u64, u64, u64, u64),
                handle,
                size,
                prop,
                flags
            );
            if ret == RT_ERROR_NONE {
                let actual_handle = unsafe { *(handle as *const u64) };
                NPU_LIMITER.post_alloc_hbm(actual_handle, size, ret);
                return RT_ERROR_NONE;
            }
            NPU_LIMITER.post_alloc_hbm(0, size, ret);
            return RT_ERROR_MEMORY_ALLOCATION;
        }
        return RT_ERROR_MEMORY_ALLOCATION;
    }
    passthrough!(
        "rtMallocPhysical",
        (u64, u64, u64, u64),
        handle,
        size,
        prop,
        flags
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn rtFreePhysical(handle: u64) -> u64 {
    let ret = passthrough!("rtFreePhysical", (u64), handle);
    if malloc_quota_enabled() && NPU_LIMITER.is_hbm_limited() {
        NPU_LIMITER.post_free_hbm(handle, ret);
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtFree(ptr: u64) -> u64 {
    let ret = passthrough!("rtFree", (u64), ptr);
    if malloc_quota_enabled() && NPU_LIMITER.is_hbm_limited() {
        NPU_LIMITER.post_free_hbm(ptr, ret);
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtMemGetInfo(free: *mut usize, total: *mut usize) -> u64 {
    let ret = passthrough!("rtMemGetInfo", (*mut usize, *mut usize), free, total);
    if ret == 0 && NPU_LIMITER.is_hbm_limited() {
        let phys_free = unsafe { if free.is_null() { 0 } else { *free } };
        let phys_total = unsafe { if total.is_null() { 0 } else { *total } };
        NPU_LIMITER.apply_quota_from_phys_meminfo(
            phys_free,
            phys_total,
            free,
            total,
            MemInfoHook::Rt,
        );
    }
    ret
}

#[unsafe(no_mangle)]
pub extern "C" fn rtMemGetInfoEx(memInfoType: u64, free: *mut usize, total: *mut usize) -> u64 {
    let ret = passthrough!(
        "rtMemGetInfoEx",
        (u64, *mut usize, *mut usize),
        memInfoType,
        free,
        total
    );
    if ret == 0 && NPU_LIMITER.is_hbm_limited() {
        let phys_free = unsafe { if free.is_null() { 0 } else { *free } };
        let phys_total = unsafe { if total.is_null() { 0 } else { *total } };
        NPU_LIMITER.apply_quota_from_phys_meminfo(
            phys_free,
            phys_total,
            free,
            total,
            MemInfoHook::RtEx,
        );
    }
    ret
}
