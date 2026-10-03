#!/bin/bash

SYSTEM_PROMPT="You're useful AI assistant"

session_id=`date +%s`

./build/llmcli --api-url http://127.0.0.1:8317/v1/chat/completions \
    --session-id "ses_${session_id}" \
    --model hy3 \
    --api-key sk-1234 \
    --debug \
    "看看当前目录有什么，然后写一句话总结"