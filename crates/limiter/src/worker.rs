use std::cell::Cell;
use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock};
use std::thread;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

use log::{debug, info, warn};

use crate::check_rts;
use crate::compute_sched;
use crate::config::local_shmem_name;
use crate::externed_api::*;
use crate::kylin_preset;
use crate::shmem::{
    self, GlobalRegistry, LocalContainerShmem, STATE_IDLE, STATE_MEASURING, STATE_RUNNING, futex,
};

// =========================================================================================
// DCMI "own used memory" sampler (aligned with legacy libmeminfo_shim)
// =========================================================================================

const DCMI_MAX_STALENESS_MS: u64 = 3000;
const DCMI_SAMPLE_PERIOD_MS: u64 = 50;
const DCMI_PROC_CAPACITY: usize = 1024;

/// Bounded poll interval for a worker blocked on a batch-state transition
/// (MEASURING / IDLE). A worker must never sleep indefinitely on `futex::wait`:
/// if a manager wakeup is lost or delayed (baton hand-off, rest window, ACL-graph
/// bursty kernel arrival on Kylin), an unbounded wait turns into a >60s stall that
/// trips vLLM's `shm_broadcast` RPC timeout. Re-checking every few hundred us makes
/// the wait self-healing, mirroring `wait_for_running` / `wait_for_global_turn`.
const WORKER_STATE_WAIT_POLL_US: u64 = 500;

#[repr(C)]
#[derive(Clone, Copy)]
struct DcmiProcMemInfo {
    proc_id: i32,
    proc_mem_usage: libc::c_ulong,
}

type DcmiInitFn = unsafe extern "C" fn() -> i32;
type DcmiShutdownFn = unsafe extern "C" fn() -> i32;
type DcmiSetContainerServiceEnableFn = unsafe extern "C" fn() -> i32;
type DcmiGetCardDevFromLogicFn =
    unsafe extern "C" fn(card_id: *mut i32, device_id: *mut i32, logic_id: u32) -> i32;
type DcmiGetDeviceResourceInfoFn = unsafe extern "C" fn(
    card_id: u32,
    device_id: u32,
    proc_info: *mut DcmiProcMemInfo,
    proc_num: *mut i32,
) -> i32;

struct DcmiApi {
    handle: *mut libc::c_void,
    init: Option<DcmiInitFn>,
    shutdown: Option<DcmiShutdownFn>,
    set_container_service_enable: Option<DcmiSetContainerServiceEnableFn>,
    get_card_dev_from_logic: Option<DcmiGetCardDevFromLogicFn>,
    get_dev_res: Option<DcmiGetDeviceResourceInfoFn>,
}

static DCMI_OWN_USED_BYTES: AtomicU64 = AtomicU64::new(0);
static DCMI_LAST_UPDATE_MS: AtomicU64 = AtomicU64::new(0);
static DCMI_READY: AtomicBool = AtomicBool::new(false);
static DCMI_STARTED: OnceLock<()> = OnceLock::new();
static MEMINFO_LOG_COUNT: AtomicU64 = AtomicU64::new(0);
static DCMI_FIRST_SAMPLE_LOGGED: AtomicBool = AtomicBool::new(false);
static DCMI_LAST_PROC_NUM: AtomicI32 = AtomicI32::new(i32::MIN);
/// Max per-process memory reported by DCMI before PID filtering (for mismatch detection).
static DCMI_LAST_RAW_MEM_MAX: AtomicU64 = AtomicU64::new(0);
/// Set once ACL/RT runtime is up. DCMI init must not run before this (avoids aclInit races).
static NPU_RUNTIME_READY: AtomicBool = AtomicBool::new(false);
/// vLLM profile_run asserts `initial_free > current_free`.  Multi-tenant baseline/DCMI
/// can falsely shrink own_used when another pod on the same card frees HBM; keep per-process
/// peaks until runtime is marked ready.
static MEMINFO_PROFILING_MAX_OWN_USED: AtomicU64 = AtomicU64::new(0);
static MEMINFO_PROFILING_MIN_FREE: AtomicU64 = AtomicU64::new(u64::MAX);

#[derive(Clone, Copy)]
struct MeminfoCacheEntry {
    phys_total: usize,
    reported_free: usize,
    reported_total: usize,
    set_at_ms: u64,
}

static MEMINFO_STARTUP_CACHE: Mutex<[Option<MeminfoCacheEntry>; 4]> =
    Mutex::new([None, None, None, None]);

/// During vLLM init profiling, never report more free HBM than a prior query in this process.
fn clamp_meminfo_for_profiling(quota: u64, mut own_used: u64, mem_tracked: u64) -> (u64, u64) {
    own_used = own_used.max(mem_tracked);
    if NPU_RUNTIME_READY.load(Ordering::Acquire) {
        let reported_free = quota.saturating_sub(own_used);
        return (own_used, reported_free);
    }

    let mut prev_max = MEMINFO_PROFILING_MAX_OWN_USED.load(Ordering::Acquire);
    while own_used > prev_max {
        match MEMINFO_PROFILING_MAX_OWN_USED.compare_exchange_weak(
            prev_max,
            own_used,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => break,
            Err(v) => prev_max = v,
        }
    }
    own_used = own_used.max(MEMINFO_PROFILING_MAX_OWN_USED.load(Ordering::Acquire));
    let mut reported_free = quota.saturating_sub(own_used);

    let prev_min = MEMINFO_PROFILING_MIN_FREE.load(Ordering::Acquire);
    if prev_min == u64::MAX {
        MEMINFO_PROFILING_MIN_FREE.store(reported_free, Ordering::Release);
    } else if reported_free < prev_min {
        MEMINFO_PROFILING_MIN_FREE.store(reported_free, Ordering::Release);
    } else {
        reported_free = prev_min;
        own_used = quota.saturating_sub(reported_free);
    }

    (own_used, reported_free)
}

fn try_meminfo_startup_cache(
    hook: MemInfoHook,
    phys_total: usize,
    free: *mut usize,
    total: *mut usize,
    quota: u64,
    mem_tracked: u64,
) -> bool {
    if !kylin_preset::meminfo_startup_cache_enabled() {
        return false;
    }
    if NPU_RUNTIME_READY.load(Ordering::Acquire) {
        return false;
    }
    let now = now_ms();
    let ttl = kylin_preset::meminfo_startup_cache_ttl_ms();
    let cache = MEMINFO_STARTUP_CACHE.lock().unwrap();
    let idx = hook as usize;
    if let Some(entry) = cache[idx] {
        if entry.phys_total == phys_total && now.saturating_sub(entry.set_at_ms) <= ttl {
            let own_used = quota.saturating_sub(entry.reported_free as u64);
            let (_, reported_free) =
                clamp_meminfo_for_profiling(quota, own_used, mem_tracked);
            unsafe {
                if !total.is_null() {
                    *total = entry.reported_total;
                }
                if !free.is_null() {
                    *free = reported_free as usize;
                }
            }
            return true;
        }
    }
    false
}

fn store_meminfo_startup_cache(
    hook: MemInfoHook,
    phys_total: usize,
    reported_free: u64,
    reported_total: u64,
) {
    if !kylin_preset::meminfo_startup_cache_enabled() || NPU_RUNTIME_READY.load(Ordering::Acquire) {
        return;
    }
    let mut cache = MEMINFO_STARTUP_CACHE.lock().unwrap();
    cache[hook as usize] = Some(MeminfoCacheEntry {
        phys_total,
        reported_free: reported_free as usize,
        reported_total: reported_total as usize,
        set_at_ms: now_ms(),
    });
}

fn now_ms() -> u64 {
    unsafe {
        let mut ts: libc::timespec = std::mem::zeroed();
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
        (ts.tv_sec as u64) * 1000 + (ts.tv_nsec as u64) / 1_000_000
    }
}

fn env_truthy(name: &str, default_val: bool) -> bool {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => {
            let v = v.to_ascii_lowercase();
            if v == "0" || v == "false" || v == "off" {
                false
            } else if v == "1" || v == "true" || v == "on" {
                true
            } else {
                default_val
            }
        }
        _ => default_val,
    }
}

fn read_logic_device_id() -> u32 {
    // Keep this lightweight and dependency-free; ASCEND_VISIBLE_DEVICES is enough for our use.
    if let Ok(vis) = std::env::var("ASCEND_VISIBLE_DEVICES") {
        let v = vis.trim();
        if !v.is_empty() {
            let first = v.split(',').next().unwrap_or(v);
            if let Ok(n) = first.parse::<u32>() {
                return n;
            }
        }
    }
    0
}

