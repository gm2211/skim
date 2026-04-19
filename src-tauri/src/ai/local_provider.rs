use async_trait::async_trait;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;

/// Unix timestamp of the last local-model inference. Used by the idle-eviction
/// watcher to drop the model from VRAM when unused.
pub static LAST_USED_AT: AtomicI64 = AtomicI64::new(0);

pub fn mark_used() {
    LAST_USED_AT.store(chrono::Utc::now().timestamp(), Ordering::Relaxed);
}

use super::provider::{AiProvider, ChatMessage, ChatRequest, ChatResponse, TokenUsage};

/// Global backend singleton — initialized once, never dropped.
/// This avoids BackendAlreadyInitialized errors when models are reloaded.
static LLAMA_BACKEND: OnceLock<LlamaBackend> = OnceLock::new();

fn get_backend() -> Result<&'static LlamaBackend, String> {
    if let Some(b) = LLAMA_BACKEND.get() {
        return Ok(b);
    }
    let backend = LlamaBackend::init()
        .map_err(|e| format!("Failed to initialize llama backend: {}", e))?;
    // If another thread beat us, that's fine — we drop ours and use theirs
    let _ = LLAMA_BACKEND.set(backend);
    LLAMA_BACKEND.get().ok_or_else(|| "Backend initialization failed".to_string())
}

pub struct LoadedModel {
    pub model: LlamaModel,
    pub path: PathBuf,
    pub gpu_layers: i32,
}

// Safety: LlamaModel and LlamaBackend are accessed only behind a Mutex
// and used on a single spawn_blocking thread at a time.
unsafe impl Send for LoadedModel {}
unsafe impl Sync for LoadedModel {}

pub type SharedModelState = Arc<Mutex<Option<LoadedModel>>>;

pub struct LocalLlmProvider {
    model_path: PathBuf,
    gpu_layers: i32,
    n_threads: i32,
    state: SharedModelState,
}

impl LocalLlmProvider {
    pub fn new(model_path: &str, gpu_layers: i32, n_threads: i32, state: SharedModelState) -> Self {
        Self {
            model_path: PathBuf::from(model_path),
            gpu_layers,
            n_threads,
            state,
        }
    }
}

/// Resolve ("cool"|"balanced"|"performance", user_override) to concrete
/// (n_gpu_layers, n_threads). The user-supplied gpu layers override always
/// wins when set to something other than -1 (the "unset" sentinel we use
/// for "let the mode decide").
pub fn resolve_power_profile(mode: &str, user_layers: Option<i32>) -> (i32, i32) {
    let detected = std::thread::available_parallelism()
        .map(|n| n.get() as i32)
        .unwrap_or(8);

    let (layers, threads) = match mode {
        "cool" => (0, 2.max(detected / 4)),
        "performance" => (-1, detected),
        _ => (24, (detected / 2).max(2)), // balanced
    };

    // User explicit override wins if set to a non-default value.
    let final_layers = match user_layers {
        Some(n) if n != 0 && n != -1 => n,
        Some(n) if mode == "balanced" && n == -1 => layers, // keep balanced default
        Some(n) => n,
        None => layers,
    };

    (final_layers, threads)
}

fn format_chat_messages(model: &LlamaModel, messages: &[ChatMessage]) -> Result<String, String> {
    // Try to use the model's built-in chat template
    if let Ok(tmpl) = model.chat_template(None) {
        let chat_msgs: Vec<LlamaChatMessage> = messages
            .iter()
            .filter_map(|m| LlamaChatMessage::new(m.role.clone(), m.content.clone()).ok())
            .collect();
        if let Ok(prompt) = model.apply_chat_template(&tmpl, &chat_msgs, true) {
            return Ok(prompt);
        }
    }

    // Fallback: simple format that works with most models
    let mut prompt = String::new();
    for msg in messages {
        match msg.role.as_str() {
            "system" => {
                prompt.push_str("### System:\n");
                prompt.push_str(&msg.content);
                prompt.push_str("\n\n");
            }
            "user" => {
                prompt.push_str("### User:\n");
                prompt.push_str(&msg.content);
                prompt.push_str("\n\n");
            }
            _ => {
                prompt.push_str(&format!("### {}:\n", msg.role));
                prompt.push_str(&msg.content);
                prompt.push_str("\n\n");
            }
        }
    }
    prompt.push_str("### Assistant:\n");
    Ok(prompt)
}

pub fn load_model(path: &Path, gpu_layers: i32) -> Result<LoadedModel, String> {
    let backend = get_backend()?;

    // -1 means "all layers on GPU"
    let n_gpu = if gpu_layers < 0 { 999 } else { gpu_layers as u32 };
    let model_params = LlamaModelParams::default().with_n_gpu_layers(n_gpu);
    let model_params = std::pin::pin!(model_params);

    let model = LlamaModel::load_from_file(backend, path, &model_params)
        .map_err(|e| format!("Failed to load model from {}: {}", path.display(), e))?;

    Ok(LoadedModel {
        model,
        path: path.to_path_buf(),
        gpu_layers,
    })
}


