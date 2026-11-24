// SPDX-License-Identifier: Apache-2.0
use crate::commands::{require_vault_at, VaultStamp};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use crate::vault;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tauri::{AppHandle, Manager, State, Webview};
use tauri_plugin_cloud_drive::Drive;

#[derive(Deserialize, Serialize)]
pub struct Entry {
    id: String,
    path: String,
    writable: bool,
}

#[tauri::command]
pub async fn cloud_drive(
    app: AppHandle,
    window: Webview,
    state: State<'_, AppState>,
    expected_epoch: u64,
    server_vault_id: Option<String>,
    allowed: Option<Vec<Entry>>,
    choose: bool,
    google: bool,
) -> AppResult<serde_json::Value> {
    crate::agent_runner::trusted_window(&window)?;
    let (root, index) = require_vault_at(&state, Some(expected_epoch))?;
    let config = root.join(".context/config.json");
    let stamp: VaultStamp = match std::fs::File::open(config) {
        Ok(file) => serde_json::from_reader(file).map_err(|e| AppError::new(e.to_string()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => VaultStamp::default(),
        Err(e) => return Err(e.into()),
    };
    if stamp.server_vault_id != server_vault_id
        || stamp.organization_id.is_some() && server_vault_id.is_none()
        || server_vault_id.is_some() != allowed.is_some() {
        return Err(AppError::new("Refresh the vault permissions before syncing"));
    }

    let key = server_vault_id.unwrap_or_else(|| root.to_string_lossy().into_owned());
    let drive = &app.state::<Drive<tauri::Wry>>().0;
    let staging = tempfile::tempdir()?;
    let payload = if choose {
        serde_json::json!({ "key": key, "google": google })
    } else {
        let grants = allowed.map(|items| items.into_iter()
            .map(|e| ((e.id, e.path), e.writable)).collect::<HashMap<_, _>>());
        let index = index.lock().unwrap();
        let notes = index.note_rows()?.into_iter().map(|r| (r.id, r.path));
        let binaries = index.file_rows()?.into_iter().map(|r| (r.id, r.path));
        let embedded = crate::attachments::list_attachments(&root)?.into_iter()
            .map(|a| (format!("attachment:{}", a.sha256), a.rel_path));
        let entries: Vec<_> = notes.chain(binaries).chain(embedded).filter_map(|(id, path)| {
            if vault::rel_path_is_ignored(&path) || vault::resolve_in_vault(&root, &path).is_err() {
                return None;
            }
            let writable = match &grants {
                Some(map) => *map.get(&(id.clone(), path.clone()))?,
                None => true,
            };
            let writable = writable && !id.starts_with("attachment:");
            Some(Entry { id, path, writable })
        }).collect();
        serde_json::json!({ "key": key, "google": google, "root": root, "staging": staging.path(), "entries": entries })
    };
    if choose {
        return drive.run_mobile_plugin_async("choose", payload).await.map_err(|e| AppError::new(e.to_string()));
    }
    #[derive(Deserialize)]
    struct Incoming { id: String, path: String, name: uuid::Uuid, base: String }
    #[derive(Deserialize)]
    struct Transfers { copied: usize, conflicts: usize, incoming: Vec<Incoming> }
    let mut result: Transfers = drive.run_mobile_plugin_async("sync", payload)
        .await.map_err(|e| AppError::new(e.to_string()))?;
    let (current_root, index) = require_vault_at(&state, Some(expected_epoch))?;
    let (notes, binaries) = {
        let db = index.lock().unwrap();
        let notes: HashMap<_, _> = db.note_rows()?.into_iter().map(|r| (r.id, r.path)).collect();
        let files: HashMap<_, _> = db.file_rows()?.into_iter().map(|r| (r.id, r.path)).collect();
        (notes, files)
    };
    for change in result.incoming {
        let is_note = notes.get(&change.id) == Some(&change.path);
        if !is_note && binaries.get(&change.id) != Some(&change.path) {
            result.conflicts += 1;
            continue;
        }
        let bytes = std::fs::read(staging.path().join(change.name.to_string().to_uppercase()))?;
        let target = vault::resolve_in_vault(&current_root, &change.path)?;
        if vault::vault_path_state(&current_root, &change.path) != vault::PathState::Regular
            || crate::notefile::sha256_file(&target)? != change.base {
            result.conflicts += 1;
            continue;
        }
        if is_note {
            let text = std::str::from_utf8(&bytes).map_err(|_| AppError::new("Cloud note is not UTF-8"))?;
            if matches!(crate::notefile::write_note_cas(&current_root, &change.path, text, Some(&change.base))?,
                        crate::notefile::WriteNoteOutcome::Stale) {
                result.conflicts += 1;
                continue;
            }
        } else {
            crate::attachments::write_tree_binary(&current_root, &change.path, &bytes)?;
        }
        result.copied += 1;
    }
    Ok(serde_json::json!({ "copied": result.copied, "conflicts": result.conflicts }))
}
