#!/bin/sh
set -u

mode="${FAKE_MODE:?}"
pid_file="${FAKE_CHILD_PID_FILE:?}"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
identity_script="$script_dir/process-identity-session-escape.py"
child_pid=""

emit() {
    printf '%s\n' "$1"
}

response() {
    command="$1"
    id="$2"
    data="${3:-}"
    if [ -n "$data" ]; then
        emit "{\"command\":\"$command\",\"data\":$data,\"id\":\"$id\",\"success\":true,\"type\":\"response\"}"
    else
        emit "{\"command\":\"$command\",\"id\":\"$id\",\"success\":true,\"type\":\"response\"}"
    fi
}

spawn_child() {
    if [ -n "$child_pid" ]; then
        return
    fi
    /bin/sleep 30 &
    child_pid=$!
    printf '%s\n' "$child_pid" >"$pid_file"
}

spawn_session_escape() {
    if [ -n "$child_pid" ]; then
        return
    fi
    /usr/bin/python3 "$identity_script" "$pid_file" &
    child_pid=$!
    attempt=0
    while [ ! -s "$pid_file" ] && [ "$attempt" -lt 100 ]; do
        /bin/sleep 0.01
        attempt=$((attempt + 1))
    done
    test -s "$pid_file"
    /bin/sleep 0.2
}

if [ "$mode" = "settle-term-exit-7" ]; then
    trap 'exit 7' TERM
fi
if [ "$mode" = "no-read-prompt" ] || [ "$mode" = "close-stdin" ]; then
    printf '%s\n' "$$" >"$pid_file"
fi
if [ "$mode" = "timeout" ]; then
    spawn_child
fi
if [ "$mode" = "timeout-session-escape" ]; then
    spawn_session_escape
fi

while IFS= read -r line; do
    command="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
    id="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    case "$command" in
        set_auto_retry|set_auto_compaction)
            response "$command" "$id"
            ;;
        get_state)
            response "$command" "$id" \
                '{"autoCompactionEnabled":false,"isStreaming":false,"model":{"id":"fake-model","provider":"fake-provider"},"sessionId":"fake-session-1","thinkingLevel":"off"}'
            ;;
        get_commands)
            response "$command" "$id" \
                '{"commands":[{"name":"skill:jidoka-code-plan","source":"skill","sourceInfo":{"origin":"top-level","path":"/bundle/skills/jidoka-code-plan/SKILL.md","scope":"temporary"}}]}'
            if [ "$mode" = "no-read-prompt" ]; then
                exec /bin/sleep 30
            fi
            if [ "$mode" = "close-stdin" ]; then
                exec 0<&-
                exec /bin/sleep 30
            fi
            ;;
        prompt)
            response "$command" "$id"
            if [ "$mode" = "session-escape-success" ] || [ "$mode" = "session-escape-error" ]; then
                spawn_session_escape
            elif [ "$mode" != "timeout-session-escape" ] && \
                [ "$mode" != "settle-exit-7" ] && \
                [ "$mode" != "settle-signal" ] && \
                [ "$mode" != "settle-term-exit-7" ]; then
                spawn_child
            fi
            if [ "$mode" = "timeout" ] || [ "$mode" = "timeout-session-escape" ]; then
                continue
            fi
            if [ "$mode" = "stderr" ]; then
                printf 'unexpected diagnostic\n' >&2
            fi
            if [ "$mode" = "malformed" ]; then
                printf 'not-json\n'
                continue
            fi
            emit '{"type":"agent_start"}'
            emit '{"type":"turn_start"}'
            emit '{"message":{"role":"user"},"type":"message_start"}'
            emit '{"message":{"role":"user"},"type":"message_end"}'
            emit '{"message":{"role":"assistant"},"type":"message_start"}'
            emit '{"assistantMessageEvent":{"contentIndex":0,"delta":"done","type":"text_delta"},"type":"message_update"}'
            emit '{"message":{"role":"assistant"},"type":"message_end"}'
            emit '{"args":{},"toolCallId":"result-1","toolName":"jidoka_code_result","type":"tool_execution_start"}'
            emit '{"isError":false,"result":{"details":{"approvedCommandIDs":["check"],"artifactSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","nonce":"nonce-12345678","payload":{"verdict":"pass"},"resultSequence":1,"role":"writer","schemaVersion":1,"workflow":"planning"}},"toolCallId":"result-1","toolName":"jidoka_code_result","type":"tool_execution_end"}'
            emit '{"message":{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"result-1","toolName":"jidoka_code_result"},"type":"message_start"}'
            emit '{"message":{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"result-1","toolName":"jidoka_code_result"},"type":"message_end"}'
            emit '{"message":{},"toolResults":[{"content":[],"details":{},"isError":false,"role":"toolResult","timestamp":1,"toolCallId":"result-1","toolName":"jidoka_code_result"}],"type":"turn_end"}'
            emit '{"messages":[],"type":"agent_end","willRetry":false}'
            if [ "$mode" = "settle-signal" ]; then
                kill -s KILL "$$"
            fi
            emit '{"type":"agent_settled"}'
            if [ "$mode" = "late-event" ]; then
                /bin/sleep 0.05
                emit '{"type":"agent_start"}'
            fi
            if [ "$mode" = "settle-exit-7" ] || [ "$mode" = "settle-term-exit-7" ]; then
                exit 7
            fi
            if [ "$mode" = "session-escape-success" ]; then
                exit 0
            fi
            if [ "$mode" = "session-escape-error" ]; then
                exit 37
            fi
            ;;
        abort)
            response "$command" "$id"
            ;;
    esac
done