fn run_inference(
    loaded: &LoadedModel,
    prompt: &str,
    max_tokens: u32,
    temperature: f64,
    n_threads: i32,
) -> Result<(String, u32, u32), String> {
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(NonZeroU32::new(4096))
        .with_n_threads(n_threads)
        .with_n_threads_batch(n_threads);

    let backend = get_backend()?;
    let mut ctx = loaded
        .model
        .new_context(backend, ctx_params)
        .map_err(|e| format!("Failed to create context: {}", e))?;

    // Tokenize the prompt
    let tokens = loaded
        .model
        .str_to_token(prompt, AddBos::Always)
        .map_err(|e| format!("Failed to tokenize prompt: {}", e))?;

    let prompt_token_count = tokens.len() as u32;

    // Create batch and add prompt tokens
    let mut batch = LlamaBatch::new(4096, 1);
    let last_index = (tokens.len() - 1) as i32;
    for (i, token) in (0_i32..).zip(tokens.into_iter()) {
        let is_last = i == last_index;
        batch
            .add(token, i, &[0], is_last)
            .map_err(|e| format!("Failed to add token to batch: {}", e))?;
    }

    // Process the prompt
    ctx.decode(&mut batch)
        .map_err(|e| format!("Failed to decode prompt: {}", e))?;

    // Build sampler chain: penalties → temperature → selection.
    let n_vocab = loaded.model.n_vocab();
    let mut samplers: Vec<LlamaSampler> = Vec::new();

    samplers.push(LlamaSampler::penalties(n_vocab, 1.2, 0.0, 0.0));

    if temperature > 0.01 {
        samplers.push(LlamaSampler::temp(temperature as f32));
        samplers.push(LlamaSampler::dist(42));
    } else {
        samplers.push(LlamaSampler::greedy());
    }

    let mut sampler = LlamaSampler::chain_simple(samplers);

    // Generate tokens
    let mut output = String::new();
    let mut n_decoded = 0u32;
    let mut n_cur = batch.n_tokens();
    let mut decoder = encoding_rs::UTF_8.new_decoder();

    loop {
        if n_decoded >= max_tokens {
            break;
        }

        let new_token = sampler.sample(&ctx, batch.n_tokens() - 1);
        sampler.accept(new_token);

        // Check for end of generation
        if loaded.model.is_eog_token(new_token) {
            break;
        }

        // Convert token to text
        if let Ok(piece) = loaded.model.token_to_piece(new_token, &mut decoder, true, None) {
            // Stop on ChatML end-of-turn marker
            if output.ends_with("<|im_end") && piece.contains("|>") {
                output.truncate(output.len() - "<|im_end".len());
                break;
            }
            output.push_str(&piece);

            // Detect repetition — stop if the last ~100 chars repeat
            let char_count = output.chars().count();
            if char_count > 200 {
                let boundary: usize = output.char_indices().rev().nth(99).map(|(i, _)| i).unwrap_or(0);
                let last = &output[boundary..];
                let prior = &output[..boundary];
                if prior.contains(last) {
                    if let Some(pos) = prior.rfind(last) {
                        output.truncate(pos + last.len());
                    }
                    break;
                }
            }
        }

        n_decoded += 1;

        // Prepare next batch
        batch.clear();
        batch
            .add(new_token, n_cur, &[0], true)
            .map_err(|e| format!("Failed to add generated token: {}", e))?;
        n_cur += 1;

        ctx.decode(&mut batch)
            .map_err(|e| format!("Failed to decode token: {}", e))?;
    }

    // Clean up trailing ChatML markers
    let output = output
        .trim_end_matches("<|im_end|>")
        .trim_end_matches("<|im_end")
        .trim()
        .to_string();

    Ok((output, prompt_token_count, n_decoded))
}

