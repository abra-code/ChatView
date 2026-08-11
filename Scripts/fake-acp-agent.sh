#!/bin/sh
# Scripts/fake-acp-agent.sh
#
# A scripted ACP agent for the bridge demo. It speaks just enough of the protocol to make the
# remote transport do everything interesting - stream a reply token by token, run a tool call,
# ask for permission - without needing a real model or a real agent installed.
#
# Deliberately SLOW (a short sleep between chunks) so streaming, reconnect, and mid-turn
# behavior are visible by hand. A real agent is not this polite.
#
# Protocol: one JSON-RPC message per line on stdin/stdout. Never write anything but JSON to
# stdout - the bridge parses every line. Diagnostics go to stderr, which the bridge collects
# into its error tail.

set -u

log() {
    printf '%s\n' "fake-acp-agent: $1" 1>&2
}

# Emits one agent_message_chunk.
chunk() {
    text=$1
    printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' \
        "$session_id" "$text"
}

session_id="demo-session"
turn_count=0

log "started (pid $$)"

while IFS= read -r line; do
    # The request id, so responses correlate. Numeric only, and EMPTY means "not a request we
    # can answer" - emitting `"id":` with nothing after it would be malformed JSON, and one bad
    # line poisons the bridge's parse of this stream. (The pattern is greedy, so it takes the
    # LAST numeric id on the line. Safe here because the bridge sends exactly one and any "id"
    # inside prompt text arrives escaped as \"id\", which does not match.)
    request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

    # Every branch below answers a request, so a line with no usable id cannot be served.
    case "$line" in
    *'"method":"initialize"'*|*'"method":"session/new"'*|*'"method":"session/prompt"'*|*'"method":"session/set_config_option"'*)
        if [ -z "$request_id" ]; then
            log "ignoring a request with no numeric id"
            continue
        fi
        ;;
    esac

    case "$line" in
    *'"method":"initialize"'*)
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":false},"agentInfo":{"name":"fake-acp-agent","version":"1.0"},"authMethods":[]}}\n' \
            "$request_id"
        log "initialized"
        ;;

    *'"method":"session/new"'*)
        # A distinct id per session so two windows do not collide.
        session_id="demo-$(date -u +%H%M%S)-$$"
        printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"%s","configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"chat","options":[{"value":"chat","name":"Chat"},{"value":"build","name":"Build"}]}]}}\n' \
            "$request_id" "$session_id"
        log "new session $session_id"
        ;;

    *'"method":"session/prompt"'*)
        turn_count=$((turn_count + 1))
        log "turn $turn_count starting"

        # Reasoning first, folded behind the Thoughts disclosure in the UI.
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Working out what to say..."}}}}\n' \
            "$session_id"
        sleep 1

        for word in "Hello " "from " "the " "bridge. " "This " "reply " "is " "streaming " "one " "word " "at " "a " "time " "so " "you " "can " "watch " "it " "arrive."; do
            chunk "$word"
            sleep 1
        done

        # Every third turn, exercise the tool-call card and the permission gate. The interesting
        # paths need to be reachable by hand, not only from the test suite.
        if [ $((turn_count % 3)) -eq 0 ]; then
            printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"tool_call","toolCallId":"call-%s","title":"Edit README.md","kind":"edit","status":"pending"}}}\n' \
                "$session_id" "$turn_count"
            sleep 1
            # A wide, unambiguous id space: matching a bare "9<turn>" prefix would also match
            # id 93 on turn 3, or any bridge request numbered 9<turn>x.
            permission_id=$((900000 + turn_count))
            printf '{"jsonrpc":"2.0","id":%s,"method":"session/request_permission","params":{"sessionId":"%s","toolCall":{"toolCallId":"call-%s","title":"Edit README.md"},"options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"},{"optionId":"deny","name":"Reject","kind":"reject_once"}]}}\n' \
                "$permission_id" "$session_id" "$turn_count"

            # Park until the bridge relays an answer. The bridge always answers - a client
            # choice, another device's choice, or its own default-deny on timeout - and EOF
            # (the bridge going away) drops out of the loop rather than hanging.
            while IFS= read -r answer; do
                # The trailing comma keeps 900001 from matching 9000010.
                case "$answer" in
                *"\"id\":${permission_id},"*)
                    log "permission answered"
                    break
                    ;;
                esac
            done

            printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-%s","status":"completed","content":[{"type":"content","content":{"type":"text","text":"Edited 1 file."}}]}}}\n' \
                "$session_id" "$turn_count"
            sleep 1
        fi

        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"usage_update","used":%s,"size":128000}}}\n' \
            "$session_id" $((turn_count * 350))
        printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$request_id"
        log "turn $turn_count done"
        ;;

    *'"method":"session/cancel"'*)
        log "cancel received (this fake finishes its turn regardless)"
        ;;

    *'"method":"session/set_config_option"'*)
        printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$request_id"
        ;;
    esac
done

log "stdin closed; exiting"
