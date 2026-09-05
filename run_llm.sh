#!/bin/bash

API_URL="http://127.0.0.1:8001/v1/chat/completions"
MODEL="any"
# EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}'

system_prompt="You are a helpful software engineer assistant."

prompt="$@"
if [ -z "$prompt" ]; then
  prompt="hi"
fi

args=(--debug --thinking high --tools Bash,EditFile,ReadFile,WriteFile \
  --system-prompt "${system_prompt}" --api-url "${API_URL}" -m "${MODEL}")
if [ -n "$EXTRA_BODY" ]; then
  args+=(--extra-body "$EXTRA_BODY")
fi

./build/llm.exe "${args[@]}" "${prompt}"
