#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OpenAI-compatible mock server（随仓库保留，用于本地验证 cmd/llm.c3）。

纯标准库，零依赖。行为与 llama-server/vLLM 的 /v1/chat/completions 流式
wire 一致：SSE 打字机 + 末尾 usage 帧 + [DONE]。llm 恒为流式请求，本 mock
也一律流式应答（'embed'/'err400' 两个错误场景除外）。

用法:
    python scripts/mock_llm.py [port]     # 默认 8123，可用 LLM_MOCK_PORT 覆盖
    LLM_API_URL=http://127.0.0.1:8123/v1/chat/completions LLM_MODEL=any \\
        ./build/llm.exe [--debug] [--thinking] "hello"

场景控制（看最后一条 user 消息的第一个词）:
    stream    默认：SSE 打字机输出 Hello world! + usage + [DONE]
    echo      回显最后一条 user 消息的原文（验证 prompt/-s/system 拼接）
    think     先流式 reasoning 再 content（验证 --debug 打印 reasoning）。
              请求体带 reasoning 对象 → 标准字段 delta.reasoning；
              否则走 DeepSeek 私有 delta.reasoning_content 兼容分支。
    length    收尾 finish_reason="length"（验证 max_tokens 截断警告）
    dump      把收到的请求体 JSON 作为 content 原样回显（验证 payload 内容，
              如 -M 透传 / reasoning / LLM_EXTRA_BODY 合并结果）
    err400    HTTP 400 + {"error":{...}}（验证流式错误路径；建议 LLM_RETRIES=0
              免等重试退避）
    embed     HTTP 200 但响应体是 {"error":{...}}（非 SSE，验证 200+error）
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def scenario_of(body: dict) -> str:
    """从最后一条 user 消息的首词取场景关键字。"""
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user":
            c = m.get("content") or ""
            if isinstance(c, str):
                first = c.strip().split(None, 1)
                return first[0].lower() if first else ""
            return ""
    return ""


def sse_ev(w, obj):
    w.write(("data: %s\n\n" % json.dumps(obj)).encode("utf-8"))


def stream_done(w):
    w.write(b"data: [DONE]\n\n")
    w.flush()


def send_error(h, code, message):
    payload = json.dumps({"error": {"message": message, "type": "mock_error"}}).encode()
    h.send_response(code)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(payload)))
    h.end_headers()
    h.wfile.write(payload)
    h.wfile.flush()


def handle_chat(h, body):
    w = h.wfile
    scenario = scenario_of(body)
    reason_std = isinstance(body.get("reasoning"), dict)  # --thinking 带的配置
    rkey = "reasoning" if reason_std else "reasoning_content"
    prompt_toks = len(json.dumps(body, ensure_ascii=False)) // 4

    # 拿到最后一条 user 文本（echo/dump 场景要用）
    last_user = ""
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user" and isinstance(m.get("content"), str):
            last_user = m["content"]
            break

    if scenario == "err400":
        send_error(h, 400, "mock 400: invalid request")
        return
    if scenario == "embed":
        send_error(h, 200, "mock embedded error (200)")
        return

    # 正常 SSE 流（无 Content-Length，靠关连接表示流结束）
    h.send_response(200)
    h.send_header("Content-Type", "text/event-stream")
    h.send_header("Cache-Control", "no-cache")
    h.send_header("Connection", "close")
    h.end_headers()

    if scenario == "dump":
        pretty = json.dumps(body, ensure_ascii=False, indent=2)
        text_parts = [("```json\n" + pretty + "\n```", "stop")]
        think_toks = 0
    elif scenario == "echo":
        text_parts = [(last_user, "stop")]
        think_toks = 0
    elif scenario == "think":
        think = [
            "Let me reason step by step. ",
            "First clarify what is being asked. ",
            "Then derive the answer carefully. ",
        ]
        text_parts = [("Hello world! ", "stop")]
        think_toks = 24
    elif scenario == "length":
        text_parts = [("hello " * 64, "length")]
        think_toks = 0
    else:  # stream / 默认
        text_parts = [("Hello ", None), ("world!", "stop")]
        think_toks = 0

    if scenario == "think":
        for piece in think:
            sse_ev(w, {"choices": [{"index": 0, "delta": {rkey: piece}}]})
            time.sleep(0.05)

    for piece, fr in text_parts:
        delta = {"content": piece}
        ev = {"choices": [{"index": 0, "delta": delta}]}
        if fr is not None:
            ev["choices"][0]["finish_reason"] = fr
        sse_ev(w, ev)
        time.sleep(0.05)

    completion_toks = sum(len(p[0]) for p in text_parts) // 4
    sse_ev(w, {"usage": {
        "prompt_tokens": prompt_toks,
        "completion_tokens": completion_toks,
        "completion_tokens_details": {"reasoning_tokens": think_toks},
    }})
    stream_done(w)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("mock: %s\n" % (fmt % args))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            send_error(self, 400, "mock: request body is not valid JSON")
            return
        handle_chat(self, body)

    def do_GET(self):
        # 探活
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


def main():
    import os
    port = int(os.environ.get("LLM_MOCK_PORT", "8123"))
    verbose = False
    for a in sys.argv[1:]:
        if a in ("-v", "--verbose"):
            verbose = True
        else:
            port = int(a)  # 位置参数：端口

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.verbose = verbose  # type: ignore[attr-defined]
    print("mock llm listening on http://127.0.0.1:%d/v1/chat/completions" % port, flush=True)
    print("scenario keywords (first word of last user message): "
          "stream echo think length dump err400 embed", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
