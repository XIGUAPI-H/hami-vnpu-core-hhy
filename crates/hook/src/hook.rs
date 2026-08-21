#![allow(non_snake_case)]
use crate::{NPU_LIMITER, passthrough};
use limiter::externed_api::{RT_ERROR_MEMORY_ALLOCATION, RT_ERROR_NONE};
use limiter::worker::MemInfoHook;
use once_cell::sync::Lazy;

// openEuler hybrid hot path:
//   compute  -> wait_for_token (limiter batch scheduler, not core_guard)
//   rtMem*   -> passthrough + apply_quota (profiling needs decreasing free)
//   ACL mem  -> passthrough + apply_quota (vLLM / torch_npu)
//   malloc   -> passthrough unless VXPU_ENABLE_MALLOC_QUOTA=1

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
pub extern "C" fn rtAicpuKernelLaunchExWithArgs(
    kernelType: u32,
    opName: u64,
    blockDim: u32,
    argsInfo: u64,
    smDesc: u64,
    stm: u64,
    flags: u32,
) -> u64 {
    NPU_LIMITER.wait_for_token(stm);
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
    if NPU_LIMITER.is_hbm_limited() {
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
    if after == before && NPU_LIMITER.is_hbm_limited() {
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
    NPU_LIMITER.wait_for_token(stm);
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
    NPU_LIMITER.wait_for_token(stm);
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
    NPU_LIMITER.wait_for_token(stm);
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
    NPU_LIMITER.wait_for_token(stm);
    passthrough!("rtModelExecute", (u64, u64, u32), mdl, stm, flag)
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