fn read_nspid_list() -> Vec<i32> {
    let s = match std::fs::read_to_string("/proc/self/status") {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("NSpid:") {
            let mut out = Vec::new();
            for tok in rest.split_whitespace() {
                if let Ok(v) = tok.parse::<i32>() {
                    out.push(v);
                }
            }
            return out;
        }
    }
    vec![]
}

fn read_host_pid_guess() -> Option<i32> {
    // NSpid: leftmost = current namespace, rightmost = initial (host/root) namespace.
    // DCMI reports host PIDs on partitioned 910B nodes.
    let ns = read_nspid_list();
    ns.last().copied().filter(|v| *v > 0)
}

fn allow_pids_without_config() -> Vec<i32> {
    // Include every PID along the namespace chain so DCMI can match host or container ids.
    let mut out = read_nspid_list();
    if out.is_empty() {
        if let Some(hpid) = read_host_pid_guess() {
            out.push(hpid);
        }
    }
    out.sort_unstable();
    out.dedup();
    out.retain(|&p| p > 0);
    out
}

fn try_read_pids_config() -> Vec<i32> {
    let path = "/etc/xpu/pids.config";
    let s = match std::fs::read_to_string(path) {
        Ok(v) => v,
        Err(_) => {
            return allow_pids_without_config();
        }
    };
    let mut out = Vec::new();
    for line in s.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if let Ok(p) = t.parse::<i32>() {
            if p > 0 {
                out.push(p);
            }
        }
    }
    out
}

fn host_pid_allowed(pid: i32, allow: &[i32]) -> bool {
    if allow.is_empty() {
        return true;
    }
    allow.iter().any(|&p| p == pid)
}

unsafe fn dlopen_first(cands: &[&'static [u8]]) -> *mut libc::c_void {
    for c in cands {
        let h = libc::dlopen(
            c.as_ptr() as *const libc::c_char,
            libc::RTLD_NOW | libc::RTLD_LOCAL,
        );
        if !h.is_null() {
            return h;
        }
    }
    std::ptr::null_mut()
}

unsafe fn dlsym_opt<T>(handle: *mut libc::c_void, sym: &'static [u8]) -> Option<T> {
    let p = libc::dlsym(handle, sym.as_ptr() as *const libc::c_char);
    if p.is_null() {
        None
    } else {
        Some(std::mem::transmute_copy(&p))
    }
}

unsafe fn load_dcmi() -> Option<DcmiApi> {
    let cands: &[&[u8]] = &[
        b"libdcmi.so\0",
        b"libdcmi_interface.so\0",
        b"/usr/local/dcmi/libdcmi.so\0",
        b"/usr/local/dcmi/lib64/libdcmi.so\0",
        b"/usr/local/dcmi/lib/libdcmi.so\0",
        b"/usr/local/Ascend/driver/lib64/common/libdcmi.so\0",
    ];
    let handle = dlopen_first(cands);
    if handle.is_null() {
        return None;
    }
    let init = dlsym_opt::<DcmiInitFn>(handle, b"dcmi_init\0");
    let shutdown = dlsym_opt::<DcmiShutdownFn>(handle, b"dcmi_shut_down\0")
        .or_else(|| dlsym_opt::<DcmiShutdownFn>(handle, b"dcmi_shutdown\0"));
    let set_container_service_enable = dlsym_opt::<DcmiSetContainerServiceEnableFn>(
        handle,
        b"dcmi_set_container_service_enable\0",
    );
    let get_card_dev_from_logic = dlsym_opt::<DcmiGetCardDevFromLogicFn>(
        handle,
        b"dcmi_get_card_id_device_id_from_logicid\0",
    );
    let get_dev_res =
        dlsym_opt::<DcmiGetDeviceResourceInfoFn>(handle, b"dcmi_get_device_resource_info\0");

    if init.is_none() || get_card_dev_from_logic.is_none() || get_dev_res.is_none() {
        return None;
    }
    Some(DcmiApi {
        handle,
        init,
        shutdown,
        set_container_service_enable,
        get_card_dev_from_logic,
        get_dev_res,
    })
}

/// Mark NPU runtime as ready and start the DCMI sampler thread (once).
/// Safe to call from kernel-launch hooks or RT meminfo after aclInit completes.
pub fn mark_npu_runtime_ready() {
    if NPU_RUNTIME_READY.swap(true, Ordering::AcqRel) {
        return;
    }
    info!(
        "[dcmi] npu runtime ready pid={}, starting sampler",
        std::process::id()
    );
    start_dcmi_sampler_once();
}

/// Fallback: start DCMI after a delay if no kernel/RT meminfo path has marked ready yet.
fn schedule_dcmi_fallback_once() {
    if !env_truthy("VXPU_MEMINFO_USE_DCMI", false) {
        return;
    }
    if env_truthy("VXPU_DCMI_START_EARLY", false) {
        mark_npu_runtime_ready();
        return;
    }
    static SCHEDULED: Once = Once::new();
    SCHEDULED.call_once(|| {
        let secs = std::env::var("VXPU_DCMI_DEFER_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .unwrap_or(15);
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(secs));
            if !NPU_RUNTIME_READY.load(Ordering::Acquire) {
                info!("[dcmi] fallback timer ({}s): starting sampler", secs);
                mark_npu_runtime_ready();
            }
        });
    });
}

/// ACL meminfo hooks can fire during aclInit; never start DCMI from them.
fn maybe_start_dcmi_for_hook(hook: MemInfoHook, phys_total: usize) {
    if env_truthy("VXPU_DCMI_START_EARLY", false) {
        mark_npu_runtime_ready();
        return;
    }
    match hook {
        MemInfoHook::Rt | MemInfoHook::RtEx if phys_total > 0 => mark_npu_runtime_ready(),
        MemInfoHook::Rt | MemInfoHook::RtEx | MemInfoHook::AclImpl | MemInfoHook::AclPub => {}
    }
}

fn start_dcmi_sampler_once() {
    let enabled = env_truthy("VXPU_MEMINFO_USE_DCMI", false);
    if !enabled {
        info!("[dcmi] disabled by VXPU_MEMINFO_USE_DCMI");
        return;
    }
    if DCMI_STARTED.set(()).is_err() {
        return;
    }

    thread::spawn(|| {
        // One-shot log: pid namespace mapping hints.
        if !DCMI_FIRST_SAMPLE_LOGGED.load(Ordering::Relaxed) {
            let ns = read_nspid_list();
            let hpid = read_host_pid_guess().unwrap_or(-1);
            info!(
                "[dcmi] pid_hint: pid={} host_pid_guess={} nspid={:?}",
                std::process::id(),
                hpid,
                ns
            );
        }

        let api = unsafe { load_dcmi() };
        let mut api = match api {
            Some(a) => a,
            None => {
                warn!("[dcmi] load failed (dlopen/dlsym)");
                DCMI_READY.store(false, Ordering::Relaxed);
                return;
            }
        };
        let init_ret = unsafe { (api.init.unwrap())() };
        if init_ret != 0 {
            warn!("[dcmi] init failed ret={}", init_ret);
            DCMI_READY.store(false, Ordering::Relaxed);
            return;
        }
        if let Some(en) = api.set_container_service_enable {
            let r = unsafe { en() };
            info!("[dcmi] set_container_service_enable ret={}", r);
        } else {
            info!("[dcmi] set_container_service_enable not found");
        }
        info!("[dcmi] sampler started");
        DCMI_READY.store(true, Ordering::Release);

        // Do one immediate sample before the first sleep to minimize the window
        // where meminfo queries happen before DCMI has produced any data.
        let mut did_first = false;
        loop {
            // Refresh filter (cheap).
            let allow_pids = try_read_pids_config();

            let logic_id = read_logic_device_id();
            let mut card_id: i32 = 0;
            let mut device_id: i32 = 0;
            let ok = unsafe {
                (api.get_card_dev_from_logic.unwrap())(&mut card_id, &mut device_id, logic_id)
            };
            if ok == 0 {
                let mut buf = vec![
                    DcmiProcMemInfo {
                        proc_id: 0,
                        proc_mem_usage: 0
                    };
                    DCMI_PROC_CAPACITY
                ];
                let mut proc_num: i32 = buf.len() as i32;
                let ret = unsafe {
                    (api.get_dev_res.unwrap())(
                        card_id as u32,
                        device_id as u32,
                        buf.as_mut_ptr(),
                        &mut proc_num,
                    )
                };
                DCMI_LAST_PROC_NUM.store(proc_num, Ordering::Relaxed);

                // Mark "we sampled" even if empty; helps meminfo path distinguish
                // between "not yet sampled" and "sampled but 0/empty".
                DCMI_LAST_UPDATE_MS.store(now_ms(), Ordering::Relaxed);

                if ret == 0 && proc_num > 0 {
                    let n = (proc_num as usize).min(buf.len());
                    let mut sum: u64 = 0;
                    let mut raw_max: u64 = 0;
                    let mut first: Vec<(i32, u64)> = Vec::new();
                    for i in 0..n {
                        let pid = buf[i].proc_id;
                        let usage = buf[i].proc_mem_usage as u64;
                        raw_max = raw_max.max(usage);
                        if first.len() < 8 {
                            first.push((pid, usage));
                        }
                        if !host_pid_allowed(pid, &allow_pids) {
                            continue;
                        }
                        sum = sum.saturating_add(usage);
                    }
                    DCMI_LAST_RAW_MEM_MAX.store(raw_max, Ordering::Relaxed);
                    DCMI_OWN_USED_BYTES.store(sum, Ordering::Relaxed);
                    if !DCMI_FIRST_SAMPLE_LOGGED.swap(true, Ordering::Relaxed) {
                        info!(
                            "[dcmi] first_sample: ret={} proc_num={} allow_pids={:?} first_pids={:?} own_used_bytes={}",
                            ret, proc_num, allow_pids, first, sum
                        );
                    } else {
                        debug!("[dcmi] own_used_bytes={} procs={}", sum, n);
                    }
                } else if !DCMI_FIRST_SAMPLE_LOGGED.swap(true, Ordering::Relaxed) {
                    DCMI_LAST_RAW_MEM_MAX.store(0, Ordering::Relaxed);
                    DCMI_OWN_USED_BYTES.store(0, Ordering::Relaxed);
                    info!(
                        "[dcmi] first_sample: ret={} proc_num={} allow_pids={:?} (no proc data)",
                        ret, proc_num, allow_pids
                    );
                } else {
                    DCMI_LAST_RAW_MEM_MAX.store(0, Ordering::Relaxed);
                    DCMI_OWN_USED_BYTES.store(0, Ordering::Relaxed);
                }
            }

            if did_first {
                thread::sleep(std::time::Duration::from_millis(DCMI_SAMPLE_PERIOD_MS));
            } else {
                did_first = true;
            }
        }

        #[allow(unreachable_code)]
        {
            if let Some(shutdown) = api.shutdown {
                let _ = unsafe { shutdown() };
            }
            unsafe { libc::dlclose(api.handle) };
        }
    });
}

