#!/usr/bin/env python3
"""llmcli 端到端回归：对着 scripts/mock_llm.py 跑 shellm 式 RLM 循环的场景。

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


def run_cli(args, stdin_text=None, traj_dir=None, timeout=60, inherit_stdin=False):
    env = dict(os.environ)
    # 轨迹根目录只由 --traj-dir / --config-dir 决定（不再读环境变量），每个场景一个隔离目录
    root = traj_dir or os.path.join(WORK, "traj")
    kwargs = {"stdin": None} if inherit_stdin else {"input": stdin_text}
    proc = subprocess.run(
        [exe_path(), "--traj-dir", root] + args,
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


def fwd(path):
    """把 Windows 路径转成正斜杠，便于嵌进 bash 单引号字符串。"""
    return path.replace("\\", "/")


def read_steps(traj_root):
    """读回某轨迹根下所有轨迹的步骤，按目录名分组。"""
    out = {}
    if not os.path.isdir(traj_root):
        return out
    for name in os.listdir(traj_root):
        path = os.path.join(traj_root, name, "trajectory.jsonl")
        if not os.path.exists(path):
            continue
        steps = []
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    steps.append(json.loads(line))
        out[name] = steps
    return out


def step_types(steps):
    return [s.get("type") for s in steps]


# --------------------------------------------------------------------------- 场景

def s1_help(mock):
    proc = run_cli(["--help"])
    check("S1 --help：退出码 0", proc.returncode == 0)
    check("S1 --help：用法与退出码表在 stdout",
          proc.stdout.startswith("llmcli") and "退出码" in proc.stdout and "0  成功" in proc.stdout)
    check("S1 --help：列出轨迹路径与风险提示",
          ".llmcli" in proc.stdout and "风险提示" in proc.stdout)
    check("S1 --help：说明 FINAL / FINAL_FILE 报捷", "FINAL" in proc.stdout, proc.stdout[:200])
    check("S1 --help：说明子命令", "traj" in proc.stdout and "shellm" in proc.stdout)


def s1_print_system_prompt(mock):
    """AC: --print-system-prompt 打印实际会发的系统提示词；不要求凭据、不读输入、不发请求。"""
    mock.reset()
    proc = run_cli(["--print-system-prompt"])
    check("S1 --print-system-prompt：退出码 0", proc.returncode == 0, proc.stderr)
    check("S1 --print-system-prompt：stdout 含内置系统提示词",
          "系统令" in proc.stdout, repr(proc.stdout[:200]))
    check("S1 --print-system-prompt：stderr 无过程日志", proc.stderr == "", repr(proc.stderr))
    check("S1 --print-system-prompt：不发任何请求", len(mock.requests()) == 0)

    mock.reset()
    proc = run_cli(["--print-system-prompt", "--system-prompt", "MARKER {{os}}"])
    check("S1 --print-system-prompt：采用显式 --system-prompt 且展开占位符",
          proc.stdout.startswith("MARKER ") and "{{" not in proc.stdout,
          repr(proc.stdout[:120]))

    proc = run_cli(["--print-system-prompt", "--list-skills"])
    check("S1 --print-system-prompt 与动作开关冲突：退出码 2", proc.returncode == 2,
          "exit=%d" % proc.returncode)


def s1_single_turn(mock, verbose):
    """AC: 单轮问答成功（无代码块 → 整段回复即答案）；stdout 无日志；三路输入互斥。"""
    root = os.path.join(WORK, "s1_traj")
    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="hello world", traj_dir=root)
    check("S1 stdin 单轮：退出码 0", proc.returncode == 0, proc.stderr)
    check("S1 stdin 单轮：stdout 只有答案", "hello world" in proc.stdout and "Trace" not in proc.stdout,
          repr(proc.stdout))
    steps = read_steps(root)
    check("S1 单轮：落盘 trajectory（头 + shellm-run + prompt + final + run-summary）",
          len(steps) == 1 and step_types(list(steps.values())[0]) ==
          ["trajectory", "shellm-run", "prompt", "final", "run-summary"],
          str({k: step_types(v) for k, v in steps.items()}))

    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url, "--quiet"],
                   stdin_text="hello world")
    check("S1 --quiet：stderr 无过程日志", "Trace" not in proc.stderr, repr(proc.stderr))

    input_file = os.path.join(WORK, "input.txt")
    with open(input_file, "w", encoding="utf-8") as fh:
        fh.write("from file")

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
                    "--traj", "../escape"], stdin_text="x")
    check("S1 非法 traj id：退出码 2", proc.returncode == 2, "exit=%d" % proc.returncode)
    check("S1 非法 traj id：不发请求", len(mock.requests()) == 0)

    check("S1 shells：可用的 bash 已就绪",
          shutil.which("bash") is not None or os.path.exists("C:/Program Files/Git/bin/bash.exe"),
          "未找到 bash")

    if verbose:
        print("    (S1 sample stdout=%r stderr=%r)" % (proc.stdout, proc.stderr))


def s2_block_loop(mock):
    """AC: bash 代码块 → 本地执行 → 输出作为下一条 user 消息回填 → 无代码块回复收尾。"""
    root = os.path.join(WORK, "s2_traj")
    mock.reset()
    proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                   stdin_text="run the tool", traj_dir=root)
    check("S2 代码块循环：退出码 0", proc.returncode == 0, proc.stderr)
    check("S2 代码块循环：stdout 只有最终答案", proc.stdout.strip() == "final answer", repr(proc.stdout))
    check("S2 代码块循环：执行输出打印到 stderr",
          "hello-from-tool" in proc.stderr, repr(proc.stderr))
    check("S2 代码块循环：每轮 iter 摘要在 stderr",
          "[iter 1]" in proc.stderr and "[iter 2]" in proc.stderr, repr(proc.stderr))
    check("S2 代码块循环：每轮都打 token 用量",
          proc.stderr.count("prompt=11") >= 2, repr(proc.stderr))

    requests = mock.requests()
    check("S2 代码块循环：共 2 次请求", len(requests) == 2, str(len(requests)))
    if len(requests) >= 2:
        second = requests[1]
        roles = [m["role"] for m in second["messages"]]
        check("S2 代码块循环：第二次请求带 system+history+执行输出",
              roles == ["system", "user", "assistant", "user"], str(roles))
        observation = second["messages"][-1]
        check("S2 代码块循环：执行输出作为 user 消息回填",
              observation["role"] == "user" and "hello-from-tool" in (observation.get("content") or ""),
              json.dumps(observation, ensure_ascii=False))
        check("S2 代码块循环：观察输出无 CRLF 污染与 xtrace",
              "\r" not in (observation.get("content") or "")
              and "+ echo" not in (observation.get("content") or "")
              and "+ set" not in (observation.get("content") or ""),
              json.dumps(observation, ensure_ascii=False))
        check("S2 请求体 stream=false", second.get("stream") is False, str(second.get("stream")))
        check("S2 请求体不带 tools（RLM 不用 tools 协议）", "tools" not in second, str(second.keys()))

    # observations 空输出兜底
    noop = Mock("no_output", port=PORT + 28)
    try:
        noop.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", noop.base_url],
                       stdin_text="静默")
        requests = noop.requests()
        check("S2 无输出：两轮收尾", len(requests) == 2, str(len(requests)))
        if len(requests) >= 2:
            observation = requests[1]["messages"][-1]
            check("S2 无输出：观察消息是（无输出）",
                  observation.get("content") == "（无输出）",
                  json.dumps(observation, ensure_ascii=False))
    finally:
        noop.stop()


def s2_block_final(mock):
    """AC: 代码里设 FINAL 当场结束，stdout 为 FINAL 的值。"""
    root = os.path.join(WORK, "s2_final_traj")
    server = Mock("block_final", port=PORT + 14)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="算一下", traj_dir=root)
        check("S2 FINAL：退出码 0", proc.returncode == 0, proc.stderr)
        check("S2 FINAL：stdout 为 FINAL 的值", proc.stdout.strip() == "final answer", repr(proc.stdout))
        check("S2 FINAL：一次请求即收尾", len(server.requests()) == 1, str(len(server.requests())))
        steps = read_steps(root)
        types = step_types(list(steps.values())[0]) if steps else []
        check("S2 FINAL：轨迹以 final 收尾", "final" in types, str(types))
    finally:
        server.stop()


def s2_final_empty():
    """AC: FINAL 设为空串也算"设置过"，当场以空答案收尾（与 bash 版 set-ness 一致）。"""
    server = Mock("block_final_empty", port=PORT + 26)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="说点什么")
        check("S2 FINAL 空串：退出码 0", proc.returncode == 0, proc.stderr)
        check("S2 FINAL 空串：stdout 为空", proc.stdout.strip() == "", repr(proc.stdout))
        check("S2 FINAL 空串：一次请求即收尾（未被当未设 FINAL）",
              len(server.requests()) == 1, str(len(server.requests())))
    finally:
        server.stop()


def s2_final_file(run_index):
    """AC: 代码设 FINAL_FILE 时其文件内容进 stdout。"""
    work = os.path.join(WORK, "work")
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "final_src_%d.txt" % run_index)
    server = Mock("block_final_file", replace={"{{FINALSRC}}": fwd(src)}, port=PORT + 27)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="从文件给答案")
        check("S2 FINAL_FILE：退出码 0", proc.returncode == 0, proc.stderr)
        check("S2 FINAL_FILE：stdout 为文件内容",
              proc.stdout.strip() == "从文件来的答案", repr(proc.stdout))
        check("S2 FINAL_FILE：一次请求即收尾",
              len(server.requests()) == 1, str(len(server.requests())))
    finally:
        server.stop()


def s2_multi_block():
    """AC: 回复含多个代码块时只执行第一个，其余丢弃并告警。"""
    server = Mock("multi_block", port=PORT + 15)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                       stdin_text="多块")
        check("S2 多代码块：退出码 0", proc.returncode == 0, proc.stderr)
        check("S2 多代码块：只执行第一个块（second 未被执行）",
              "first" in proc.stderr and "second" not in proc.stderr, repr(proc.stderr))
        check("S2 多代码块：stderr 告警只执行第一个",
              "只执行第一个" in proc.stderr, repr(proc.stderr[-400:]))
    finally:
        server.stop()


def s2_error_paths():
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
        check("S2 空响应：退出码 3（重试耗尽）", proc.returncode == 3, "exit=%d" % proc.returncode)
        check("S2 空响应：stdout 为空", proc.stdout == "", repr(proc.stdout))
    finally:
        empty.stop()

    proc = run_cli(["--model", "any", "--api-key", API_KEY,
                    "--api-url", "http://127.0.0.1:1/v1/chat/completions"], stdin_text="x")
    check("S2 网络错误：退出码 1", proc.returncode == 1, "exit=%d" % proc.returncode)
    check("S2 网络错误：stderr 有可读错误", "网络错误" in proc.stderr, proc.stderr)


def s2_idle_watchdog():
    """AC: 空闲看门狗杀掉无输出的命令，并回填结构化反馈。"""
    root = os.path.join(WORK, "idle_traj")
    server = Mock("idle_command", port=PORT + 21)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--inactivity-timeout", "2", "--max-iterations", "1"],
                       stdin_text="idle", traj_dir=root, timeout=30)
        check("S2 空闲看门狗：退出码 3（被止损后未收敛）", proc.returncode == 3,
              "exit=%d stderr=%s" % (proc.returncode, proc.stderr[-300:]))
        steps = read_steps(root)
        shells = [s for s in list(steps.values())[0] if s.get("type") == "shell-output"]
        text = shells[-1].get("stdout", "") if shells else ""
        check("S2 空闲看门狗：回填结构化反馈（提示交互式/改非交互）",
              "空闲看门狗" in text and "非交互" in text, repr(text[:200]))
    finally:
        server.stop()


def s3_trajectory(mock, verbose):
    """AC: 同 traj 二次调用续接；reasoning 落盘；bash 代码轮次可读回。"""
    root = os.path.join(WORK, "s3_traj")
    shutil.rmtree(root, ignore_errors=True)

    mock.reset()
    first = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                     "--traj", "reg1"], stdin_text="第一问", traj_dir=root)
    check("S3 首次：退出码 0", first.returncode == 0, first.stderr)

    traj_file = os.path.join(root, "reg1", "trajectory.jsonl")
    check("S3 轨迹文件已创建", os.path.exists(traj_file), traj_file)

    steps = read_steps(root).get("reg1", [])
    types = step_types(steps)
    check("S3 落盘步骤序列（含 reasoning/shell-output/final）",
          types[:4] == ["trajectory", "shellm-run", "prompt", "reasoning"]
          and "shell-output" in types and "final" in types, str(types))
    check("S3 每条步骤都有 step_id/ts/type/run_id",
          all({"step_id", "ts", "type", "run_id"} <= set(s) for s in steps[1:]),
          str(steps[:2]))

    second = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url,
                      "--traj", "reg1"], stdin_text="第二问", traj_dir=root)
    check("S3 续话：退出码 0", second.returncode == 0, second.stderr)

    requests = mock.requests()
    second_request = requests[-1] if requests else {}
    contents = [m.get("content") for m in second_request.get("messages", [])]
    check("S3 续话请求携带历史", "第一问" in contents, json.dumps(contents, ensure_ascii=False))
    check("S3 续话请求带新输入", "第二问" in contents, json.dumps(contents, ensure_ascii=False))
    check("S3 所有请求都不含 reasoning_content",
          all("reasoning_content" not in json.dumps(r) for r in requests))

    after = read_steps(root).get("reg1", [])
    check("S3 续话：已有步骤原样保留（只追加、不重写）",
          after[:len(steps)] == steps,
          "before=%d after=%d" % (len(steps), len(after)))
    check("S3 续话：轨迹以 final 收尾", "final" in step_types(after), str(step_types(after)))

    proc = run_cli(["--list-sessions"], traj_dir=root)
    check("S3 --list-sessions：列出目录名与步数",
          "reg1" in proc.stdout and "步" in proc.stdout, repr(proc.stdout))

    if verbose:
        print("    (S3 steps=%d stderr=%s)" % (len(steps), second.stderr))


def s3_sub_run():
    """AC: 生成代码显式起子 run，父轨迹记 fork/merge。"""
    root = os.path.join(WORK, "s3_sub_traj")
    shutil.rmtree(root, ignore_errors=True)
    child = Mock("simple", port=PORT + 31)
    parent = Mock("sub_run", port=PORT + 30, replace={
        "{{LLMCLI}}": fwd(exe_path()),
        "{{APIKEY}}": API_KEY,
        "{{APIURL}}": child.base_url,
        "{{TRAJDIR}}": fwd(root),
    })
    try:
        child.reset()
        parent.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", parent.base_url,
                        "--traj-dir", root], stdin_text="父任务", traj_dir=root, timeout=60)
        check("S3 子 run：父退出码 0", proc.returncode == 0, proc.stderr)
        check("S3 子 run：stdout 为父最终答案", proc.stdout.strip() == "parent done", repr(proc.stdout))

        groups = read_steps(root)
        parent_steps = None
        child_found = False
        for name, steps in groups.items():
            types = step_types(steps)
            if "fork" in types:
                parent_steps = steps
            if "final" in types and "fork" not in types:
                child_found = True
        check("S3 子 run：父轨迹有 fork 步骤",
              parent_steps is not None and "fork" in step_types(parent_steps),
              str({k: step_types(v) for k, v in groups.items()}))
        check("S3 子 run：父轨迹有 merge 步骤",
              parent_steps is not None and "merge" in step_types(parent_steps),
              str({k: step_types(v) for k, v in groups.items()}))
        check("S3 子 run：存在独立的子轨迹", child_found and len(groups) >= 2, str(list(groups.keys())))
        if parent_steps:
            fork = [s for s in parent_steps if s.get("type") == "fork"][0]
            merge = [s for s in parent_steps if s.get("type") == "merge"][0]
            check("S3 子 run：fork.child == merge.from_traj",
                  fork.get("child") == merge.get("from_traj"),
                  "%s vs %s" % (fork.get("child"), merge.get("from_traj")))
    finally:
        parent.stop()
        child.stop()


def s3_reasoning():
    """AC: reasoning_content 落盘、stderr 只打长度摘要、stdout 无泄漏。"""
    root = os.path.join(WORK, "reasoning_traj")
    shutil.rmtree(root, ignore_errors=True)
    server = Mock("reasoning", port=PORT + 4)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--traj", "r1"], stdin_text="think", traj_dir=root)
        check("S3 reasoning：退出码 0", proc.returncode == 0, proc.stderr)
        check("S3 reasoning：stdout 不含思维链",
              "step 1" not in proc.stdout, repr(proc.stdout))
        check("S3 reasoning：stderr 只有长度摘要",
              "reasoning 23 字符" in proc.stderr and "step 1" not in proc.stderr,
              repr(proc.stderr))

        traj_file = os.path.join(root, "r1", "trajectory.jsonl")
        with open(traj_file, "r", encoding="utf-8") as fh:
            steps = [json.loads(line) for line in fh if line.strip()]
        reasons = [s.get("reasoning_content") for s in steps if s.get("type") == "reasoning"]
        check("S3 reasoning：全量落盘（reasoning_content 字段）",
              any("step 1" in (x or "") for x in reasons), str(reasons))

        server.reset()
        debug = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                         "--debug", "--traj", "r1"], stdin_text="think again", traj_dir=root)
        check("S4 --debug：密钥不出现", API_KEY not in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：密钥以脱敏形式出现",
              "sk-***ret" in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：打印原始响应",
              "reasoning_content" in debug.stderr, repr(debug.stderr[-800:]))
        check("S4 --debug：stdout 仍然纯净",
              "step 1" not in debug.stdout and "debug:" not in debug.stdout, repr(debug.stdout))
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
    flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    baseline = count_process(image)
    try:
        server.reset()
        proc = subprocess.Popen(
            [exe_path(), "--traj-dir", os.path.join(WORK, "interrupt_traj"),
             "--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=ROOT, creationflags=flags,
        )
        proc.stdin.write(b"go\n")
        proc.stdin.close()

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


def s5_max_iterations():
    """AC: --max-iterations n>0 时最多 n 次请求；达到上限则 stderr 说明、stdout 空、退出码 3。"""
    server = Mock("always_blocks", port=PORT + 10)
    try:
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--max-iterations", "3"], stdin_text="spin")
        check("S5 --max-iterations=3：退出码 3（循环未收敛）", proc.returncode == 3,
              "exit=%d stderr=%s" % (proc.returncode, proc.stderr))
        check("S5 --max-iterations=3：stdout 为空", proc.stdout == "", repr(proc.stdout))
        check("S5 --max-iterations=3：stderr 说明原因",
              "--max-iterations=3 上限" in proc.stderr, repr(proc.stderr))
        check("S5 --max-iterations=3：恰好发 3 次请求", len(server.requests()) == 3,
              str(len(server.requests())))

        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--max-iterations=1"], stdin_text="spin")
        check("S5 --max-iterations=1：恰好发 1 次请求", len(server.requests()) == 1,
              str(len(server.requests())))
        check("S5 --max-iterations=1：退出码 3", proc.returncode == 3, str(proc.returncode))

        # 别名 --max-turns 仍生效
        server.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                        "--max-turns=2"], stdin_text="spin")
        check("S5 --max-turns 别名：恰好发 2 次请求", len(server.requests()) == 2,
              str(len(server.requests())))

        # 不给该参数 = 不设上限：这里给 5 秒，够跑出远多于 1 次请求
        server.reset()
        try:
            proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url],
                           stdin_text="spin", timeout=5)
            unlimited_returncode = proc.returncode
        except subprocess.TimeoutExpired:
            unlimited_returncode = None  # 5 秒都没跑完 → 确实没有上限
        check("S5 不给 --max-iterations：不设上限（5 秒内未自行止损）",
              unlimited_returncode is None and len(server.requests()) > 1,
              "returncode=%s requests=%d" % (unlimited_returncode, len(server.requests())))
    finally:
        server.stop()


def s6_subcommands():
    """AC: traj / context 子命令可查轨迹；skills 等价 --list-skills。"""
    root = os.path.join(WORK, "s6_traj")
    server = Mock("block_loop", port=PORT + 32)
    try:
        server.reset()
        run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", server.base_url,
                 "--traj", "demo"], stdin_text="子命令", traj_dir=root)

        proc = run_cli(["traj", "list"], traj_dir=root)
        check("S6 traj list：列出轨迹名", "demo" in proc.stdout and "步" in proc.stdout,
              repr(proc.stdout))

        proc = run_cli(["traj", "show", "demo"], traj_dir=root)
        check("S6 traj show：打印步骤类型",
              "prompt" in proc.stdout and "reasoning" in proc.stdout and "final" in proc.stdout,
              repr(proc.stdout))

        proc = run_cli(["traj", "tail", "demo", "2"], traj_dir=root)
        check("S6 traj tail：只打印末尾若干步",
              proc.stdout.count("\n") <= 2, repr(proc.stdout))

        proc = run_cli(["traj", "search", "demo", "final answer"], traj_dir=root)
        check("S6 traj search：命中子串", "final" in proc.stdout, repr(proc.stdout))

        proc = run_cli(["traj", "show", "demo", "--full"], traj_dir=root)
        check("S6 traj show --full：打印完整正文", "final answer" in proc.stdout, repr(proc.stdout))

        proc = run_cli(["traj", "list", "--children"], traj_dir=root)
        check("S6 traj list --children：列出轨迹", "demo" in proc.stdout, repr(proc.stdout))

        proc = run_cli(["context", "--traj", "demo"], traj_dir=root)
        check("S6 context：渲染出 user/assistant 消息",
              "--- user ---" in proc.stdout and "--- assistant ---" in proc.stdout,
              repr(proc.stdout))
    finally:
        server.stop()


def s2_edit_task(run_index):
    """PRD 成功指标：读文件 -> 改文件 -> FINAL。"""
    work = os.path.join(WORK, "work")
    os.makedirs(work, exist_ok=True)
    sample = os.path.join(work, "sample.txt")
    with open(sample, "w", encoding="utf-8") as fh:
        fh.write("line one\nold-text\nline three\n")

    mock = Mock("edit_task", replace={"{{FILE}}": fwd(sample)}, port=PORT + 6)
    try:
        mock.reset()
        proc = run_cli(["--model", "any", "--api-key", API_KEY, "--api-url", mock.base_url],
                       stdin_text="把 old-text 改成 new-text")
        with open(sample, "r", encoding="utf-8") as fh:
            content = fh.read()
        ok = (proc.returncode == 0
              and content == "line one\nnew-text\nline three\n"
              and proc.stdout.strip().endswith("sample.txt"))
        if run_index == 1:
            check("S2 edit_task：代码轮的摘要带 reasoning 字符数",
                  "reasoning 21 字符" in proc.stderr, repr(proc.stderr))
        check("S2 edit_task #%d：退出码 0 + 文件被改对 + 有最终答案" % run_index, ok,
              "exit=%d stdout=%r file=%r stderr=%s" % (proc.returncode, proc.stdout, content,
                                                       proc.stderr))
        return ok
    finally:
        mock.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--repetitions", type=int, default=20,
                        help="edit_task 回归次数（PRD 成功指标：成功率 >= 90%%）")
    args = parser.parse_args()

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    simple_mock = Mock("simple", port=PORT + 7)
    mock = Mock("block_loop")
    try:
        s1_help(simple_mock)
        s1_print_system_prompt(simple_mock)
        s1_single_turn(simple_mock, args.verbose)
        s2_block_loop(mock)
        s2_block_final(mock)
        s2_final_empty()
        s2_final_file(1)
        s2_multi_block()
        s2_error_paths()
        s2_idle_watchdog()
        s3_trajectory(mock, args.verbose)
        s3_sub_run()
        s3_reasoning()
        s4_ci_hygiene(mock)
        s6_subcommands()
        s2_interrupt()
        s5_max_iterations()

        wins = 0
        for index in range(1, args.repetitions + 1):
            if s2_edit_task(index):
                wins += 1
        rate = wins / args.repetitions
        check("S2 edit_task 成功率 %d/%d (%.0f%%) >= 90%%" % (wins, args.repetitions, rate * 100),
              rate >= 0.9, "rate=%.2f" % rate)
    finally:
        simple_mock.stop()
        mock.stop()

    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\n%d 项检查，%d 项失败" % (len(RESULTS), len(failed)))
    for name in failed:
        print("  FAIL %s" % name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
