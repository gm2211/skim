use crate::models::*;
use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use serde::Deserialize;
    use serde_json::{json, Value};
    use std::{
        io::{BufRead, BufReader, Write},
        path::PathBuf,
        process::{Child, ChildStdin, ChildStdout, Command, Stdio},
        sync::Mutex,
    };
    use tauri::Emitter;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    pub(super) struct Reply {
        #[serde(default)]
        ok: bool,
        value: Option<String>,
        bool: Option<bool>,
        availability: Option<FoundationModelAvailability>,
        error: Option<String>,
        progress: Option<f64>,
    }
    struct Worker {
        child: Child,
        stdin: ChildStdin,
        stdout: BufReader<ChildStdout>,
    }
    impl Drop for Worker {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
    pub struct SkimAi<R: Runtime> {
        app: AppHandle<R>,
        bridge: PathBuf,
        worker: Mutex<Option<Worker>>,
    }

    #[cfg(debug_assertions)]
    pub(super) fn debug_bridge_path(
        explicit: Option<std::ffi::OsString>,
        sibling: Option<PathBuf>,
        fallback: PathBuf,
    ) -> PathBuf {
        explicit
            .map(PathBuf::from)
            .or_else(|| {
                // A copied debug executable alone cannot initialize MLX: its Metal
                // library must be beside it. The development package contains both.
                sibling.filter(|path| {
                    path.is_file()
                        && path
                            .parent()
                            .is_some_and(|dir| dir.join("mlx.metallib").is_file())
                })
            })
            .unwrap_or(fallback)
    }

    pub fn init<R: Runtime, C: DeserializeOwned>(
        app: &AppHandle<R>,
        _api: PluginApi<R, C>,
    ) -> crate::Result<SkimAi<R>> {
        let bundled = std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(|dir| dir.join("skim-ai-macos-bridge")));
        #[cfg(debug_assertions)]
        let bridge = debug_bridge_path(
            std::env::var_os("SKIM_AI_MAC_BRIDGE_PATH"),
            bundled.clone(),
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("bin/skim-ai-macos-bridge-aarch64-apple-darwin"),
        );
        #[cfg(not(debug_assertions))]
        let bridge = bundled.unwrap_or_else(|| PathBuf::from("skim-ai-macos-bridge"));
        Ok(SkimAi {
            app: app.clone(),
            bridge,
            worker: Mutex::new(None),
        })
    }

    impl<R: Runtime> SkimAi<R> {
        fn call(&self, request: Value, repo: Option<&str>) -> crate::Result<Reply> {
            if !self.bridge.exists() {
                return Err(crate::Error::Other(format!(
                    "macOS AI bridge not found at {}. Rebuild Skim to restore on-device AI.",
                    self.bridge.display()
                )));
            }
            let mut slot = self
                .worker
                .lock()
                .map_err(|e| crate::Error::Other(e.to_string()))?;
            if slot
                .as_mut()
                .is_some_and(|worker| worker.child.try_wait().ok().flatten().is_some())
            {
                *slot = None;
            }
            if slot.is_none() {
                let mut child = Command::new(&self.bridge)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .spawn()
                    .map_err(|e| {
                        crate::Error::Other(format!("Unable to launch macOS AI bridge: {e}"))
                    })?;
                let stdin = child.stdin.take().expect("piped stdin");
                let stdout = BufReader::new(child.stdout.take().expect("piped stdout"));
                *slot = Some(Worker {
                    child,
                    stdin,
                    stdout,
                });
            }
            let result = (|| {
                let worker = slot.as_mut().expect("worker initialized");
                writeln!(worker.stdin, "{request}")
                    .map_err(|e| crate::Error::Other(e.to_string()))?;
                worker
                    .stdin
                    .flush()
                    .map_err(|e| crate::Error::Other(e.to_string()))?;
                loop {
                    let mut line = String::new();
                    if worker
                        .stdout
                        .read_line(&mut line)
                        .map_err(|e| crate::Error::Other(e.to_string()))?
                        == 0
                    {
                        return Err(crate::Error::Other(
                            "macOS AI bridge exited before replying".into(),
                        ));
                    }
                    let reply: Reply = serde_json::from_str(line.trim()).map_err(|e| {
                        crate::Error::Other(format!("Invalid macOS AI bridge response: {e}"))
                    })?;
                    if let Some(percent) = reply.progress {
                        let _ = self.app.emit(
                        "skim-ai://mlx-download-progress",
                        json!({"repoId":repo,"percent":percent * 100.0,"downloaded":0,"total":0}),
                    );
                    } else if reply.ok {
                        return Ok(reply);
                    } else {
                        return Err(crate::Error::Other(
                            reply
                                .error
                                .unwrap_or_else(|| "macOS AI bridge failed".into()),
                        ));
                    }
                }
            })();
            if result.is_err() {
                *slot = None;
            }
            result
        }
        pub fn mlx_is_available(&self) -> crate::Result<bool> {
            Ok(self
                .call(json!({"command":"mlx_available"}), None)?
                .bool
                .unwrap_or(false))
        }
        pub fn mlx_is_model_downloaded(&self, p: RepoIdArgs) -> crate::Result<bool> {
            Ok(self
                .call(json!({"command":"mlx_downloaded","repoId":p.repo_id}), None)?
                .bool
                .unwrap_or(false))
        }
        pub fn mlx_download_model(&self, p: RepoIdArgs) -> crate::Result<()> {
            let repo = p.repo_id;
            self.call(
                json!({"command":"mlx_download","repoId":repo.clone()}),
                Some(&repo),
            )
            .map(|_| ())
        }
        pub fn mlx_delete_model(&self, p: RepoIdArgs) -> crate::Result<()> {
            self.call(json!({"command":"mlx_delete","repoId":p.repo_id}), None)
                .map(|_| ())
        }
        pub fn mlx_complete(&self, p: CompleteArgs) -> crate::Result<String> {
            let repo = p.repo_id.clone();
            self.call(p.into_bridge_request("mlx_complete"),repo.as_deref())?.value.ok_or_else(||crate::Error::Other("MLX returned no text".into()))
        }
        pub fn fm_is_available(&self) -> crate::Result<bool> {
            Ok(self.fm_availability()?.available)
        }
        pub fn fm_availability(&self) -> crate::Result<FoundationModelAvailability> {
            self.call(json!({"command":"fm_availability"}), None)?
                .availability
                .ok_or_else(|| {
                    crate::Error::Other("Foundation Models returned no availability".into())
                })
        }
        pub fn fm_complete(&self, p: CompleteArgs) -> crate::Result<String> {
            self.call(p.into_bridge_request("fm_complete"),None)?.value.ok_or_else(||crate::Error::Other("Foundation Models returned no text".into()))
        }
        pub fn ios_keychain_store(&self, _: KeychainSetArgs) -> crate::Result<()> {
            Err(crate::Error::Other(
                "iOS Keychain is unavailable on macOS".into(),
            ))
        }
        pub fn ios_keychain_load(&self, _: KeychainKeyArgs) -> crate::Result<Option<String>> {
            Ok(None)
        }
        pub fn ios_keychain_clear(&self, _: KeychainKeyArgs) -> crate::Result<()> {
            Err(crate::Error::Other(
                "iOS Keychain is unavailable on macOS".into(),
            ))
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;
    const NO: &str = "skim-ai: on-device tier is unavailable on this desktop platform";
    pub struct SkimAi<R: Runtime>(AppHandle<R>);
    pub fn init<R: Runtime, C: DeserializeOwned>(
        app: &AppHandle<R>,
        _: PluginApi<R, C>,
    ) -> crate::Result<SkimAi<R>> {
        Ok(SkimAi(app.clone()))
    }
    impl<R: Runtime> SkimAi<R> {
        pub fn mlx_is_available(&self) -> crate::Result<bool> {
            Ok(false)
        }
        pub fn mlx_is_model_downloaded(&self, _: RepoIdArgs) -> crate::Result<bool> {
            Ok(false)
        }
        pub fn mlx_download_model(&self, _: RepoIdArgs) -> crate::Result<()> {
            Err(crate::Error::Other(NO.into()))
        }
        pub fn mlx_delete_model(&self, _: RepoIdArgs) -> crate::Result<()> {
            Err(crate::Error::Other(NO.into()))
        }
        pub fn mlx_complete(&self, _: CompleteArgs) -> crate::Result<String> {
            Err(crate::Error::Other(NO.into()))
        }
        pub fn fm_is_available(&self) -> crate::Result<bool> {
            Ok(false)
        }
        pub fn fm_availability(&self) -> crate::Result<FoundationModelAvailability> {
            Ok(FoundationModelAvailability {
                available: false,
                status: "unsupported-platform".into(),
                message: NO.into(),
            })
        }
        pub fn fm_complete(&self, _: CompleteArgs) -> crate::Result<String> {
            Err(crate::Error::Other(NO.into()))
        }
        pub fn ios_keychain_store(&self, _: KeychainSetArgs) -> crate::Result<()> {
            Err(crate::Error::Other(NO.into()))
        }
        pub fn ios_keychain_load(&self, _: KeychainKeyArgs) -> crate::Result<Option<String>> {
            Ok(None)
        }
        pub fn ios_keychain_clear(&self, _: KeychainKeyArgs) -> crate::Result<()> {
            Err(crate::Error::Other(NO.into()))
        }
    }
}
pub use platform::{init, SkimAi};

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::platform::Reply;
    #[cfg(debug_assertions)]
    #[test]
    fn debug_helper_requires_its_metal_resource_but_explicit_override_wins() {
        use super::platform::debug_bridge_path;
        let dir = std::env::temp_dir().join(format!(
            "skim-helper-selection-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let sibling = dir.join("skim-ai-macos-bridge");
        let fallback = dir.join("package").join("helper");
        std::fs::write(&sibling, b"test executable").unwrap();
        assert_eq!(
            debug_bridge_path(None, Some(sibling.clone()), fallback.clone()),
            fallback
        );
        std::fs::write(dir.join("mlx.metallib"), b"test library").unwrap();
        assert_eq!(
            debug_bridge_path(None, Some(sibling.clone()), fallback.clone()),
            sibling
        );
        let explicit = dir.join("explicit-helper");
        assert_eq!(
            debug_bridge_path(
                Some(explicit.clone().into_os_string()),
                Some(sibling),
                fallback
            ),
            explicit
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn progress_envelope_does_not_require_final_reply_fields() {
        assert!(serde_json::from_str::<Reply>(r#"{"progress":0.25}"#).is_ok());
    }
}
