//! Optional vxpu timeslice scheduler (CoreLimiter). Off by default — enable with `core_scheduler` feature.
#![cfg(feature = "core_scheduler")]

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use log::warn;

fn env_truthy(name: &str, default_val: bool) -> bool {
    match std::env::var(name) {
        Ok(v) => {
            let v = v.trim();
            v == "1"
                || v.eq_ignore_ascii_case("true")
                || v.eq_ignore_ascii_case("yes")
                || v.eq_ignore_ascii_case("on")
        }
        Err(_) => default_val,
    }
}
const TS_PERIOD_UNITS: u32 = 100;
const TS_MIN_POWER: u32 = 5;
const TS_MAX_NODES: usize = (TS_PERIOD_UNITS / TS_MIN_POWER) as usize; // 20
const TS_ERR_TIMEOUT_NS: u64 = 1_000_000_000; // 1s
const TS_PERIOD_TIMEOUT_NS: u64 = 100_000_000; // 100ms

const TS_MAGIC_INIT: u32 =
    ((b'i' as u32) << 24) | ((b'n' as u32) << 16) | ((b'i' as u32) << 8) | (b't' as u32);
// v1 layout (pre-padding) used magic ending in 'U'; v2 adds time_unit_ns field.
const TS_MAGIC_READY_V1: u32 =
    ((b'v' as u32) << 24) | ((b'N' as u32) << 16) | ((b'P' as u32) << 8) | (b'U' as u32);
const TS_MAGIC_READY: u32 =
    ((b'v' as u32) << 24) | ((b'N' as u32) << 16) | ((b'P' as u32) << 8) | (b'2' as u32);
const TS_TIME_UNIT_NS: u64 = 1_000_000; // 1ms, aligned with libmeminfo_shim TS_TIME_UNIT
const DEFAULT_CORE_ACQUIRE_TIMEOUT_SECS: u64 = 30;
const DEFAULT_CORE_BCK_TIMEOUT_SECS: u64 = 60;

#[repr(C)]
struct TsNode {
    period_check_ns: AtomicU64, // 0 means unused
}

// Layout aligned with libmeminfo_shim TsContext (magic, timeUnit, usedUnits, current, nodes).
#[repr(C)]
struct TsContext {
    magic_number: AtomicU32,
    _pad0: u32,
    time_unit_ns: AtomicU64,
    used_units: AtomicU32,
    _pad1: u32,
    current: AtomicI32,
    nodes: [TsNode; TS_MAX_NODES],
}

static CORE_LIMITER: OnceLock<Arc<CoreLimiter>> = OnceLock::new();

struct LiteSem {
    mu: Mutex<i32>,
    cv: std::sync::Condvar,
}

impl LiteSem {
    fn new(init: i32) -> Self {
        Self {
            mu: Mutex::new(init),
            cv: std::sync::Condvar::new(),
        }
    }
    fn release(&self, n: i32) {
        let mut g = self.mu.lock().unwrap();
        *g += n;
        self.cv.notify_all();
    }
    fn acquire(&self, n: i32) {
        let mut g = self.mu.lock().unwrap();
        while *g < n {
            g = self.cv.wait(g).unwrap();
        }
        *g -= n;
    }
    fn acquire_timeout(&self, n: i32, timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut g = self.mu.lock().unwrap();
        while *g < n {
            let now = std::time::Instant::now();
            if now >= deadline {
                return false;
            }
            g = self.cv.wait_timeout(g, deadline - now).unwrap().0;
        }
        *g -= n;
        true
    }
    fn acquire_all(&self) -> i32 {
        let mut g = self.mu.lock().unwrap();
        let c = *g;
        *g = 0;
        c
    }
    fn is_zero(&self) -> bool {
        *self.mu.lock().unwrap() == 0
    }
}

pub(crate) struct CoreLimiter {
    configured: bool,
    pub(crate) enabled: AtomicBool,
    percent: u32,
    batch_size: i32,
    die_id: String,
    hint_idx: i32,

    fwd: LiteSem,
    bck: LiteSem,

