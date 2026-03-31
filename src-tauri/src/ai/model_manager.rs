use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::Emitter;
use tokio::io::AsyncWriteExt;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HfModelInfoRaw {
    pub id: String,
    pub author: Option<String>,
    pub downloads: Option<i64>,
    pub likes: Option<i64>,
    pub tags: Option<Vec<String>>,
    pub pipeline_tag: Option<String>,
    #[serde(rename = "lastModified")]
    pub last_modified: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HfModelInfo {
    pub id: String,
    pub author: Option<String>,
    pub downloads: Option<i64>,
    pub likes: Option<i64>,
    pub tags: Option<Vec<String>>,
    pub pipeline_tag: Option<String>,
    pub last_modified: Option<String>,
    pub params_billions: Option<f64>,
    pub recommended_file_size: Option<u64>,
    pub summarization_rank: Option<u32>,
    pub summarization_score: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HfModelFile {
    pub filename: String,
    pub size: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalModel {
    pub filename: String,
    pub path: String,
    pub size_bytes: u64,
    pub is_partial: bool,
    pub download_repo_id: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct PartialDownloadMeta {
    repo_id: String,
    filename: String,
}

#[derive(Clone, Serialize)]
pub struct DownloadProgress {
    pub filename: String,
    pub downloaded: u64,
    pub total: u64,
    pub percent: f64,
}

fn extract_base_model(tags: &Option<Vec<String>>) -> Option<String> {
    tags.as_ref()?.iter().find_map(|t| {
        let stripped = t.strip_prefix("base_model:")?;
        if stripped.starts_with("quantized:") {
            return None;
        }
        Some(stripped.to_string())
    })
}

#[derive(Deserialize)]
struct SafetensorsInfo {
    total: Option<u64>,
}

#[derive(Deserialize)]
struct BaseModelInfo {
    safetensors: Option<SafetensorsInfo>,
}

// Preferred quantizations in priority order
const PREFERRED_QUANTS: &[&str] = &["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q8_0", "Q3_K_M"];

async fn fetch_recommended_size(client: &reqwest::Client, repo_id: &str) -> Option<u64> {
    let url = format!("https://huggingface.co/api/models/{}/tree/main", repo_id);
    let entries: Vec<HfTreeEntry> = client.get(&url).send().await.ok()?.json().await.ok()?;
    let gguf_files: Vec<&HfTreeEntry> = entries
        .iter()
        .filter(|e| e.entry_type == "file" && e.path.ends_with(".gguf"))
        .collect();

    // Find the first preferred quant that exists
    for quant in PREFERRED_QUANTS {
        if let Some(entry) = gguf_files.iter().find(|e| e.path.contains(quant)) {
            return entry.size;
        }
    }
    // Fallback: smallest gguf file
    gguf_files.iter().filter_map(|e| e.size).min()
}

#[derive(Deserialize)]
struct ProllmResponse {
    records: Vec<ProllmRecord>,
}

#[derive(Deserialize, Clone)]
struct ProllmRecord {
    model_id: String,
    model_name: String,
    metric_accuracy: Option<f64>,
    metric_instruct: Option<f64>,
    metric_quality: Option<f64>,
}

impl ProllmRecord {
    fn avg_score(&self) -> f64 {
        let a = self.metric_accuracy.unwrap_or(0.0);
        let i = self.metric_instruct.unwrap_or(0.0);
        let q = self.metric_quality.unwrap_or(0.0);
        (a + i + q) / 3.0
    }
}

async fn fetch_summarization_leaderboard(client: &reqwest::Client) -> Vec<ProllmRecord> {
    let url = "https://backend.prollm.ai/leaderboard/summarization?language=english&level=advanced";
    let resp = match client.get(url).send().await {
        Ok(r) => r,
        Err(_) => return vec![],
    };
    let data: ProllmResponse = match resp.json().await {
        Ok(d) => d,
        Err(_) => return vec![],
    };
    let mut records = data.records;
    records.sort_by(|a, b| b.avg_score().partial_cmp(&a.avg_score()).unwrap_or(std::cmp::Ordering::Equal));
    records
}

/// Normalize a model name for fuzzy matching: lowercase, strip punctuation, collapse whitespace
fn normalize_for_match(s: &str) -> String {
    s.to_lowercase()
        .replace(|c: char| !c.is_alphanumeric() && c != ' ', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Extract the core model identity: e.g. "llama 3 1 8b instruct" from various formats
fn extract_model_key(name: &str) -> String {
    let n = normalize_for_match(name);
    // Strip common suffixes/prefixes
    let n = n.replace("gguf", "").replace("turbo", "").replace("preview", "")
        .replace("hf", "").replace("fp8", "").replace("fp16", "");
    // Strip org prefixes like "meta llama", "google", "bartowski", etc.
    let parts: Vec<&str> = n.split_whitespace().collect();
    // Skip known org names at the start
    let skip = if parts.first().map_or(false, |p| ["meta", "google", "microsoft", "bartowski", "maziyarpanahi", "qwen", "nvidia", "mistralai", "unsloth"].contains(p)) {
        1
    } else {
        0
    };
    parts[skip..].join(" ").trim().to_string()
}

/// Try to match a HuggingFace model to a prollm.ai leaderboard entry
fn match_leaderboard(base_model: &Option<String>, hf_id: &str, leaderboard: &[ProllmRecord]) -> Option<(u32, f64)> {
    // Build keys to match against
    let hf_key = extract_model_key(hf_id.split('/').last().unwrap_or(hf_id));
    let base_key = base_model.as_deref().map(|b| extract_model_key(b.split('/').last().unwrap_or(b)));

    for (rank, record) in leaderboard.iter().enumerate() {
        let lb_key_id = extract_model_key(&record.model_id);
        let lb_key_name = extract_model_key(&record.model_name);

        // Check if either the HF name or base model name matches the leaderboard entry
        for lb_key in [&lb_key_id, &lb_key_name] {
            if lb_key.is_empty() { continue; }

            // Compare with spaces removed too (handles "llama3" vs "llama 3")
            let lb_compact = lb_key.replace(' ', "");
            let hf_compact = hf_key.replace(' ', "");

            if hf_compact.contains(&lb_compact) || lb_compact.contains(&hf_compact)
                || hf_key.contains(lb_key) || lb_key.contains(&hf_key)
            {
                return Some(((rank + 1) as u32, record.avg_score()));
            }
            if let Some(ref bk) = base_key {
                let bk_compact = bk.replace(' ', "");
                if bk_compact.contains(&lb_compact) || lb_compact.contains(&bk_compact)
                    || bk.contains(lb_key) || lb_key.contains(bk)
                {
                    return Some(((rank + 1) as u32, record.avg_score()));
                }
            }
        }
    }
    None
}

async fn fetch_param_count(client: &reqwest::Client, base_model: &str) -> Option<f64> {
    let url = format!(
        "https://huggingface.co/api/models/{}?expand[]=safetensors",
        base_model
    );
    let resp = client.get(&url).send().await.ok()?;
    let info: BaseModelInfo = resp.json().await.ok()?;
    let total = info.safetensors?.total?;
    Some(total as f64 / 1_000_000_000.0)
}

pub async fn search_hf_models(query: &str) -> Result<Vec<HfModelInfo>, String> {
    let client = reqwest::Client::new();
    let url = format!(
        "https://huggingface.co/api/models?filter=gguf&search={}&sort=downloads&direction=-1&limit=20",
        urlencoding::encode(query)
    );
    let raw_models: Vec<HfModelInfoRaw> = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("HuggingFace search failed: {}", e))?
        .json()
        .await
        .map_err(|e| format!("Failed to parse HuggingFace response: {}", e))?;

    // Collect unique base models to fetch param counts
    let base_models: std::collections::HashMap<String, String> = raw_models
        .iter()
        .filter_map(|m| {
            let base = extract_base_model(&m.tags)?;
            Some((m.id.clone(), base))
        })
        .collect();

    // Fetch param counts and recommended file sizes in parallel
    let unique_bases: Vec<String> = base_models.values().cloned().collect::<std::collections::HashSet<_>>().into_iter().collect();
    let param_futures: Vec<_> = unique_bases
        .iter()
        .map(|base| {
            let client = client.clone();
            let base = base.clone();
            async move {
                let count = fetch_param_count(&client, &base).await;
                (base, count)
            }
        })
        .collect();

    let size_futures: Vec<_> = raw_models
        .iter()
        .map(|m| {
            let client = client.clone();
            let id = m.id.clone();
            async move {
                let size = fetch_recommended_size(&client, &id).await;
                (id, size)
            }
        })
        .collect();

    // Also fetch the prollm.ai summarization leaderboard
    let leaderboard_future = fetch_summarization_leaderboard(&client);

    let (param_results_vec, size_results_vec, leaderboard) = futures_util::future::join3(
        futures_util::future::join_all(param_futures),
        futures_util::future::join_all(size_futures),
        leaderboard_future,
    ).await;

    let param_results: std::collections::HashMap<String, f64> = param_results_vec
        .into_iter()
        .filter_map(|(base, count)| Some((base, count?)))
        .collect();

    let size_results: std::collections::HashMap<String, u64> = size_results_vec
        .into_iter()
        .filter_map(|(id, size)| Some((id, size?)))
        .collect();

    // Merge into results
    let models = raw_models
        .into_iter()
        .map(|m| {
            let base_model = base_models.get(&m.id).cloned();
            let params = base_model
                .as_ref()
                .and_then(|base| param_results.get(base))
                .copied();
            let rec_size = size_results.get(&m.id).copied();
            let (sum_rank, sum_score) = match_leaderboard(&base_model, &m.id, &leaderboard)
                .map(|(r, s)| (Some(r), Some(s)))
                .unwrap_or((None, None));
            HfModelInfo {
                id: m.id,
                author: m.author,
                downloads: m.downloads,
                likes: m.likes,
                tags: m.tags,
                pipeline_tag: m.pipeline_tag,
                last_modified: m.last_modified,
                params_billions: params,
                recommended_file_size: rec_size,
                summarization_rank: sum_rank,
                summarization_score: sum_score,
            }
        })
        .collect();

    Ok(models)
}

#[derive(Deserialize)]
struct HfTreeEntry {
    #[serde(rename = "type")]
    entry_type: String,
    path: String,
    size: Option<u64>,
}

pub async fn get_hf_model_files(repo_id: &str) -> Result<Vec<HfModelFile>, String> {
    let client = reqwest::Client::new();
    let url = format!("https://huggingface.co/api/models/{}/tree/main", repo_id);
    let entries: Vec<HfTreeEntry> = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch model files: {}", e))?
        .json()
        .await
        .map_err(|e| format!("Failed to parse model files: {}", e))?;

    let files = entries
        .into_iter()
        .filter(|e| e.entry_type == "file" && e.path.ends_with(".gguf"))
        .map(|e| HfModelFile {
            filename: e.path,
            size: e.size,
        })
        .collect();

    Ok(files)
}

pub async fn download_model(
    app_handle: &tauri::AppHandle,
    repo_id: &str,
    filename: &str,
    target_dir: &Path,
    cancel_flag: Arc<AtomicBool>,
) -> Result<PathBuf, String> {
    // Reset cancel flag
    cancel_flag.store(false, Ordering::SeqCst);

    // Ensure target directory exists
    tokio::fs::create_dir_all(target_dir)
        .await
        .map_err(|e| format!("Failed to create models directory: {}", e))?;

    let target_path = target_dir.join(filename);
    let part_path = target_dir.join(format!("{}.part", filename));
    let meta_path = target_dir.join(format!("{}.part.meta", filename));
    let url = format!(
        "https://huggingface.co/{}/resolve/main/{}",
        repo_id, filename
    );

    // Save download metadata for resume
    let meta = PartialDownloadMeta {
        repo_id: repo_id.to_string(),
        filename: filename.to_string(),
    };
    if let Ok(meta_json) = serde_json::to_string(&meta) {
        let _ = tokio::fs::write(&meta_path, meta_json).await;
    }

    // Also write a .size file so we can detect truncated downloads later
    let size_path = target_dir.join(format!("{}.size", filename));

    // If there's a truncated .gguf file but no .part file, rename it to .part for resume
    if target_path.exists() && !part_path.exists() {
        let _ = tokio::fs::rename(&target_path, &part_path).await;
    }

    // Check for existing partial download
    let existing_size = if part_path.exists() {
        tokio::fs::metadata(&part_path)
            .await
            .map(|m| m.len())
            .unwrap_or(0)
    } else {
        0
    };

    let client = reqwest::Client::new();
    let mut request = client.get(&url);

    // Resume from where we left off
    if existing_size > 0 {
        request = request.header("Range", format!("bytes={}-", existing_size));
        log::info!("Resuming download of {} from {} bytes", filename, existing_size);
    }

    let response = request
        .send()
        .await
        .map_err(|e| format!("Download request failed: {}", e))?;

    let status = response.status();
    if !status.is_success() && status.as_u16() != 206 {
        // If resume not supported (no 206), start fresh
        if existing_size > 0 && status.is_client_error() {
            let _ = tokio::fs::remove_file(&part_path).await;
            return Box::pin(download_model(app_handle, repo_id, filename, target_dir, cancel_flag)).await;
        }
        return Err(format!("Download failed with status: {}", status));
    }

    // Calculate total size
    let resumed = status.as_u16() == 206;
    let content_length = response.content_length().unwrap_or(0);
    let total = if resumed {
        existing_size + content_length
    } else {
        content_length
    };
    let mut downloaded: u64 = if resumed { existing_size } else { 0 };

    // Save expected total size so we can detect truncated files
    if total > 0 {
        let _ = tokio::fs::write(&size_path, total.to_string()).await;
    }

    // Open file for appending (resume) or creating fresh
    let file = if resumed {
        tokio::fs::OpenOptions::new()
            .append(true)
            .open(&part_path)
            .await
            .map_err(|e| format!("Failed to open partial file: {}", e))?
    } else {
        tokio::fs::File::create(&part_path)
            .await
            .map_err(|e| format!("Failed to create file: {}", e))?
    };
    let mut file = file;

    let mut stream = response.bytes_stream();
    let mut last_emit = std::time::Instant::now();

    while let Some(chunk) = stream.next().await {
        if cancel_flag.load(Ordering::SeqCst) {
            // Keep the .part file for resume — don't delete it
            return Err("Download paused — will resume next time".to_string());
        }

        let chunk = chunk.map_err(|e| format!("Download stream error: {}", e))?;
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("Failed to write file: {}", e))?;
        downloaded += chunk.len() as u64;

        // Emit progress at most every 100ms to avoid flooding
        if last_emit.elapsed().as_millis() >= 100 {
            let _ = app_handle.emit(
                "model-download-progress",
                DownloadProgress {
                    filename: filename.to_string(),
                    downloaded,
                    total,
                    percent: if total > 0 {
                        (downloaded as f64 / total as f64) * 100.0
                    } else {
                        0.0
                    },
                },
            );
            last_emit = std::time::Instant::now();
        }
    }

    file.flush()
        .await
        .map_err(|e| format!("Failed to flush file: {}", e))?;

    // Rename .part → final filename and clean up meta
    tokio::fs::rename(&part_path, &target_path)
        .await
        .map_err(|e| format!("Failed to finalize download: {}", e))?;
    let _ = tokio::fs::remove_file(&meta_path).await;
    let _ = tokio::fs::remove_file(&size_path).await;

    // Emit final 100% progress
    let _ = app_handle.emit(
        "model-download-progress",
        DownloadProgress {
            filename: filename.to_string(),
            downloaded,
            total: downloaded,
            percent: 100.0,
        },
    );

    Ok(target_path)
}


/// Parse a GGUF file header to determine if the file is truncated.
/// GGUF format: magic(4) + version(4) + tensor_count(8) + metadata_kv_count(8)
/// Then metadata KV pairs, then tensor infos, then tensor data.
/// We read tensor infos to find the last tensor's offset + size.
fn is_gguf_truncated(path: &Path, actual_size: u64) -> bool {
    use std::io::{Read, Seek, SeekFrom};

    let mut f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return true,
    };

    let mut buf4 = [0u8; 4];
    let mut buf8 = [0u8; 8];

    // Magic
    if f.read_exact(&mut buf4).is_err() || &buf4 != b"GGUF" {
        return true;
    }

    // Version (u32)
    if f.read_exact(&mut buf4).is_err() {
        return true;
    }
    let version = u32::from_le_bytes(buf4);
    if version < 2 || version > 3 {
        return true; // Unknown version
    }

    // Tensor count (u64)
    if f.read_exact(&mut buf8).is_err() {
        return true;
    }
    let tensor_count = u64::from_le_bytes(buf8);

    // Metadata KV count (u64)
    if f.read_exact(&mut buf8).is_err() {
        return true;
    }
    let kv_count = u64::from_le_bytes(buf8);

    // Skip metadata KV pairs — each has: key_len(u64) + key + value_type(u32) + value
    for _ in 0..kv_count {
        // Key length
        if f.read_exact(&mut buf8).is_err() {
            return true;
        }
        let key_len = u64::from_le_bytes(buf8);
        if f.seek(SeekFrom::Current(key_len as i64)).is_err() {
            return true;
        }

        // Value type (u32)
        if f.read_exact(&mut buf4).is_err() {
            return true;
        }
        let vtype = u32::from_le_bytes(buf4);

        // Skip value based on type
        if skip_gguf_value(&mut f, vtype).is_err() {
            return true;
        }
    }

    // Now read tensor infos to find expected data end
    let mut max_data_end: u64 = 0;
    for _ in 0..tensor_count {
        // Tensor name: len(u64) + string
        if f.read_exact(&mut buf8).is_err() {
            return true;
        }
        let name_len = u64::from_le_bytes(buf8);
        if f.seek(SeekFrom::Current(name_len as i64)).is_err() {
            return true;
        }

        // n_dimensions (u32)
        if f.read_exact(&mut buf4).is_err() {
            return true;
        }
        let n_dims = u32::from_le_bytes(buf4);

        // dimensions (n_dims * u64)
        let mut n_elements: u64 = 1;
        for _ in 0..n_dims {
            if f.read_exact(&mut buf8).is_err() {
                return true;
            }
            n_elements *= u64::from_le_bytes(buf8);
        }

        // type (u32)
        if f.read_exact(&mut buf4).is_err() {
            return true;
        }
        let tensor_type = u32::from_le_bytes(buf4);

        // offset (u64) — offset from start of tensor data section
        if f.read_exact(&mut buf8).is_err() {
            return true;
        }
        let offset = u64::from_le_bytes(buf8);

        // Calculate tensor size in bytes based on type
        let bits_per_element = gguf_type_bits(tensor_type);
        let tensor_bytes = (n_elements * bits_per_element + 7) / 8;

        let data_end = offset + tensor_bytes;
        if data_end > max_data_end {
            max_data_end = data_end;
        }
    }

    // The tensor data section starts after alignment from current position
    let header_end = f.stream_position().unwrap_or(0);
    // GGUF default alignment is 32 bytes
    let alignment: u64 = 32;
    let data_start = (header_end + alignment - 1) / alignment * alignment;
    let expected_size = data_start + max_data_end;

    // If actual file is significantly smaller than expected, it's truncated
    // Allow 1KB tolerance for alignment differences
    actual_size + 1024 < expected_size
}

/// Bits per element for GGUF tensor types
fn gguf_type_bits(t: u32) -> u64 {
    match t {
        0 => 32,   // F32
        1 => 16,   // F16
        2 => 5,    // Q4_0 (4.5 effective)
        3 => 5,    // Q4_1
        6 => 5,    // Q5_0
        7 => 6,    // Q5_1
        8 => 8,    // Q8_0
        9 => 9,    // Q8_1
        10 => 3,   // Q2_K
        11 => 4,   // Q3_K_S
        12 => 4,   // Q3_K_M
        13 => 4,   // Q3_K_L
        14 => 5,   // Q4_K_S
        15 => 5,   // Q4_K_M
        16 => 6,   // Q5_K_S
        17 => 6,   // Q5_K_M
        18 => 7,   // Q6_K
        19 => 8,   // Q8_K
        20 => 2,   // IQ2_XXS
        21 => 2,   // IQ2_XS
        22 => 3,   // IQ3_XXS
        23 => 2,   // IQ1_S
        24 => 4,   // IQ4_NL
        25 => 3,   // IQ3_S
        26 => 3,   // IQ2_S
        27 => 4,   // IQ4_XS
        28 => 8,   // I8
        29 => 16,  // I16
        30 => 32,  // I32
        31 => 64,  // I64
        32 => 64,  // F64
        33 => 2,   // IQ1_M
        34 => 16,  // BF16
        _ => 8,    // Unknown, assume 8
    }
}

/// Skip a GGUF metadata value based on its type
fn skip_gguf_value(f: &mut std::fs::File, vtype: u32) -> std::io::Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let mut buf4 = [0u8; 4];
    let mut buf8 = [0u8; 8];
    match vtype {
        0 => { f.seek(SeekFrom::Current(1))?; } // UINT8
        1 => { f.seek(SeekFrom::Current(1))?; } // INT8
        2 => { f.seek(SeekFrom::Current(2))?; } // UINT16
        3 => { f.seek(SeekFrom::Current(2))?; } // INT16
        4 => { f.seek(SeekFrom::Current(4))?; } // UINT32
        5 => { f.seek(SeekFrom::Current(4))?; } // INT32
        6 => { f.seek(SeekFrom::Current(4))?; } // FLOAT32
        7 => { f.seek(SeekFrom::Current(1))?; } // BOOL
        8 => { // STRING: len(u64) + data
            f.read_exact(&mut buf8)?;
            let len = u64::from_le_bytes(buf8);
            f.seek(SeekFrom::Current(len as i64))?;
        }
        9 => { // ARRAY: type(u32) + count(u64) + values
            f.read_exact(&mut buf4)?;
            let elem_type = u32::from_le_bytes(buf4);
            f.read_exact(&mut buf8)?;
            let count = u64::from_le_bytes(buf8);
            for _ in 0..count {
                skip_gguf_value(f, elem_type)?;
            }
        }
        10 => { f.seek(SeekFrom::Current(8))?; } // UINT64
        11 => { f.seek(SeekFrom::Current(8))?; } // INT64
        12 => { f.seek(SeekFrom::Current(8))?; } // FLOAT64
        _ => { return Err(std::io::Error::new(std::io::ErrorKind::Other, "unknown gguf value type")); }
    }
    Ok(())
}

pub fn list_local_models(model_dir: &Path) -> Result<Vec<LocalModel>, String> {
    if !model_dir.exists() {
        return Ok(vec![]);
    }

    let mut models = Vec::new();
    let entries =
        std::fs::read_dir(model_dir).map_err(|e| format!("Failed to read models directory: {}", e))?;

    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        let is_gguf = path.extension().and_then(|e| e.to_str()) == Some("gguf");
        let is_part = name.ends_with(".gguf.part");

        // Skip metadata sidecar files
        if name.ends_with(".meta") || name.ends_with(".size") {
            continue;
        }

        if is_gguf || is_part {
            let metadata = std::fs::metadata(&path).map_err(|e| e.to_string())?;
            let file_size = metadata.len();
            let gguf_name = if is_part {
                name.trim_end_matches(".part").to_string()
            } else {
                name.clone()
            };

            // Check if this is a truncated .gguf file
            let is_truncated = if is_gguf {
                // First check .size sidecar
                let size_path = model_dir.join(format!("{}.size", gguf_name));
                if let Ok(expected_str) = std::fs::read_to_string(&size_path) {
                    expected_str.trim().parse::<u64>().map_or(false, |expected| file_size < expected)
                } else {
                    // No sidecar — parse GGUF header to compute expected size
                    is_gguf_truncated(&path, file_size)
                }
            } else {
                false
            };

            let is_incomplete = is_part || is_truncated;

            // Read repo_id from meta file (works for both .part and truncated .gguf)
            let repo_id = if is_incomplete {
                let meta_path = model_dir.join(format!("{}.part.meta", gguf_name));
                std::fs::read_to_string(meta_path)
                    .ok()
                    .and_then(|s| serde_json::from_str::<PartialDownloadMeta>(&s).ok())
                    .map(|m| m.repo_id)
            } else {
                None
            };

            models.push(LocalModel {
                filename: gguf_name,
                path: path.to_string_lossy().to_string(),
                size_bytes: file_size,
                is_partial: is_incomplete,
                download_repo_id: repo_id,
            });
        }
    }

    models.sort_by(|a, b| a.filename.cmp(&b.filename));
    Ok(models)
}

pub fn delete_local_model(model_path: &Path) -> Result<(), String> {
    if model_path.exists() {
        std::fs::remove_file(model_path).map_err(|e| format!("Failed to delete model: {}", e))?;
    }
    // Also clean up sidecar files (.part, .part.meta, .size)
    let name = model_path.file_name().unwrap_or_default().to_string_lossy();
    let gguf_name = name.trim_end_matches(".part");
    if let Some(dir) = model_path.parent() {
        let _ = std::fs::remove_file(dir.join(format!("{}.part", gguf_name)));
        let _ = std::fs::remove_file(dir.join(format!("{}.part.meta", gguf_name)));
        let _ = std::fs::remove_file(dir.join(format!("{}.size", gguf_name)));
    }
    Ok(())
}
