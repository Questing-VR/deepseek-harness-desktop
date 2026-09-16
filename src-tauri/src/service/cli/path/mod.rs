//! 用户 PATH 注册与路径计算：bin 目录定位、Windows 注册表读写与
//! `WM_SETTINGCHANGE` 广播、Unix shell rc 幂等块更新（备份 + 失败回滚），以及
//! 用户 pnpm 探测。
//!
//! 模块划分：
//! - [`pnpm`]：用户 pnpm 探测（PATH + mise/Windows 标准目录，排除本应用 shim）
//! - [`registry`]：Windows 注册表辅助（仅 Windows）
//! - [`rc`]：Unix shell rc 幂等块注入/移除（仅 Unix）

#[cfg(not(windows))]
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

use crate::config;

#[cfg(windows)]
use super::shim::SHIM_CMD_NAME;
#[cfg(unix)]
use super::shim::SHIM_SH_NAME;
#[cfg(windows)]
use crate::config::CLI_ROOT_DEV_DIR_NAME;

#[cfg(not(windows))]
use rc::{inject_shell_rc, strip_shell_rc, RC_FILES, RC_MARK_START};
#[cfg(windows)]
use registry::{
    notify_environment_change, path_contains_token, read_user_path, remove_path_token,
    write_user_path,
};

mod pnpm;
mod rc;
#[cfg(windows)]
mod registry;

#[cfg(windows)]
pub(crate) use pnpm::find_user_pnpm_executable;
pub use pnpm::{find_user_pnpm, pnpm_env_value};

/// Windows 下 shim 根目录名（`%LOCALAPPDATA%\<此目录>\bin`）
#[cfg_attr(not(windows), allow(dead_code))] // 仅 Windows 的 bin 目录计算使用
const CLI_ROOT_DIR_NAME: &str = "deepseek-harness";

/// Unix 下 shim 所在目录（XDG 约定）
#[cfg(unix)]
const UNIX_BIN_DIR: &str = ".local/bin";

/// Windows 下 dev 构建的 shim 根目录名后缀（`%LOCALAPPDATA%\deepseek-harness-dev\bin`），
/// 只用于识别/清理切换构建或可移植模式前留下的 PATH 条目
#[cfg(windows)]
const CLI_ROOT_DEV_DIR_NAME_SUFFIX: &str = "-dev";

// ---------------------------------------------------------------------------
// 路径计算
// ---------------------------------------------------------------------------

/// bin 目录：
/// - 可移植模式（`DSH_APP_DATA`）：`<根目录>/bin`——用户已声明「所有数据都在这个
///   目录里」，shim 不能再落到 `%LOCALAPPDATA%` / `~/.local/bin`；
/// - Windows 默认：`%LOCALAPPDATA%\deepseek-harness\bin`（用户级、不随应用数据目录变动）
/// - Unix 默认：`~/.local/bin`（XDG 约定，通常已在 PATH 中）
pub fn get_bin_dir(app_handle: &AppHandle) -> PathBuf {
    // 可移植模式优先于平台默认位置；debug 的额外下沉已由 `portable_root()` 完成，
    // 这里不再叠加一层，保证与 core/plugin 解析出的 bin 目录完全一致。
    if let Some(portable) = config::portable_bin_dir() {
        return portable;
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .or_else(|| {
                app_handle
                    .path()
                    .local_data_dir()
                    .ok()
                    .and_then(|d| d.parent().map(|p| p.to_path_buf()))
            })
            .unwrap_or_else(std::env::temp_dir)
            .join(if cfg!(debug_assertions) {
                CLI_ROOT_DEV_DIR_NAME
            } else {
                CLI_ROOT_DIR_NAME
            })
            .join("bin")
    }
    #[cfg(not(windows))]
    {
        let home = app_handle
            .path()
            .home_dir()
            .unwrap_or_else(|_| PathBuf::from("."));
        if cfg!(debug_assertions) {
            home.join(".local/bin/dev")
        } else {
            home.join(UNIX_BIN_DIR)
        }
    }
}

