mod constants;
pub mod dependencies;
mod format;
pub mod i18n;
pub mod manifest;
mod region;
mod runtime;
// store 路径权威（`setting::store_dat_path`）要供兄弟模块与 bridge 命令直接引用，
// 故模块本身对外可见（其余模块仍只经下面的 glob 重导出使用）。
pub mod setting;
mod theme;
mod utils;
mod window_state;

pub use constants::*;
pub use format::*;
pub use manifest::{
    is_above_recommended as is_dsh_version_above_recommended, recommended_dsh_version,
};
pub use region::*;
pub use runtime::*;
pub use setting::*;
pub use theme::*;
pub use utils::*;
pub use window_state::*;
