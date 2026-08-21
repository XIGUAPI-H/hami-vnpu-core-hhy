use std::sync::atomic::Ordering;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use log::{debug, info};

use crate::config::ManagerConfig;
use crate::kylin_preset;
use crate::shmem::{
    GlobalRegistry, LocalContainerShmem, MAX_MANAGERS, MAX_WORKERS, STATE_IDLE, STATE_MEASURING,
    STATE_RUNNING, futex,
};

const GLOBAL_WAIT_POLL_US: u64 = 1_000;
// How long the manager waits in MEASURING for workers to report.
// Was 50ms, which was too short when kernels take hundreds of ms; make it longer
// and also extend dynamically in the run loop.
const LOCAL_REPORT_GRACE_MS: u64 = 500;
const MIN_TOKENS: u64 = 1;
const MAX_TOKENS: u64 = 2_000_000;
// Seed per-manager average; used both locally and when registering in the global scoreboard.
const DEFAULT_AVG_US: u64 = 500;
// Gemini-style burst estimation defaults (IEEE TCC 2021).
const DEFAULT_BURST_ALPHA: f64 = 0.3;
const BURST_EXTEND_MIN_CONSUMED: u64 = 8;
const BURST_CAP_MULTIPLIER_DEFAULT: u64 = 4;
const BURST_CAP_MULTIPLIER_LLM: u64 = 16;
// FCSP-style continuous token bucket refill (BUD-FCSP / GPU-Virt-Bench OH-008).
const DEFAULT_FCSP_REFILL_INTERVAL_US: u64 = 100;
/// vCANN-RT elastic: micro-sleep per borrow slice when competitors are idle.
const ELASTIC_BORROW_SLICE_US: u64 = 500;
const ELASTIC_IDLE_GRACE_US: u64 = 300;
const ELASTIC_BORROW_TOKEN_MUL: u64 = 4;
const ELASTIC_SOLO_TOKEN_MUL: u64 = 8;
const TOKEN_EMPTY_ACTIVE_GRACE_US: u64 = 5_000;
// Batches measured via wall-clock (ACL-graph capture, LLM light measure) report the
// whole decode window divided by token count — orders of magnitude above real
// per-kernel GPU time (~500us). Origin never hit this because it almost always
// takes the GPU-event path; optimized FCSP/burst/LLM paths hit MEASURING more often
// and fall back to wall-clock, which then inflates anchor_avg and rest_wait.
const MAX_STAT_KERNEL_AVG_US: u64 = 50_000;
// Absolute ceiling for a single fixed-share rest window (see NPU_MAX_REST_WAIT_US).
const DEFAULT_MAX_REST_WAIT_US: u64 = 2_000_000;

const MB_TO_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SchedPolicy {
    /// Strict proportional timeslice (NPU_FIXED_SHARE_RATIO=1 semantics).
    Fixed,
    /// Skip idle timeslice + borrow when others idle (vCANN-RT elastic).
    Elastic,
    /// No compute wait unless another tenant wants the device (AntMan opportunistic).
    BestEffort,
}

#[derive(Debug, Clone, Copy)]
struct SharePlan {
    tokens: u64,
    time_limit_us: u64,
    base_tokens: u64,
    expected_run_us: u64,
    rest_wait_us: u64,
    #[allow(dead_code)]
    anchor_speed_us: u64,
}

pub struct ContainerManager {
    global: &'static GlobalRegistry,
    local: &'static LocalContainerShmem,
    #[allow(dead_code)]
    my_pid: i32,
    my_global_idx: usize,
    current_avg_us: u64,
    my_priority: f64,
    token_scale: f64,
    ema_alpha: f64,
    fixed_share_ratio: bool,
    max_rest_wait_us: u64,
    next_run_not_before: Option<Instant>,
    /// Peak kernels consumed in a single batch (for burst estimation).
    burst_max_tokens: u64,
    /// Last batch kernel count (burst length proxy).
    burst_last_tokens: u64,
    burst_alpha: f64,
    burst_continuous: bool,
    fcsp_refill: bool,
    fcsp_refill_interval_us: u64,
    llm_mode: bool,
    sched_policy: SchedPolicy,
    fikit_mode: bool,
    iteration_sched: bool,
}

