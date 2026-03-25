use async_trait::async_trait;
use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;
use llama_cpp_2::json_schema_to_grammar;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;

use super::provider::{AiProvider, ChatMessage, ChatRequest, ChatResponse, TokenUsage};

/// JSON schema for summary output — used with json_schema_to_grammar()
/// to generate a GBNF grammar via llama.cpp's own converter.
const JSON_SCHEMA_OBJECT: &str = r#"{"type": "object"}"#;

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
    grammar: Option<&str>,
) -> Result<(String, u32, u32), String> {
    let ctx_params =
        LlamaContextParams::default().with_n_ctx(NonZeroU32::new(4096));

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

    // Build sampler chain: grammar (first) → penalties → temperature → selection (last)
    // Grammar must come first to constrain the token space before other samplers operate.
    // Chain must end with a selection sampler (greedy or dist).
    let n_vocab = loaded.model.n_vocab();
    let mut samplers: Vec<LlamaSampler> = Vec::new();

    if let Some(ref grammar_str) = grammar {
        match LlamaSampler::grammar(&loaded.model, grammar_str, "root") {
            Ok(gs) => samplers.push(gs),
            Err(e) => log::warn!("Failed to create grammar sampler: {:?}", e),
        }
    }

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

        // Use llama.cpp's own json_schema_to_grammar converter to generate
        // a GBNF grammar compatible with this version of the library.
        let grammar: Option<String> = if request.json_mode {
            match json_schema_to_grammar(JSON_SCHEMA_OBJECT) {
                Ok(g) => {
                    log::info!("Generated JSON grammar: {}...", &g[..g.len().min(100)]);
                    Some(g)
                }
                Err(e) => {
                    log::warn!("Failed to generate JSON grammar: {:?}, falling back to no grammar", e);
                    None
                }
            }
        } else {
            None
        };

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
    fn test_json_schema_grammar_generation() {
        let grammar = json_schema_to_grammar(JSON_SCHEMA_OBJECT)
            .expect("json_schema_to_grammar should succeed");
        println!("Generated grammar:\n{}", grammar);
        assert!(grammar.contains("root"), "Grammar must have a root rule");
        assert!(grammar.contains("object"), "Grammar must define object");
        assert!(grammar.contains("string"), "Grammar must define string");
    }

    #[test]
    fn test_summarize_grammar_llama() {
        let Some(model_path) = find_qwen_model() else {
            panic!("No Qwen GGUF model found");
        };
        println!("Using model: {}", model_path.display());
        let loaded = load_model(&model_path, -1).expect("Failed to load model");

        // Test: use json_schema_to_grammar (same as what worked for step 0 before)
        let g1 = json_schema_to_grammar(JSON_SCHEMA_OBJECT)
            .expect("Failed to generate grammar");
        println!("=== Test json_schema_to_grammar output");
        println!("Creating grammar sampler...");
        match LlamaSampler::grammar(&loaded.model, &g1, "root") {
            Ok(mut sampler) => {
                println!("Grammar sampler created OK. Trying to sample...");
                // Create a minimal context and try sampling
                let backend = get_backend().unwrap();
                let ctx_params = LlamaContextParams::default().with_n_ctx(NonZeroU32::new(512));
                let mut ctx = loaded.model.new_context(backend, ctx_params).unwrap();

                let messages = vec![
                    ChatMessage { role: "user".to_string(), content: "Return JSON: {\"test\": true} /nothink".to_string() },
                ];
                let prompt_str = format_chat_messages(&loaded.model, &messages).unwrap();
                let tokens = loaded.model.str_to_token(&prompt_str, AddBos::Always).unwrap();
                let mut batch = LlamaBatch::new(4096, 1);
                let last_idx = (tokens.len() - 1) as i32;
                for (i, token) in (0_i32..).zip(tokens.into_iter()) {
                    batch.add(token, i, &[0], i == last_idx).unwrap();
                }
                ctx.decode(&mut batch).unwrap();

                println!("Context ready, generating tokens...");
                // Build chain manually — grammar first, then greedy for selection
                let greedy = LlamaSampler::greedy();
                let mut chain = LlamaSampler::chain(vec![sampler, greedy], true);
                let mut output = String::new();
                let mut n_cur = batch.n_tokens();
                let mut decoder = encoding_rs::UTF_8.new_decoder();
                for step in 0..50 {
                    let token = chain.sample(&ctx, batch.n_tokens() - 1);
                    chain.accept(token);
                    if loaded.model.is_eog_token(token) {
                        println!("Step {}: EOG", step);
                        break;
                    }
                    if let Ok(piece) = loaded.model.token_to_piece(token, &mut decoder, true, None) {
                        print!("{}", piece);
                        output.push_str(&piece);
                    }
                    batch.clear();
                    batch.add(token, n_cur, &[0], true).unwrap();
                    n_cur += 1;
                    ctx.decode(&mut batch).unwrap();
                }
                println!("Generated: {}", output);
            }
            Err(e) => println!("Grammar sampler creation FAILED: {:?}", e),
        }

        println!("=== Test via run_inference");
        let r1 = run_inference(&loaded, "Say hello.\n", 10, 0.1, Some(&g1));
        println!("Result 1: {:?}", r1.as_ref().map(|(s,_,_)| s.as_str()));

        // Test 2: JSON grammar from json_schema_to_grammar
        let grammar_str = json_schema_to_grammar(JSON_SCHEMA_OBJECT)
            .expect("Failed to generate grammar");
        println!("=== Test JSON grammar");

        let messages = vec![
            ChatMessage { role: "system".to_string(), content: "Respond with JSON only.".to_string() },
            ChatMessage { role: "user".to_string(), content: "Return {\"hello\": \"world\"}".to_string() },
        ];
        let prompt = format_chat_messages(&loaded.model, &messages)
            .expect("Failed to format messages");
        let r2 = run_inference(&loaded, &prompt, 50, 0.1, Some(&grammar_str));
        println!("Result 2: {:?}", r2.as_ref().map(|(s,_,_)| s.as_str()));

        if let Ok((output, _, _)) = &r2 {
            let parsed: Result<serde_json::Value, _> = serde_json::from_str(output);
            assert!(parsed.is_ok(), "Must be valid JSON: {}", output);
            println!("Valid JSON!");
        }
    }

    #[test]
    fn test_summarize_with_grammar() {
        let Some(model_path) = find_qwen_model() else {
            panic!("No GGUF model found — download Qwen 3.5 via the app first");
        };
        println!("Using model: {}", model_path.display());

        let loaded = load_model(&model_path, -1).expect("Failed to load model");

        let grammar_str = json_schema_to_grammar(JSON_SCHEMA_OBJECT)
            .expect("Failed to generate grammar");
        println!("Grammar:\n{}", grammar_str);

        // Build prompt matching the real summarize code path
        let system = "You write concisely and precisely. No filler, no hedging. \
            Every point conveys a specific fact or insight. Use clear, direct language. No emoji. \
            Lead with the single most important takeaway.";
        let user = format!(
            "Summarize this article in 1-2 sentences (~30 words). Be specific and precise.\n\n\
            Title: CERN Discovers New Particle\n\n\
            Content:\n{}\n\n\
            CRITICAL: Respond with ONLY a valid JSON object. No text before or after.\n\
            The \"summary\" field must contain ONLY the final summary text.\n\n\
            {{{{\"summary\": \"your summary here\", \"notes\": \"any reasoning goes here\"}}}} /nothink",
            ARTICLE_TEXT
        );

        let messages = vec![
            ChatMessage { role: "system".to_string(), content: system.to_string() },
            ChatMessage { role: "user".to_string(), content: user },
        ];
        let prompt = format_chat_messages(&loaded.model, &messages)
            .expect("Failed to format messages");

        println!("Prompt length: {} chars", prompt.len());
        println!("Running grammar-constrained inference...");

        let result = run_inference(&loaded, &prompt, 200, 0.2, Some(&grammar_str));
        match result {
            Ok((output, prompt_tokens, gen_tokens)) => {
                println!("=== OUTPUT ({} prompt tokens, {} gen tokens) ===", prompt_tokens, gen_tokens);
                println!("{}", output);
                println!("=== END OUTPUT ===");

                // Must be valid JSON
                let parsed: Result<serde_json::Value, _> = serde_json::from_str(&output);
                assert!(parsed.is_ok(), "Output must be valid JSON, got: {}", output);

                let val = parsed.unwrap();
                assert!(val.is_object(), "Output must be a JSON object");
                println!("Parsed JSON: {}", serde_json::to_string_pretty(&val).unwrap());
            }
            Err(e) => {
                panic!("Grammar-constrained inference failed: {}", e);
            }
        }
    }
}
