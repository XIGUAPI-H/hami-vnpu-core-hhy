use std::ffi::CString;
use std::fs;
use std::mem;
use std::path::Path;
use std::ptr;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

use libc::{
    MAP_FAILED, MAP_SHARED, O_CREAT, O_RDWR, PROT_READ, PROT_WRITE, close, ftruncate, mmap, off_t,
    open, shm_open,
};

use crate::config::mem_quota_mb_from_env;
use crate::kylin_preset;
use crate::shmem::GlobalRegistry;
use crate::shmem::LocalContainerShmem;

const OPEN_RETRY_MS: u64 = 100;
const OPEN_RETRY_ATTEMPTS: u32 = 50;

unsafe fn mmap_shmem<T>(fd: i32, label: &str) -> &'static T {
    let size = mem::size_of::<T>();
    let ptr = mmap(
        ptr::null_mut(),
        size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        fd,
        0,
    );
    if ptr == MAP_FAILED {
        panic!(
            "Failed to mmap {}: {}",
            label,
            std::io::Error::last_os_error()
        );
    }
    &*(ptr as *const T)
}

/// POSIX shm_open backend (default on non-Kylin).
pub fn create_shmem<T>(name: &str) -> &'static T {
    unsafe {
        let c_name = CString::new(name).unwrap();
        let fd = shm_open(c_name.as_ptr(), O_CREAT | O_RDWR, 0o666);
        if fd < 0 {
            panic!(
                "Manager failed to shm_open {}: {}",
                name,
                std::io::Error::last_os_error()
            );
        }

        let size = mem::size_of::<T>();
        if ftruncate(fd, size as off_t) < 0 {
            panic!(
                "Failed to ftruncate {}: {}",
                name,
                std::io::Error::last_os_error()
            );
        }

        let shmem = mmap_shmem::<T>(fd, name);
        close(fd);
        shmem
    }
}

/// File-backed mmap under /hami-shared-region (Kylin preset default).
pub fn create_file_shmem<T>(path: &str) -> &'static T {
    if let Some(parent) = Path::new(path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let c_path = CString::new(path).unwrap();
    unsafe {
        let fd = open(c_path.as_ptr(), O_RDWR | O_CREAT, 0o666);
        if fd < 0 {
            panic!(
                "Manager failed to open local shmem file {}: {}",
                path,
                std::io::Error::last_os_error()
            );
        }
        let size = mem::size_of::<T>();
        if ftruncate(fd, size as off_t) < 0 {
            panic!(
                "Failed to ftruncate {}: {}",
                path,
                std::io::Error::last_os_error()
            );
        }
        let shmem = mmap_shmem::<T>(fd, path);
        close(fd);
        shmem
    }
}

/// Create local container shmem (file or posix based on env / Kylin preset).
pub fn create_local_shmem<T>(name: &str) -> &'static T {
    if kylin_preset::use_file_local_shmem() {
        let path = kylin_preset::local_shmem_file_path(name);
        log::info!("[shmem] create local file shmem {}", path);
        create_file_shmem::<T>(&path)
    } else {
        create_shmem::<T>(name)
    }
}

unsafe fn try_open_shmem<T>(name: &str) -> Option<&'static T> {
    let c_name = CString::new(name).ok()?;
    let fd = shm_open(c_name.as_ptr(), O_RDWR, 0o666);
    if fd < 0 {
        return None;
    }

    let ptr = mmap(
        ptr::null_mut(),
        mem::size_of::<T>(),
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        fd,
        0,
    );
    close(fd);
    if ptr == MAP_FAILED {
        return None;
    }
    Some(&*(ptr as *const T))
}

unsafe fn try_open_file_shmem<T>(path: &str) -> Option<&'static T> {
    let c_path = CString::new(path).ok()?;
    let fd = open(c_path.as_ptr(), O_RDWR);
    if fd < 0 {
        return None;
    }
    let ptr = mmap(
        ptr::null_mut(),
        mem::size_of::<T>(),
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        fd,
        0,
    );
    close(fd);
    if ptr == MAP_FAILED {
        return None;
    }
    Some(&*(ptr as *const T))
}

