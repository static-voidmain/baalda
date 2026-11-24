// SPDX-License-Identifier: Apache-2.0
use tauri::{plugin::{Builder, PluginHandle, TauriPlugin}, Manager, Runtime};

tauri::ios_plugin_binding!(init_plugin_cloud_drive);

pub struct Drive<R: Runtime>(pub PluginHandle<R>);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("cloud-drive").setup(|app, api| {
        app.manage(Drive(api.register_ios_plugin(init_plugin_cloud_drive)?));
        Ok(())
    }).build()
}