fn get_own_used_bytes_dcmi() -> Option<u64> {
    if !DCMI_READY.load(Ordering::Acquire) {
        return None;
    }
    let ts = DCMI_LAST_UPDATE_MS.load(Ordering::Relaxed);
    if ts == 0 {
        return None;
    }
    let now = now_ms();
    if now < ts || now - ts > DCMI_MAX_STALENESS_MS {
        return None;
    }
    // CRITICAL: if DCMI reported zero processes for this device, it means DCMI is
    // structurally unable to enumerate our worker (common on Ascend 910B3 partitions
    // where `dcmi_get_device_resource_info` returns proc_num=0).  We must NOT treat
    // own_used=0 as authoritative — it would prevent vLLM's profile_run assertion
    // (`initial_free != final_free`) from ever triggering and over-report free
    // memory throughout the pod lifetime.  Fall back to baseline-tracking instead.
    if DCMI_LAST_PROC_NUM.load(Ordering::Relaxed) <= 0 {
        return None;
    }
    let own = DCMI_OWN_USED_BYTES.load(Ordering::Relaxed);
    // DCMI listed processes with memory but PID filter zeroed them out (common when
    // container pid != host pid).  Fall back to per-hook baseline tracking.
    if own == 0 && DCMI_LAST_RAW_MEM_MAX.load(Ordering::Relaxed) > 0 {
        return None;
    }
    Some(own)
}

// =========================================================================================
// Compute limit bypass + optional core scheduler (feature `core_scheduler`, off by default)
// =========================================================================================

static COMPUTE_ENFORCED_CACHE: AtomicU8 = AtomicU8::new(2); // 0=off, 1=on, 2=unknown
static MANAGER_ACTIVE: AtomicBool = AtomicBool::new(false);

/// True when token-based compute limiting should run (NPU_PRIORITY < 100 and not opted out).
fn compute_limit_enforced() -> bool {
    match COMPUTE_ENFORCED_CACHE.load(Ordering::Relaxed) {
        0 => false,
        1 => true,
        _ => {
            let enforced = if !env_truthy("VXPU_COMPUTE_LIMIT", true) {
                false
            } else if let Ok(v) = std::env::var(crate::config::ENV_PRIORITY) {
                v.parse::<f64>().map(|p| p < 100.0).unwrap_or(true)
            } else {
                true
            };
            COMPUTE_ENFORCED_CACHE.store(if enforced { 1 } else { 0 }, Ordering::Relaxed);
            enforced
        }
    }
}

fn note_manager_activity(shmem: &LocalContainerShmem) {
    if shmem.state.load(Ordering::Relaxed) != STATE_IDLE {
        MANAGER_ACTIVE.store(true, Ordering::Relaxed);
    }
    if shmem.batch_id.load(Ordering::Relaxed) > 0 {
        MANAGER_ACTIVE.store(true, Ordering::Relaxed);
    }
}

fn bypass_compute_wait(inner: &SchedulerClientInner) -> bool {
    if !compute_limit_enforced() {
        return true;
    }
    if (best_effort_enabled() || auto_best_effort_enabled()) && !global_contention(inner.shmem) {
        return true;
    }
    note_manager_activity(inner.shmem);
    // Worker bootstrapped local shmem without a limiter daemon: mem-only quota, no compute wait.
    inner.worker_bootstrapped && !MANAGER_ACTIVE.load(Ordering::Relaxed)
}

fn auto_best_effort_enabled() -> bool {
    static AUTO_BE: OnceLock<bool> = OnceLock::new();
    *AUTO_BE.get_or_init(|| {
        if kylin_preset::env_var_set("NPU_AUTO_BEST_EFFORT") {
            return kylin_preset::env_bool("NPU_AUTO_BEST_EFFORT", false);
        }
        false
    })
}

/// Whether the hook should use CoreLimiter instead of manager tokens on this call.
///
/// Fast path: Manager mode (the default) never uses CoreLimiter, so we must NOT
/// pay for a global-registry contention scan on every kernel launch. Only the
/// explicit CoreLimiter / Auto modes consult contention.
#[inline(always)]
pub fn hook_use_core_limiter(shmem: &LocalContainerShmem) -> bool {
    if !compute_sched::prefers_core_limiter() {
        return false;
    }
    if !compute_limit_enforced() {
        return false;
    }
    compute_sched::resolve_use_core_limiter(global_contention(shmem))
}

pub fn compute_sched_mode_name() -> &'static str {
    match compute_sched::compute_sched_mode() {
        compute_sched::ComputeSchedMode::Manager => "manager",
        compute_sched::ComputeSchedMode::CoreLimiter => "core_limiter",
        compute_sched::ComputeSchedMode::Auto => "auto",
    }
}

#[cfg(not(feature = "core_scheduler"))]
pub struct CoreGuard;

#[cfg(not(feature = "core_scheduler"))]
impl Drop for CoreGuard {
    fn drop(&mut self) {}
}

#[cfg(not(feature = "core_scheduler"))]
impl CoreGuard {
    pub(crate) fn acquired(&self) -> bool {
        false
    }
}

#[cfg(feature = "core_scheduler")]
pub use crate::core_scheduler::CoreGuard;

#[derive(Debug)]
struct GpuTiming {
    internal_stream: u64,
    start_event: u64,
    end_event: u64,
    tracking_event: u64,
}

/// Per-thread batch participation state (no NPU resources — shared process-wide).
#[derive(Debug)]
struct PerThreadCtx {
    my_slot_idx: usize,
    batch_active: Cell<bool>,
    /// True only while this thread's current batch is reflected in
    /// `LocalContainerShmem::active_workers`.
    active_counted: Cell<bool>,
    current_batch_id: Cell<u64>,
    last_user_stream: Cell<u64>,
    start_time_us: Cell<u64>,
    /// Local token debt — amortize global atomic fetch_sub across a burst.
    local_token_debt: Cell<u64>,
    /// Gemini-style kernel burst: skip hook overhead between sync points.
    /// The kernels recorded while the gate is open live in the process-wide
    /// `GLOBAL_BURST_NOTEBOOK`, not here, so a thread that syncs but never
    /// launches can still settle them.
    kernel_burst_open: Cell<bool>,
}