impl ContainerManager {
    pub fn new(
        global: &'static GlobalRegistry,
        local: &'static LocalContainerShmem,
        pid: i32,
        config: ManagerConfig,
    ) -> Self {
        let idx = Self::register_global_slot(global, pid);

        // TODO: Refactor
        let token_scale = std::env::var("NPU_TOKEN_SCALE")
            .unwrap_or_else(|_| "100.0".to_string())
            .parse::<f64>()
            .unwrap_or(1.0)
            .max(0.1);
        // Faster EMA by default.
        let ema_alpha = std::env::var("NPU_AVG_ALPHA")
            .unwrap_or_else(|_| "0.7".to_string())
            .parse::<f64>()
            .unwrap_or(0.7)
            .clamp(0.05, 0.95);
        let fixed_share_ratio = std::env::var("NPU_FIXED_SHARE_RATIO")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let max_rest_wait_us = std::env::var("NPU_MAX_REST_WAIT_US")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&v| v > 0)
            .unwrap_or(DEFAULT_MAX_REST_WAIT_US);
        let burst_alpha = std::env::var("NPU_BURST_ALPHA")
            .unwrap_or_else(|_| format!("{DEFAULT_BURST_ALPHA}"))
            .parse::<f64>()
            .unwrap_or(DEFAULT_BURST_ALPHA)
            .clamp(0.05, 0.95);
        let burst_continuous = std::env::var("NPU_BURST_CONTINUOUS")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("on"))
            .unwrap_or(false);
        let llm_mode = kylin_preset::env_bool_kylin_lite("NPU_LLM_MODE", false, true, false);
        let burst_continuous = burst_continuous || llm_mode;
        let fcsp_refill = kylin_preset::env_bool_kylin_lite("NPU_FCSP_REFILL", false, false, true);
        let fcsp_refill_interval_us = std::env::var("NPU_FCSP_REFILL_INTERVAL_US")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(DEFAULT_FCSP_REFILL_INTERVAL_US)
            .clamp(20, 10_000);
        let sched_policy = parse_sched_policy(&fixed_share_ratio, llm_mode);
        let fikit_mode =
            kylin_preset::env_bool_kylin_lite("NPU_FIKIT_MODE", false, false, llm_mode);
        let iteration_sched =
            kylin_preset::env_bool_kylin_lite("NPU_ITERATION_SCHED", false, false, llm_mode);

        // default value
        let comp_priority = config.priority;
        let memory_limit = config.memory_limit_mb;

        info!(
            "[Manager] Registered as Global Manager #{} (PID: {}). Compute limit: {}, Memory limit: {}, Policy: {:?}, FixedShare: {}, LLM: {}, FIKIT: {}, IterSched: {}, KylinLite: {}, KylinPreset: {}",
            idx,
            pid,
            comp_priority,
            memory_limit,
            sched_policy,
            fixed_share_ratio,
            llm_mode,
            fikit_mode,
            iteration_sched,
            kylin_preset::kylin_lite_active(),
            kylin_preset::kylin_preset_active()
        );

        let memory_limit_bytes = memory_limit * MB_TO_BYTES;

        // Initialize
        local
            .memory_limit
            .store(memory_limit_bytes, Ordering::Relaxed);
        local.memory_used.store(0, Ordering::Relaxed);
        local.global_slot_idx.store(idx as u32, Ordering::Relaxed);
        local.workers_waiting.store(0, Ordering::Relaxed);

        Self {
            global,
            local,
            my_pid: pid,
            my_global_idx: idx,
            current_avg_us: DEFAULT_AVG_US,
            my_priority: comp_priority,
            token_scale,
            ema_alpha,
            fixed_share_ratio,
            max_rest_wait_us,
            next_run_not_before: None,
            burst_max_tokens: 0,
            burst_last_tokens: 0,
            burst_alpha,
            burst_continuous,
            fcsp_refill,
            fcsp_refill_interval_us,
            llm_mode,
            sched_policy,
            fikit_mode,
            iteration_sched,
        }
    }

    fn parse_sched_policy_from_env() -> Option<SchedPolicy> {
        parse_sched_policy_env()
    }

    fn competitors_want_compute(&self) -> bool {
        self.global.slots.iter().enumerate().any(|(i, slot)| {
            i != self.my_global_idx
                && slot.is_active.load(Ordering::Relaxed) == 1
                && slot.wants_compute.load(Ordering::Relaxed) > 0
        })
    }

    fn elastic_borrow_tokens(&self, plan: &SharePlan) -> u64 {
        if self.sched_policy != SchedPolicy::Elastic {
            return 0;
        }
        if self.competitors_want_compute() {
            return 0;
        }
        let tenants = self.active_tenant_count().max(1) as u64;
        if tenants == 1 {
            plan.tokens
                .saturating_mul(ELASTIC_SOLO_TOKEN_MUL)
                .min(MAX_TOKENS)
        } else {
            plan.tokens
                .saturating_mul(ELASTIC_BORROW_TOKEN_MUL)
                .min(MAX_TOKENS)
        }
    }

    fn mirror_worker_signals(&self) {
        let waiting = self.local.workers_waiting.load(Ordering::Relaxed);
        let active = self.local.active_workers.load(Ordering::Relaxed);
        self.global.slots[self.my_global_idx]
            .wants_compute
            .store(waiting, Ordering::Relaxed);
        self.global.slots[self.my_global_idx]
            .workers_active
            .store(active, Ordering::Relaxed);
    }

    fn register_global_slot(global: &'static GlobalRegistry, pid: i32) -> usize {
        for (i, slot) in global.slots.iter().enumerate() {
            if slot
                .is_active
                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::Relaxed)
                .is_ok()
            {
                slot.pid.store(pid, Ordering::Relaxed);
                slot.avg_kernel_time
                    .store(DEFAULT_AVG_US, Ordering::Relaxed);
                slot.last_heartbeat.store(get_time_us(), Ordering::Relaxed);
                return i;
            }
        }

        panic!("Global registry full. Increase MAX_MANAGERS.");
    }

    fn active_tenant_count(&self) -> usize {
        self.global
            .slots
            .iter()
            .filter(|s| s.is_active.load(Ordering::Relaxed) == 1)
            .count()
    }

    pub fn run(&mut self) {
        self.join_global_queue();

        loop {
            self.wait_for_global_turn();
            self.update_heartbeat();
            self.mirror_worker_signals();
            self.honor_fixed_rest_wait();

            let plan = self.calculate_fair_share();
            let (actual_duration, tokens_used) = self.run_local_round(&plan);

            if tokens_used > 0 && actual_duration > 0 {
                self.update_local_stats(actual_duration, tokens_used);
            }
            self.schedule_rest_wait(plan.rest_wait_us);
            self.pass_baton();
        }
    }

    fn join_global_queue(&self) {
        let tail = self.global.queue_tail.fetch_add(1, Ordering::SeqCst) as usize;
        let slot_idx = tail % MAX_MANAGERS;
        self.global.queue[slot_idx].store(self.my_global_idx as u32, Ordering::Release);
    }

    fn wait_for_global_turn(&self) {
        loop {
            let owner_idx = self.global.lock_owner.load(Ordering::Acquire);
            if owner_idx == self.my_global_idx as u32 {
                return;
            }

            // If the recorded owner is invalid or already marked inactive, claim immediately.
            let owner_active = (owner_idx as usize) < MAX_MANAGERS
                && self.global.slots[owner_idx as usize]
                    .is_active
                    .load(Ordering::Relaxed)
                    == 1;
            if !owner_active {
                if self
                    .global
                    .lock_owner
                    .compare_exchange(
                        owner_idx,
                        self.my_global_idx as u32,
                        Ordering::SeqCst,
                        Ordering::Relaxed,
                    )
                    .is_ok()
                {
                    self.update_heartbeat();
                    return;
                }
            }

            let last_heartbeat = self.global.lock_timestamp.load(Ordering::Relaxed);
            let now = get_time_us();

            if (now > last_heartbeat)
                && (now - last_heartbeat > kylin_preset::global_watchdog_timeout_us())
            {
                info!(
                    "[Manager] detected stale owner {}; attempting to claim global lock",
                    owner_idx
                );
                if (owner_idx as usize) < MAX_MANAGERS {
                    self.global.slots[owner_idx as usize]
                        .is_active
                        .store(0, Ordering::Relaxed);
                }
                if self
                    .global
                    .lock_owner
                    .compare_exchange(
                        owner_idx,
                        self.my_global_idx as u32,
                        Ordering::SeqCst,
                        Ordering::Relaxed,
                    )
                    .is_ok()
                {
                    self.update_heartbeat();
                    return;
                }
            }

            let current_sig = self.global.signal_counter.load(Ordering::Relaxed);
            if self.global.lock_owner.load(Ordering::Relaxed) == self.my_global_idx as u32 {
                return;
            }

            futex::wait_timeout(
                &self.global.signal_counter,
                current_sig,
                GLOBAL_WAIT_POLL_US,
            );
        }
    }

    fn pass_baton(&self) {
        // Re-enqueue ourselves before handing off to guarantee the next slot is initialized.
        self.join_global_queue();

        // Advance the head to the next queued slot.
        let mut next_head = self.global.queue_head.load(Ordering::Relaxed) as usize + 1;

        // Default to self; the scan may also select our own re-enqueued slot.
        let mut next_manager_idx = self.my_global_idx as u32;
        for _ in 0..MAX_MANAGERS {
            let slot_idx = next_head % MAX_MANAGERS;
            let candidate = self.global.queue[slot_idx].load(Ordering::Acquire);

            if (candidate as usize) < MAX_MANAGERS
                && self.global.slots[candidate as usize]
                    .is_active
                    .load(Ordering::Relaxed)
                    == 1
            {
                next_manager_idx = candidate;
                break;
            }

            // Stale entry: move forward and keep looking.
            next_head += 1;
        }

        // Commit the head to the slot we actually consumed.
        self.global
            .queue_head
            .store(next_head as u32, Ordering::Release);

        // Hand off ownership and wake any waiters.
        self.global
            .lock_owner
            .store(next_manager_idx, Ordering::Release);
        self.global.signal_counter.fetch_add(1, Ordering::Release);
        futex::wake_all(&self.global.signal_counter);
    }

    fn apply_burst_sizing(&self, fair_tokens: u64) -> u64 {
        if self.burst_last_tokens < BURST_EXTEND_MIN_CONSUMED {
            return fair_tokens;
        }
        let est = (self.burst_alpha * self.burst_max_tokens as f64
            + (1.0 - self.burst_alpha) * self.burst_last_tokens as f64)
            .ceil() as u64;
        let boosted = fair_tokens.max(est);
        let cap_mul = if self.llm_mode {
            BURST_CAP_MULTIPLIER_LLM
        } else {
            BURST_CAP_MULTIPLIER_DEFAULT
        };
        boosted
            .min(fair_tokens.saturating_mul(cap_mul).max(fair_tokens))
            .clamp(MIN_TOKENS, MAX_TOKENS)
    }

    fn estimate_burst_extension(&self, plan: &SharePlan) -> u64 {
        let est = if self.burst_last_tokens > 0 {
            (self.burst_alpha * self.burst_max_tokens as f64
                + (1.0 - self.burst_alpha) * self.burst_last_tokens as f64)
                .ceil() as u64
        } else {
            plan.tokens
        };
        est.max(BURST_EXTEND_MIN_CONSUMED).min(MAX_TOKENS).min(
            plan.tokens
                .saturating_mul(if self.llm_mode { 8 } else { 2 })
                .max(BURST_EXTEND_MIN_CONSUMED),
        )
    }

    fn should_extend_burst_batch(
        &self,
        plan: &SharePlan,
        start_time: Instant,
        initial_tokens: u64,
        tokens_consumed: u64,
    ) -> bool {
        if !self.burst_continuous || self.burst_last_tokens == 0 {
            return false;
        }
        if tokens_consumed < BURST_EXTEND_MIN_CONSUMED {
            return false;
        }
        if tokens_consumed + 1 < initial_tokens {
            return false;
        }
        let budget = Duration::from_micros(plan.expected_run_us);
        let elapsed = start_time.elapsed();
        elapsed < budget / 4 || elapsed < Duration::from_millis(2)
    }

    fn calculate_fair_share(&self) -> SharePlan {
        // Anchor is the slowest active; never let it fall below 1us to preserve relativity.
        let mut anchor_speed_us = 1u64;

        for slot in self.global.slots.iter() {
            if slot.is_active.load(Ordering::Relaxed) == 1 {
                let time = slot.avg_kernel_time.load(Ordering::Relaxed);
                if time > anchor_speed_us {
                    anchor_speed_us = time;
                }
            }
        }

        let my_time = self.current_avg_us.max(1);
        // Allow sub-1.0 priorities to act as fractions only when fixed-share is requested.
        let prio_for_tokens = if self.fixed_share_ratio {
            self.my_priority.max(0.01)
        } else {
            self.my_priority.max(1.0)
        };

        // Base tokens before scaling (used for time budgeting and averaging).
        // Formula: tokens = priority * (anchor / my_time)
        let raw_tokens = prio_for_tokens * (anchor_speed_us as f64 / my_time as f64);
        let mut base_tokens = raw_tokens.ceil() as u64;
        base_tokens = base_tokens.clamp(MIN_TOKENS, MAX_TOKENS);

        // Apply scaling for how many tokens we allow to launch.
        let mut tokens = (base_tokens as f64 * self.token_scale) as u64;
        tokens = self.apply_burst_sizing(tokens);
        if self.sched_policy == SchedPolicy::Elastic && !self.competitors_want_compute() {
            let tenants = self.active_tenant_count().max(1) as u64;
            let mul = if tenants == 1 {
                ELASTIC_SOLO_TOKEN_MUL
            } else {
                ELASTIC_BORROW_TOKEN_MUL
            };
            tokens = tokens.saturating_mul(mul).min(MAX_TOKENS);
        }
        tokens = tokens.clamp(MIN_TOKENS, MAX_TOKENS);

        // Time budget should reflect the scaled tokens actually handed out.
        let mut expected_run_us = tokens.saturating_mul(my_time);

        // Fixed-share duty cycle: rest/run = (100-p)/p. Derive rest from the same
        // run budget (expected_run_us) that this round will actually use, NOT from
        // anchor_speed * token_scale. The old formula shared origin's shape but
        // coupled rest to global anchor_avg; when wall-clock batches inflated
        // anchor_avg to milliseconds, rest hit 60s and wedged vLLM workers.
        let mut rest_wait_us = 0u64;
        if self.fixed_share_ratio || self.sched_policy == SchedPolicy::Fixed {
            let p = self.my_priority.clamp(1.0, 100.0);
            let ideal_rest = (expected_run_us as f64 * (100.0 - p)) / p;
            if ideal_rest > self.max_rest_wait_us as f64 {
                // Clipping the rest window alone silently raises the duty cycle:
                // origin computes the full rest and honours it, so a 1250ms run at
                // p=25 rests 3750ms (25.0%), while clipping at 2s yields 38.5%. At
                // p=5 the same clip gives 11% instead of 5%. Shrink the run window
                // by the same factor, so the cap bounds how long a slice may be
                // without changing the share that was asked for.
                let shrink = self.max_rest_wait_us as f64 / ideal_rest;
                tokens = ((tokens as f64 * shrink).round() as u64).clamp(MIN_TOKENS, MAX_TOKENS);
                expected_run_us = tokens.saturating_mul(my_time);
                rest_wait_us = self.max_rest_wait_us;
            } else {
                rest_wait_us = ideal_rest.round() as u64;
            }
        }

        let timeout_us = expected_run_us + (expected_run_us / 2) + 50_000;

        debug!(
            "[Sched] Anchor: {}us, MyAvg: {}us, Prio: {}, BaseTokens: {}, Scale: {}, FinalTokens: {}, Timeout: {}ms, Rest: {}ms",
            anchor_speed_us,
            my_time,
            self.my_priority,
            base_tokens,
            self.token_scale,
            tokens,
            timeout_us / 1000,
            rest_wait_us / 1000
        );

        SharePlan {
            tokens,
            time_limit_us: timeout_us,
            base_tokens,
            expected_run_us: expected_run_us.max(1),
            rest_wait_us,
            anchor_speed_us,
        }
    }

    fn start_local_batch(&self, batch_id: u64, tokens: u64) {
        self.local.batch_id.store(batch_id, Ordering::Relaxed);
        self.local.tokens_remaining.store(tokens, Ordering::Relaxed);
        self.local
            .outstanding_token_debt
            .store(0, Ordering::Relaxed);
        self.local.active_workers.store(0, Ordering::Relaxed);
        self.local.reported_count.store(0, Ordering::Relaxed);

        self.local.state.store(STATE_RUNNING, Ordering::Release);
        futex::wake_all(&self.local.state);
    }

    fn enter_measuring_state(&self) {
        self.local.tokens_remaining.store(0, Ordering::Relaxed);
        self.update_heartbeat();
        self.local.state.store(STATE_MEASURING, Ordering::Release);
        futex::wake_all(&self.local.state);
    }

    fn finish_local_batch(&self) {
        // Keep the global contention signal honest between rounds. Without this,
        // workers_active can remain non-zero until the next start_local_batch reset,
        // making other tenants think this container is still executing kernels.
        self.local.active_workers.store(0, Ordering::Release);
        self.mirror_worker_signals();
    }

    /// FCSP continuous token-bucket refill while staying in RUNNING (avoids MEASURING churn).
    fn fcsp_refill_tokens(&self, plan: &SharePlan, last_refill: &mut Instant) -> u64 {
        if !self.fcsp_refill {
            return 0;
        }
        let now = Instant::now();
        // Solo + continuous: deliver the quota in finer increments so the duty
        // cycle tracks hard-split's constant fraction more tightly (smaller
        // sawtooth -> lower TPOT jitter). CPU is plentiful on the 192-core
        // Kunpeng-920 host, so a tighter cadence is essentially free here.
        let effective_interval_us = if self.burst_continuous && self.active_tenant_count() <= 1 {
            (self.fcsp_refill_interval_us / 2).max(20)
        } else {
            self.fcsp_refill_interval_us
        };
        let interval = Duration::from_micros(effective_interval_us);
        let since = now.duration_since(*last_refill);
        if since < interval {
            return 0;
        }
        *last_refill = now;

        let delta_us = since.as_micros().min(u64::MAX as u128) as u64;
        let budget = plan.expected_run_us.max(1);
        let base_rate = plan.base_tokens as f64 / budget as f64;
        let prio = self.my_priority.max(1.0) / 100.0;
        let add = (base_rate * prio * delta_us as f64).floor() as u64;
        if add == 0 {
            return 0;
        }

        let cap = self.apply_burst_sizing(plan.tokens);
        let current = self.local.tokens_remaining.load(Ordering::Relaxed);
        if current >= cap {
            return 0;
        }
        let new_val = (current.saturating_add(add)).min(cap);
        let added = new_val.saturating_sub(current);
        if added == 0 {
            return 0;
        }
        self.local
            .tokens_remaining
            .store(new_val, Ordering::Release);
        futex::wake_all(&self.local.state);
        debug!(
            "[Manager] FCSP refill +{} tokens (bucket {}/{})",
            added, new_val, cap
        );
        added
    }

    fn run_local_round(&self, plan: &SharePlan) -> (u64, u64) {
        let tokens = plan.tokens;
        let base_tokens = plan.base_tokens;
        let batch_id = self.local.batch_id.load(Ordering::Relaxed) + 1;
        debug!("\n=======================================================");
        debug!(
            "[Manager] >>> Start Batch ID: {}. initial Tokens: {}, base_tokens: {}, time_limit: {} us, budget: {} us",
            batch_id, tokens, base_tokens, plan.time_limit_us, plan.expected_run_us
        );

        self.start_local_batch(batch_id, tokens);

        let start_time = Instant::now();
        let timeout_duration = Duration::from_micros(plan.time_limit_us);
        let budget_duration = Duration::from_micros(plan.expected_run_us);
        let mt_fast = self.llm_mode && self.active_tenant_count() > 1;
        let mut saw_progress = false;
        let mut last_tokens = tokens;
        let mut tokens_consumed_for_stats = 0u64;
        let mut total_tokens_issued = tokens;
        let mut last_refill = Instant::now();
        let mut token_empty_active_since: Option<Instant> = None;

        loop {
            let refill_add = self.fcsp_refill_tokens(plan, &mut last_refill);
            if refill_add > 0 {
                total_tokens_issued = total_tokens_issued.saturating_add(refill_add);
            }

            let current_tokens = self.local.tokens_remaining.load(Ordering::Relaxed);
            let outstanding = self.local.outstanding_token_debt.load(Ordering::Acquire);
            let active_workers = self.local.active_workers.load(Ordering::Relaxed);

            if current_tokens == 0 && (outstanding > 0 || active_workers > 0) {
                let stalled_for = token_empty_active_since
                    .get_or_insert_with(Instant::now)
                    .elapsed();
                if stalled_for >= Duration::from_micros(TOKEN_EMPTY_ACTIVE_GRACE_US) {
                    debug!(
                        "[Manager] --- Token empty while active/outstanding for {:?}; enter STATE_MEASURING (outstanding={}, active={})",
                        stalled_for, outstanding, active_workers
                    );
                    tokens_consumed_for_stats = total_tokens_issued;
                    break;
                }
                thread::sleep(Duration::from_micros(if mt_fast { 5 } else { 50 }));
                continue;
            }
            token_empty_active_since = None;

            if current_tokens == 0 {
                if self.fcsp_refill_tokens(plan, &mut last_refill) > 0 {
                    continue;
                }
                let consumed = total_tokens_issued;
                if self.should_extend_burst_batch(plan, start_time, total_tokens_issued, consumed) {
                    let extension = self.estimate_burst_extension(plan);
                    debug!(
                        "[Manager] --- burst extend +{} tokens (consumed {}, elapsed {:?})",
                        extension,
                        consumed,
                        start_time.elapsed()
                    );
                    self.local
                        .tokens_remaining
                        .store(extension, Ordering::Release);
                    total_tokens_issued = total_tokens_issued.saturating_add(extension);
                    futex::wake_all(&self.local.state);
                    last_tokens = extension;
                    continue;
                }
                if self.sched_policy == SchedPolicy::Elastic {
                    let borrow = self.elastic_borrow_tokens(plan);
                    if borrow > 0 {
                        debug!(
                            "[Manager] --- elastic borrow +{} tokens (no competitors)",
                            borrow
                        );
                        self.local.tokens_remaining.store(borrow, Ordering::Release);
                        total_tokens_issued = total_tokens_issued.saturating_add(borrow);
                        futex::wake_all(&self.local.state);
                        last_tokens = borrow;
                        thread::sleep(Duration::from_micros(ELASTIC_BORROW_SLICE_US));
                        continue;
                    }
                }
                debug!("[Manager] --- Token all used, enter STATE_MEASURING ");
                break;
            }

            if self.fixed_share_ratio {
                if start_time.elapsed() >= budget_duration {
                    tokens_consumed_for_stats = total_tokens_issued.saturating_sub(current_tokens);
                    break;
                }
            } else {
                if current_tokens < last_tokens || active_workers > 0 {
                    saw_progress = true;
                }
                let idle_grace = if self.sched_policy == SchedPolicy::Elastic {
                    // Solo + continuous: stay RUNNING across decode-step gaps to avoid
                    // MEASURING→IDLE→RUNNING churn that adds per-token wakeup latency.
                    if self.burst_continuous && self.active_tenant_count() <= 1 {
                        Duration::from_millis(200)
                    } else {
                        Duration::from_micros(ELASTIC_IDLE_GRACE_US)
                    }
                } else if self.llm_mode && self.burst_continuous {
                    if self.active_tenant_count() <= 1 {
                        Duration::from_secs(86400)
                    } else {
                        Duration::from_millis(20)
                    }
                } else if self.llm_mode {
                    Duration::from_millis(200)
                } else {
                    Duration::from_millis(5)
                };
                if !saw_progress
                    && active_workers == 0
                    && outstanding == 0
                    && start_time.elapsed() > idle_grace
                {
                    debug!(
                        "[Manager] --- no progress for {:?}, enter STATE_MEASURING early",
                        idle_grace
                    );
                    break;
                }
            }
            last_tokens = current_tokens;

            if start_time.elapsed() > timeout_duration {
                let remaining = self.local.tokens_remaining.load(Ordering::Relaxed);
                if remaining < total_tokens_issued {
                    debug!(
                        "[Manager] --- time up! Remaining Token: {}/{}.",
                        remaining, total_tokens_issued
                    );
                }
                tokens_consumed_for_stats = total_tokens_issued.saturating_sub(remaining);
                break;
            }
            self.update_heartbeat();
            self.mirror_worker_signals();
            thread::sleep(Duration::from_micros(50));
        }

        // Capture how many tokens were actually spent before we zero-out the bucket.
        if tokens_consumed_for_stats == 0 {
            let remaining = self.local.tokens_remaining.load(Ordering::Relaxed);
            tokens_consumed_for_stats = total_tokens_issued.saturating_sub(remaining);
        }

        if self.fikit_mode && self.llm_mode {
            let elapsed_us = start_time.elapsed().as_micros().min(u64::MAX as u128) as u64;
            let tokens_used = tokens_consumed_for_stats.max(1);
            self.finish_local_batch();
            self.local.state.store(STATE_IDLE, Ordering::Release);
            futex::wake_all(&self.local.state);
            debug!(
                "[Manager] <<< FIKIT batch {} ends (skip MEASURING). tokens: {}, duration: {} us",
                batch_id, tokens_used, elapsed_us
            );
            return (elapsed_us, tokens_used);
        }

        self.enter_measuring_state();

        let report_start = Instant::now();
        // LLM wall-clock reports finish in microseconds; avoid 500ms grace stalls.
        let grace_duration = if self.llm_mode {
            if self.active_tenant_count() > 1 {
                Duration::from_millis(2)
            } else {
                Duration::from_millis(10)
            }
        } else {
            Duration::from_millis(LOCAL_REPORT_GRACE_MS).max(
                Duration::from_micros(plan.time_limit_us / 4)
                    .saturating_add(Duration::from_millis(10)),
            )
        };

        // While waiting for worker reports, keep heartbeating so other managers
        // do not declare us dead during a long grace window.
        let mut last_hb = Instant::now();
        loop {
            let active = self.local.active_workers.load(Ordering::Acquire);
            let reported = self.local.reported_count.load(Ordering::Acquire);

            if reported >= active {
                break;
            }
            if report_start.elapsed() > grace_duration {
                break;
            }
            if last_hb.elapsed() > Duration::from_millis(100) {
                self.update_heartbeat();
                last_hb = Instant::now();
            }
            thread::yield_now();
        }

        let (duration, tokens_used) =
            self.aggregate_local_times(batch_id, tokens_consumed_for_stats);
        self.finish_local_batch();
        self.local.state.store(STATE_IDLE, Ordering::Release);

        if tokens_used > 0 {
            debug!(
                "[Manager] <<< Batch {} ends. consume Token (for stats): {}, duration: {} us",
                batch_id, tokens_used, duration
            );
        }

        (duration, tokens_used)
    }

    fn honor_fixed_rest_wait(&mut self) {
        if !self.fixed_share_ratio {
            return;
        }
        if let Some(deadline) = self.next_run_not_before {
            let now = Instant::now();
            if now < deadline {
                let mut last_hb = Instant::now();
                loop {
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    if last_hb.elapsed() > Duration::from_millis(100) {
                        self.update_heartbeat();
                        last_hb = Instant::now();
                    }
                    let remaining = deadline.saturating_duration_since(now);
                    let sleep_for = remaining.min(Duration::from_millis(2));
                    thread::sleep(sleep_for);
                }
            }
            self.next_run_not_before = None;
        }
    }

    fn aggregate_local_times(&self, batch_id: u64, tokens_for_stats: u64) -> (u64, u64) {
        let mut global_start = u64::MAX;
        let mut global_end = 0;
        let mut participants = 0;

        for i in 0..MAX_WORKERS {
            let slot = &self.local.reports[i];
            if slot.batch_id.load(Ordering::Acquire) == batch_id {
                let start = slot.cpu_start_us.load(Ordering::Relaxed);
                let dur = slot.duration_us.load(Ordering::Relaxed);

                if dur > 0 {
                    let end = start + dur;

                    if start < global_start {
                        global_start = start;
                    }
                    if end > global_end {
                        global_end = end;
                    }
                    participants += 1;
                }
            }
        }

        if participants == 0 {
            return (0, 0);
        }
        let total_duration = if global_end > global_start {
            global_end - global_start
        } else {
            0
        };
        // Use the actual tokens consumed (post-scale) so averages are per real token.
        let tokens_used = tokens_for_stats;

        debug!(
            "[Manager-Aggregate] total participants: {}, earliest time: {}, latest time: {}",
            participants, global_start, global_end
        );
        debug!(
            "[Manager-Aggregate] total duration: {} us, consume Tokens: {}",
            total_duration, tokens_used
        );

        (total_duration, tokens_used)
    }

    fn update_local_stats(&mut self, duration_us: u64, tokens: u64) {
        if tokens == 0 {
            return;
        }
        let new_avg = duration_us / tokens;
        // Reject wall-clock / capture spikes (see MAX_STAT_KERNEL_AVG_US). Origin
        // effectively never sees these because GPU-event timing stays in microseconds.
        if new_avg > MAX_STAT_KERNEL_AVG_US {
            debug!(
                "[Manager] skip avg update: outlier {} us/token (batch {} us / {} tokens)",
                new_avg, duration_us, tokens
            );
            return;
        }
        self.burst_last_tokens = tokens;
        if tokens > self.burst_max_tokens {
            self.burst_max_tokens = tokens;
        }
        // Clamp swings but allow faster adaptation.
        let lower = (self.current_avg_us / 4).max(1);
        let upper = self.current_avg_us.saturating_mul(4).max(1);
        let clamped_avg = new_avg.clamp(lower, upper);
        let alpha = self.ema_alpha;
        self.current_avg_us =
            ((self.current_avg_us as f64 * (1.0 - alpha)) + (clamped_avg as f64 * alpha)) as u64;

        self.global.slots[self.my_global_idx]
            .avg_kernel_time
            .store(self.current_avg_us, Ordering::Relaxed);
        self.global.slots[self.my_global_idx]
            .last_heartbeat
            .store(get_time_us(), Ordering::Relaxed);
    }

    fn schedule_rest_wait(&mut self, rest_wait_us: u64) {
        if !self.fixed_share_ratio || rest_wait_us == 0 {
            self.next_run_not_before = None;
            return;
        }
        // Defense in depth: never schedule a rest longer than the hard cap even if a
        // future code path forgets to clamp at the source.
        let capped = rest_wait_us.min(self.max_rest_wait_us);
        let now = Instant::now();
        let deadline = now
            .checked_add(Duration::from_micros(capped))
            .unwrap_or(now);
        self.next_run_not_before = Some(deadline);
    }

    fn update_heartbeat(&self) {
        self.global
            .lock_timestamp
            .store(get_time_us(), Ordering::Relaxed);
        self.global.slots[self.my_global_idx]
            .last_heartbeat
            .store(get_time_us(), Ordering::Relaxed);
        self.mirror_worker_signals();
    }
}

