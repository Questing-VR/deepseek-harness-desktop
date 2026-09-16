import type { StoreOptions } from '@tauri-apps/plugin-store'
import { invoke } from '@tauri-apps/api/core'
import { Store } from '@tauri-apps/plugin-store'
import { defineDriver } from 'unstorage'

export interface TauriStorageDriverOptions {
  path?: string
  options?: StoreOptions
}

/** 取不到权威路径时的回落文件名：相对名由插件解析，仅用于非 Tauri 环境兜底。 */
const FALLBACK_STORE_PATH = '.store.dat'

/**
 * 解析 store 持久化文件的**绝对**路径。
 *
 * `Store.load` 传相对名时，插件按 `BaseDirectory::AppData` 解析到
 * `%APPDATA%\<identifier>`；可移植模式（`DSH_APP_DATA`）下 Rust 写的是
 * `<root>/.store.dat`，两边各写一份、`zoom_factor` 等值静默分叉。路径只能由
 * Rust 权威（`config::setting::store_dat_path`，经 `store_path` 命令）算出。
 */
async function resolveStorePath(path?: string): Promise<string> {
  if (path) {
    return path
  }
  try {
    return await invoke<string>('store_path')
  }
  catch {
    return FALLBACK_STORE_PATH
  }
}

export const tauriStorageDriver = defineDriver<TauriStorageDriverOptions | undefined, never>((options) => {
  const promise = resolveStorePath(options?.path).then(path => Store.load(path, options?.options))
  return {
    name: 'tauri-storage',
    options,
    async hasItem(key) {
      return promise.then(store => store.has(key))
    },
    async getItem(key) {
      return promise.then(store => store.get(key))
    },
    async setItem(key, value) {
      return promise.then(store => store.set(key, value))
    },
    async removeItem(key) {
      await promise.then(store => store.delete(key))
    },
    async getKeys() {
      return promise.then(store => store.keys())
    },
    async clear() {
      return promise.then(store => store.clear())
    },
    async watch(callback) {
      return promise.then(store => store.onChange((key, value) => callback(value === null ? 'remove' : 'update', key)))
    },
  }
})
