pub mod compute_sched;
pub mod config;
pub mod externed_api;
pub mod kylin_preset;
pub mod manager;
pub mod shmem;
pub mod worker;

#[cfg(feature = "core_scheduler")]
pub(crate) mod core_scheduler;

use ctor::ctor;

#[ctor]
fn init_logger() {
    let _ = env_logger::builder()
        .filter_level(log::LevelFilter::Info)
        .parse_default_env()
        .try_init();
    if crate::compute_sched::hard_sim_active() {
        log::info!(
            "[hard-sim] NPU_HARD_SIM=1 — compute_sched=auto, iteration_sched, LLM burst; CoreLimiter when alone"
        );
    } else if crate::kylin_preset::kylin_lite_active() {
        log::info!(
            "[kylin] lite mode (os_kylin={}) — wait_for_token hook path, file-shmem, meminfo-cache; industry stack off",
            crate::kylin_preset::is_kylin_os()
        );
    } else if crate::kylin_preset::kylin_preset_active() {
        log::info!(
            "[kylin] preset active (os_kylin={}) — file-shmem, meminfo-cache, FCSP off",
            crate::kylin_preset::is_kylin_os()
        );
    }
}

#[macro_export]
macro_rules! check_rts {
    ($call:expr) => {{
        let ret = unsafe { $call } as u32; // Cast the result to `u32`.
        if ret != 0 {
            println!(
                "RTS error: {}, from file '{}', line {} - function: `{}`",
                ret,
                file!(),
                line!(),
                stringify!($call),
            );
        } else {
            // add debug log if necessary
        }
        ret // Return the result (0 in this case) for further use if needed.
    }};
}
