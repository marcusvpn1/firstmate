#!/usr/bin/env python3
"""Run one bounded local-Qwen scout (read-only) or ship (worktree-write) task under a deny-default macOS sandbox."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
from typing import Optional


DEFAULT_PI = Path("/Users/marcusnascimento/.npm-global/bin/pi")
DEFAULT_TOOLCALL_PROXY = Path(__file__).resolve().parent / "fm-toolcall-fallback-proxy.py"
NODE_PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/marcusnascimento/.npm-global/bin"


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_port(port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.2)
            try:
                probe.connect(("127.0.0.1", port))
                return True
            except OSError:
                time.sleep(0.05)
    return False


def quote_sandbox(value: Path) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def sha256(path: Path) -> Optional[str]:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_task(brief: str) -> str:
    """Return only the firstmate brief's Task section for the small local model."""
    marker = "# Task\n"
    if marker not in brief:
        raise ValueError("brief is missing the required '# Task' section")
    task = brief.split(marker, 1)[1].split("\n# ", 1)[0].strip()
    if not task or task == "{TASK}":
        raise ValueError("brief has an empty or unfilled Task section")
    return task


def terminate_group(process: subprocess.Popen[bytes]) -> str:
    if process.poll() is not None:
        return "exited"
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
        return "terminated"
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
        return "killed"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--brief", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--run-record", type=Path, required=True)
    parser.add_argument("--task-tmp", type=Path, required=True)
    parser.add_argument("--model", default="ollama-alienware/qwen3:8b")
    parser.add_argument("--kind", choices=["scout", "ship"], default="scout",
                         help="scout: read-only, report-only. ship: bounded write access to the worktree")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--pi", type=Path, default=DEFAULT_PI, help=argparse.SUPPRESS)
    parser.add_argument("--tool-call-fallback", action="store_true",
                         help="rewrite bare-JSON tool calls into real tool_calls via a local proxy")
    parser.add_argument("--toolcall-proxy", type=Path, default=DEFAULT_TOOLCALL_PROXY, help=argparse.SUPPRESS)
    args = parser.parse_args()

    started_wall = time.time()
    started = time.monotonic()
    args.task_tmp.mkdir(parents=True, exist_ok=True)
    agent_dir = args.task_tmp / "pi-agent"
    agent_dir.mkdir(exist_ok=True)
    output = args.task_tmp / "pi-events.jsonl"
    profile = args.task_tmp / "sandbox.sb"
    model_id = args.model.split("/", 1)[-1]

    proxy_process = None
    inference_port = 21434
    if args.tool_call_fallback:
        inference_port = free_loopback_port()
        proxy_process = subprocess.Popen(
            [sys.executable, str(args.toolcall_proxy.resolve()), "--listen-port", str(inference_port),
             "--upstream-port", "21434"],
            stdout=subprocess.DEVNULL, stderr=(args.task_tmp / "toolcall-proxy.log").open("wb"),
        )
        if not wait_for_port(inference_port):
            proxy_process.terminate()
            parser.error("tool-call fallback proxy did not become ready in time")

    models = {
        "providers": {
            "ollama-alienware": {
                "baseUrl": f"http://127.0.0.1:{inference_port}/v1",
                "api": "openai-completions",
                "apiKey": "ollama",
                "compat": {"supportsDeveloperRole": False, "supportsReasoningEffort": False},
                "models": [{
                    "id": model_id,
                    "name": "Bounded Qwen on alienware-ai",
                    "reasoning": False,
                    "input": ["text"],
                    "contextWindow": 4096,
                    "maxTokens": 1024,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                }],
            }
        }
    }
    (agent_dir / "models.json").write_text(json.dumps(models, indent=2) + "\n")

    profile.write_text(f'''(version 1)
(deny default)
(import "system.sb")
(allow process*)
(allow sysctl-read)
(allow mach-lookup)
(allow signal (target self))
(allow file-read-metadata)
(allow file-read*
  (subpath "/System")
  (subpath "/usr")
  (subpath "/bin")
  (subpath "/sbin")
  (subpath "/Library/Apple")
  (subpath "/Library/Developer/CommandLineTools")
  (subpath "/private/etc/ssl")
  (subpath "/opt/homebrew")
  (subpath "/Users/marcusnascimento/.npm-global")
  (literal "{quote_sandbox(args.pi.resolve())}")
  (subpath "{quote_sandbox(args.worktree.resolve())}")
  (subpath "{quote_sandbox(args.task_tmp.resolve())}")
  (literal "{quote_sandbox(args.brief.resolve())}")
  (literal "/dev/null")
  (literal "/dev/random")
  (literal "/dev/urandom"))
(allow file-write*
  (subpath "{quote_sandbox(args.task_tmp.resolve())}")
  (literal "{quote_sandbox(args.report.resolve())}")
{"  (subpath " + chr(34) + quote_sandbox(args.worktree.resolve()) + chr(34) + ")" if args.kind == "ship" else ""}
  (literal "/dev/stdout")
  (literal "/dev/stderr")
  (subpath "/dev/fd"))
(allow network-outbound (remote ip "localhost:{inference_port}"))
''')

    try:
        task = extract_task(args.brief.read_text())
    except ValueError as exc:
        parser.error(str(exc))
    if args.kind == "ship":
        tools = "read,grep,find,ls,write,edit,bash"
        prompt = (
            "EXPERIMENTAL BOUNDED SHIP BOUNDARY:\n"
            "Use only read, grep, find, ls, write, edit, and bash, scoped to the current worktree. "
            "Do not install dependencies, access the network, commit, push, or edit any file the task "
            "does not require. Run only the one local test command the task describes; do not run any "
            "other command. When finished, report as your final answer: model, files changed, the exact "
            "test command run, its result, and any limitations. "
            "If the task is ambiguous or its requested action conflicts with this boundary, stop and "
            "report that clearly instead of guessing or attempting the action.\n\n"
            "TASK:\n" + task
        )
    else:
        tools = "read,grep,find,ls,write"
        prompt = (
            "EXPERIMENTAL READ-ONLY SCOUT BOUNDARY:\n"
            "Use only read, grep, find, ls, and write. Do not run shell commands, edit the worktree, "
            "install anything, access another path, or use public network. The only writable deliverable "
            f"is {args.report.resolve()}. Write a self-contained evidence report there. "
            "If the task is ambiguous or its requested action conflicts with this boundary, report that "
            "clearly instead of guessing or attempting the action.\n\n"
            "TASK:\n" + task
        )
    command = [
        "/usr/bin/sandbox-exec", "-f", str(profile), str(args.pi.resolve()),
        "--provider", "ollama-alienware", "--model", model_id, "--thinking", "off",
        "--tools", tools, "--no-extensions", "--no-skills",
        "--no-prompt-templates", "--no-context-files", "--no-session",
        "--mode", "json", "--print", prompt,
    ]
    environment = {
        "HOME": str(args.task_tmp),
        "PATH": NODE_PATH,
        "PI_CODING_AGENT_DIR": str(agent_dir),
        "PI_OFFLINE": "1",
        "PI_TELEMETRY": "0",
        "LANG": "C.UTF-8",
        "TMPDIR": str(args.task_tmp),
    }
    timed_out = False
    cleanup = "exited"
    with output.open("wb") as stream:
        process = subprocess.Popen(
            command, cwd=args.worktree, env=environment, stdout=stream,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            return_code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            cleanup = terminate_group(process)
            return_code = process.returncode

    if proxy_process is not None:
        proxy_process.terminate()
        try:
            proxy_process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proxy_process.kill()
            proxy_process.wait(timeout=3)

    diff = subprocess.run(
        ["/usr/bin/git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=args.worktree, text=True, capture_output=True, check=False,
    )
    report_hash = sha256(args.report)
    if args.kind == "ship":
        # A ship job is expected to change the worktree; whether the change is
        # correct is verified independently outside this adapter (diff review,
        # test rerun), not inferred here. This records execution containment only.
        passed = return_code == 0 and not timed_out
        allowed_write_paths = [str(args.worktree.resolve()), str(args.report.resolve()), str(args.task_tmp.resolve())]
        permitted_tools = ["read", "grep", "find", "ls", "write", "edit", "bash"]
    else:
        passed = return_code == 0 and not timed_out and report_hash is not None and not diff.stdout.strip()
        allowed_write_paths = [str(args.report.resolve()), str(args.task_tmp.resolve())]
        permitted_tools = ["read", "grep", "find", "ls", "write"]
    record = {
        "schema_version": 1,
        "task_id": args.id,
        "task_class": args.kind,
        "harness": "pi-qwen-alienware",
        "provider": "ollama-alienware",
        "model": model_id,
        "worktree": str(args.worktree.resolve()),
        "allowed_read_paths": [str(args.worktree.resolve()), str(args.brief.resolve())],
        "allowed_write_paths": allowed_write_paths,
        "permitted_tools": permitted_tools,
        "permitted_commands": [],
        "network": f"localhost:{inference_port} only",
        "tool_call_fallback": args.tool_call_fallback,
        "timeout_seconds": args.timeout,
        "timed_out": timed_out,
        "cleanup": cleanup,
        "return_code": return_code,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "started_epoch": started_wall,
        "ended_epoch": time.time(),
        "worktree_status": diff.stdout.splitlines(),
        "report_sha256": report_hash,
        "events_sha256": sha256(output),
        "result": "pass" if passed else "fail",
    }
    args.run_record.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    args.status.parent.mkdir(parents=True, exist_ok=True)
    state = "done" if passed else "failed"
    with args.status.open("a") as stream:
        stream.write(f"{state}: bounded local-Qwen {args.kind} {record['result']}\n")
    print(json.dumps(record, sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
