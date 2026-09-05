#!/bin/bash

export LLM_API_URL="http://127.0.0.1:8001/v1/chat/completions"
export LLM_MODEL="any"
# export LLM_EXTRA_BODY='{"chat_template_kwargs":{"enable_thinking":false}}'

system_prompt="You are a helpful software engineer assistant."

prompt="$@"
if [ -z "$prompt" ]; then
  prompt="hi"
fi


./build/llm.exe --debug --thinking low --tools Bash --system-prompt "${system_prompt}" "${prompt}"
