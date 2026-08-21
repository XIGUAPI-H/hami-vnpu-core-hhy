//! Compute scheduling mode: manager token daemon vs CoreLimiter (61 / ubs-virt style).
//!
//! `NPU_HARD_SIM=1` enables the full hard-split simulation stack:
//!   NPU_COMPUTE_SCHED=auto, NPU_ITERATION_SCHED=1, NPU_LLM_MODE=1, NPU_LLM_BURST=1
//!
//! `auto` resolves at runtime: CoreLimiter when no global contention, manager tokens otherwise.

use std::sync::OnceLock;

use crate::kylin_preset;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComputeSchedMode {
    /// Limiter daemon baton + futex token path (default).
    Manager,
    /// LiteSem timeslice scheduler in-process (61 libmeminfo_shim style).
    CoreLimiter,
    /// CoreLimiter when alone on the card; manager when multi-tenant.
    Auto,
}

static MODE: OnceLock<ComputeSchedMode> = OnceLock::new();

fn parse_mode(raw: &str) -> Option<ComputeSchedMode> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "manager" | "token" | "tokens" => Some(ComputeSchedMode::Manager),
        "core_limiter" | "core" | "corelimiter" | "lite" => Some(ComputeSchedMode::CoreLimiter),
        "auto" | "hard_sim" | "hardsim" => Some(ComputeSchedMode::Auto),
        _ => None,
    }
}

/// True when `NPU_HARD_SIM=1` — one switch for hard-split-like behaviour.
pub fn hard_sim_active() -> bool {
    static ACTIVE: OnceLock<bool> = OnceLock::new();
    *ACTIVE.get_or_init(|| kylin_preset::env_bool("NPU_HARD_SIM", false))
}

pub fn compute_sched_mode() -> ComputeSchedMode {
    *MODE.get_or_init(|| {
        if hard_sim_active() {
            return ComputeSchedMode::Auto;
        }
        std::env::var("NPU_COMPUTE_SCHED")
            .ok()
            .and_then(|v| parse_mode(&v))
            .unwrap_or(ComputeSchedMode::Manager)
    })
}

/// Static preference before runtime contention is known.
pub fn prefers_core_limiter() -> bool {
    matches!(
        compute_sched_mode(),
        ComputeSchedMode::CoreLimiter | ComputeSchedMode::Auto
    )
}

/// Runtime resolution for hook / worker hot path.
pub fn resolve_use_core_limiter(global_contention: bool) -> bool {
    match compute_sched_mode() {
        ComputeSchedMode::CoreLimiter => true,
        ComputeSchedMode::Manager => false,
        ComputeSchedMode::Auto => !global_contention,
    }
}

/// Default iteration-level scheduling when env unset.
pub fn iteration_sched_default() -> bool {
    if hard_sim_active() {
        return true;
    }
    match compute_sched_mode() {
        ComputeSchedMode::CoreLimiter | ComputeSchedMode::Auto => true,
        ComputeSchedMode::Manager => false,
    }
}

/// Default LLM burst hooks when env unset under hard-sim.
pub fn llm_mode_default(fallback: bool) -> bool {
    if hard_sim_active() {
        return true;
    }
    fallback
}
