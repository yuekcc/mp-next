#!/usr/bin/env python3
"""llmcli 端到端回归：对着 scripts/mock_llm.py 跑 PRD 里的验收场景。

    python scripts/regress.py                # 跑全部场景
    python scripts/regress.py --verbose      # 额外打印每个场景的 stdout/stderr

前置：先 `c3c build` 生成 build/llmcli.exe（Windows）或 build/llmcli。
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build", "regress")
PORT = 8199
BASE_URL = "http://127.0.0.1:%d/v1/chat/completions" % PORT
API_KEY = "sk-regress-secret"

RESULTS = []


def exe_path():
    for name in ("llmcli.exe", "llmcli"):
        path = os.path.join(ROOT, "build", name)
        if os.path.exists(path):
            return path
    sys.exit("找不到 build/llmcli[.exe]，请先运行 c3c build")


def post_json(url, payload=None):
    data = b"" if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


class Mock:
    """一个 mock_llm.py 子进程。"""

    def __init__(self, scenario, replace=None, port=None):
        self.port = port or PORT
        self.base_url = "http://127.0.0.1:%d/v1/chat/completions" % self.port
        command = [sys.executable, os.path.join(ROOT, "scripts", "mock_llm.py"),
                   "--port", str(self.port), "--scenario", scenario]
        for key, value in (replace or {}).items():
            command += ["--replace", "%s=%s" % (key, value)]
        self.proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.wait_ready()

    def wait_ready(self):
        for _ in range(100):
            try:
                get_json("http://127.0.0.1:%d/health" % self.port)
                return
            except Exception:  # noqa: BLE001 - 启动期轮询
                time.sleep(0.05)
        raise RuntimeError("mock 启动失败")

    def reset(self):
        post_json("http://127.0.0.1:%d/control/reset" % self.port)

    def requests(self):
        return get_json("http://127.0.0.1:%d/control/requests" % self.port)["requests"]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def run_cli(args, stdin_text=None, home=None, timeout=60, inherit_stdin=False):
    env = dict(os.environ)
    env["LLMCLI_HOME"] = home or os.path.join(WORK, "home")
    kwargs = {"stdin": None} if inherit_stdin else {"input": stdin_text}
    proc = subprocess.run(
        [exe_path()] + args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=timeout,
        cwd=ROOT,
        **kwargs,
    )
    return proc


def check(name, condition, detail=""):
    RESULTS.append((name, bool(condition), detail))
    mark = "ok  " if condition else "FAIL"
    sys.stdout.write("[%s] %s%s\n" % (mark, name, "" if condition else "  <- " + detail))
    return condition


# --------------------------------------------------------------------------- 场景

def s1_single_turn(mock, verbose):
    """AC: 单轮问答成功；stdout 无日志；三路输入互斥。"""
    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="hello world")
    check("S1 stdin 单轮：退出码 0", proc.returncode == 0, proc.stderr)
    check("S1 stdin 单轮：stdout 只有答案", "hello world" in proc.stdout and "Trace" not in proc.stdout,
          repr(proc.stdout))

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url, "--quiet"],
                   stdin_text="hello world")
    check("S1 --quiet：stderr 无过程日志", "Trace" not in proc.stderr, repr(proc.stderr))

    input_file = os.path.join(WORK, "input.txt")
    with open(input_file, "w", encoding="utf-8") as fh:
        fh.write("from file")

    # 位置参数 / --input-file 只有在 stdin 是终端时才不构成第二个来源
    if sys.stdin.isatty():
        mock.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                        "--input-file", input_file], inherit_stdin=True)
        check("S1 --input-file：退出码 0 且读到文件", proc.returncode == 0 and "from file" in proc.stdout,
              "exit=%d stdout=%r stderr=%s" % (proc.returncode, proc.stdout, proc.stderr))

        mock.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                        "位置参数也生效"], inherit_stdin=True)
        check("S1 位置参数：退出码 0", proc.returncode == 0 and "位置参数也生效" in proc.stdout,
              "exit=%d stdout=%r stderr=%s" % (proc.returncode, proc.stdout, proc.stderr))
    else:
        check("S1 --input-file / 位置参数：本环境 stdin 非终端，跳过（冲突路径另测）", True, "")

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                    "--input-file", input_file, "位置参数"])
    check("S1 输入冲突：退出码 2", proc.returncode == 2, "exit=%d" % proc.returncode)
    check("S1 输入冲突：不发请求", len(mock.requests()) == 0)
    check("S1 输入冲突：stdout 为空", proc.stdout == "", repr(proc.stdout))

    mock.reset()
    proc = run_cli(["--input-file", input_file, "位置参数"])
    check("S1 缺 api-key/model：退出码 2", proc.returncode == 2, "exit=%d" % proc.returncode)
    check("S1 缺 api-key 时提示明确", "--api-key" in proc.stderr, proc.stderr)

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                    "--session-id", "../escape"], stdin_text="x")
    check("S1 非法 session-id：退出码 2", proc.returncode == 2, "exit=%d" % proc.returncode)
    check("S1 非法 session-id：不发请求", len(mock.requests()) == 0)

    if verbose:
        print("    (S1 sample stdout=%r stderr=%r)" % (proc.stdout, proc.stderr))


def s1_help(mock):
    proc = run_cli(["--help"])
    check("S1 --help：退出码 0", proc.returncode == 0)
    check("S1 --help：用法与退出码表在 stdout",
          proc.stdout.startswith("llmcli") and "退出码" in proc.stdout and "0  成功" in proc.stdout)
    check("S1 --help：列出会话路径与风险提示",
          ".llmcli" in proc.stdout and "风险提示" in proc.stdout)


def s2_tool_loop(mock):
    """AC: tool_calls -> 执行工具 -> 回填 -> stop。"""
    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="run the tool")
    check("S2 工具循环：退出码 0", proc.returncode == 0, proc.stderr)
    check("S2 工具循环：stdout 只有最终答案", proc.stdout.strip() == "final answer", repr(proc.stdout))
    check("S2 工具循环：命令原文打印到 stderr（可审计）",
          "echo hello-from-tool" in proc.stderr, repr(proc.stderr))
    check("S2 工具循环：每轮 turn 摘要在 stderr",
          "[turn 1]" in proc.stderr and "[turn 2]" in proc.stderr, repr(proc.stderr))
    check("S2 工具循环：每轮都打 token 用量（含工具轮）",
          proc.stderr.count("prompt=11") >= 2, repr(proc.stderr))

    requests = mock.requests()
    check("S2 工具循环：共 2 次请求", len(requests) == 2, str(len(requests)))
    if len(requests) >= 2:
        second = requests[1]
        roles = [m["role"] for m in second["messages"]]
        check("S2 工具循环：第二次请求带 history+tool 回填",
              roles == ["user", "assistant", "tool"], str(roles))
        tool_message = second["messages"][2]
        check("S2 工具循环：tool 消息含 tool_call_id 与实际输出",
              tool_message.get("tool_call_id") == "call_1"
              and "hello-from-tool" in (tool_message.get("content") or ""),
              json.dumps(tool_message, ensure_ascii=False))
        check("S2 请求体 stream=false", second.get("stream") is False, str(second.get("stream")))
        check("S2 请求体带 tools 定义", bool(second.get("tools")))


def s2_edit_task(mock, run_index):
    """PRD 成功指标：读文件 -> 改文件 -> 收尾。"""
    work = os.path.join(WORK, "work")
    os.makedirs(work, exist_ok=True)
    sample = os.path.join(work, "sample.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("line one\nold-text\nline three\n")

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="把 old-text 改成 new-text")
    with open(sample, "r", encoding="utf-8") as fh:
        content = fh.read()
    ok = (proc.returncode == 0
          and content == "line one\nnew-text\nline three\n"
          and proc.stdout.strip().endswith("sample.txt"))
    if run_index == 1:
        # mock 的 edit_task 第一轮带 reasoning_content，工具轮也要给字符数
        check("S2 edit_task：工具轮的摘要带 reasoning 字符数",
              "reasoning 21 字符" in proc.stderr, repr(proc.stderr))
    check("S2 edit_task #%d：退出码 0 + 文件被改对 + 有最终答案" % run_index, ok,
          "exit=%d stdout=%r file=%r stderr=%s" % (proc.returncode, proc.stdout, content,
                                                   proc.stderr))
    return ok


def s2_error_paths(mock):
    """AC: 协议错误/HTTP 错误/无答案 分别对应退出码。"""
    bad = Mock("bad_json", port=PORT + 1)
    try:
        bad.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", bad.base_url],
                       stdin_text="x")
        check("S2 非法 JSON 响应：退出码 1", proc.returncode == 1, "exit=%d" % proc.returncode)
        check("S2 非法 JSON 响应：stdout 为空", proc.stdout == "", repr(proc.stdout))
        check("S2 非法 JSON 响应：stderr 带原始响应摘要",
              "不是合法 JSON" in proc.stderr and "this is not json" in proc.stderr, proc.stderr)
    finally:
        bad.stop()

    server_error = Mock("http_500", port=PORT + 2)
    try:
        server_error.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY,
                        "--api-url", server_error.base_url], stdin_text="x")
        check("S2 HTTP 500：退出码 1", proc.returncode == 1, "exit=%d" % proc.returncode)
        check("S2 HTTP 500：stderr 带状态码", "HTTP 500" in proc.stderr, proc.stderr)
    finally:
        server_error.stop()

    empty = Mock("no_answer", port=PORT + 3)
    try:
        empty.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", empty.base_url],
                       stdin_text="x")
        check("S2 无最终答案：退出码 3", proc.returncode == 3, "exit=%d" % proc.returncode)
        check("S2 无最终答案：stdout 为空", proc.stdout == "", repr(proc.stdout))
    finally:
        empty.stop()

    proc = run_cli(["--model", "any", "--api-key", API_KEY,
                    "--api-url", "http://127.0.0.1:1/v1/chat/completions"], stdin_text="x")
    check("S2 网络错误：退出码 1", proc.returncode == 1, "exit=%d" % proc.returncode)
    check("S2 网络错误：stderr 有可读错误", "网络错误" in proc.stderr, proc.stderr)


def s3_sessions(mock, verbose):
    """AC: 同 id 二次调用带历史；reasoning 落盘但请求里剥离；坏行跳过。"""
    home = os.path.join(WORK, "session_home")
    shutil.rmtree(home, ignore_errors=True)

    mock.reset()
    first = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                     "--session-id", "reg1"], stdin_text="第一问", home=home)
    check("S3 首次会话：退出码 0", first.returncode == 0, first.stderr)

    session_file = os.path.join(home, ".llmcli", "sessions", "reg1.jsonl")
    check("S3 会话文件已创建", os.path.exists(session_file), session_file)

    records = []
    if os.path.exists(session_file):
        with open(session_file, "r", encoding="utf-8") as fh:
            records = [json.loads(line) for line in fh if line.strip()]
    check("S3 落盘包含 user/assistant/tool 三类消息",
          {r["message"]["role"] for r in records} >= {"user", "assistant", "tool"},
          str([r["message"]["role"] for r in records]))
    check("S3 每条记录都有 ts/turn/message",
          all({"ts", "turn", "message"} <= set(r) for r in records))

    second = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                      "--session-id", "reg1"], stdin_text="第二问", home=home)
    check("S3 续话：退出码 0", second.returncode == 0, second.stderr)

    requests = mock.requests()
    second_request = requests[-1] if requests else {}
    contents = [m.get("content") for m in second_request.get("messages", [])]
    check("S3 续话请求携带历史", "第一问" in contents, json.dumps(contents, ensure_ascii=False))
    check("S3 续话请求带新输入", "第二问" in contents, json.dumps(contents, ensure_ascii=False))
    check("S3 所有请求都不含 reasoning_content",
          all("reasoning_content" not in json.dumps(r) for r in requests))

    # 追加一行坏数据，确认只警告不中断
    with open(session_file, "a", encoding="utf-8") as fh:
        fh.write("{ 这是坏行 }\n")
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                    "--session-id", "reg1"], stdin_text="第三问", home=home)
    check("S3 坏行：跳过告警且不影响本次运行",
          proc.returncode == 0 and "无法解析" in proc.stderr,
          "exit=%d stderr=%s" % (proc.returncode, proc.stderr))

    proc = run_cli(["--list-sessions"], home=home)
    check("S3 --list-sessions：列出 id 与消息数",
          "reg1" in proc.stdout and "条消息" in proc.stdout, repr(proc.stdout))

    if verbose:
        print("    (S3 records=%d stderr=%s)" % (len(records), second.stderr))


def s3_reasoning(mock):
    """AC: reasoning_content 落盘、stderr 只打长度摘要、stdout 无泄漏。"""
    home = os.path.join(WORK, "reasoning_home")
    shutil.rmtree(home, ignore_errors=True)
    server = Mock("reasoning", port=PORT + 4)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--session-id", "r1"], stdin_text="think", home=home)
        check("S3 reasoning：退出码 0", proc.returncode == 0, proc.stderr)
        check("S3 reasoning：stdout 不含思维链",
              "step 1" not in proc.stdout, repr(proc.stdout))
        check("S3 reasoning：stderr 只有长度摘要",
              "reasoning 23 字符" in proc.stderr and "step 1" not in proc.stderr,
              repr(proc.stderr))

        session_file = os.path.join(home, ".llmcli", "sessions", "r1.jsonl")
        with open(session_file, "r", encoding="utf-8") as fh:
            records = [json.loads(line) for line in fh if line.strip()]
        reasons = [r["message"].get("reasoning_content") for r in records]
        check("S3 reasoning：全量落盘", any("step 1" in (x or "") for x in reasons), str(reasons))

        server.reset()
        debug = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                         "--debug", "--session-id", "r1"], stdin_text="think again", home=home)
        check("S4 --debug：密钥不出现", API_KEY not in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：密钥以脱敏形式出现",
              "sk-***ret" in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：打印原始响应",
              "reasoning_content" in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：stdout 仍然纯净",
              "step 1" not in debug.stdout and "debug:" not in debug.stdout, repr(debug.stdout))
    finally:
        server.stop()


def s2_unknown_tool(mock):
    """未知工具 / 参数非法要回填给 LLM 并继续。"""
    server = Mock("unknown_tool", port=PORT + 5)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="x")
        check("S2 未知工具：回填错误后仍收敛", proc.returncode == 0, proc.stderr)
        requests = server.requests()
        if len(requests) >= 2:
            tool_message = requests[1]["messages"][-1]
            check("S2 未知工具：错误文本回填给 LLM",
                  "未知工具" in (tool_message.get("content") or ""),
                  json.dumps(tool_message, ensure_ascii=False))
        else:
            check("S2 未知工具：错误文本回填给 LLM", False, "只有 %d 次请求" % len(requests))
    finally:
        server.stop()


def s4_ci_hygiene(mock):
    """AC: 输出非终端时不出现 ANSI 颜色；stdout 可重定向。"""
    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="x")
    check("S4 非终端输出：stderr 无 ANSI 转义", "\x1b[" not in proc.stderr, repr(proc.stderr))
    check("S4 非终端输出：stdout 无 ANSI 转义", "\x1b[" not in proc.stdout, repr(proc.stdout))

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                    "--no-color"], stdin_text="x")
    check("S4 --no-color：可正常执行", proc.returncode == 0, proc.stderr)


def s2_bad_arguments():
    """AC: 参数 JSON 非法要回填错误给 LLM。"""
    server = Mock("bad_arguments", port=PORT + 8)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="x")
        check("S2 参数非法：回填错误后仍收敛", proc.returncode == 0, proc.stderr)
        requests = server.requests()
        if len(requests) >= 2:
            tool_message = requests[1]["messages"][-1]
            check("S2 参数非法：错误文本回填给 LLM",
                  "command" in (tool_message.get("content") or ""),
                  json.dumps(tool_message, ensure_ascii=False))
        else:
            check("S2 参数非法：错误文本回填给 LLM", False, "只有 %d 次请求" % len(requests))
    finally:
        server.stop()


def count_process(image):
    """当前系统里叫 image 的进程数（用 tasklist / ps）。"""
    try:
        if os.name == "nt":
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq %s" % image, "/FO", "CSV"],
                                 capture_output=True, text=True, timeout=20).stdout
            return sum(1 for line in out.splitlines() if line.lower().startswith('"%s"' % image.lower()))
        out = subprocess.run(["pgrep", "-c", "-f", image], capture_output=True, text=True,
                             timeout=20).stdout.strip()
        return int(out or 0)
    except Exception:  # noqa: BLE001 - 环境没有对应工具就按 0 算
        return 0


def s2_interrupt():
    """AC: 使用者中断时子进程被一并终止，无残留；stdout 为空。"""
    if os.name == "nt":
        sleep_command = "ping -n 120 127.0.0.1"
        image = "PING.EXE"
    else:
        sleep_command = "sleep 120"
        image = "sleep"

    server = Mock("slow_command", replace={"{{SLEEP}}": sleep_command}, port=PORT + 9)
    env = dict(os.environ)
    env["LLMCLI_HOME"] = os.path.join(WORK, "interrupt_home")
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    baseline = count_process(image)
    try:
        server.reset()
        proc = subprocess.Popen(
            [exe_path(), "--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=ROOT, creationflags=flags,
        )
        proc.stdin.write(b"go\n")
        proc.stdin.close()

        # 等 bash 工具真的把子进程拉起来
        started = False
        for _ in range(60):
            if count_process(image) > baseline:
                started = True
                break
            time.sleep(0.25)
        check("S2 中断：慢命令子进程已启动", started, "未观察到 %s" % image)

        if os.name == "nt":
            proc.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            proc.send_signal(signal.SIGINT)

        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
        stdout = proc.stdout.read()
        check("S2 中断：退出码为 130（我们的中断处理器）", proc.returncode == 130, str(proc.returncode))
        check("S2 中断：stdout 为空", stdout.strip() == b"", repr(stdout))

        time.sleep(1)
        check("S2 中断：无孤儿子进程残留", count_process(image) <= baseline,
              "%s: %d -> %d" % (image, baseline, count_process(image)))
    finally:
        server.stop()


def s5_max_turns():
    """AC: --max-turns n>0 时最多 n 次请求；达到上限则 stderr 说明、stdout 空、退出码 3。"""
    server = Mock("always_tools", port=PORT + 10)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--max-turns", "3"], stdin_text="spin")
        check("S5 --max-turns=3：退出码 3（循环未收敛）", proc.returncode == 3,
              "exit=%d stderr=%s" % (proc.returncode, proc.stderr))
        check("S5 --max-turns=3：stdout 为空", proc.stdout == "", repr(proc.stdout))
        check("S5 --max-turns=3：stderr 说明原因",
              "--max-turns=3 上限" in proc.stderr, repr(proc.stderr))
        check("S5 --max-turns=3：恰好发 3 次请求", len(server.requests()) == 3,
              str(len(server.requests())))

        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--max-turns=1"], stdin_text="spin")
        check("S5 --max-turns=1：恰好发 1 次请求", len(server.requests()) == 1,
              str(len(server.requests())))
        check("S5 --max-turns=1：退出码 3", proc.returncode == 3, str(proc.returncode))

        # 不给该参数 = 不设上限：这里给 5 秒，够跑出远多于 1 次请求
        server.reset()
        try:
            proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                           stdin_text="spin", timeout=5)
            unlimited_returncode = proc.returncode
        except subprocess.TimeoutExpired:
            unlimited_returncode = None  # 5 秒都没跑完 → 确实没有上限
        check("S5 不给 --max-turns：不设上限（5 秒内未自行止损）",
              unlimited_returncode is None and len(server.requests()) > 3,
              "returncode=%s requests=%d" % (unlimited_returncode, len(server.requests())))
    finally:
        server.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--repetitions", type=int, default=20,
                        help="edit_task 回归次数（PRD 成功指标：成功率 >= 90%%）")
    args = parser.parse_args()

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    simple_mock = Mock("simple", port=PORT + 7)
    mock = Mock("tool_loop")
    edit_mock = Mock(
        "edit_task",
        replace={"{{FILE}}": os.path.join(WORK, "work", "sample.txt")},
        port=PORT + 6,
    )
    try:
        s1_help(simple_mock)
        s1_single_turn(simple_mock, args.verbose)
        s2_tool_loop(mock)
        s2_error_paths(mock)
        s3_sessions(mock, args.verbose)
        s3_reasoning(mock)
        s2_unknown_tool(mock)
        s2_bad_arguments()
        s4_ci_hygiene(mock)
        s2_interrupt()
        s5_max_turns()

        wins = 0
        for index in range(1, args.repetitions + 1):
            if s2_edit_task(edit_mock, index):
                wins += 1
        rate = wins / args.repetitions
        check("S2 edit_task 成功率 %d/%d (%.0f%%) >= 90%%" % (wins, args.repetitions, rate * 100),
              rate >= 0.9, "rate=%.2f" % rate)
    finally:
        simple_mock.stop()
        mock.stop()
        edit_mock.stop()

    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\n%d 项检查，%d 项失败" % (len(RESULTS), len(failed)))
    for name in failed:
        print("  FAIL %s" % name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
