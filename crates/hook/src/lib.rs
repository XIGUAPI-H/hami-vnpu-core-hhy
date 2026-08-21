use once_cell::sync::Lazy;

use limiter::worker::SchedulerClient;

pub use limiter::worker::MemInfoHook;

pub static NPU_LIMITER: Lazy<SchedulerClient> = Lazy::new(SchedulerClient::new);

macro_rules! passthrough {
    ($name:expr, ($($sig:tt)*), $($arg:expr),*) => {
        {
            static REAL: ::once_cell::sync::Lazy<extern "C" fn($($sig)*) -> u64> =
                ::once_cell::sync::Lazy::new(|| unsafe {
                    let ptr = libc::dlsym(libc::RTLD_NEXT, concat!($name, "\0").as_ptr() as *const libc::c_char);
                    if ptr.is_null() {
                        panic!("cannot find original function: {}", $name);
                    }
                    std::mem::transmute(ptr)
                });
            // println!("in func {:?}", $name);
            (*REAL)($($arg),*)
        }
    };
}

pub(crate) use passthrough;

#[cfg(all(feature = "optimized", feature = "kylin_lite"))]
compile_error!("hook features `optimized` and `kylin_lite` are mutually exclusive");

#[cfg(feature = "optimized")]
#[path = "hook_optimized.rs"]
mod hook;

#[cfg(not(feature = "optimized"))]
mod hook;

mod signal_compat;