static PROCESS_GPU_TIMING: OnceLock<Mutex<GpuTiming>> = OnceLock::new();
static GPU_START_BATCH: AtomicU64 = AtomicU64::new(0);
static HBM_LIMITED_CACHE: AtomicU8 = AtomicU8::new(2); // 0=no, 1=yes, 2=unknown
static TOKEN_CHUNK: OnceLock<u64> = OnceLock::new();
static FAST_MEASURE: OnceLock<bool> = OnceLock::new();
static LLM_MODE: OnceLock<bool> = OnceLock::new();
static LLM_BURST: OnceLock<bool> = OnceLock::new();
static BURST_KERNELS_PER_TOKEN: OnceLock<u64> = OnceLock::new();
static FIKIT_MODE: OnceLock<bool> = OnceLock::new();
static ITERATION_SCHED: OnceLock<bool> = OnceLock::new();
static BEST_EFFORT: OnceLock<bool> = OnceLock::new();
static GLOBAL_REG: OnceLock<Option<&'static GlobalRegistry>> = OnceLock::new();

thread_local! {
    static ITER_CORE_GUARD: std::cell::RefCell<Option<CoreGuard>> = const { std::cell::RefCell::new(None) };
    static PER_THREAD_CTX: OnceLock<PerThreadCtx> = const { OnceLock::new() };
}

pub fn iteration_sched_enabled() -> bool {
    *ITERATION_SCHED.get_or_init(|| {
        if kylin_preset::env_var_set("NPU_ITERATION_SCHED") {
            return kylin_preset::env_bool("NPU_ITERATION_SCHED", false);
        }
        if compute_sched::iteration_sched_default() {
            return true;
        }
        kylin_preset::env_bool_kylin_lite("NPU_ITERATION_SCHED", false, false, llm_mode_enabled())
    })
}

pub fn sched_kernel_limit_active() -> bool {
    !iteration_sched_enabled()
}

fn fikit_mode_enabled() -> bool {
    *FIKIT_MODE.get_or_init(|| {
        kylin_preset::env_bool_kylin_lite("NPU_FIKIT_MODE", false, false, llm_mode_enabled())
    })
}

fn best_effort_enabled() -> bool {
    *BEST_EFFORT.get_or_init(|| {
        std::env::var("NPU_SCHED_POLICY")
            .map(|v| {
                let v = v.trim().to_ascii_lowercase();
                v == "best-effort" || v == "best_effort" || v == "besteffort"
            })
            .unwrap_or(false)
    })
}

fn global_registry() -> Option<&'static GlobalRegistry> {
    *GLOBAL_REG.get_or_init(|| {
        std::env::var("NPU_GLOBAL_SHM_PATH")
            .ok()
            .map(|p| shmem::setup::open_global_registry(&p))
    })
}

fn global_contention(shmem: &LocalContainerShmem) -> bool {
    let Some(global) = global_registry() else {
        return false;
    };
    let my_slot = shmem.global_slot_idx.load(Ordering::Relaxed) as usize;
    global.slots.iter().enumerate().any(|(i, slot)| {
        i != my_slot
            && slot.is_active.load(Ordering::Relaxed) == 1
            && (slot.wants_compute.load(Ordering::Relaxed) > 0
                || slot.workers_active.load(Ordering::Relaxed) > 0)
    })
}

fn track_worker_waiting(shmem: &LocalContainerShmem, waiting: bool) {
    if waiting {
        shmem.workers_waiting.fetch_add(1, Ordering::Relaxed);
    } else {
        let _ = shmem
            .workers_waiting
            .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |n| n.checked_sub(1));
    }
}

fn llm_mode_enabled() -> bool {
    *LLM_MODE.get_or_init(|| {
        if kylin_preset::env_var_set("NPU_LLM_MODE") {
            return kylin_preset::env_bool("NPU_LLM_MODE", false);
        }
        if compute_sched::llm_mode_default(false) {
            return true;
        }
        kylin_preset::env_bool_kylin_lite("NPU_LLM_MODE", false, true, false)
    })
}

fn llm_kernel_burst_enabled() -> bool {
    *LLM_BURST.get_or_init(|| llm_mode_enabled() && env_truthy("NPU_LLM_BURST", true))
}

static KERNEL_BURST: OnceLock<bool> = OnceLock::new();

/// Gemini-style kernel burst, decoupled from full `llm_mode`.
///
/// Between two sync points each kernel only does a notebook increment plus a
/// slice-boundary check; the token budget is charged in bulk at the burst boundary
/// (rtStreamSynchronize / rtModelExecute) or as soon as the slice ends. At the
/// default ratio of one kernel per token the budget comes out identical to
/// origin's, while the per-kernel hook cost collapses to a relaxed fetch_add and
/// two relaxed loads.
///
/// Crucially this does NOT enable `llm_mode`'s wall-clock measurement, so the
/// manager keeps allocating tokens from accurate GPU-event timing (avoids the
/// token-starvation that made the full Kylin preset regress).
pub fn kernel_burst_active() -> bool {
    *KERNEL_BURST.get_or_init(|| {
        if kylin_preset::env_var_set("NPU_KERNEL_BURST") {
            return kylin_preset::env_bool("NPU_KERNEL_BURST", false);
        }
        // Full llm burst implies kernel burst.
        if llm_kernel_burst_enabled() {
            return true;
        }
        // Default ON under Kylin (preset or lite) — proven low-overhead hot path.
        kylin_preset::kylin_preset_active() || kylin_preset::kylin_lite_active()
    })
}

static BURST_ACCOUNTING: OnceLock<bool> = OnceLock::new();

/// True when any burst accounting (full llm or standalone kernel burst) is active.
/// Cached to a single relaxed OnceLock read so the per-kernel hot path stays cheap.
#[inline(always)]
fn burst_accounting_active() -> bool {
    *BURST_ACCOUNTING.get_or_init(|| llm_kernel_burst_enabled() || kernel_burst_active())
}

/// Kernels charged as one token (Gemini burst accounting).
///
/// Always 1 by default, in either burst flavour: origin charges one token per
/// kernel launch, so any ratio above 1 hands the container that multiple of its
/// configured share. Burst is meant to be an overhead-only optimization — the
/// budget must come out identical to origin's. Values > 1 are a deliberate quota
/// inflation and only exist for experiments; they invalidate any share
/// comparison against origin.
fn burst_kernels_per_token() -> u64 {
    *BURST_KERNELS_PER_TOKEN.get_or_init(|| {
        std::env::var("NPU_BURST_KERNELS_PER_TOKEN")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(1)
            .clamp(1, 256)
    })
}

/// Kernels launched under an open burst but not yet charged, process-wide.
///
/// Deliberately not thread-local: frameworks routinely launch on one thread and
/// synchronize on another, and a per-thread notebook is invisible to the syncing
/// thread — those kernels would then never be charged at all.
static GLOBAL_BURST_NOTEBOOK: AtomicU64 = AtomicU64::new(0);
static BURST_STRICT: OnceLock<bool> = OnceLock::new();
static BURST_MAX_OPEN: OnceLock<u64> = OnceLock::new();
static BURST_REPAY_ROUNDS: OnceLock<u32> = OnceLock::new();

/// Honour the timeslice boundary from inside an open burst.
///
/// Set `NPU_BURST_STRICT=0` to get the old behaviour (a burst runs unmetered
/// until the next sync hook) for A/B measurement of the enforcement cost.
#[inline(always)]
fn burst_strict_enabled() -> bool {
    *BURST_STRICT.get_or_init(|| env_truthy("NPU_BURST_STRICT", true))
}

/// Kernels recorded in one open burst before an inline settle is forced.
/// Bounds both the size of a single charge and the audit gap.
fn burst_max_open() -> u64 {
    *BURST_MAX_OPEN.get_or_init(|| {
        std::env::var("NPU_BURST_MAX_OPEN")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(512)
            .clamp(1, 1 << 20)
    })
}

/// How many slices a launch may block on to repay carried-over burst debt before
/// giving up and proceeding (the debt stays on the books either way). Bounded so
/// a large debt cannot look like a hang to a framework watchdog.
fn burst_repay_rounds() -> u32 {
    *BURST_REPAY_ROUNDS.get_or_init(|| {
        std::env::var("NPU_BURST_REPAY_ROUNDS")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(16)
            .clamp(0, 4096)
    })
}

