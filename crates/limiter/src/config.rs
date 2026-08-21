pub const ENV_GLOBAL_SHM_PATH: &str = "NPU_GLOBAL_SHM_PATH";
pub const ENV_LOCAL_SHM_NAME: &str = "NPU_LOCAL_SHM_NAME";
pub const ENV_PRIORITY: &str = "NPU_PRIORITY";
pub const ENV_MEM_QUOTA_MB: &str = "NPU_MEM_QUOTA";
pub const ENV_KYLIN_PRESET: &str = "NPU_KYLIN_PRESET";
pub const ENV_KYLIN_LITE: &str = "NPU_KYLIN_LITE";
pub const ENV_LOCAL_SHM_BACKEND: &str = "NPU_LOCAL_SHM_BACKEND";
pub const ENV_LOCAL_SHM_DIR: &str = "NPU_LOCAL_SHM_DIR";

pub const DEFAULT_LOCAL_SHMEM_NAME: &str = "vnpu_local_session";
pub const DEFAULT_PRIORITY: f64 = 1.0;
pub const DEFAULT_MEM_QUOTA_MB: u64 = 0;

pub const VIRTUAL_OVERHEAD_MB: usize = 128; // Reserve 128MB as HBM overhead

#[derive(Debug, Clone)]
pub struct ManagerConfig {
    pub global_shm_path: String,
    pub local_shm_name: String,
    pub priority: f64,
    pub memory_limit_mb: u64,
}

impl ManagerConfig {
    pub fn from_env() -> Result<Self, String> {
        let global_shm_path = std::env::var(ENV_GLOBAL_SHM_PATH)
            .map_err(|_| format!("Missing environment variable: {}", ENV_GLOBAL_SHM_PATH))?;

        let local_shm_name = std::env::var(ENV_LOCAL_SHM_NAME)
            .unwrap_or_else(|_| DEFAULT_LOCAL_SHMEM_NAME.to_string());

        let priority = parse_f64(ENV_PRIORITY, DEFAULT_PRIORITY);
        let memory_limit_mb = parse_u64(ENV_MEM_QUOTA_MB, DEFAULT_MEM_QUOTA_MB);

        Ok(Self {
            global_shm_path,
            local_shm_name,
            priority,
            memory_limit_mb,
        })
    }
}

pub fn local_shmem_name() -> String {
    std::env::var(ENV_LOCAL_SHM_NAME).unwrap_or_else(|_| DEFAULT_LOCAL_SHMEM_NAME.to_string())
}

/// Memory quota in MiB for worker-side shmem bootstrap when limiter daemon is absent.
pub fn mem_quota_mb_from_env() -> u64 {
    if let Ok(v) = std::env::var(ENV_MEM_QUOTA_MB) {
        if let Ok(n) = v.trim().parse::<u64>() {
            if n > 0 {
                return n;
            }
        }
    }
    if let Ok(v) = std::env::var("VXPU_MEM_LIMIT_MIB") {
        if let Ok(n) = v.trim().parse::<u64>() {
            return n;
        }
    }
    DEFAULT_MEM_QUOTA_MB
}

fn parse_f64(name: &str, default: f64) -> f64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(default)
}

fn parse_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(default)
}
