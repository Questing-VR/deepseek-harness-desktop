//! 命令行集成：安装后在用户 PATH 中注册 `dsh` / `pnpm` 命令。
//!
//! `dsh` 与捆绑的 `pnpm` 都是 Node 脚本（`lib/bin.js` / `bin/pnpm.cjs`），并非原生
//! 可执行文件，因此生成包装脚本（shim）并注册到用户 PATH：
//!
//! - 可移植模式（设置了 `DSH_APP_DATA`）：shim 目录改为数据根目录内的
//!   `<根目录>\bin`（Windows）/ `<根目录>/bin`（macOS/Linux），由
//!   `crate::config::portable_bin_dir()` 给出，不再落到平台默认位置；
//! - Windows 默认：`%LOCALAPPDATA%\deepseek-harness\bin\dsh.cmd` / `dsh.ps1` 与
//!   `pnpm.cmd` / `pnpm.ps1`，通过 `HKCU\Environment\Path` 注册并广播
//!   `WM_SETTINGCHANGE`；
//! - macOS/Linux 默认：`~/.local/bin/dsh` 与 `~/.local/bin/pnpm`，必要时向
//!   `~/.zshrc` / `~/.bashrc` 幂等更新 PATH 导出块（只动自身标记块、保留
//!   用户其余配置；写入前备份临时文件 + rename，失败自动回滚）。
//!
//! 两种模式共用同一块标记与同一套开关（`cli_link_enabled`）：切到可移植模式后
//! 注入块里的导出路径会整体换成数据根目录内的 bin，用户 PATH 中残留的旧平台
//! 默认目录条目在下次注册时被摘除，不会出现新旧两个 shim 目录同时生效。
//!
//! shim 运行时优先使用本地版本兼容的 node（校验规则与
//! [`crate::config::is_supported_node_version`] 一致），否则回退到捆绑运行时；
//! `pnpm` shim 还额外优先转发用户自己安装的 pnpm（PATH 中排除本 shim 目录）。
//! shim 不重定向 stdin/stdout、不修改工作目录，保证交互式命令可用，
//! 并透传全部参数与退出码。
//!
//! 模块划分（参考 `service/download/`）：
//! - [`shim`]：shim 脚本内容生成与落盘
//! - [`path`]：bin 目录定位、PATH 注册（注册表 / shell rc）、用户 pnpm 探测
//! - [`core`]：对外接口（状态 / 启用 / 清理）

mod core;
mod path;
mod shim;

pub use core::{ensure, ensure_shims, get_status, remove, CliLinkStatus};
#[cfg(windows)]
pub(crate) use path::find_user_pnpm_executable;
pub use path::{find_user_pnpm, get_bin_dir, pnpm_env_value};
pub use shim::is_generated_shim;