fn parse_sched_policy_env() -> Option<SchedPolicy> {
    let v = std::env::var("NPU_SCHED_POLICY").ok()?;
    let v = v.trim().to_ascii_lowercase();
    match v.as_str() {
        "fixed" | "fixed-share" | "fixed_share" => Some(SchedPolicy::Fixed),
        "elastic" => Some(SchedPolicy::Elastic),
        "best-effort" | "best_effort" | "besteffort" => Some(SchedPolicy::BestEffort),
        _ => None,
    }
}

fn parse_sched_policy(fixed_share_ratio: &bool, llm_mode: bool) -> SchedPolicy {
    if let Some(p) = parse_sched_policy_env() {
        return p;
    }
    if *fixed_share_ratio {
        SchedPolicy::Fixed
    } else if llm_mode {
        SchedPolicy::Elastic
    } else {
        SchedPolicy::Elastic
    }
}

impl Drop for ContainerManager {
    fn drop(&mut self) {
        // Mark this manager inactive so others will skip its slot and can steal the lock.
        self.global.slots[self.my_global_idx]
            .is_active
            .store(0, Ordering::Relaxed);

        // Nudge waiters so they re-check ownership promptly (even if we held the lock).
        self.global.signal_counter.fetch_add(1, Ordering::Release);
        futex::wake_all(&self.global.signal_counter);
    }
}

fn get_time_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_micros() as u64
}
