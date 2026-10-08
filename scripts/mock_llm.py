#!/usr/bin/env python3
"""本地 mock OpenAI chat completions 服务，供 llmcli 回归测试使用。

只实现 POST /v1/chat/completions（非流式）与 GET /health。
响应按"脚本"依次返回：第 N 次请求返回脚本第 N 条，脚本用完后重复最后一条。

llmcli 是 shellm 式 RLM 循环：模型回复一个 ```python 代码块，本地执行后把输出作为
下一条 user 消息回填，直到代码里设置 FINAL / FINAL_FILE；没有代码块的回复即最终答案。
所以脚本条目就是"每一轮模型的回复文本"。

用法：
    python scripts/mock_llm.py --port 8123 --scenario block_loop
    python scripts/mock_llm.py --port 8123 --script my_turns.json

脚本格式（JSON 数组），每条是 choices[0].message 的补丁：
    [
      {"finish_reason": "stop", "content": "```python\\nprint(\"hi\")\\n```"},
      {"finish_reason": "stop", "content": "done", "reasoning_content": "思考中"}
    ]
content 里的 {{PLACEHOLDER}} 可用 --replace k=v 替换。

内置 scenario：
    simple        单轮，回显最后一条 user 消息（无代码块 → 直接是最终答案）
    block_loop    先执行一个 print 代码块，再以无代码块的文本收尾
    block_final   一轮里执行代码并设置 FINAL，运行当场结束
    edit_task     读文件 -> 改文件 -> FINAL（PRD 成功指标里的任务）
    reasoning     单轮带 reasoning_content
    bad_json      返回非法 JSON
    http_500      返回 500
    no_answer     返回 finish_reason=stop 但 content 为空
    slow_command  一个长时间不退出的代码块（用 {{SLEEP}} 填充 subprocess 命令）
    two_code_calls 同一 Trace 内两轮代码块（用 {{SESSION}} 观察中途落盘）
    always_blocks 永远返回不带 FINAL 的代码块（用来验证 --max-turns 止损）
"""

import argparse
import os
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCENARIOS = {
    "simple": [
        {"finish_reason": "stop", "content": "__ECHO__"},
    ],
    "block_loop": [
        {"finish_reason": "stop",
         "content": "先跑一下。\n```python\nprint(\"hello-from-tool\")\n```"},
        {"finish_reason": "stop", "content": "final answer"},
    ],
    "block_final": [
        {"finish_reason": "stop",
         "content": "算好了。\n```python\nprint(\"computing\")\nFINAL = \"final answer\"\n```"},
    ],
    # FINAL 设为空串也算"设置过"（与 bash 版 [ -n "${FINAL+x}" ] 一致），当场以空答案收尾；
    # 若按真假值判断会误当未设，多跑一轮。
    "block_final_empty": [
        {"finish_reason": "stop",
         "content": "无甚可说。\n```python\nFINAL = \"\"\n```"},
        {"finish_reason": "stop", "content": "这个不该出现"},
    ],
    # FINAL_FILE：代码写出文件并以此为最终答案，内容按字节取回
    "block_final_file": [
        {"finish_reason": "stop",
         "content": "写好了。\n```python\nopen(r'{{FINALSRC}}', 'w', encoding='utf-8').write('从文件来的答案')\nFINAL_FILE = r'{{FINALSRC}}'\n```"},
    ],
    # 回复含多个代码块：只执行第一个，其余丢弃并告警
    "multi_block": [
        {"finish_reason": "stop",
         "content": "```python\nprint(\"first\")\n```\n说明\n```python\nprint(\"second\")\n```"},
        {"finish_reason": "stop", "content": "done"},
    ],
    "edit_task": [
        {"finish_reason": "stop", "reasoning_content": "先看看文件内容",
         "content": "看看文件。\n```python\nprint(open(r'{{FILE}}', encoding=\"utf-8\").read())\n```"},
        {"finish_reason": "stop",
         "content": "改文件。\n```python\np = r'{{FILE}}'\ns = open(p, encoding=\"utf-8\").read()\nopen(p, \"w\", encoding=\"utf-8\").write(s.replace(\"old-text\", \"new-text\"))\n```"},
        {"finish_reason": "stop",
         "content": "收尾。\n```python\nFINAL = \"edited {{FILE}}\"\n```"},
    ],
    "reasoning": [
        {
            "finish_reason": "stop",
            "content": "answer after thinking",
            "reasoning_content": "step 1: ...\nstep 2: ...",
        }
    ],
    # 无输出的代码：观察消息应回填“（无输出）”而不是一个空行
    "no_output": [
        {"finish_reason": "stop", "content": "无声操作。\n```python\nx = 1\n```"},
        {"finish_reason": "stop", "content": "done-no-output"},
    ],
    "bad_json": [{"__raw__": "this is not json"}],
    "http_500": [{"__status__": 500, "content": "internal boom"}],
    "no_answer": [{"finish_reason": "stop", "content": ""}],
    "slow_command": [
        {"finish_reason": "stop",
         "content": "```python\nimport subprocess\nsubprocess.run(r'{{SLEEP}}'.split())\n```"},
        {"finish_reason": "stop", "content": "done sleeping"},
    ],
    # 两轮代码块，用 {{SESSION}} 指向当前会话文件，观察 Trace 中途是否已落盘
    "two_code_calls": [
        {"finish_reason": "stop", "content": "```python\nprint(\"first\")\n```"},
        {"finish_reason": "stop", "content": "```python\nprint(open(r'{{SESSION}}', encoding=\"utf-8\").read())\n```"},
        {"finish_reason": "stop", "content": "done"},
    ],
    # 永远返回不带 FINAL 的代码块（脚本用完后重复最后一条），用来验证 --max-turns 止损
    "always_blocks": [
        {"finish_reason": "stop", "content": "```python\nprint(\"spin\")\n```"},
    ],
}