/// 旧平台默认 bin 目录（可移植模式下的清理目标）：
/// Windows `%LOCALAPPDATA%\<shim 根目录名>\bin`，Unix `~/.local/bin`。
///
/// 可移植模式之前 shim 写在这里，若不做清理，用户 PATH 中会同时存在本应用新旧
/// 两个条目，旧目录排在前面时终端会执行到上一次的 shim（内容可能仍烘焙着旧的
/// `$DSH_HOME`），形成难以排查的「命令行行为不一致」。
pub(super) fn legacy_bin_dir(app_handle: &AppHandle) -> PathBuf {
    #[cfg(windows)]
    {
        let dir_name = if cfg!(debug_assertions) {
            format!("{CLI_ROOT_DIR_NAME}{CLI_ROOT_DEV_DIR_NAME_SUFFIX}")
        } else {
            CLI_ROOT_DIR_NAME.to_string()
        };
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .or_else(|| {
                app_handle
                    .path()
                    .local_data_dir()
                    .ok()
                    .and_then(|d| d.parent().map(|p| p.to_path_buf()))
            })
            .unwrap_or_else(std::env::temp_dir)
            .join(dir_name)
            .join("bin")
    }
    #[cfg(not(windows))]
    {
        let home = app_handle
            .path()
            .home_dir()
            .unwrap_or_else(|_| PathBuf::from("."));
        if cfg!(debug_assertions) {
            home.join(".local/bin/dev")
        } else {
            home.join(UNIX_BIN_DIR)
        }
    }
}

// ---------------------------------------------------------------------------
// 路径注册辅助
// ---------------------------------------------------------------------------

/// 写 shim / 改 PATH 前先建好 bin 目录：可移植模式下 `<根目录>/bin` 全新出现，
/// 惰性创建保证第一次启用命令行集成就能落地。
fn ensure_bin_dir(bin_dir: &std::path::Path) -> Result<(), String> {
    config::ensure_dir(bin_dir)
        .map_err(|e| format!("SHIM_MKDIR_FAILED: create bin dir failed: {e}"))
}

/// 主 shim 文件路径（状态展示用）
pub fn get_shim_path(app_handle: &AppHandle) -> PathBuf {
    let bin_dir = get_bin_dir(app_handle);
    #[cfg(windows)]
    {
        bin_dir.join(SHIM_CMD_NAME)
    }
    #[cfg(not(windows))]
    {
        bin_dir.join(SHIM_SH_NAME)
    }
}

/// 当前用户 PATH 中是否已包含 bin 目录（Windows 以注册表为准，
/// 因为进程内 PATH 在广播 WM_SETTINGCHANGE 后不会自动更新）
pub fn path_registered(app_handle: &AppHandle) -> bool {
    #[cfg(windows)]
    {
        let bin_dir = get_bin_dir(app_handle);
        let Some(bin_str) = bin_dir.to_str() else {
            return false;
        };
        read_user_path()
            .map(|value| path_contains_token(&value, bin_str))
            .unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        let bin_dir = get_bin_dir(app_handle);
        // 1. 当前进程 PATH 已包含（新终端直接可用）
        if std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .any(|p| p == bin_dir)
        {
            return true;
        }
        // 2. rc 文件中已注入标记块（重启 shell 后可用）
        let home = app_handle
            .path()
            .home_dir()
            .unwrap_or_else(|_| PathBuf::from("."));
        RC_FILES.iter().any(|name| {
            fs::read_to_string(home.join(name))
                .map(|content| content.contains(RC_MARK_START))
                .unwrap_or(false)
        })
    }
}

// ---------------------------------------------------------------------------
// PATH 注册 / 注销（Windows：注册表 + WM_SETTINGCHANGE；Unix：shell rc）
// ---------------------------------------------------------------------------

