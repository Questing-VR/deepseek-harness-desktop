//! Minimal backend i18n for user-facing errors.
//!
//! The frontend owns the rich UI language state; the backend only needs a few
//! translated strings for errors that may surface in logs or returned messages.

use std::sync::atomic::{AtomicU8, Ordering};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Zh,
    En,
}

// 默认英文。`set_language` 在启动流程里只被调用一次，在它之前产生的用户可见
// 文案（构建期、早期错误路径）只能取这个默认值；默认中文会让这些文案一律中文。
// Windows 上更严重：set_language 曾经只在 macOS 分支被调用，于是整进程恒为中文。
// 显式选择中文仍然生效——默认值只影响「设置尚未应用」的那一小段窗口。
static CURRENT_LANG: AtomicU8 = AtomicU8::new(1); // 0 = zh, 1 = en

pub fn set_language(lang: Lang) {
    CURRENT_LANG.store(
        match lang {
            Lang::Zh => 0,
            Lang::En => 1,
        },
        Ordering::SeqCst,
    );
}

fn lang() -> Lang {
    if CURRENT_LANG.load(Ordering::SeqCst) == 1 {
        Lang::En
    } else {
        Lang::Zh
    }
}

/// Look up a translation key. Keys are grouped by domain with `_` separators.
pub fn t(key: &str) -> String {
    let (zh, en): (&str, &str) = match key {
        "runtime.unsupported_platform" => {
            ("不支持当前平台/架构", "Unsupported platform/architecture")
        }
        "runtime.title" => ("Node.js 运行时", "Node.js runtime"),
        "runtime.not_found" => (
            "Node.js 运行时不存在，请先完成安装",
            "Node.js runtime not found, run setup first",
        ),
        "runtime.incompatible" => (
            "Node.js 运行时不兼容，需要 Node 22.19+（仅 22.x）或 Node 24+",
            "Node.js runtime is incompatible; need Node 22.19+ (22.x only) or Node 24+",
        ),
        "harness.title" => ("DeepSeek Harness 核心", "DeepSeek Harness core"),
        "harness.core_not_found" => (
            "未找到 DeepSeek Harness 核心包，请先完成安装",
            "DeepSeek Harness core package not found, run setup first",
        ),
        "harness.manifest_invalid" => ("Harness 包清单无效", "Invalid harness package manifest"),
        "harness.asset_not_found" => (
            "发布资源中未找到匹配的平台包",
            "No matching platform asset found in the release",
        ),
        "harness.hash_mismatch" => (
            "下载文件哈希校验失败",
            "Downloaded file hash verification failed",
        ),
        "harness.start_failed" => (
            "启动 DeepSeek Harness 服务失败",
            "Failed to start DeepSeek Harness service",
        ),
        "harness.health_unhealthy" => (
            "DeepSeek Harness 服务未就绪",
            "DeepSeek Harness service is not ready",
        ),
        "process.manager_poisoned" => ("进程管理器状态异常", "Process manager state is corrupted"),
        "config.load_failed" => ("读取配置失败", "Failed to load configuration"),
        "config.save_failed" => ("保存配置失败", "Failed to save configuration"),
        "download.failed" => ("下载失败", "Download failed"),
        "install.downloading" => ("正在下载", "Downloading"),
        "install.extracting" => ("正在解压", "Extracting"),
        "install.downloaded" => ("已下载", "Downloaded"),
        "install.done" => ("依赖已安装完毕", "Dependencies installed"),
        "menu.application" => ("应用", "Application"),
        "menu.help" => ("帮助", "Help"),
        "menu.file" => ("文件", "File"),
        "menu.new_window" => ("新建窗口", "New Window"),
        "menu.new_chat" => ("新聊天", "New Chat"),
        "menu.open_folder" => ("打开文件夹", "Open Folder"),
        // 托盘左键/菜单的「打开面板」：与「打开文件夹」不是同一动作，之前托盘直接写死
        // 中文字面量，未走 i18n，导致 `language: "en"` 下托盘菜单仍是中文。
        "menu.open_panel" => ("打开面板", "Open Panel"),
        // 通知授权对话框：此前在 `desktop/notification.rs` 里写死中文，属于用户可见文案。
        "notification.permission_title" => ("允许发送通知？", "Allow notifications?"),
        "notification.permission_description" => (
            "DSH 页面请求发送桌面通知。是否允许？",
            "The DSH page is requesting permission to show desktop notifications. Allow?",
        ),
        "menu.close" => ("关闭", "Close"),
        "menu.quit" => ("退出", "Quit"),
        "menu.documentation" => ("文档", "Documentation"),
        "menu.settings" => ("设置…", "Settings…"),
        "menu.enter_fullscreen" => ("进入全屏幕", "Enter Full Screen"),
        "menu.exit_fullscreen" => ("退出全屏幕", "Exit Full Screen"),
        "menu.about" => ("关于 Desktop", "About Desktop"),
        "menu.run_logs" => ("运行日志", "Run Logs"),
        "menu.check_update" => ("检查更新", "Check for Updates"),
        "menu.restart" => ("重启", "Restart"),
        "menu.edit" => ("编辑", "Edit"),
        "menu.undo" => ("撤销", "Undo"),
        "menu.redo" => ("重做", "Redo"),
        "menu.cut" => ("剪切", "Cut"),
        "menu.copy" => ("复制", "Copy"),
        "menu.paste" => ("粘贴", "Paste"),
        "menu.select_all" => ("全选", "Select All"),
        _ => (key, key),
    };
    match lang() {
        Lang::Zh => zh.to_string(),
        Lang::En => en.to_string(),
    }
}