#[async_trait]
impl AiProvider for LocalLlmProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let model_path = self.model_path.clone();
        let gpu_layers = self.gpu_layers;
        let n_threads = self.n_threads;
        let state = self.state.clone();

        if !model_path.exists() {
            return Err(format!(
                "Model file not found: {}. Download a model in Settings.",
                model_path.display()
            ));
        }

        let max_tokens = request.max_tokens.unwrap_or(2048) as u32;
        let temperature = request.temperature.unwrap_or(0.3);
        let mut messages = request.messages.clone();

        // When using grammar-constrained JSON output, disable thinking mode
        // for models that support it (Qwen 3.x, DeepSeek, etc.).
        // Thinking tokens like <think> break grammar sampling because
        // the grammar expects JSON from the first token.
        if request.json_mode {
            if let Some(last) = messages.last_mut() {
                if last.role == "user" {
                    last.content.push_str(" /nothink");
                }
            }
        }

        mark_used();
        let result = tokio::task::spawn_blocking(move || {
            let mut guard = state.blocking_lock();

            let needs_load = match guard.as_ref() {
                None => true,
                Some(loaded) => loaded.path != model_path || loaded.gpu_layers != gpu_layers,
            };

            if needs_load {
                log::info!("Loading local model: {}", model_path.display());
                let loaded = load_model(&model_path, gpu_layers)?;
                *guard = Some(loaded);
                log::info!("Model loaded successfully");
            }

            let loaded = guard.as_ref().unwrap();
            let prompt = format_chat_messages(&loaded.model, &messages)?;
            let out = run_inference(loaded, &prompt, max_tokens, temperature, n_threads);
            mark_used();
            out
            // For local models, JSON extraction is handled by extract_json_object()
            // in the caller. Grammar-constrained sampling is not used due to
            // BPE tokenizer incompatibilities in llama.cpp's grammar engine.
        })
        .await
        .map_err(|e| format!("Inference task failed: {}", e))??;

        let (content, prompt_tokens, completion_tokens) = result;

        Ok(ChatResponse {
            content,
            model: self
                .model_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string(),
            usage: Some(TokenUsage {
                prompt_tokens: Some(prompt_tokens as i64),
                completion_tokens: Some(completion_tokens as i64),
            }),
        })
    }

    fn name(&self) -> &str {
        "local"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Find the Qwen 3.5 model in the app's models directory.
    fn find_qwen_model() -> Option<PathBuf> {
        let home = std::env::var("HOME").ok()?;
        let models_dir = PathBuf::from(&home)
            .join("Library/Application Support/com.skim.rss/models");
        if models_dir.exists() {
            if let Some(p) = find_gguf_matching(&models_dir, "qwen") {
                return Some(p);
            }
        }
        // Fallback: any .gguf in the models dir
        if models_dir.exists() {
            return find_gguf_matching(&models_dir, "");
        }
        None
    }

    fn find_gguf_matching(dir: &Path, pattern: &str) -> Option<PathBuf> {
        std::fs::read_dir(dir)
            .ok()?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .find(|p| {
                p.extension().is_some_and(|ext| ext == "gguf")
                    && (pattern.is_empty()
                        || p.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_lowercase()
                            .contains(pattern))
            })
    }

    const ARTICLE_TEXT: &str = "Scientists at CERN have announced the discovery of a new \
        subatomic particle that could reshape our understanding of quantum physics. The particle, \
        tentatively named the Zephyr boson, was detected during high-energy collisions in the \
        Large Hadron Collider. Researchers say the Zephyr boson has properties that do not fit \
        neatly into the Standard Model, the theoretical framework that has governed particle \
        physics for decades. If confirmed by independent experiments, this discovery could open \
        the door to new physics beyond the Standard Model, potentially explaining dark matter \
        and dark energy. The research team, led by Dr. Elena Vasquez, published their findings \
        in the journal Nature Physics. The discovery has generated significant excitement in the \
        scientific community, with many physicists calling it the most important finding since \
        the Higgs boson in 2012.";

    #[test]
    fn test_summarize_local_model() {
        let Some(model_path) = find_qwen_model() else {
            panic!("No GGUF model found — download a model via the app first");
        };
        println!("Using model: {}", model_path.display());

        let loaded = load_model(&model_path, -1).expect("Failed to load model");

        let system = "You write concisely. Always respond with valid JSON only.";
        let user = format!(
            "Summarize this article in 1-2 sentences.\n\n\
            Article: {}\n\n\
            Respond with JSON: {{\"summary\": \"your summary\", \"notes\": \"none\"}} /nothink",
            ARTICLE_TEXT
        );

        let messages = vec![
            ChatMessage { role: "system".to_string(), content: system.to_string() },
            ChatMessage { role: "user".to_string(), content: user },
        ];
        let prompt = format_chat_messages(&loaded.model, &messages)
            .expect("Failed to format messages");

        let result = run_inference(&loaded, &prompt, 200, 0.5, 4);
        match result {
            Ok((output, prompt_tokens, gen_tokens)) => {
                println!("=== OUTPUT ({} prompt, {} gen tokens) ===", prompt_tokens, gen_tokens);
                println!("{}", output);

                // Try to extract JSON from output
                if let Some(json_str) = crate::commands::ai::extract_json_object(&output) {
                    println!("Extracted JSON: {}", json_str);
                    let parsed: Result<serde_json::Value, _> = serde_json::from_str(json_str);
                    assert!(parsed.is_ok(), "Extracted text must be valid JSON: {}", json_str);
                } else {
                    println!("No JSON found in output — model did not produce JSON");
                }
            }
            Err(e) => panic!("Inference failed: {}", e),
        }
    }
}