/// Charge exactly `count` tokens, returning how many were actually charged.
///
/// Unlike `try_consume_token_chunk` this never grabs a whole chunk into
/// `local_token_debt`: a settle that over-reserves up to `NPU_TOKEN_CHUNK`
/// tokens strands budget that sibling threads and the next slice still need, and
/// leaves `outstanding_token_debt` non-zero so the manager cuts the slice short.
fn try_charge_tokens_exact(
    shmem: &LocalContainerShmem,
    pt: Option<&PerThreadCtx>,
    count: u64,
) -> u64 {
    if count == 0 {
        return 0;
    }
    let mut need = count;

    // Spend already-reserved thread-local tokens first.
    if let Some(pt) = pt {
        let debt = pt.local_token_debt.get();
        let from_local = debt.min(need);
        if from_local > 0 {
            pt.local_token_debt.set(debt - from_local);
            decrement_outstanding_saturating(shmem, from_local);
            need -= from_local;
        }
    }

    let mut current = shmem.tokens_remaining.load(Ordering::Acquire);
    while need > 0 && current > 0 {
        let take = current.min(need);
        match shmem.tokens_remaining.compare_exchange_weak(
            current,
            current - take,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => {
                need -= take;
                current -= take;
            }
            Err(actual) => current = actual,
        }
    }
    count - need
}

/// Settle the process-wide notebook against the token budget.
///
/// Never blocks — this also runs from sync/RPC paths. Any shortfall goes back on
/// the books unconditionally: dropping it whenever the slice had already ended
/// (which is precisely when a shortfall is most likely) is what let a burst
/// overrun its budget for free.
fn settle_global_notebook(shmem: &LocalContainerShmem, pt: Option<&PerThreadCtx>) -> u64 {
    let notebook = GLOBAL_BURST_NOTEBOOK.swap(0, Ordering::AcqRel);
    if notebook == 0 {
        return 0;
    }
    let ratio = burst_kernels_per_token();
    let charge = notebook.div_ceil(ratio);
    let charged = try_charge_tokens_exact(shmem, pt, charge);
    let unpaid = charge.saturating_sub(charged).saturating_mul(ratio);
    if unpaid > 0 {
        GLOBAL_BURST_NOTEBOOK.fetch_add(unpaid, Ordering::AcqRel);
    }
    unpaid
}

fn token_chunk_size() -> u64 {
    *TOKEN_CHUNK.get_or_init(|| {
        let default_chunk = if iteration_sched_enabled() {
            1
        } else if burst_accounting_active() {
            // Burst accounting already amortizes the shared-counter traffic, so
            // chunk pre-reservation buys nothing and costs correctness: whatever a
            // thread reserves but does not spend is dropped at the slice boundary
            // (`clear_stale_batch`) and becomes free credit, and a single thread
            // can strand the pool that its siblings still need.
            1
        } else if llm_mode_enabled() {
            512
        } else {
            32
        };
        std::env::var("NPU_TOKEN_CHUNK")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(default_chunk)
            .clamp(1, 512)
    })
}

fn fast_measure_enabled() -> bool {
    *FAST_MEASURE.get_or_init(|| {
        std::env::var("NPU_FAST_MEASURE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("on"))
            .unwrap_or(false)
    })
}

/// Wall-clock batch timing without rtDeviceSynchronize (LLM decode hot path).
fn llm_light_measure_enabled() -> bool {
    llm_mode_enabled() || env_truthy("NPU_LLM_LIGHT_MEASURE", false) || fast_measure_enabled()
}

#[inline(always)]
fn wait_for_running(shmem: &LocalContainerShmem) {
    for _ in 0..kylin_preset::wait_spin_iters() {
        if shmem.state.load(Ordering::Relaxed) == STATE_RUNNING {
            return;
        }
        std::hint::spin_loop();
    }
    futex::wait_timeout(&shmem.state, STATE_RUNNING, 100);
}

/// Bounded hybrid pre-spin used before futex-sleeping at a slice boundary.
/// Returns true if `shmem.state` left `expected` within the spin budget (i.e. the
/// manager already flipped us into the next slice), letting the caller skip the
/// futex syscall entirely. This shaves the wakeup round-trip off the per-slice
/// handoff — the dominant dead time that keeps soft time-slicing behind hard
/// spatial partitioning under multi-tenant contention.
#[inline(always)]
fn slice_wakeup_spin_iters(shmem: &LocalContainerShmem) -> u32 {
    if let Some(v) = kylin_preset::slice_wakeup_spin_override() {
        return v;
    }
    if global_contention(shmem) {
        kylin_preset::slice_wakeup_spin_iters()
    } else {
        0
    }
}

#[inline(always)]
fn spin_for_state_leave(shmem: &LocalContainerShmem, expected: u32) -> bool {
    let iters = slice_wakeup_spin_iters(shmem);
    for _ in 0..iters {
        if shmem.state.load(Ordering::Relaxed) != expected {
            return true;
        }
        std::hint::spin_loop();
    }
    shmem.state.load(Ordering::Relaxed) != expected
}

#[inline(always)]
fn flush_token_debt(shmem: &LocalContainerShmem, pt: &PerThreadCtx) {
    let debt = pt.local_token_debt.get();
    if debt > 0 {
        shmem.tokens_remaining.fetch_add(debt, Ordering::Relaxed);
        // Saturating: the manager may have reset `outstanding_token_debt` to 0 for a
        // new batch between our chunk grab and this flush. A raw fetch_sub would then
        // underflow to a huge u64, making the manager believe debt is permanently
        // outstanding and churn into MEASURING every round. Clamp at 0 instead.
        decrement_outstanding_saturating(shmem, debt);
        pt.local_token_debt.set(0);
    }
}

/// Decrement `outstanding_token_debt` without ever wrapping below zero.
#[inline(always)]
fn decrement_outstanding_saturating(shmem: &LocalContainerShmem, amount: u64) {
    if amount == 0 {
        return;
    }
    let _ = shmem.outstanding_token_debt.fetch_update(
        Ordering::AcqRel,
        Ordering::Relaxed,
        |cur| Some(cur.saturating_sub(amount)),
    );
}

#[inline(always)]
fn try_consume_token_chunk(shmem: &LocalContainerShmem, pt: &PerThreadCtx) -> bool {
    let debt = pt.local_token_debt.get();
    if debt > 0 {
        pt.local_token_debt.set(debt - 1);
        decrement_outstanding_saturating(shmem, 1);
        return true;
    }

    let chunk = token_chunk_size();
    let mut current = shmem.tokens_remaining.load(Ordering::Acquire);
    loop {
        if current == 0 {
            return false;
        }
        let take = current.min(chunk);
        match shmem.tokens_remaining.compare_exchange_weak(
            current,
            current - take,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => {
                let remaining_debt = take - 1;
                pt.local_token_debt.set(remaining_debt);
                if remaining_debt > 0 {
                    shmem
                        .outstanding_token_debt
                        .fetch_add(remaining_debt, Ordering::Relaxed);
                }
                return true;
            }
            Err(actual) => current = actual,
        }
    }
}

#[derive(Clone, Debug)]
pub struct SchedulerClient {
    inner: Arc<SchedulerClientInner>,
}

/// Which memory-info hook the quota application is coming from.
///
/// We keep a **separate baseline** per hook (mirroring libmeminfo_shim's design with
/// `g_baselineAcl`, `g_baselineAclPub`, `g_baselineRt`, `g_baselineRtEx`).  Each hook's
/// "first call" happens at a different phase of vLLM initialisation; the baseline
/// absorbs whatever `phys_used` already exists when that hook is first invoked.  Sharing
/// one baseline across all hooks means the hook that fires earliest pins the baseline
/// to a small value, and every later hook sees inflated `own_used` once profile_run /
/// runtime caching grows the pool.
#[derive(Clone, Copy, Debug)]
pub enum MemInfoHook {
    AclImpl = 0,
    AclPub = 1,
    Rt = 2,
    RtEx = 3,
}

struct MemBaseline {
    used: AtomicU64,
    set: AtomicBool,
}

impl MemBaseline {
    const fn new() -> Self {
        Self {
            used: AtomicU64::new(0),
            set: AtomicBool::new(false),
        }
    }
}

struct SchedulerClientInner {
    shmem: &'static LocalContainerShmem,
    worker_bootstrapped: bool,
    hbm_handle_map: Mutex<HashMap<u64, u64>>,
    mem_baselines: [MemBaseline; 4],
}

impl fmt::Debug for SchedulerClientInner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SchedulerClientInner")
            .field("shmem", &self.shmem)
            .finish()
    }
}