/// 注册 bin 目录到用户 PATH（幂等）
pub fn register_path(app_handle: &AppHandle) -> Result<(), String> {
    if path_registered(app_handle) {
        return Ok(());
    }
    #[cfg(windows)]
    {
        let bin_dir = get_bin_dir(app_handle);
        // 可移植模式下 bin 位于数据根目录内，可能尚未创建
        ensure_bin_dir(&bin_dir)?;
        let bin_str = bin_dir
            .to_str()
            .ok_or_else(|| "PATH_BIN_DIR_NOT_UTF8: bin dir is not valid UTF-8".to_string())?;
        // 注册表读取失败（None）时中止，绝不把失败当成空 PATH 写回（那会清空
        // 用户 PATH 其它条目）；`Path` 值缺失（ERROR_FILE_NOT_FOUND）返回的
        // Some("") 才按空串处理。
        let current = read_user_path()
            .ok_or_else(|| "PATH_REG_READ_FAILED: failed to read user PATH".to_string())?;
        // 可移植模式：先摘掉旧平台默认 bin 目录的条目，避免新旧两个 shim 目录同时
        // 留在 PATH 中（旧条目排在前面时终端会跑到上一次的 shim）。仅当旧目录确实
        // 与新目录不同才处理，平台默认模式下两者相同，因此该分支为 no-op。
        let current = remove_legacy_path_entry(&legacy_bin_dir(app_handle), bin_str, current);
        let new_value = if current.trim().is_empty() {
            bin_str.to_string()
        } else {
            format!("{};{}", current.trim_end_matches(';'), bin_str)
        };
        write_user_path(&new_value)?;
        notify_environment_change();
        log::info!("Registered dsh bin dir in user PATH: {bin_str}");
    }
    #[cfg(not(windows))]
    {
        // 可移植模式下 rc 注入块里的导出路径指向 `<根目录>/bin`，目录必须先存在
        ensure_bin_dir(&get_bin_dir(app_handle))?;
        inject_shell_rc(app_handle)?;
    }
    Ok(())
}

/// 移除仍留在用户 PATH 中的旧平台默认 bin 目录条目，返回清理后的 PATH 值。
///
/// 旧目录即当前 bin 目录（平台默认模式）、或 PATH 中本就没有旧条目时原样返回，
/// 保证非可移植模式下行为与改动前完全一致。
#[cfg(windows)]
fn remove_legacy_path_entry(
    legacy: &std::path::Path,
    bin_str: &str,
    current: String,
) -> String {
    let Some(legacy_str) = legacy.to_str() else {
        return current;
    };
    if legacy_str == bin_str || !path_contains_token(&current, legacy_str) {
        return current;
    }
    let cleaned = remove_path_token(&current, legacy_str);
    if cleaned != current {
        log::info!("Removed stale dsh bin dir from user PATH: {legacy_str}");
    }
    cleaned
}

/// 从用户 PATH 中移除 bin 目录（幂等）
pub fn unregister_path(app_handle: &AppHandle) -> Result<(), String> {
    #[cfg(windows)]
    {
        let bin_dir = get_bin_dir(app_handle);
        let Some(bin_str) = bin_dir.to_str() else {
            return Ok(());
        };
        if let Some(current) = read_user_path() {
            if !path_contains_token(&current, bin_str) {
                return Ok(());
            }
            let new_value = remove_path_token(&current, bin_str);
            write_user_path(&new_value)?;
            notify_environment_change();
            log::info!("Removed dsh bin dir from user PATH");
        }
    }
    #[cfg(not(windows))]
    {
        strip_shell_rc(app_handle)?;
    }
    Ok(())
}

#[cfg(test)]
mod test_util {
    use std::path::Path;

    pub(super) fn make_executable(path: &Path) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(path).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(path, permissions).unwrap();
        }
        #[cfg(not(unix))]
        let _ = path;
    }

    pub(super) fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "dsh-rc-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
