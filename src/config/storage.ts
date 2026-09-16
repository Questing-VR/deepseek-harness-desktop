import { createStorage } from 'unstorage'
import { tauriStorageDriver } from './storage.driver'

// 不指定 path：驱动会经 Rust 的 `store_path` 命令取绝对路径（见 storage.driver），
// 与后端共用同一份 store 文件——写死相对名会让可移植模式下前后端各写一份。
export const storage = createStorage({
  driver: tauriStorageDriver({}),
})
