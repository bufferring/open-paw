#!/usr/bin/env bash
OPEN_PAW_VERSION="10.2.0"

# ==============================================================================
# Open-Paw v10.2 - Intelligence Edition
# Features: Streaming, Auto-Learn, Smart Pruning, Dual-Mode, Swarm
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. VISUALS & CONFIGURATION
# ------------------------------------------------------------------------------
C_RESET='\e[0m'
C_BLUE='\e[34m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_CYAN='\e[36m'
C_MAGENTA='\e[35m'
C_RED='\e[31m'
C_BOLD='\e[1m'
C_DIM='\e[2m'

OLLAMA_API="http://localhost:11434"
INVOKED_NAME=$(basename "$0")
MY_REAL_PATH=$(realpath "$0")

# Workspace Architecture
WORKSPACE="$HOME/.agent_workspace"
SWARM_DIR="$WORKSPACE/agents"
SWARM_BIN="$WORKSPACE/bin"
MY_DIR="$SWARM_DIR/$INVOKED_NAME"
SCRIPTS_DIR="$WORKSPACE/scripts"

# Files
CORE_FILE="$MY_DIR/core.json"
LOCAL_SKILLS="$MY_DIR/skills.json"
GLOBAL_SKILLS="$WORKSPACE/global_skills.json"
AUDIT_LOG="$WORKSPACE/audit.log"
SESSION_FILE="/tmp/${INVOKED_NAME}_session.json"

# Performance Tuning
MAX_LOOPS=10
API_TIMEOUT=90
CMD_TIMEOUT=60
QUICK_TOKENS=512
AGENT_TOKENS=1024
MAX_OBS_CHARS=4000
KEEP_ALIVE="30m"
QUICK_TEMP=0.3
AGENT_TEMP=0

# Action verbs that trigger the full agent loop
# Stems + full forms: grep -Ei matches substrings so "creat" catches create/creating/created
ACTION_VERBS="execute|run|launch|open|start|stop|kill|restart|creat|delet|install|uninstall|writ|read|find|search|mov|copy|renam|list|make|build|deploy|updat|upgrad|downgrad|schedul|remov|monitor|download|upload|edit|modif|chang|add|set|configur|check|scan|analyz|debug|fix|patch|pull|push|commit|clon|spawn|delegat|assign|show|display|print|cat|echo|clear|test|mount|umount|unmount|ping|ssh|grep|sort|backup|restor|encrypt|decrypt|shutdown|reboot|poweroff|enabl|disabl|generat|convert|connect|disconnect|clean|purge|link|unlink|compress|extract|setup|clos|verif|validat|format|partition|sync|zip|unzip|tar|chmod|chown|curl|wget|apt|dnf|yum|pacman|snap|brew|pip|npm|docker|systemctl|journalctl|mkdi|rmdi|touch|head|tail|tee|awk|sed|wc|diff|rsync|scp|ftp|netstat|ifconfig|iptable|ufw|crontab|service|init|boot|login|logout|passwd|useradd|userdel|groupadd|chroot|lsblk|fdisk|mkfs|fsck|dd|losetup|swapoff|swapon|free|htop|top|ps|pgrep|pkill|nohup|screen|tmux|watch|xargs|locate|whereis|which|file|stat|du|df"

# ------------------------------------------------------------------------------
# 2. BOOTSTRAP & DEPENDENCY CHECK
# ------------------------------------------------------------------------------
for dep in curl jq date realpath git; do
  if ! command -v "$dep" &> /dev/null; then
    echo -e "${C_RED}CRITICAL: Required dependency '$dep' missing.${C_RESET}"
    exit 1
  fi
done

# Build workspace structure
mkdir -p "$MY_DIR" "$SCRIPTS_DIR" "$SWARM_BIN"

if [ ! -f "$CORE_FILE" ]; then echo '{"model": "qwen2.5-coder:7b"}' > "$CORE_FILE"; fi
if [ ! -f "$LOCAL_SKILLS" ]; then echo '[]' > "$LOCAL_SKILLS"; fi
if [ ! -f "$GLOBAL_SKILLS" ]; then echo '[]' > "$GLOBAL_SKILLS"; fi

# Auto-initialize Git for rollbacks
if [ ! -d "$WORKSPACE/.git" ]; then
  cd "$WORKSPACE" && git init -q && git commit -q --allow-empty -m "Swarm Initialized"
fi

MODEL=$(jq -r '.model' "$CORE_FILE")

# ------------------------------------------------------------------------------
# 3. OLLAMA HEALTH CHECK
# ------------------------------------------------------------------------------
if ! curl -sf --max-time 5 "$OLLAMA_API/api/tags" > /dev/null 2>&1; then
  echo -e "${C_RED}ERROR: Ollama is not running at $OLLAMA_API${C_RESET}"
  echo -e "${C_DIM}Start it with: ollama serve${C_RESET}"
  exit 1
fi

# ------------------------------------------------------------------------------
# 4. AUDIT LOGGING
# ------------------------------------------------------------------------------
log_audit() {
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\": \"$ts\", \"agent\": \"$INVOKED_NAME\", \"event\": \"$1\", \"details\": $(echo "$2" | jq -R -s '.')}" >> "$AUDIT_LOG"
}

# ------------------------------------------------------------------------------
# 5. DETECT EXECUTION MODE
# ------------------------------------------------------------------------------
# --resume: restore previous session
# --quick:  force one-shot Q&A mode
# (auto):   detect based on query content

FORCE_QUICK=false
FORCE_AGENT=false

if [ "$1" == "--resume" ]; then
  EXEC_MODE="agent"
  if [ -f "$SESSION_FILE" ]; then
    MESSAGES=$(cat "$SESSION_FILE")
    echo -e "${C_BLUE}▶ Session Resumed [Agent: $INVOKED_NAME]${C_RESET}\n"
  else
    echo -e "${C_RED}No active session found for $INVOKED_NAME.${C_RESET}"
    exit 1
  fi
elif [ "$1" == "--quick" ]; then
  shift
  FORCE_QUICK=true
  TASK="$*"
elif [ "$1" == "--agent" ]; then
  shift
  FORCE_AGENT=true
  TASK="$*"
elif [ $# -eq 0 ]; then
  echo -e "${C_YELLOW}Usage:${C_RESET} $INVOKED_NAME <task> | --resume | --quick <question> | --agent <task>"
  exit 1
else
  TASK="$*"
fi

# Auto-detect mode for new tasks (not --resume)
if [ -n "$TASK" ]; then
  log_audit "SESSION_START" "$TASK"
  TASK_LOWER=$(echo "$TASK" | tr '[:upper:]' '[:lower:]')

  if [ "$FORCE_AGENT" = true ]; then
    EXEC_MODE="agent"
  elif [ "$FORCE_QUICK" = true ] || ! echo "$TASK_LOWER" | grep -qEi "$ACTION_VERBS"; then
    EXEC_MODE="quick"
  else
    EXEC_MODE="agent"
  fi
fi

# ==============================================================================
# MODE A: QUICK ONE-SHOT (Q&A, Explanations, Knowledge)
# ==============================================================================
if [ "$EXEC_MODE" == "quick" ]; then
  SYS_OS=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  QUICK_CTX="OS: ${SYS_OS:-Linux} | Dir: $(pwd) | Shell: $SHELL"

  echo -e "${C_BLUE}▶ ${C_BOLD}$INVOKED_NAME${C_RESET}${C_BLUE} | Quick Mode | $MODEL${C_RESET}\n"

  # Build JSON payload safely via jq (handles special chars in TASK)
  QUICK_PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "You are a concise Linux CLI assistant. Context: $QUICK_CTX\nAnswer directly and briefly.\n\nUser: $TASK" \
    --arg keep "$KEEP_ALIVE" \
    --argjson tokens "$QUICK_TOKENS" \
    --argjson temp "$QUICK_TEMP" \
    '{model: $model, prompt: $prompt, stream: true, keep_alive: $keep, options: {num_predict: $tokens, temperature: $temp}}')

  # Stream tokens to terminal in real-time (-N = no-buffer)
  FULL_RESPONSE=""
  while IFS= read -r line; do
    TOKEN=$(echo "$line" | jq -r '.response // empty' 2>/dev/null)
    DONE_FLAG=$(echo "$line" | jq -r '.done // false' 2>/dev/null)
    if [ -n "$TOKEN" ]; then
      printf '%s' "$TOKEN"
      FULL_RESPONSE+="$TOKEN"
    fi
    if [ "$DONE_FLAG" = "true" ]; then
      EVAL_TOKENS=$(echo "$line" | jq -r '.eval_count // 0')
      break
    fi
  done < <(curl -sN --max-time $API_TIMEOUT "$OLLAMA_API/api/generate" -d "$QUICK_PAYLOAD" 2>/dev/null)

  if [ -z "$FULL_RESPONSE" ]; then
    echo -e "${C_RED}No response from model.${C_RESET}"
    exit 1
  fi

  echo -e "\n\n${C_DIM}${C_CYAN}[Tokens: ${EVAL_TOKENS:-0} | Mode: Quick]${C_RESET}"
  log_audit "QUICK_COMPLETE" "$FULL_RESPONSE"
  exit 0
fi

# ==============================================================================
# MODE B: FULL AGENT LOOP (ReAct Execution)
# ==============================================================================

# --- Build context only for new sessions (not --resume) ---
if [ -z "$MESSAGES" ]; then
  SYS_OS=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  TELEMETRY="OS: ${SYS_OS:-Linux} | Dir: $(pwd) | UTC: $(date -u +"%H:%M:%S") | User: $(whoami)"

  # #6: Snapshot current directory for context
  DIR_LISTING=$(ls -1A 2>/dev/null | head -n 30)
  [ -n "$DIR_LISTING" ] && DIR_CTX="\n[CWD Contents]\n$DIR_LISTING" || DIR_CTX=""

  # #10: Detect installed tools so model doesn't suggest unavailable commands
  TOOLS_AVAILABLE=""
  for tool in python3 python node npm pip docker docker-compose gcc make cmake go rust cargo java mvn ruby gem php composer nginx apache2 mysql psql redis-cli mongosh sqlite3 ffmpeg convert pandoc; do
    command -v "$tool" &>/dev/null && TOOLS_AVAILABLE+="$tool "
  done
  [ -n "$TOOLS_AVAILABLE" ] && TOOLS_CTX="\n[Available Tools] $TOOLS_AVAILABLE" || TOOLS_CTX=""

  # Base system prompt — short and direct for small models
  SYSTEM_PROMPT="You are '$INVOKED_NAME', a Linux CLI agent. Model: $MODEL.
State: $TELEMETRY

RULES:
1. You MUST respond with JSON: {\"thought\": \"...\", \"command\": \"...\", \"done\": true/false, \"summary\": \"...\"}
2. You MUST ALWAYS provide a bash command in the \"command\" field. NEVER leave it empty.
3. Commands MUST be a single line. No literal newlines in commands. Use ; or && to chain.
4. Set \"done\": false until the task is fully completed.
5. Only set \"done\": true AFTER commands have been executed and the task is finished.
6. If a command ran and the result answers the question (including \"not found\"), set \"done\": true with a summary.
7. Do NOT explain or converse. Act by proposing commands.
8. NEVER repeat the same command. If it failed or returned nothing, try a different approach or report the result.
9. Only use tools/commands that are installed on the system.

Example:
{\"thought\": \"I need to create test.txt\", \"command\": \"touch ~/Desktop/test.txt\", \"done\": false, \"summary\": \"\"}$DIR_CTX$TOOLS_CTX"

  # Inject swarm rules only when delegation/agent keywords detected
  if echo "$TASK_LOWER" | grep -qEw "agent|create.*agent|delegate|assign|spawn|swarm"; then
    SYSTEM_PROMPT+="
[SWARM]
- See siblings: ls $SWARM_DIR
- Create agent X with model Y: mkdir -p $SWARM_DIR/X && echo '{\"model\": \"Y\"}' > $SWARM_DIR/X/core.json && echo '[]' > $SWARM_DIR/X/skills.json && ln -sf $MY_REAL_PATH $SWARM_BIN/X
- NEVER auto-delegate. Only when explicitly asked."
  fi

  # Merge skills — only include if non-empty
  GLOBAL_DUMP=$(cat "$GLOBAL_SKILLS")
  LOCAL_DUMP=$(cat "$LOCAL_SKILLS")
  SKILLS_CONTEXT=""
  [ "$GLOBAL_DUMP" != "[]" ] && SKILLS_CONTEXT+="\n[GLOBAL SKILLS]\n$GLOBAL_DUMP"
  [ "$LOCAL_DUMP" != "[]" ] && SKILLS_CONTEXT+="\n[LOCAL SKILLS]\n$LOCAL_DUMP"

  MESSAGES=$(jq -n --arg sp "$SYSTEM_PROMPT$SKILLS_CONTEXT" --arg tk "$TASK" \
    '[{"role": "system", "content": $sp}, {"role": "user", "content": $tk}]')

  echo -e "${C_BLUE}▶ ${C_BOLD}$INVOKED_NAME${C_RESET}${C_BLUE} | Agent Mode | $MODEL${C_RESET}\n"
fi

# --- The Execution Loop ---
LOOP_COUNT=0
COMMANDS_RAN=0
LAST_CMD=""
PARSE_FAILS=0
CMDS_LOG=""

while true; do
  ((LOOP_COUNT++))

  # Loop Guard
  if [ $LOOP_COUNT -gt $MAX_LOOPS ]; then
    echo -e "${C_RED}[Loop Guard] Max iterations ($MAX_LOOPS) reached. Exiting.${C_RESET}"
    log_audit "LOOP_GUARD" "Exited after $MAX_LOOPS iterations"
    break
  fi

  echo -e "${C_MAGENTA}[$INVOKED_NAME is processing... (${LOOP_COUNT}/${MAX_LOOPS})]${C_RESET}"

  # API Call with proper JSON closure and token budget
  API_RESPONSE=$(curl -s --max-time $API_TIMEOUT "$OLLAMA_API/api/chat" -d "{
    \"model\": \"$MODEL\",
    \"messages\": $MESSAGES,
    \"stream\": false,
    \"keep_alive\": \"$KEEP_ALIVE\",
    \"options\": { \"num_predict\": $AGENT_TOKENS, \"temperature\": $AGENT_TEMP, \"top_p\": 0.9 },
    \"format\": {
      \"type\": \"object\",
      \"properties\": {
        \"thought\": {\"type\": \"string\"},
        \"command\": {\"type\": \"string\"},
        \"done\": {\"type\": \"boolean\"},
        \"summary\": {\"type\": \"string\"}
      },
      \"required\": [\"thought\", \"command\", \"done\"]
    }
  }")

  # Parse response
  JSON_PAYLOAD=$(echo "$API_RESPONSE" | jq -e '.message.content | fromjson' 2>/dev/null)
  PARSE_OK=$?
  PROMPT_TOKENS=$(echo "$API_RESPONSE" | jq -r '.prompt_eval_count // 0')
  EVAL_TOKENS=$(echo "$API_RESPONSE" | jq -r '.eval_count // 0')

  if [ $PARSE_OK -ne 0 ]; then
    ((PARSE_FAILS++))
    echo -e "${C_RED}[Error] Invalid response from model (attempt $LOOP_COUNT, fails: $PARSE_FAILS).${C_RESET}"
    if [ $PARSE_FAILS -ge 2 ]; then
      # Trim last 2 messages (the observation that likely confused the model) and retry
      echo -e "${C_YELLOW}[Recovery] Trimming context to recover...${C_RESET}"
      MESSAGES=$(echo "$MESSAGES" | jq 'if length > 4 then .[0:2] + .[2:-2] else . end')
      PARSE_FAILS=0
    else
      MESSAGES=$(echo "$MESSAGES" | jq --arg obs "OBSERVATION: Your last response was not valid JSON. Respond ONLY with: {\"thought\": \"...\", \"command\": \"...\", \"done\": false, \"summary\": \"\"}" \
        '. + [{"role": "user", "content": $obs}]')
    fi
    continue
  fi
  PARSE_FAILS=0

  THOUGHT=$(echo "$JSON_PAYLOAD" | jq -r '.thought // empty')
  CMD=$(echo "$JSON_PAYLOAD" | jq -r '.command // empty')
  IS_DONE=$(echo "$JSON_PAYLOAD" | jq -r '.done')
  SUMMARY=$(echo "$JSON_PAYLOAD" | jq -r '.summary // empty')

  # Sanitize CMD: collapse newlines to semicolons so commands stay single-line
  CMD=$(echo "$CMD" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  # Display reasoning
  echo -e "${C_DIM}${C_MAGENTA}$THOUGHT${C_RESET}"
  echo -e "${C_DIM}${C_CYAN}└─ [Tokens: In=$PROMPT_TOKENS Out=$EVAL_TOKENS | Loop ${LOOP_COUNT}/${MAX_LOOPS}]${C_RESET}\n"

  # --- Task Complete ---
  if [ "$IS_DONE" == "true" ]; then
    # Structural guard: block premature completion if no command was ever run
    if [ $COMMANDS_RAN -eq 0 ] && [ $LOOP_COUNT -lt $MAX_LOOPS ]; then
      OUTPUT="OBSERVATION: You cannot mark done=true without executing a command first. Provide a bash command. Example: {\"thought\": \"I will create the file\", \"command\": \"touch ~/Desktop/test.txt\", \"done\": false, \"summary\": \"\"}"
      MESSAGES=$(echo "$MESSAGES" | jq --arg ai "$JSON_PAYLOAD" --arg obs "$OUTPUT" \
        '. + [{"role": "assistant", "content": $ai}, {"role": "user", "content": $obs}]')
      echo -e "${C_YELLOW}[Guard] No command executed yet — pushing back.${C_RESET}\n"
      continue
    fi
    echo -e "${C_GREEN}${C_BOLD}[Task Complete]${C_RESET}\n$SUMMARY\n"
    log_audit "SESSION_COMPLETE" "$SUMMARY"

    # #7: Auto-learn — save successful task pattern to skills.json
    if [ $COMMANDS_RAN -gt 0 ] && [ -n "$CMDS_LOG" ]; then
      SKILL_ENTRY=$(jq -n --arg task "$TASK" --arg cmds "$CMDS_LOG" --arg summary "$SUMMARY" \
        '{task: $task, commands: $cmds, summary: $summary}')
      # Append only if not a duplicate task
      if ! jq -e --arg task "$TASK" '.[] | select(.task == $task)' "$LOCAL_SKILLS" &>/dev/null; then
        jq --argjson entry "$SKILL_ENTRY" '. + [$entry]' "$LOCAL_SKILLS" > "${LOCAL_SKILLS}.tmp" && mv "${LOCAL_SKILLS}.tmp" "$LOCAL_SKILLS"
        echo -e "${C_DIM}${C_CYAN}[Learned] Saved task pattern to skills.json${C_RESET}"
      fi
    fi

    # #14: Batch git commit at session end instead of per-command
    (cd "$WORKSPACE" && git add -A && git diff-index --quiet HEAD || git commit -q -m "$INVOKED_NAME: $TASK") &

    rm -f "$SESSION_FILE"
    break
  fi

  # --- Command Execution ---
  if [ -n "$CMD" ]; then
    # Detect repeated commands — break the loop
    if [ "$CMD" = "$LAST_CMD" ]; then
      echo -e "${C_YELLOW}[Guard] Duplicate command detected — forcing new approach.${C_RESET}\n"
      OUTPUT="DUPLICATE COMMAND REJECTED: You already ran this exact command. Try a completely different approach or report your findings with done=true."
      MESSAGES=$(echo "$MESSAGES" | jq --arg ai "$JSON_PAYLOAD" --arg obs "OBSERVATION: $OUTPUT" \
        '. + [{"role": "assistant", "content": $ai}, {"role": "user", "content": $obs}]')
      continue
    fi
    LAST_CMD="$CMD"

    echo -e "${C_YELLOW}[Action Required]${C_RESET} Execute: ${C_BOLD}$CMD${C_RESET}"
    read -r -p "▶ Run this? [Y/n/e]: " ANS

    SUDO_OK=true
    RUN_CMD="$CMD"

    case "${ANS,,}" in
      n|no)
        OUTPUT="Command rejected by user."
        SUDO_OK=false
        echo -e "${C_RED}✗ Skipped.${C_RESET}"
        ;;
      e|edit)
        read -e -p "Edit: " -i "$CMD" EDITED_CMD
        RUN_CMD="$EDITED_CMD"
        CMD="$RUN_CMD"
        ;;
    esac

    # Pre-authenticate sudo so password prompt doesn't bleed into output capture
    if [ "$SUDO_OK" = true ] && echo "$RUN_CMD" | grep -q 'sudo'; then
      echo -e "${C_CYAN}[sudo] Pre-authenticating...${C_RESET}"
      if ! sudo -v 2>/dev/null; then
        OUTPUT="SUDO FAILED: Authentication failed or user is not in sudoers. Suggest a command that does not require root, or ask the user for help."
        SUDO_OK=false
        echo -e "${C_RED}✗ sudo authentication failed.${C_RESET}"
      fi
    fi

    # Execute the command
    if [ "$SUDO_OK" = true ]; then
      OUTPUT=$(timeout $CMD_TIMEOUT bash -c "$RUN_CMD" 2>&1 | head -c $MAX_OBS_CHARS)
      EXIT_CODE=$?

      if [ -z "$OUTPUT" ]; then
        OUTPUT="[Command completed. No output. Exit code: $EXIT_CODE. If this was a search, it means no matches were found.]"
      fi

      # Sanitize output: replace control chars and limit line count to prevent context corruption
      OUTPUT=$(echo "$OUTPUT" | tr -d '\000-\010\016-\037' | head -n 50)

      # Detect permission errors in output and annotate for the model
      if echo "$OUTPUT" | grep -qiE "permission denied|operation not permitted|access denied"; then
        OUTPUT+=$'\n'"[NOTE: Some results had permission errors. Consider using sudo or narrowing the search scope to avoid restricted paths.]"
      fi

      # Detect timeout
      if [ $EXIT_CODE -eq 124 ]; then
        OUTPUT+=$'\n'"[NOTE: Command timed out after ${CMD_TIMEOUT}s. Consider a more targeted approach.]"
      fi
    fi

    echo -e "${C_CYAN}↳ $(echo "$OUTPUT" | head -n 3 | tr '\n' ' ')${C_RESET}\n"

    ((COMMANDS_RAN++))
    CMDS_LOG+="$CMD; "
  else
    OUTPUT="You must provide a bash command. Example: {\"thought\": \"I need to do X\", \"command\": \"actual_bash_command_here\", \"done\": false, \"summary\": \"\"}"
  fi

  # --- Update State & Prune Context (#8 + #13: single jq call) ---
  MESSAGES=$(echo "$MESSAGES" | jq --arg ai "$JSON_PAYLOAD" --arg obs "OBSERVATION: $OUTPUT" \
    '(. + [{"role": "assistant", "content": $ai}, {"role": "user", "content": $obs}]) | if length > 14 then .[0:2] + .[-8:] else . end')
  echo "$MESSAGES" > "$SESSION_FILE"
done