/// Initialize quota fields when workers bootstrap shmem without the limiter daemon.
pub fn bootstrap_local_shmem_if_needed(shmem: &'static LocalContainerShmem, created: bool) {
    if shmem.memory_limit.load(Ordering::Relaxed) > 0 {
        return;
    }
    let mb = mem_quota_mb_from_env();
    if mb == 0 {
        return;
    }
    let bytes = mb.saturating_mul(1024 * 1024);
    shmem.memory_limit.store(bytes, Ordering::Relaxed);
    if created {
        shmem.memory_used.store(0, Ordering::Relaxed);
    }
}

/// Open local shmem created by limiter, retry briefly, or bootstrap it from env.
pub fn open_or_create_local_shmem(name: &str) -> (&'static LocalContainerShmem, bool) {
    let use_file = kylin_preset::use_file_local_shmem();
    let file_path = kylin_preset::local_shmem_file_path(name);

    for attempt in 0..OPEN_RETRY_ATTEMPTS {
        let shmem = if use_file {
            unsafe { try_open_file_shmem::<LocalContainerShmem>(&file_path) }
        } else {
            unsafe { try_open_shmem::<LocalContainerShmem>(name) }
        };
        if let Some(shmem) = shmem {
            if attempt > 0 {
                log::info!(
                    "[shmem] opened existing local shmem '{}' after {} retries",
                    if use_file { &file_path } else { name },
                    attempt
                );
            }
            bootstrap_local_shmem_if_needed(shmem, false);
            return (shmem, false);
        }
        thread::sleep(Duration::from_millis(OPEN_RETRY_MS));
    }

    log::warn!(
        "[shmem] limiter daemon not ready; worker bootstrapping local shmem '{}' from NPU_MEM_QUOTA",
        if use_file { &file_path } else { name }
    );
    let shmem = create_local_shmem::<LocalContainerShmem>(name);
    bootstrap_local_shmem_if_needed(shmem, true);
    (shmem, true)
}

/// For Worker to open SHM (strict; used by limiter manager path).
pub fn open_shmem<T>(name: &str) -> &'static T {
    if kylin_preset::use_file_local_shmem() {
        let path = kylin_preset::local_shmem_file_path(name);
        unsafe {
            let shmem = try_open_file_shmem::<T>(&path)
                .unwrap_or_else(|| panic!("Worker failed to open local shmem file {}", path));
            return shmem;
        }
    }
    unsafe {
        let c_name = CString::new(name).unwrap();
        let fd = shm_open(c_name.as_ptr(), O_RDWR, 0o666);
        if fd < 0 {
            panic!("Worker failed to open NPU Manager shmem! Is the Daemon running?");
        }

        let shmem = mmap_shmem::<T>(fd, name);
        close(fd);
        shmem
    }
}

pub fn open_global_registry(path: &str) -> &'static GlobalRegistry {
    let c_path = CString::new(path).unwrap();
    println!("open global registry path is {:?}", path);
    let mut fd = unsafe { open(c_path.as_ptr(), O_RDWR) };
    let mut needs_init = false;

    if fd < 0 {
        println!("[Global] Global Registry not exist, now creating...");
        if let Some(parent) = Path::new(path).parent() {
            let _ = fs::create_dir_all(parent);
        }
        fd = unsafe { open(c_path.as_ptr(), O_RDWR | O_CREAT, 0o666) };
        if fd < 0 {
            panic!("cannot open: {}", path);
        }
        needs_init = true;
    }

    let size = std::mem::size_of::<GlobalRegistry>();

    if needs_init {
        unsafe { ftruncate(fd, size as i64) };
    }

    let ptr = unsafe {
        mmap(
            std::ptr::null_mut(),
            size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0,
        )
    };

    if ptr == MAP_FAILED {
        panic!("mmap failed");
    }

    let reg = unsafe { &*(ptr as *const GlobalRegistry) };

    if needs_init {
        // Fields are zero-initialized on first mmap.
    }
    println!("connect to global registry");
    reg
}