def substitute(obj, mapping):
    """在脚本的字符串值里替换占位符。

    必须先按结构替换再交给 json.dumps：直接对序列化后的 JSON 文本做替换，
    会把路径里的反斜杠塞进 JSON 字符串转义里，导致解析失败。
    """
    if isinstance(obj, str):
        for key, value in mapping.items():
            obj = obj.replace(key, value)
        return obj
    if isinstance(obj, list):
        return [substitute(item, mapping) for item in obj]
    if isinstance(obj, dict):
        return {key: substitute(value, mapping) for key, value in obj.items()}
    return obj


def load_script(args):
    if args.script:
        with open(args.script, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return list(SCENARIOS[args.scenario])


def as_openai_message(turn, echo_text):
    """把脚本条目转成 OpenAI 的 message 对象。"""
    msg = {"role": "assistant"}
    if "content" in turn:
        msg["content"] = turn["content"].replace("__ECHO__", echo_text)
    else:
        msg["content"] = None
    if "reasoning_content" in turn:
        msg["reasoning_content"] = turn["reasoning_content"]
    return msg


class MockServer(ThreadingHTTPServer):
    # Windows 上 SO_REUSEADDR 允许两个进程同时 bind 同一端口，会让测试静默连到旧实例上。
    # 关掉它，端口被占用时直接报错。
    allow_reuse_address = os.name != "nt"
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mock-llm/1.0"

    def log_message(self, fmt, *a):  # 安静点，别把测试输出搞乱
        if self.server.verbose:
            sys.stderr.write("[mock] " + (fmt % a) + "\n")

    def _send(self, status, payload, raw=False):
        body = payload if raw else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/control/requests":
            # 供回归脚本断言"实际发出去的请求长什么样"
            self._send(200, {
                "calls": self.server.calls,
                "requests": self.server.requests,
            })
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if self.server.verbose:
            sys.stderr.write("[mock] << %s\n" % raw.decode("utf-8", "replace"))

        if self.path == "/control/reset":
            self.server.calls = 0
            self.server.requests = []
            self._send(200, {"status": "reset"})
            return

        if self.path != "/v1/chat/completions":
            self._send(404, {"error": {"message": "not found"}})
            return

        try:
            request = json.loads(raw.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001 - 报给测试用
            self._send(400, {"error": {"message": "bad request json: %s" % exc}})
            return

        self.server.requests.append(request)

        turns = self.server.script
        index = min(self.server.calls, len(turns) - 1)
        turn = dict(turns[index])
        self.server.calls += 1

        if "__status__" in turn:
            status = turn.pop("__status__")
            self._send(status, {"error": {"message": turn.get("content", "error")}})
            return

        if "__raw__" in turn:
            raw_body = substitute(turn["__raw__"], self.server.replace)
            if not isinstance(raw_body, str):
                raw_body = json.dumps(raw_body, ensure_ascii=False)
            self._send(200, raw_body, raw=True)
            return

        echo_text = ""
        for message in reversed(request.get("messages", [])):
            if message.get("role") == "user":
                echo_text = message.get("content") or ""
                break
        message = as_openai_message(substitute(turn, self.server.replace), echo_text)
        response = {
            "id": "chatcmpl-mock-%d" % self.server.calls,
            "object": "chat.completion",
            "created": 0,
            "model": request.get("model", "mock"),
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": turn.get("finish_reason", "stop"),
                }
            ],
            "usage": {
                "prompt_tokens": 11,
                "completion_tokens": 22,
                "total_tokens": 33,
            },
        }
        self._send(200, response)


def main():
    parser = argparse.ArgumentParser(description="mock OpenAI chat completions server")
    parser.add_argument("--port", type=int, default=8123)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--script", help="JSON 脚本文件路径")
    parser.add_argument("--scenario", default="simple", choices=sorted(SCENARIOS))
    parser.add_argument("--replace", action="append", default=[],
                        help="KEY=VALUE，替换脚本里的占位符，可重复")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = MockServer((args.host, args.port), Handler)
    server.script = load_script(args)
    server.calls = 0
    server.requests = []
    server.verbose = args.verbose
    server.replace = {}
    for pair in args.replace:
        key, _, value = pair.partition("=")
        server.replace[key] = value

    sys.stderr.write("[mock] listening on http://%s:%d scenario=%s turns=%d\n"
                     % (args.host, args.port, args.scenario, len(server.script)))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
