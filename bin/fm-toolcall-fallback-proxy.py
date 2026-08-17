#!/usr/bin/env python3
"""Rewrites bare-JSON tool calls from an Ollama endpoint into OpenAI tool_calls."""

import argparse
import hashlib
import json
import re
import signal
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional, Tuple


def _parse_tool_call(text: str) -> Optional[Tuple[str, str]]:
    try:
        parsed, _ = json.JSONDecoder().raw_decode(text)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    name = parsed.get("name")
    arguments = parsed.get("arguments")
    if not isinstance(name, str) or not isinstance(arguments, (dict, str)):
        return None
    if isinstance(arguments, dict):
        arguments = json.dumps(arguments, separators=(",", ":"))
    return name, arguments


def extract_tool_call(content: object) -> Optional[Tuple[str, str]]:
    if not isinstance(content, str) or not content:
        return None
    match = re.search(r"<tool_call>(.*?)</tool_call>", content, re.DOTALL)
    if match:
        return _parse_tool_call(match.group(1).strip())
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", content.strip(), re.DOTALL)
    if fenced:
        return _parse_tool_call(fenced.group(1).strip())
    return _parse_tool_call(content.strip())


def _force_non_streaming(request_body: bytes) -> Tuple[bytes, bool]:
    if not request_body:
        return request_body, False
    try:
        parsed = json.loads(request_body)
    except ValueError:
        return request_body, False
    if not isinstance(parsed, dict) or "messages" not in parsed:
        return request_body, False
    wanted_stream = bool(parsed.get("stream"))
    if not wanted_stream:
        return request_body, False
    parsed["stream"] = False
    return json.dumps(parsed).encode("utf-8"), True


def _sse_chunk_body(parsed: dict) -> bytes:
    choice = parsed["choices"][0]
    message = choice["message"]
    base = {
        "id": parsed.get("id", "chatcmpl-fallback"),
        "object": "chat.completion.chunk",
        "created": parsed.get("created", 0),
        "model": parsed.get("model", ""),
    }
    delta = {"role": message.get("role", "assistant"), "content": message.get("content") or ""}
    if message.get("tool_calls"):
        delta["tool_calls"] = message["tool_calls"]
    first = dict(base, choices=[{"index": 0, "delta": delta, "finish_reason": None}])
    last = dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": choice.get("finish_reason")}])
    lines = [f"data: {json.dumps(first)}\n\n", f"data: {json.dumps(last)}\n\n", "data: [DONE]\n\n"]
    return "".join(lines).encode("utf-8")


def final_content_type(original: str) -> str:
    if not original:
        return "application/json; charset=utf-8"
    if "charset=" in original.lower():
        return original
    return original + "; charset=utf-8"


class ProxyHandler(BaseHTTPRequestHandler):
    upstream_host = "127.0.0.1"
    upstream_port = 21434

    def log_message(self, format: str, *args) -> None:
        pass

    def _log(self, path: str, status: int, fallback_applied: bool, name: Optional[str]) -> None:
        record = {"path": path, "status": status, "fallback_applied": fallback_applied}
        if name is not None:
            record["name"] = name
        print(json.dumps(record, sort_keys=True), file=sys.stderr)

    def _extra_headers(self, headers) -> list:
        result = []
        for name, value in headers.items():
            if name.lower() in ("content-length", "transfer-encoding", "connection", "content-type"):
                continue
            result.append((name, value))
        return result

    def _respond(self, status: int, body: bytes, content_type: str, extra_headers: list) -> None:
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    @staticmethod
    def _is_chat(parsed) -> bool:
        choices = parsed.get("choices") if isinstance(parsed, dict) else None
        if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
            return False
        return isinstance(choices[0].get("message"), dict)

    @staticmethod
    def _maybe_rewrite(parsed) -> Tuple[bool, Optional[str]]:
        message = parsed["choices"][0]["message"]
        tool_calls = message.get("tool_calls")
        if isinstance(tool_calls, list) and tool_calls:
            return False, None
        extracted = extract_tool_call(message.get("content"))
        if extracted is None:
            return False, None
        name, arguments = extracted
        call_id = "fallback_call_" + hashlib.sha256((arguments + name).encode("utf-8")).hexdigest()[:12]
        message["tool_calls"] = [{
            "id": call_id,
            "index": 0,
            "type": "function",
            "function": {"name": name, "arguments": arguments},
        }]
        message["content"] = ""
        parsed["choices"][0]["finish_reason"] = "tool_calls"
        return True, name

    def _proxy(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        request_body = self.rfile.read(length) if length > 0 else b""
        request_body, wanted_stream = _force_non_streaming(request_body)
        upstream_url = f"http://{self.upstream_host}:{self.upstream_port}{self.path}"
        forward_headers = {
            name: value for name, value in self.headers.items()
            if name.lower() not in ("host", "content-length", "connection", "accept-encoding")
        }
        upstream_request = urllib.request.Request(
            upstream_url, data=request_body, method=self.command, headers=forward_headers,
        )
        try:
            with urllib.request.urlopen(upstream_request) as response:
                status = response.getcode() or 200
                upstream_body = response.read()
                headers = response.headers
        except urllib.error.HTTPError as error:
            status = error.code
            upstream_body = error.read()
            headers = error.headers
        except urllib.error.URLError:
            self._log(self.path, 502, False, None)
            self._respond(502, b"upstream unreachable", "text/plain", [])
            return

        content_type = headers.get("Content-Type") or ""
        parsed = None
        if "text/event-stream" not in content_type.lower():
            try:
                parsed = json.loads(upstream_body)
            except ValueError:
                parsed = None

        if parsed is not None and self._is_chat(parsed):
            fallback_applied, name = self._maybe_rewrite(parsed)
            self._log(self.path, status, fallback_applied, name)
            if wanted_stream:
                out_body = _sse_chunk_body(parsed)
                self._respond(status, out_body, "text/event-stream; charset=utf-8", [])
            else:
                out_body = json.dumps(parsed).encode("utf-8")
                self._respond(status, out_body, final_content_type(content_type), self._extra_headers(headers))
        else:
            self._log(self.path, status, False, None)
            self._respond(status, upstream_body, content_type, self._extra_headers(headers))

    def do_GET(self) -> None:
        self._proxy()

    def do_POST(self) -> None:
        self._proxy()

    def do_PUT(self) -> None:
        self._proxy()

    def do_DELETE(self) -> None:
        self._proxy()

    def do_PATCH(self) -> None:
        self._proxy()

    def do_HEAD(self) -> None:
        self._proxy()

    def do_OPTIONS(self) -> None:
        self._proxy()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, default=21434)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    args = parser.parse_args()

    ProxyHandler.upstream_host = args.upstream_host
    ProxyHandler.upstream_port = args.upstream_port
    server = HTTPServer(("127.0.0.1", args.listen_port), ProxyHandler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()

    server.shutdown()
    server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
