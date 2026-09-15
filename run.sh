#!/bin/bash

SYSTEM_PROMPT="You're useful AI assistant"

./build/llmcli --api-url http://127.0.0.1:8001/v1/chat/completions \
    --model any \
    --api-key sk-1234 \
    --system-prompt "${SYSTEM_PROMPT}" \
    --debug \
    "有什么内置工具可以使用"
