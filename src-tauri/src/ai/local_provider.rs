use async_trait::async_trait;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;

use super::provider::{AiProvider, ChatMessage, ChatRequest, ChatResponse, TokenUsage};

pub struct LoadedModel {
    pub model: LlamaModel,
    pub backend: LlamaBackend,
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
    state: SharedModelState,
}

impl LocalLlmProvider {
    pub fn new(model_path: &str, gpu_layers: i32, state: SharedModelState) -> Self {
        Self {
            model_path: PathBuf::from(model_path),
            gpu_layers,
            state,
        }
    }
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
    let backend =
        LlamaBackend::init().map_err(|e| format!("Failed to initialize llama backend: {}", e))?;

    // -1 means "all layers on GPU"
    let n_gpu = if gpu_layers < 0 { 999 } else { gpu_layers as u32 };
    let model_params = LlamaModelParams::default().with_n_gpu_layers(n_gpu);
    let model_params = std::pin::pin!(model_params);

    let model = LlamaModel::load_from_file(&backend, path, &model_params)
        .map_err(|e| format!("Failed to load model from {}: {}", path.display(), e))?;

    Ok(LoadedModel {
        model,
        backend,
        path: path.to_path_buf(),
        gpu_layers,
    })
}


fn run_inference(
    loaded: &LoadedModel,
    prompt: &str,
    max_tokens: u32,
    temperature: f64,
    grammar: Option<&str>,
) -> Result<(String, u32, u32), String> {
    let ctx_params =
        LlamaContextParams::default().with_n_ctx(NonZeroU32::new(4096));

    let mut ctx = loaded
        .model
        .new_context(&loaded.backend, ctx_params)
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

    // Build sampler chain: penalties + temperature/greedy + optional grammar
    let n_vocab = loaded.model.n_vocab();
    let mut samplers: Vec<LlamaSampler> = vec![
        LlamaSampler::penalties(n_vocab, 1.2, 0.0, 0.0),
    ];

    if let Some(grammar_str) = grammar {
        match LlamaSampler::grammar(&loaded.model, grammar_str, "root") {
            Ok(gs) => samplers.push(gs),
            Err(e) => log::warn!("Failed to create grammar sampler: {:?}", e),
        }
    }

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

            // Detect repetition — stop if the last 100 chars repeat
            if output.len() > 200 {
                let last = &output[output.len() - 100..];
                let prior = &output[..output.len() - 100];
                if prior.contains(last) {
                    // Trim to the first occurrence
                    if let Some(pos) = output[..output.len() - 100].rfind(last) {
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
        let state = self.state.clone();

        if !model_path.exists() {
            return Err(format!(
                "Model file not found: {}. Download a model in Settings.",
                model_path.display()
            ));
        }

        let max_tokens = request.max_tokens.unwrap_or(2048) as u32;
        let temperature = request.temperature.unwrap_or(0.3);
        let messages = request.messages.clone();

        // Grammar-constrained sampling disabled for now — causes crashes with some models.
        // TODO: debug GBNF grammar compatibility with llama-cpp-2 v0.1.140
        let grammar: Option<String> = None;

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
            run_inference(loaded, &prompt, max_tokens, temperature, grammar.as_deref())
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
