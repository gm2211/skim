//! Fixed synthetic checks for release packaging and sandbox inheritance.
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let helper = std::env::current_exe()?
        .parent()
        .ok_or("Missing executable directory")?
        .join("skim-ai-macos-bridge");
    let mut child = Command::new(helper)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or("Missing helper stdin")?;
    let stdout = child.stdout.take().ok_or("Missing helper stdout")?;
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let requests = [
            serde_json::json!({"command": "fm_availability"}),
            serde_json::json!({"command": "mlx_complete", "repoId": "mlx-community/gemma-3-1b-it-4bit", "system": "Answer briefly.", "user": "What is 2 + 2?", "maxTokens": 24}),
            serde_json::json!({"command": "mlx_complete", "repoId": "mlx-community/gemma-3-1b-it-4bit", "system": "Answer briefly.", "user": "What is 3 + 3?", "maxTokens": 24}),
        ];
        let mut reader = BufReader::new(stdout);
        for request in requests {
            writeln!(stdin, "{request}")?;
            stdin.flush()?;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line)? == 0 {
                    return Err("Helper exited before replying".into());
                }
                let response: serde_json::Value = serde_json::from_str(&line)?;
                if response.get("progress").is_some() {
                    continue;
                }
                if response.get("ok").and_then(|value| value.as_bool()) != Some(true) {
                    return Err(format!("Helper error: {response}").into());
                }
                if request["command"] == "mlx_complete"
                    && response["value"]
                        .as_str()
                        .is_none_or(|text| text.trim().is_empty())
                {
                    return Err("MLX returned empty text".into());
                }
                println!("{}: {response}", request["command"]);
                break;
            }
        }
        Ok(())
    })();
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    result
}