    shm_fd: i32,
    shm_addr: *mut libc::c_void,
    ctx: *mut TsContext,
    my_idx: i32,

    sched_end: AtomicBool,
}

unsafe impl Send for CoreLimiter {}
unsafe impl Sync for CoreLimiter {}

impl CoreLimiter {
    fn core_acquire_timeout() -> Duration {
        std::env::var("VXPU_CORE_ACQUIRE_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&s| s > 0)
            .map(Duration::from_secs)
            .unwrap_or(Duration::from_secs(DEFAULT_CORE_ACQUIRE_TIMEOUT_SECS))
    }

    fn core_bck_timeout() -> Duration {
        std::env::var("VXPU_CORE_BCK_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&s| s > 0)
            .map(Duration::from_secs)
            .unwrap_or(Duration::from_secs(DEFAULT_CORE_BCK_TIMEOUT_SECS))
    }

    fn now_ns() -> u64 {
        unsafe {
            let mut ts: libc::timespec = std::mem::zeroed();
            libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts);
            (ts.tv_sec as u64) * 1_000_000_000 + (ts.tv_nsec as u64)
        }
    }

    fn read_core_percent() -> Option<u32> {
        if let Ok(v) = std::env::var("VXPU_CORE_LIMIT_PERCENT") {
            if let Ok(p) = v.parse::<i32>() {
                if p > 0 && p < 100 {
                    return Some(p as u32);
                }
            }
        }
        // Compatibility fallback: treat NPU_PRIORITY as percent when present (common in this repo).
        if let Ok(v) = std::env::var("NPU_PRIORITY") {
            if let Ok(p) = v.parse::<i32>() {
                let p = p.clamp(1, 99);
                return Some(p as u32);
            }
        }
        None
    }

    fn read_batch_size() -> i32 {
        std::env::var("NPU_CORE_BATCH_SIZE")
            .ok()
            .and_then(|v| v.trim().parse::<i32>().ok())
            .filter(|&n| n > 0)
            .map(|n| n.min(1024))
            .unwrap_or(10)
    }

    /// Only processes that actually launch NPU kernels should join the timeslice scheduler.
    /// vLLM V1 EngineCore/APIServer preload libvnpu but must not steal TsContext slots.
    pub(crate) fn scheduler_eligible() -> bool {
        if let Ok(v) = std::env::var("VXPU_CORE_SCHEDULER") {
            let v = v.trim();
            if !v.is_empty() {
                return env_truthy("VXPU_CORE_SCHEDULER", true);
            }
        }
        if let Ok(role) = std::env::var("VXPU_WORKER_ROLE") {
            let role = role.trim().to_ascii_lowercase();
            if role == "worker" || role == "1" || role == "true" {
                return true;
            }
            if role == "control" || role == "0" || role == "false" {
                return false;
            }
        }
        if let Ok(cmdline) = std::fs::read("/proc/self/cmdline") {
            let joined = String::from_utf8_lossy(&cmdline).replace('\0', " ");
            let lower = joined.to_ascii_lowercase();
            if lower.contains("enginecore")
                || lower.contains("apiserver")
                || lower.contains("api_server")
            {
                return false;
            }
            if lower.contains("spawn_main")
                || lower.contains("gpu_worker")
                || lower.contains("gpuworker")
                || lower.contains("worker")
            {
                return true;
            }
        }
        true
    }

    fn sanitize_die_id(die_id: &str) -> String {
        let s: String = die_id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        if s.is_empty() {
            "global".to_string()
        } else {
            s
        }
    }

    fn read_die_id_and_idx() -> Option<(String, i32)> {
        // libmeminfo_shim: /etc/xpu/vnpu-ids.config contains "<dieId>-<idx>"
        if let Ok(s) = std::fs::read_to_string("/etc/xpu/vnpu-ids.config") {
            if let Some(line) = s.lines().next() {
                let line = line.trim();
                if !line.is_empty() {
                    if let Some((a, b)) = line.rsplit_once('-') {
                        if let Ok(idx) = b.parse::<i32>() {
                            return Some((a.to_string(), idx));
                        }
                    }
                    return Some((line.to_string(), 0));
                }
            }
        }
        if let Ok(vis) = std::env::var("ASCEND_RT_VISIBLE_DEVICES") {
            let v = vis.trim();
            if !v.is_empty() {
                let first = v.split(',').next().unwrap_or(v).to_string();
                return Some((first, 0));
            }
        }
        if let Ok(vis) = std::env::var("ASCEND_VISIBLE_DEVICES") {
            let v = vis.trim();
            if !v.is_empty() {
                // If list, take first entry.
                let first = v.split(',').next().unwrap_or(v).to_string();
                return Some((first, 0));
            }
        }
        None
    }

    fn valid_slot(idx: i32) -> Option<usize> {
        if idx >= 0 && (idx as usize) < TS_MAX_NODES {
            Some(idx as usize)
        } else {
            None
        }
    }

    unsafe fn reset_ctx(ctx: *mut TsContext) {
        (*ctx)
            .time_unit_ns
            .store(TS_TIME_UNIT_NS, Ordering::Relaxed);
        (*ctx).used_units.store(0, Ordering::Relaxed);
        (*ctx).current.store(0, Ordering::Relaxed);
        for i in 0..TS_MAX_NODES {
            (*ctx).nodes[i].period_check_ns.store(0, Ordering::Relaxed);
        }
        (*ctx).magic_number.store(TS_MAGIC_READY, Ordering::Release);
    }

    unsafe fn init_shared_memory(
        die_id: &str,
        hint_idx: i32,
        percent: u32,
        batch_size: i32,
    ) -> Option<(i32, *mut libc::c_void, *mut TsContext, i32)> {
        let name = format!("/{}", die_id);
        let c_name = std::ffi::CString::new(name).ok()?;
        let fd = libc::shm_open(c_name.as_ptr(), libc::O_CREAT | libc::O_RDWR, 0o600);
        if fd < 0 {
            return None;
        }
        let size = std::mem::size_of::<TsContext>() as libc::off_t;
        if libc::ftruncate(fd, size) != 0 {
            libc::close(fd);
            return None;
        }
        let addr = libc::mmap(
            std::ptr::null_mut(),
            std::mem::size_of::<TsContext>(),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        );
        if addr == libc::MAP_FAILED {
            libc::close(fd);
            return None;
        }
        let ctx = addr as *mut TsContext;

        // Init shared context (CAS protocol like NpuTimesliceScheduler).
        let begin = Self::now_ns();
        loop {
            let state = (*ctx).magic_number.load(Ordering::Acquire);
            if state == TS_MAGIC_READY {
                // Guard against stale/corrupt current index in existing shm.
                let cur = (*ctx).current.load(Ordering::Acquire);
                if Self::valid_slot(cur).is_none() {
                    (*ctx).current.store(0, Ordering::Release);
                }
                break;
            }
            if state == TS_MAGIC_READY_V1 {
                // Migrate v1 layout -> v2 by full reset.
                if (*ctx)
                    .magic_number
                    .compare_exchange(state, TS_MAGIC_INIT, Ordering::SeqCst, Ordering::Relaxed)
                    .is_ok()
                {
                    Self::reset_ctx(ctx);
                    break;
                }
                thread::yield_now();
                continue;
            }
            if state != TS_MAGIC_INIT && state != 0 {
                // Unknown/corrupt magic: attempt one-shot reclaim.
                if (*ctx)
                    .magic_number
                    .compare_exchange(state, TS_MAGIC_INIT, Ordering::SeqCst, Ordering::Relaxed)
                    .is_ok()
                {
                    warn!(
                        "[vnpu] core limiter: reclaiming corrupt TsContext magic=0x{:08x} shm=/{}",
                        state, die_id
                    );
                    Self::reset_ctx(ctx);
                    break;
                }
                thread::yield_now();
                continue;
            }
            if state == TS_MAGIC_INIT {
                if Self::now_ns().saturating_sub(begin) > TS_ERR_TIMEOUT_NS {
                    let _ = (*ctx).magic_number.compare_exchange(
                        state,
                        0,
                        Ordering::SeqCst,
                        Ordering::Relaxed,
                    );
                }
                thread::yield_now();
                continue;
            }
            if (*ctx)
                .magic_number
                .compare_exchange(state, TS_MAGIC_INIT, Ordering::SeqCst, Ordering::Relaxed)
                .is_err()
            {
                continue;
            }
            Self::reset_ctx(ctx);
            break;
        }

        let my_idx = Self::claim_slot(ctx, hint_idx);
        if my_idx < 0 {
            eprintln!(
                "[vnpu] core limiter: no TsContext slot available shm=/{}, pid={}",
                die_id,
                std::process::id()
            );
            libc::munmap(addr, std::mem::size_of::<TsContext>());
            libc::close(fd);
            return None;
        }
        eprintln!(
            "[vnpu] core limiter: shm=/{}, idx={}, quota={}%, batch={}, pid={}",
            die_id,
            my_idx,
            percent,
            batch_size,
            std::process::id()
        );

        Some((fd, addr, ctx, my_idx))
    }

    unsafe fn claim_slot(ctx: *mut TsContext, hint_idx: i32) -> i32 {
        let now = Self::now_ns();
        let try_idx = |i: usize| -> bool {
            let ts = (*ctx).nodes[i].period_check_ns.load(Ordering::Acquire);
            ts == 0 || now.saturating_sub(ts) > TS_ERR_TIMEOUT_NS
        };

        if hint_idx >= 0 && (hint_idx as usize) < TS_MAX_NODES {
            let i = hint_idx as usize;
            if try_idx(i) {
                (*ctx).nodes[i]
                    .period_check_ns
                    .store(now, Ordering::Release);
                return hint_idx;
            }
        }

        for i in 0..TS_MAX_NODES {
            if try_idx(i) {
                (*ctx).nodes[i]
                    .period_check_ns
                    .store(now, Ordering::Release);
                return i as i32;
            }
        }
        -1
    }

    pub(crate) fn ensure_started() -> Arc<Self> {
        CORE_LIMITER
            .get_or_init(|| {
                let percent = Self::read_core_percent().unwrap_or(0);
                let (die_id, hint_idx) = match Self::read_die_id_and_idx() {
                    Some((d, i)) => (Self::sanitize_die_id(&d), i),
                    None => ("global".to_string(), 0),
                };

                let configured = percent > 0 && percent < 100;
                let batch_size = Self::read_batch_size();

                let mut me = CoreLimiter {
                    configured,
                    enabled: AtomicBool::new(false),
                    percent,
                    batch_size,
                    die_id,
                    hint_idx,
                    fwd: LiteSem::new(0),
                    bck: LiteSem::new(0),
                    shm_fd: -1,
                    shm_addr: std::ptr::null_mut(),
                    ctx: std::ptr::null_mut(),
                    my_idx: -1,
                    sched_end: AtomicBool::new(false),
                };

                if !configured {
                    return Arc::new(me);
                }

                // Lazy-init like libmeminfo_shim: defer shm/thread until first kernel launch.
                Arc::new(me)
            })
            .clone()
    }

    pub(crate) fn lazy_init_if_needed(self: &Arc<Self>) {
        if !self.configured || self.enabled.load(Ordering::Relaxed) {
            return;
        }
        if !Self::scheduler_eligible() {
            return;
        }
        // Only one thread should init.
        static INIT_ONCE: std::sync::Once = std::sync::Once::new();
        let me = self.clone();
        INIT_ONCE.call_once(|| {
            unsafe {
                if let Some((fd, addr, ctx, my_idx)) =
                    Self::init_shared_memory(&me.die_id, me.hint_idx, me.percent, me.batch_size)
                {
                    // SAFETY: init thread owns mutable init; rest uses atomics.
                    let p = Arc::as_ptr(&me) as *mut CoreLimiter;
                    (*p).shm_fd = fd;
                    (*p).shm_addr = addr;
                    (*p).ctx = ctx;
                    (*p).my_idx = my_idx;
                    (*p).enabled.store(true, Ordering::Release);

                    let thread_me = me.clone();
                    thread::spawn(move || thread_me.scheduler_thread_main());
                } else {
                    eprintln!(
                        "[vnpu] core limiter shm init failed; disabled pid={}",
                        std::process::id()
                    );
                }
            }
        });
    }

    fn update_timestamp(&self) -> u64 {
        let now = Self::now_ns();
        unsafe {
            if !self.ctx.is_null() {
                if let Some(slot) = Self::valid_slot(self.my_idx) {
                    (*self.ctx).nodes[slot]
                        .period_check_ns
                        .store(now, Ordering::Release);
                }
            }
        }
        now
    }

    fn select_new_current(&self) {
        unsafe {
            if self.ctx.is_null() {
                return;
            }
            let Some(my_slot) = Self::valid_slot(self.my_idx) else {
                return;
            };
            let cur = (*self.ctx).current.load(Ordering::Acquire);
            let cur_slot = match Self::valid_slot(cur) {
                Some(s) => s,
                None => {
                    (*self.ctx).current.store(0, Ordering::Release);
                    0
                }
            };
            let cur_ts = (*self.ctx).nodes[cur_slot]
                .period_check_ns
                .load(Ordering::Acquire);
            let now = (*self.ctx).nodes[my_slot]
                .period_check_ns
                .load(Ordering::Acquire);
            if now.saturating_sub(cur_ts) <= TS_ERR_TIMEOUT_NS {
                return;
            }
            let mut best = my_slot;
            let mut best_ts = now;
            for i in 0..TS_MAX_NODES {
                let ts = (*self.ctx).nodes[i].period_check_ns.load(Ordering::Acquire);
                if ts == 0 || now.saturating_sub(ts) > TS_ERR_TIMEOUT_NS {
                    continue;
                }
                if best_ts < ts {
                    continue;
                }
                best = i;
                best_ts = ts;
            }
            let _ = (*self.ctx).current.compare_exchange(
                cur,
                best as i32,
                Ordering::SeqCst,
                Ordering::Relaxed,
            );
        }
    }

    fn check_current(&self) -> bool {
        unsafe {
            if self.ctx.is_null() || Self::valid_slot(self.my_idx).is_none() {
                return true;
            }
            if (*self.ctx).current.load(Ordering::Acquire) == self.my_idx {
                return true;
            }
            self.select_new_current();
            (*self.ctx).current.load(Ordering::Acquire) == self.my_idx
        }
    }

    fn release_current(&self) {
        unsafe {
            let Some(my_slot) = Self::valid_slot(self.my_idx) else {
                return;
            };
            if self.ctx.is_null() {
                return;
            }
            let now = (*self.ctx).nodes[my_slot]
                .period_check_ns
                .load(Ordering::Acquire);
            let mut cur = self.my_idx;
            for i in 1..TS_MAX_NODES {
                let next = ((cur as usize) + i) % TS_MAX_NODES;
                let ts = (*self.ctx).nodes[next]
                    .period_check_ns
                    .load(Ordering::Acquire);
                if ts == 0 || now.saturating_sub(ts) > TS_PERIOD_TIMEOUT_NS {
                    continue;
                }
                if (*self.ctx)
                    .current
                    .compare_exchange(cur, next as i32, Ordering::SeqCst, Ordering::Relaxed)
                    .is_ok()
                {
                    return;
                }
                cur = (*self.ctx).current.load(Ordering::Acquire);
                if Self::valid_slot(cur).is_none() {
                    (*self.ctx).current.store(0, Ordering::Release);
                    cur = 0;
                }
            }
        }
    }

    fn drain_bck_or_reset(&self, used: i32) {
        if used <= 0 {
            return;
        }
        let timeout = Self::core_bck_timeout();
        if self.bck.acquire_timeout(used, timeout) {
            return;
        }
        warn!(
            "[vnpu] core limiter: bck acquire timed out used={} after {:?} pid={} reset batch",
            used,
            timeout,
            std::process::id()
        );
        let _ = self.bck.acquire_all();
    }

    fn execute_slice(&self, begin_ns: u64, slice_ns: u64) -> u64 {
        let mut budget_added = false;
        let mut end_ns = begin_ns;
        loop {
            if !budget_added {
                self.fwd.release(self.batch_size);
                budget_added = true;
            }
            thread::yield_now();
            if self.fwd.is_zero() {
                let remaining = self.fwd.acquire_all();
                let used = self.batch_size - remaining;
                self.drain_bck_or_reset(used);
                budget_added = false;
            }
            end_ns = self.update_timestamp();
            if end_ns.saturating_sub(begin_ns) >= slice_ns {
                break;
            }
        }
        if budget_added {
            let remaining = self.fwd.acquire_all();
            let used = self.batch_size - remaining;
            self.drain_bck_or_reset(used);
        }
        self.update_timestamp()
    }

    fn execute_idle_time(&self, last_used: &mut u32, last_valid: &mut bool) {
        unsafe {
            if self.ctx.is_null() {
                return;
            }
            let used = (*self.ctx)
                .used_units
                .fetch_add(self.percent, Ordering::Relaxed)
                .wrapping_add(self.percent);
            if !*last_valid {
                *last_used = used;
                *last_valid = true;
                return;
            }
            let period_used = used.wrapping_sub(*last_used);
            if period_used == 0 || period_used > TS_PERIOD_UNITS {
                return;
            }
            let period_idle = TS_PERIOD_UNITS - period_used;
            // idleTime = 1ms * idle * quotaPct / used
            let idle_ms = (period_idle as u64)
                .saturating_mul(self.percent as u64)
                .saturating_div(period_used as u64);
            if idle_ms > 0 {
                thread::sleep(std::time::Duration::from_millis(idle_ms));
            }
            *last_used = used;
        }
    }

    fn scheduler_thread_main(self: Arc<Self>) {
        // Wait until ctx appears or end requested.
        while self.enabled.load(Ordering::Acquire)
            && self.ctx.is_null()
            && !self.sched_end.load(Ordering::Relaxed)
        {
            thread::yield_now();
        }
        if !self.enabled.load(Ordering::Acquire) {
            return;
        }

        let quota_ns = (self.percent as u64) * 1_000_000; // 1ms units
        let mut current_slice_ns = quota_ns;
        let mut last_used: u32 = 0;
        let mut last_valid = false;

        while !self.sched_end.load(Ordering::Relaxed) {
            let begin = self.update_timestamp();
            if !self.check_current() {
                thread::sleep(Duration::from_millis(1));
                continue;
            }
            let end = self.execute_slice(begin, current_slice_ns);
            let spent = end.saturating_sub(begin);
            let overdraft = spent.saturating_sub(current_slice_ns);
            current_slice_ns = quota_ns.saturating_sub(overdraft);
            self.execute_idle_time(&mut last_used, &mut last_valid);
            self.release_current();
        }

        unsafe {
            if !self.ctx.is_null() {
                if let Some(slot) = Self::valid_slot(self.my_idx) {
                    (*self.ctx).nodes[slot]
                        .period_check_ns
                        .store(0, Ordering::Release);
                }
            }
        }
    }

    pub(crate) fn acquire_one(&self) -> bool {
        if !self.configured {
            return false;
        }
        if !self.enabled.load(Ordering::Acquire) {
            return false;
        }
        let timeout = Self::core_acquire_timeout();
        let ok = self.fwd.acquire_timeout(1, timeout);
        if !ok {
            warn!(
                "[vnpu] core limiter: token acquire timed out after {:?} pid={} passthrough",
                timeout,
                std::process::id()
            );
        }
        ok
    }

    fn ack_one(&self) {
        if !self.enabled.load(Ordering::Acquire) {
            return;
        }
        self.bck.release(1);
    }
}

pub struct CoreGuard {
    limiter: Arc<CoreLimiter>,
    acquired: bool,
}

impl CoreGuard {
    pub(crate) fn new(limiter: Arc<CoreLimiter>, acquired: bool) -> Self {
        Self { limiter, acquired }
    }

    pub(crate) fn acquired(&self) -> bool {
        self.acquired
    }
}

impl Drop for CoreGuard {
    fn drop(&mut self) {
        if self.acquired {
            self.limiter.ack_one();
        }
    }
}
