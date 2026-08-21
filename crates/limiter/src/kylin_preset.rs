//! Kylin Server V11 tuning: auto-detect hybrid-stack hosts and apply safer defaults.
use std::sync::OnceLock;

static IS_KYLIN: OnceLock<bool> = OnceLock::new();
static PRESET_ACTIVE: OnceLock<bool> = OnceLock::new();

fn parse_bool_env(raw: &str, default_val: bool) -> bool {
    let v = raw.trim().to_ascii_lowercase();
    if v == "0" || v == "false" || v == "off" {
        false
    } else if v == "1" || v == "true" || v == "on" {
        true
    } else {
        default_val
    }
}

/// True when running on Kylin Server (V10/V11).
pub fn is_kylin_os() -> bool {
    *IS_KYLIN.get_or_init(|| {
        if let Ok(s) = std::fs::read_to_string("/etc/os-release") {
            let lower = s.to_ascii_lowercase();
            if lower.contains("kylin") {
                return true;
            }
        }
        std::path::Path::new("/etc/kylin-release").exists()
    })
}

/// Kylin preset is on when NPU_KYLIN_PRESET is unset/true on Kylin, or forced via env.
pub fn kylin_preset_active() -> bool {
    *PRESET_ACTIVE.get_or_init(|| match std::env::var("NPU_KYLIN_PRESET") {
        Ok(v) if !v.is_empty() => parse_bool_env(&v, true),
        _ => is_kylin_os(),
    })
}

pub fn env_var_set(name: &str) -> bool {
    std::env::var(name).map(|v| !v.is_empty()).unwrap_or(false)
}

pub fn env_bool(name: &str, default_val: bool) -> bool {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => parse_bool_env(&v, default_val),
        _ => default_val,
    }
}

static KYLIN_LITE: OnceLock<bool> = OnceLock::new();

/// Kylin lite: origin-style wait_for_token hook + infra only (no LLM/FIKIT/iter stack).
/// Default on when NPU_KYLIN_LITE is unset on Kylin; set NPU_KYLIN_LITE=0 to use full preset.
pub fn kylin_lite_active() -> bool {
    *KYLIN_LITE.get_or_init(|| match std::env::var("NPU_KYLIN_LITE") {
        Ok(v) if !v.is_empty() => parse_bool_env(&v, true),
        _ => is_kylin_os(),
    })
}

/// Default for NPU_LLM_MODE when env unset under Kylin preset.
pub fn llm_mode_preset_default() -> bool {
    kylin_preset_active() && !kylin_lite_active()
}

/// Use `preset_default` when Kylin preset is active and the env var is unset.
pub fn env_bool_kylin(name: &str, preset_default: bool, fallback: bool) -> bool {
    if env_var_set(name) {
        env_bool(name, fallback)
    } else if kylin_preset_active() {
        preset_default
    } else {
        fallback
    }
}

/// Kylin-aware bool with lite overrides for industry-stack knobs.
pub fn env_bool_kylin_lite(
    name: &str,
    lite_default: bool,
    full_preset_default: bool,
    fallback: bool,
) -> bool {
    if env_var_set(name) {
        env_bool(name, fallback)
    } else if kylin_lite_active() {
        lite_default
    } else if kylin_preset_active() {
        full_preset_default
    } else {
        fallback
    }
}

pub fn wait_spin_iters() -> u32 {
    if kylin_preset_active() { 48 } else { 12 }
}

/// Bounded pre-spin budget before a worker futex-sleeps at a slice boundary
/// (RUNNING<->MEASURING/IDLE). Catching a manager state flip inside this spin
/// window avoids a full futex wakeup round-trip, which is the main per-slice
/// dead time that separates soft time-slicing from hard spatial partitioning.
///
/// Tunable via NPU_SLICE_WAKEUP_SPIN. Kept small (tens of microseconds worth)
/// so a long off-slice still falls back to futex and does not burn a core.
pub fn slice_wakeup_spin_override() -> Option<u32> {
    std::env::var("NPU_SLICE_WAKEUP_SPIN")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok())
        .map(|n| n.min(1_000_000))
}

pub fn slice_wakeup_spin_iters() -> u32 {
    static ITERS: OnceLock<u32> = OnceLock::new();
    *ITERS.get_or_init(|| {
        if let Some(n) = slice_wakeup_spin_override() {
            return n;
        }
        if kylin_preset_active() { 4096 } else { 0 }
    })
}

pub fn global_watchdog_timeout_us() -> u64 {
    if kylin_preset_active() {
        300_000
    } else {
        1_000_000
    }
}

pub fn meminfo_startup_cache_enabled() -> bool {
    env_bool_kylin("NPU_MEMINFO_STARTUP_CACHE", true, false)
}

pub fn meminfo_startup_cache_ttl_ms() -> u64 {
    std::env::var("NPU_MEMINFO_STARTUP_CACHE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(120_000)
}

pub fn use_file_local_shmem() -> bool {
    match std::env::var("NPU_LOCAL_SHM_BACKEND")
        .map(|v| v.trim().to_ascii_lowercase())
        .ok()
        .as_deref()
    {
        Some("file") => true,
        Some("shm") | Some("posix") | Some("devshm") => false,
        _ => kylin_preset_active(),
    }
}

pub fn local_shmem_file_path(name: &str) -> String {
    let dir = std::env::var("NPU_LOCAL_SHM_DIR")
        .unwrap_or_else(|_| "/hami-shared-region/local_shmem".to_string());
    let dir = dir.trim_end_matches('/');
    format!("{dir}/{name}")
}