impl SchedulerClient {
    /// Initialized ONCE per NPUDeviceList (per process/device)
    pub fn new() -> Self {
        info!(
            "[Worker PID:{}] Initialize SchedulerClient...",
            std::process::id()
        );

        let shmem_name = local_shmem_name();
        let (shmem, bootstrapped) = shmem::setup::open_or_create_local_shmem(shmem_name.as_str());
        if bootstrapped {
            info!(
                "[Worker PID:{}] Local shmem bootstrapped (no limiter daemon required for mem quota)",
                std::process::id()
            );
        }

        Self {
            inner: Arc::new(SchedulerClientInner {
                shmem,
                worker_bootstrapped: bootstrapped,
                hbm_handle_map: Mutex::new(HashMap::new()),
                mem_baselines: [
                    MemBaseline::new(),
                    MemBaseline::new(),
                    MemBaseline::new(),
                    MemBaseline::new(),
                ],
            }),
        }
    }

    /// Runtime path selection for hook hot path (manager tokens vs CoreLimiter).
    pub fn hook_uses_core_limiter(&self) -> bool {
        hook_use_core_limiter(self.inner.shmem)
    }

    fn gpu_timing() -> &'static Mutex<GpuTiming> {
        PROCESS_GPU_TIMING.get_or_init(|| Mutex::new(Self::create_gpu_timing()))
    }

    fn create_gpu_timing() -> GpuTiming {
        let mut internal_stream: u64 = 0;
        let mut start_event: u64 = 0;
        let mut end_event: u64 = 0;
        let mut tracking_event: u64 = 0;

        check_rts!(rtStreamCreate(&mut internal_stream, 0));
        check_rts!(rtEventCreate(&mut start_event));
        check_rts!(rtEventCreate(&mut end_event));
        check_rts!(rtEventCreate(&mut tracking_event));

        GpuTiming {
            internal_stream,
            start_event,
            end_event,
            tracking_event,
        }
    }

    /// Charge one scheduling unit at an iteration boundary (Salus / rtModelExecute).
    pub fn wait_for_iteration_boundary(&self, user_stream: u64) {
        if bypass_compute_wait(&self.inner) {
            return;
        }
        if hook_use_core_limiter(self.inner.shmem) {
            self.acquire_iteration_core(user_stream);
        } else {
            self.wait_for_token_impl(user_stream, true);
        }
    }

    /// The Main Entry Point — optimized for steady-state kernel launches.
    pub fn wait_for_token(&self, user_stream: u64) {
        self.wait_for_token_impl(user_stream, false);
    }

    fn wait_for_token_impl(&self, user_stream: u64, force_iteration: bool) {
        let shmem = self.inner.shmem;

        // FAST PATH (Gemini burst): one hook entry per forward pass. While a burst
        // is open every subsequent kernel is just a notebook increment — no
        // bypass/manager-activity atomics, no OnceLock churn, no slot lookup.
        if burst_accounting_active() {
            let handled = PER_THREAD_CTX.with(|cell| {
                let Some(pt) = cell.get() else {
                    return false;
                };
                if !pt.kernel_burst_open.get() {
                    return false;
                }
                pt.last_user_stream.set(user_stream);
                if !burst_strict_enabled() {
                    GLOBAL_BURST_NOTEBOOK.fetch_add(1, Ordering::Relaxed);
                    return true;
                }
                // The slice can end at any point while the gate is open. Two
                // relaxed loads are enough to notice; without them the thread
                // keeps launching at full rate until the next sync hook — and if
                // it never syncs on this thread, forever. The batch check also
                // forces a trip through `begin_batch`, which is what keeps
                // `active_workers` (and hence the cross-tenant contention signal)
                // honest for a long-running burst.
                if shmem.state.load(Ordering::Relaxed) != STATE_RUNNING
                    || shmem.batch_id.load(Ordering::Relaxed) != pt.current_batch_id.get()
                {
                    GLOBAL_BURST_NOTEBOOK.fetch_add(1, Ordering::Relaxed);
                    pt.kernel_burst_open.set(false);
                    settle_global_notebook(shmem, Some(pt));
                    return false; // fall through and block until the next slice
                }
                let notebook = GLOBAL_BURST_NOTEBOOK.fetch_add(1, Ordering::Relaxed) + 1;
                if notebook < burst_max_open() {
                    return true;
                }
                // Keep the notebook bounded so a sync-free stretch cannot build a
                // charge far larger than a whole slice's budget.
                if settle_global_notebook(shmem, Some(pt)) == 0 {
                    return true;
                }
                // Already over budget mid-burst. Close the gate and go wait, both
                // to enforce the limit and to avoid retrying the settle on every
                // subsequent kernel.
                pt.kernel_burst_open.set(false);
                false
            });
            if handled {
                return;
            }
        }

        if bypass_compute_wait(&self.inner) {
            return;
        }
        if !force_iteration && !sched_kernel_limit_active() {
            return;
        }
        PER_THREAD_CTX.with(|cell| {
            let pt = cell.get_or_init(|| {
                let my_slot_idx = Self::register_worker_slot(shmem);
                debug!("[Scheduler] Thread Registered at Slot {}", my_slot_idx);
                PerThreadCtx {
                    my_slot_idx,
                    batch_active: Cell::new(false),
                    active_counted: Cell::new(false),
                    current_batch_id: Cell::new(0),
                    last_user_stream: Cell::new(0),
                    start_time_us: Cell::new(0),
                    local_token_debt: Cell::new(0),
                    kernel_burst_open: Cell::new(false),
                }
            });
            pt.last_user_stream.set(user_stream);
            Self::wait_for_token_loop(shmem, pt);
            if burst_accounting_active() {
                if burst_strict_enabled() {
                    Self::repay_burst_debt(shmem, pt);
                }
                pt.kernel_burst_open.set(true);
            }
        });
    }

    /// Settle carried-over burst debt before opening a new gate.
    ///
    /// Without this the notebook only ever grows: each settle charges what it can
    /// and rolls the rest forward, but nothing ever makes the container wait for
    /// the budget it already spent, so the "limit" is advisory. A kernel launch is
    /// the right place to block — the non-burst path blocks here too.
    fn repay_burst_debt(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx) {
        if GLOBAL_BURST_NOTEBOOK.load(Ordering::Relaxed) == 0 {
            return;
        }
        for _ in 0..=burst_repay_rounds() {
            if settle_global_notebook(shmem, Some(pt)) == 0 {
                return;
            }
            // Out of budget: wait for the next slice, then keep paying.
            Self::wait_for_token_loop(shmem, pt);
        }
        // Still owing after the bounded wait. Proceed rather than risk looking
        // like a hang; the residual stays on the books and is charged later.
        debug!(
            "[Burst] repay incomplete, {} kernels still owed",
            GLOBAL_BURST_NOTEBOOK.load(Ordering::Relaxed)
        );
    }

    /// Called from sync hooks at burst boundary (Gemini IEEE TCC 2021).
    pub fn end_kernel_burst(&self) {
        if ITER_CORE_GUARD.with(|g| g.borrow().is_some()) {
            self.release_iteration_core();
            return;
        }
        if bypass_compute_wait(&self.inner)
            || !burst_accounting_active()
            || iteration_sched_enabled()
        {
            return;
        }
        let shmem = self.inner.shmem;
        PER_THREAD_CTX.with(|cell| {
            // Settle even when this thread has no gate of its own: a sync can come
            // from a thread that never launched a kernel, and the kernels waiting
            // in the notebook must still be charged.
            let pt = cell.get();
            if let Some(pt) = pt {
                pt.kernel_burst_open.set(false);
            }
            // Charge ceil(kernels / ratio) tokens instead of 1 per kernel (origin
            // baseline). Any shortfall is carried, never forgiven.
            settle_global_notebook(shmem, pt);
        });
    }

    fn wait_for_token_loop(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx) {
        loop {
            let state = shmem.state.load(Ordering::Acquire);
            let global_batch = shmem.batch_id.load(Ordering::Relaxed);

            if pt.batch_active.get() && global_batch != pt.current_batch_id.get() {
                Self::clear_stale_batch(pt);
            }

            // FAST PATH: already participating in the current RUNNING batch.
            if pt.batch_active.get() {
                if state == STATE_RUNNING {
                    if try_consume_token_chunk(shmem, pt) {
                        return;
                    }
                    flush_token_debt(shmem, pt);
                    wait_for_running(shmem);
                    continue;
                }
                if fikit_mode_enabled() && state == STATE_IDLE {
                    flush_token_debt(shmem, pt);
                    Self::fikit_report_batch(shmem, pt);
                }
            }

            match state {
                STATE_RUNNING => {
                    if !try_consume_token_chunk(shmem, pt) {
                        flush_token_debt(shmem, pt);
                        wait_for_running(shmem);
                        continue;
                    }

                    if !pt.batch_active.get() {
                        debug!(
                            "[Worker PID:{} Slot:{}] get Batch {} first Token!, start record time...",
                            std::process::id(),
                            pt.my_slot_idx,
                            global_batch
                        );
                        Self::begin_batch(shmem, pt, global_batch);
                    }
                    return;
                }

                STATE_MEASURING => {
                    if pt.batch_active.get() && global_batch == pt.current_batch_id.get() {
                        flush_token_debt(shmem, pt);
                        if fikit_mode_enabled() {
                            Self::fikit_report_batch(shmem, pt);
                        } else {
                            debug!(
                                "[Worker PID:{} Slot:{}] start measuring Batch {} ...",
                                std::process::id(),
                                pt.my_slot_idx,
                                global_batch
                            );
                            Self::measure_and_report_batch(shmem, pt);
                        }
                    }
                    track_worker_waiting(shmem, true);
                    if !spin_for_state_leave(shmem, STATE_MEASURING) {
                        futex::wait_timeout(
                            &shmem.state,
                            STATE_MEASURING,
                            WORKER_STATE_WAIT_POLL_US,
                        );
                    }
                    track_worker_waiting(shmem, false);
                }

                _ => {
                    track_worker_waiting(shmem, true);
                    if !spin_for_state_leave(shmem, STATE_IDLE) {
                        futex::wait_timeout(&shmem.state, STATE_IDLE, WORKER_STATE_WAIT_POLL_US);
                    }
                    track_worker_waiting(shmem, false);
                }
            }
        }
    }

    fn begin_batch(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx, global_batch: u64) {
        pt.current_batch_id.set(global_batch);
        pt.batch_active.set(true);

        shmem.active_workers.fetch_add(1, Ordering::Release);
        pt.active_counted.set(true);

        let now_us = get_time_us();
        shmem.reports[pt.my_slot_idx]
            .cpu_start_us
            .store(now_us, Ordering::Relaxed);
        pt.start_time_us.set(now_us);

        // One GPU start event per batch for the whole process (matches main overhead).
        if GPU_START_BATCH.load(Ordering::Relaxed) != global_batch {
            let gpu = Self::gpu_timing().lock().unwrap();
            if GPU_START_BATCH.load(Ordering::Relaxed) != global_batch {
                check_rts!(rtEventRecord(gpu.start_event, gpu.internal_stream));
                GPU_START_BATCH.store(global_batch, Ordering::Release);
            }
        }
    }

    fn release_active_worker(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx) {
        if !pt.active_counted.replace(false) {
            return;
        }
        let _ = shmem
            .active_workers
            .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |active| {
                active.checked_sub(1)
            });
    }

    fn clear_stale_batch(pt: &PerThreadCtx) {
        // The manager has already advanced `batch_id` and reset active_workers for
        // the new batch, so do not decrement the shared counter here.
        pt.active_counted.set(false);
        pt.batch_active.set(false);
        pt.start_time_us.set(0);
        pt.local_token_debt.set(0);
        // A gate left open across a rotation would let the new slice's kernels ride
        // on the previous slice's admission decision.
        pt.kernel_burst_open.set(false);
    }

    fn register_worker_slot(shmem: &'static LocalContainerShmem) -> usize {
        for (i, slot) in shmem.reports.iter().enumerate() {
            if slot
                .occupied
                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::Relaxed)
                .is_ok()
            {
                slot.batch_id.store(0, Ordering::Relaxed);
                slot.cpu_start_us.store(0, Ordering::Relaxed);
                slot.duration_us.store(0, Ordering::Relaxed);
                return i;
            }
        }

        panic!("[Scheduler] Registry full. Increase MAX_WORKERS.");
    }

    fn acquire_iteration_core(&self, user_stream: u64) {
        let guard = self.core_guard(user_stream);
        if guard.acquired() {
            ITER_CORE_GUARD.with(|cell| {
                let mut slot = cell.borrow_mut();
                if slot.is_none() {
                    *slot = Some(guard);
                }
            });
        }
    }

    fn release_iteration_core(&self) {
        ITER_CORE_GUARD.with(|cell| {
            cell.borrow_mut().take();
        });
    }

    /// Acquire a core-budget token using the vxpu/libmeminfo_shim-compatible scheduler.
    /// This is intentionally lightweight in the hook hot-path (Acquire in ctor, ack on Drop).
    pub fn core_guard(&self, user_stream: u64) -> CoreGuard {
        #[cfg(feature = "core_scheduler")]
        {
            mark_npu_runtime_ready();
            let limiter = crate::core_scheduler::CoreLimiter::ensure_started();
            if !crate::core_scheduler::CoreLimiter::scheduler_eligible() {
                return CoreGuard::new(limiter, false);
            }
            limiter.lazy_init_if_needed();
            let enabled = limiter.enabled.load(Ordering::Acquire);
            let acquired = if enabled {
                limiter.acquire_one()
            } else {
                false
            };
            let _ = user_stream;
            CoreGuard::new(limiter, acquired)
        }
        #[cfg(not(feature = "core_scheduler"))]
        {
            let _ = user_stream;
            CoreGuard
        }
    }

    fn fikit_report_batch(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx) {
        let start_time_us = pt.start_time_us.get();
        let duration_us = if start_time_us != 0 {
            get_time_us().saturating_sub(start_time_us)
        } else {
            0
        };
        let slot = &shmem.reports[pt.my_slot_idx];
        slot.duration_us.store(duration_us, Ordering::Relaxed);
        slot.batch_id
            .store(pt.current_batch_id.get(), Ordering::Release);
        shmem.reported_count.fetch_add(1, Ordering::Release);
        Self::release_active_worker(shmem, pt);
        pt.batch_active.set(false);
        pt.start_time_us.set(0);
        pt.local_token_debt.set(0);
    }

    fn measure_and_report_batch(shmem: &'static LocalContainerShmem, pt: &PerThreadCtx) {
        let mut duration_us: u64 = 0;
        let mut used_wall_clock = false;
        let last_stream = pt.last_user_stream.get();
        let start_time_us = pt.start_time_us.get();

        // Detect whether the user's stream is mid ACL-graph capture. While a stream
        // is capturing, ANY device op on or around it (rtDeviceSynchronize,
        // rtEventRecord, rtStreamSynchronize) is illegal on Ascend and can wedge the
        // worker indefinitely — vLLM's EngineCore then trips its 60s shm_broadcast
        // RPC timeout. This only manifests when ACL graph is enabled (enforce-eager
        // never captures), matching the observed "eager OK / graph hangs" split.
        // When capturing we MUST fall back to pure wall-clock timing and issue no
        // device calls whatsoever.
        let mut capturing = false;
        if last_stream != 0 {
            let mut status: u32 = 0;
            let mut model: u64 = 0;
            let _ = check_rts!(rtStreamGetCaptureInfo(last_stream, &mut status, &mut model));
            capturing = status != 0;
        }

        // Wall-clock path: LLM light-measure mode, or whenever the stream is capturing.
        if (llm_light_measure_enabled() || capturing) && start_time_us != 0 {
            if capturing {
                debug!(
                    "[Limiter] stream 0x{:x} is capturing; using wall-clock timing (no device sync).",
                    last_stream
                );
            }
            duration_us = get_time_us().saturating_sub(start_time_us);
            used_wall_clock = true;
        }

        // Device-timing paths are only safe when the stream is NOT capturing.
        if !used_wall_clock && !capturing {
            if last_stream == 0 {
                debug!("[Limiter] no last user stream; using device sync timing.");
                check_rts!(rtDeviceSynchronize());
                if start_time_us != 0 {
                    duration_us = get_time_us().saturating_sub(start_time_us);
                }
                used_wall_clock = true;
            } else {
                let gpu = Self::gpu_timing().lock().unwrap();
                check_rts!(rtEventRecord(gpu.tracking_event, last_stream));
                check_rts!(rtStreamWaitEvent(gpu.internal_stream, gpu.tracking_event));
                check_rts!(rtEventRecord(gpu.end_event, gpu.internal_stream));
                check_rts!(rtStreamSynchronize(gpu.internal_stream));
                let mut ms: f32 = 0.0;
                check_rts!(rtEventElapsedTime(&mut ms, gpu.start_event, gpu.end_event));
                duration_us = (ms * 1000.0) as u64;
                used_wall_clock = true;
            }
        }

        // Capturing but no start timestamp (should not happen): report 0 rather than
        // risk a device call. Never block the vLLM worker at a capture boundary.
        if !used_wall_clock && capturing && start_time_us != 0 {
            duration_us = get_time_us().saturating_sub(start_time_us);
            used_wall_clock = true;
        }

        // Wall-clock batch spans must not feed anchor_avg unless full LLM mode
        // intentionally trades measurement accuracy for hook overhead. Origin stays
        // healthy because GPU-event timing keeps per-kernel averages in microseconds;
        // optimized paths (capture / NPU_LLM_LIGHT_MEASURE) would otherwise write
        // whole-batch milliseconds into stats and blow up fixed-share rest_wait.
        if used_wall_clock && !llm_mode_enabled() {
            debug!(
                "[Limiter] wall-clock measure excluded from stats (batch {}, {} us)",
                pt.current_batch_id.get(),
                duration_us
            );
            duration_us = 0;
        }

        let slot = &shmem.reports[pt.my_slot_idx];
        slot.duration_us.store(duration_us, Ordering::Relaxed);
        slot.batch_id
            .store(pt.current_batch_id.get(), Ordering::Release);

        shmem.reported_count.fetch_add(1, Ordering::Release);
        Self::release_active_worker(shmem, pt);

        pt.batch_active.set(false);
        pt.start_time_us.set(0);
        pt.local_token_debt.set(0);
    }
}

// Limit HBM
impl SchedulerClient {
    pub fn check_memory_quota(&self, size: u64) -> u64 {
        let shmem = self.inner.shmem;
        let limit = shmem.memory_limit.load(Ordering::Relaxed);

        // if no limit
        if limit == 0 {
            return 0;
        }

        let mut current_used = shmem.memory_used.load(Ordering::Acquire);

        loop {
            let new_used = current_used + size;

            if new_used > limit {
                warn!(
                    "[Worker PID:{}] Memory Quota Exceeded! Request: {} MB, Used: {} MB, Limit: {} MB",
                    std::process::id(),
                    size / 1024 / 1024,
                    current_used / 1024 / 1024,
                    limit / 1024 / 1024
                );
                return RT_ERROR_MEMORY_ALLOCATION;
            }

            match shmem.memory_used.compare_exchange(
                current_used,
                new_used,
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    debug!(
                        "[Worker] Memory Quota Reserved: {} bytes. Total used: {} bytes",
                        size, new_used
                    );
                    return 0; // success
                }
                Err(actual) => {
                    // If updated by another thread, update the local value and retry.
                    current_used = actual;
                }
            }
        }
    }

    pub fn post_alloc_hbm(&self, p: u64, size: u64, rts_return: u64) {
        if rts_return == RT_ERROR_NONE {
            // success
            let mut map = self.inner.hbm_handle_map.lock().unwrap();
            map.insert(p, size);
        } else {
            // fail
            self.inner
                .shmem
                .memory_used
                .fetch_sub(size, Ordering::SeqCst);
        }
    }

    pub fn post_free_hbm(&self, handle: u64, ret: u64) {
        if ret == RT_ERROR_NONE {
            let size = {
                let mut map = self.inner.hbm_handle_map.lock().unwrap();
                map.remove(&handle).unwrap_or(0)
            };

            if size > 0 {
                self.inner
                    .shmem
                    .memory_used
                    .fetch_sub(size, Ordering::SeqCst);
                debug!(
                    "[Limiter] Free Success: Handle 0x{:x}, Size {} bytes returned to quota.",
                    handle, size
                );
            } else {
                warn!(
                    "[Limiter] Free Success but Handle 0x{:x} was untracked!",
                    handle
                );
            }
        } else {
            warn!(
                "[Limiter] rtFreePhysical FAILED (code: {}), handle: 0x{:x}. Quota not released.",
                ret, handle
            );
        }
    }

    /// Fast path: report quota from shmem counters (no CANN rtMemGetInfoEx round-trip).
    pub fn get_hbm_info(&self, free: *mut usize, total: *mut usize) {
        let shmem = self.inner.shmem;
        let quota = shmem.memory_limit.load(Ordering::Relaxed) as usize;
        let used = shmem.memory_used.load(Ordering::Relaxed) as usize;
        let overhead_bytes = (crate::config::VIRTUAL_OVERHEAD_MB * 1024 * 1024) as usize;

        let logical_free = quota.saturating_sub(used);
        let reported_free = logical_free.saturating_sub(overhead_bytes);

        unsafe {
            if !total.is_null() {
                *total = quota;
            }
            if !free.is_null() {
                *free = reported_free;
            }
        }
    }

    /// Apply the baseline-tracking quota algorithm (ported from legacy `libmeminfo_shim.so`).
    ///
    /// - On first successful query, capture `baseline_used = phys_used`.
    /// - For later queries, compute `own_used = max(0, phys_used - baseline_used)`.
    /// - Report `total = quota` and `free = max(0, quota - own_used)`.
    pub fn apply_quota_from_phys_meminfo(
        &self,
        phys_free: usize,
        phys_total: usize,
        free: *mut usize,
        total: *mut usize,
        hook: MemInfoHook,
    ) {
        schedule_dcmi_fallback_once();
        maybe_start_dcmi_for_hook(hook, phys_total);
        // Do NOT block on the first meminfo call.  libmeminfo_shim does not block either,
        // and waiting up to several seconds here was masking a deeper issue (over-eager
        // clamping by phys_free) rather than fixing it.  The DCMI sampler runs in the
        // background and will be picked up on subsequent calls if it produces data.

        let quota = self.inner.shmem.memory_limit.load(Ordering::Relaxed) as u64;
        if quota == 0 {
            return;
        }

        let mem_tracked = self.inner.shmem.memory_used.load(Ordering::Relaxed);

        if try_meminfo_startup_cache(hook, phys_total, free, total, quota, mem_tracked) {
            return;
        }

        // Match libmeminfo_shim::ApplyQuota:
        //   - prefer DCMI per-process accounting when it is available;
        //   - otherwise use per-hook physical baseline tracking;
        //   - finally report total=quota and free=quota-own_used.
        let (mut own_used, own_used_src) = if let Some(v) = get_own_used_bytes_dcmi() {
            (v, "dcmi")
        } else {
            let bl = &self.inner.mem_baselines[hook as usize];
            let phys_used = if phys_total > 0 {
                (phys_total as u64).saturating_sub(phys_free as u64)
            } else {
                0
            };
            if !bl.set.load(Ordering::Acquire) && phys_total > 0 {
                bl.used.store(phys_used, Ordering::Relaxed);
                bl.set.store(true, Ordering::Release);
            }
            let baseline = bl.used.load(Ordering::Relaxed);
            (phys_used.saturating_sub(baseline), "baseline")
        };

        let (own_used, reported_free) =
            clamp_meminfo_for_profiling(quota, own_used, mem_tracked);
        let reported_total = quota;

        store_meminfo_startup_cache(hook, phys_total, reported_free, reported_total);

        // Optional trace logging for meminfo debugging (VXPU_MEMINFO_TRACE=1).
        if env_truthy("VXPU_MEMINFO_TRACE", false) {
            let n = MEMINFO_LOG_COUNT.fetch_add(1, Ordering::Relaxed);
            if n < 30 {
                let profiling = if NPU_RUNTIME_READY.load(Ordering::Relaxed) {
                    "post"
                } else {
                    "profile"
                };
                info!(
                    "[meminfo#{}] hook={:?} src={} phase={} phys_free={} phys_total={} quota={} own_used={} mem_tracked={} => free={} total={}",
                    n,
                    hook,
                    own_used_src,
                    profiling,
                    phys_free,
                    phys_total,
                    quota,
                    own_used,
                    mem_tracked,
                    reported_free,
                    reported_total
                );
            }
        } else {
            debug!(
                "[meminfo] hook={:?} src={} own_used={} => free={} total={}",
                hook, own_used_src, own_used, reported_free, reported_total
            );
        }

        unsafe {
            if !total.is_null() {
                *total = reported_total as usize;
            }
            if !free.is_null() {
                *free = reported_free as usize;
            }
        }
    }

    pub fn is_hbm_limited(&self) -> bool {
        match HBM_LIMITED_CACHE.load(Ordering::Relaxed) {
            0 => false,
            1 => true,
            _ => {
                let limited = self.inner.shmem.memory_limit.load(Ordering::Relaxed) > 0;
                HBM_LIMITED_CACHE.store(if limited { 1 } else { 0 }, Ordering::Relaxed);
                limited
            }
        }
    }

    /// HBM quota in bytes (from limiter shmem, set by the limiter daemon).
    pub fn memory_quota_bytes(&self) -> u64 {
        self.inner.shmem.memory_limit.load(Ordering::Relaxed) as u64
    }
}

// Helper
fn get_time_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_micros() as u64
}
