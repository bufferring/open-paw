#!/usr/bin/env bash

# ==============================================================================
# Open-Paw Installer v10.2.0
# One-liner: curl -fsSL https://raw.githubusercontent.com/bufferring/open-paw/master/install.sh | bash
# ==============================================================================

C_RESET='\e[0m'
C_GREEN='\e[32m'
C_CYAN='\e[36m'
C_YELLOW='\e[33m'
C_RED='\e[31m'
C_BLUE='\e[34m'
C_BOLD='\e[1m'
C_DIM='\e[2m'

REPO_URL="https://raw.githubusercontent.com/bufferring/open-paw/master/open-paw.sh"
INSTALL_DIR="$HOME/.agent_workspace/bin"
AGENTS_DIR="$HOME/.agent_workspace/agents"
AGENT_NAME="ai"
DEFAULT_MODEL="qwen2.5-coder:7b"

# ==============================================================================
# Helpers
# ==============================================================================

INSTALLER_VERSION="10.2.0"

print_header() {
  echo ""
  echo -e "${C_CYAN}${C_BOLD}  🐾 Open-Paw Installer v${INSTALLER_VERSION}${C_RESET}"
  echo -e "${C_DIM}  Local AI Swarm for Linux Terminals${C_RESET}"
  echo ""
}

# Extract version from an installed open-paw script
get_installed_version() {
  local script="$INSTALL_DIR/$AGENT_NAME"
  if [ -f "$script" ]; then
    grep -m1 '^OPEN_PAW_VERSION=' "$script" 2>/dev/null | cut -d'"' -f2
  fi
}

# Extract version from the source script (local repo or downloaded)
get_new_version() {
  local script="$1"
  if [ -f "$script" ]; then
    grep -m1 '^OPEN_PAW_VERSION=' "$script" 2>/dev/null | cut -d'"' -f2
  fi
}

check_deps() {
  local MISSING=""
  for dep in curl jq git bash; do
    if ! command -v "$dep" &> /dev/null; then
      MISSING+="$dep "
    fi
  done
  if [ -n "$MISSING" ]; then
    echo -e "${C_RED}  ✗ Missing dependencies: ${C_BOLD}$MISSING${C_RESET}"
    echo -e "${C_DIM}    Install with: sudo apt install $MISSING${C_RESET}"
    exit 1
  fi
  echo -e "${C_GREEN}  ✔ Dependencies OK${C_RESET} ${C_DIM}(curl, jq, git, bash)${C_RESET}"
}

check_ollama() {
  if command -v ollama &> /dev/null; then
    echo -e "${C_GREEN}  ✔ Ollama found${C_RESET} ${C_DIM}($(ollama --version 2>/dev/null | head -1))${C_RESET}"
    return 0
  else
    echo -e "${C_YELLOW}  ⚠ Ollama not found.${C_RESET}"
    echo -e "${C_DIM}    Install: curl -fsSL https://ollama.com/install.sh | sh${C_RESET}"
    return 1
  fi
}

# Returns list of locally available Ollama models, one per line
get_local_models() {
  ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$' || true
}

# ==============================================================================
# Actions
# ==============================================================================

do_install() {
  echo ""
  echo -e "${C_CYAN}${C_BOLD}── Installing Open-Paw ──────────────────────────${C_RESET}"
  echo ""

  check_deps

  local OLLAMA_OK=0
  check_ollama && OLLAMA_OK=1

  # --- Detect previous installation ---
  local INSTALLED_VER=""
  local IS_UPGRADE=false
  local CORE_FILE="$AGENTS_DIR/$AGENT_NAME/core.json"
  local SKILLS_FILE="$AGENTS_DIR/$AGENT_NAME/skills.json"
  local GLOBAL_SKILLS="$HOME/.agent_workspace/global_skills.json"

  if is_installed; then
    INSTALLED_VER=$(get_installed_version)
    IS_UPGRADE=true
    echo -e "${C_YELLOW}  ⚡ Existing installation detected: v${INSTALLED_VER:-unknown}${C_RESET}"

    # Preserve existing model from core.json
    local EXISTING_MODEL
    EXISTING_MODEL=$(jq -r '.model // empty' "$CORE_FILE" 2>/dev/null)
    if [ -n "$EXISTING_MODEL" ]; then
      echo -e "${C_DIM}    → Preserving model: $EXISTING_MODEL${C_RESET}"
    fi

    # Count learned skills
    local SKILL_COUNT
    SKILL_COUNT=$(jq 'length' "$SKILLS_FILE" 2>/dev/null || echo 0)
    if [ "$SKILL_COUNT" -gt 0 ]; then
      echo -e "${C_DIM}    → Preserving $SKILL_COUNT learned skills${C_RESET}"
    fi

    # Preserve spawned agents
    local AGENT_COUNT
    AGENT_COUNT=$(find "$AGENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "$AGENT_COUNT" -gt 1 ]; then
      echo -e "${C_DIM}    → Preserving $((AGENT_COUNT - 1)) spawned agent(s)${C_RESET}"
    fi

    echo ""
  fi

  # --- Pick model (only on fresh install) ---
  local SELECTED_MODEL="$DEFAULT_MODEL"
  if [ "$IS_UPGRADE" = true ] && [ -n "$EXISTING_MODEL" ]; then
    SELECTED_MODEL="$EXISTING_MODEL"
  elif [ "$OLLAMA_OK" -eq 1 ]; then
    local MODELS
    MODELS=$(get_local_models)
    if [ -n "$MODELS" ]; then
      echo ""
      echo -e "${C_CYAN}  Available local models:${C_RESET}"
      local i=1
      local MODEL_ARR=()
      while IFS= read -r m; do
        MODEL_ARR+=("$m")
        if [ "$m" = "$DEFAULT_MODEL" ]; then
          echo -e "    ${C_BOLD}[$i]${C_RESET} $m ${C_GREEN}(default)${C_RESET}"
        else
          echo -e "    ${C_DIM}[$i]${C_RESET} $m"
        fi
        ((i++))
      done <<< "$MODELS"
      echo ""
      echo -e "  ${C_DIM}Press Enter to use the default, or type a number:${C_RESET}"
      read -rp "  Model [1-${#MODEL_ARR[@]}]: " MODEL_CHOICE
      if [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]] && [ "$MODEL_CHOICE" -ge 1 ] && [ "$MODEL_CHOICE" -le "${#MODEL_ARR[@]}" ]; then
        SELECTED_MODEL="${MODEL_ARR[$((MODEL_CHOICE - 1))]}"
      else
        if printf '%s\n' "${MODEL_ARR[@]}" | grep -qx "$DEFAULT_MODEL"; then
          SELECTED_MODEL="$DEFAULT_MODEL"
        else
          SELECTED_MODEL="${MODEL_ARR[0]}"
        fi
      fi
    else
      echo -e "${C_YELLOW}  ⚠ No local models found. Using default: ${C_BOLD}$DEFAULT_MODEL${C_RESET}"
      echo -e "${C_DIM}    Pull one with: ollama pull $DEFAULT_MODEL${C_RESET}"
    fi
  fi

  echo ""
  echo -e "${C_CYAN}  [1/3]${C_RESET} Creating workspace..."
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$AGENTS_DIR/$AGENT_NAME"
  mkdir -p "$HOME/.agent_workspace/scripts"

  echo -e "${C_CYAN}  [2/3]${C_RESET} Downloading Open-Paw..."

  # Back up existing script before overwriting
  if [ "$IS_UPGRADE" = true ] && [ -f "$INSTALL_DIR/$AGENT_NAME" ]; then
    cp "$INSTALL_DIR/$AGENT_NAME" "$INSTALL_DIR/${AGENT_NAME}.bak"
    echo -e "${C_DIM}    → Backed up previous version to ${AGENT_NAME}.bak${C_RESET}"
  fi

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
  if [ -f "$SCRIPT_DIR/open-paw.sh" ]; then
    cp "$SCRIPT_DIR/open-paw.sh" "$INSTALL_DIR/$AGENT_NAME"
    echo -e "${C_DIM}    → Copied from local source${C_RESET}"
  else
    curl -fsSL "$REPO_URL" -o "$INSTALL_DIR/$AGENT_NAME"
    echo -e "${C_DIM}    → Downloaded from GitHub${C_RESET}"
  fi
  chmod +x "$INSTALL_DIR/$AGENT_NAME"

  # Show version transition
  local NEW_VER
  NEW_VER=$(get_installed_version)
  if [ "$IS_UPGRADE" = true ]; then
    echo -e "${C_DIM}    → Upgraded: v${INSTALLED_VER:-unknown} → v${NEW_VER:-unknown}${C_RESET}"
  else
    echo -e "${C_DIM}    → Installed: v${NEW_VER:-unknown}${C_RESET}"
  fi

  # --- Initialize config (preserve existing) ---
  if [ "$IS_UPGRADE" = true ]; then
    # Only update core.json if it doesn't exist (should never happen on upgrade)
    [ ! -f "$CORE_FILE" ] && echo "{\"model\": \"$SELECTED_MODEL\"}" > "$CORE_FILE"
    echo -e "${C_DIM}    → Config preserved (model: $SELECTED_MODEL)${C_RESET}"
  else
    echo "{\"model\": \"$SELECTED_MODEL\"}" > "$CORE_FILE"
    echo -e "${C_DIM}    → Model set to: ${C_BOLD}$SELECTED_MODEL${C_RESET}"
  fi

  [ ! -f "$SKILLS_FILE" ] && echo '[]' > "$SKILLS_FILE"
  [ ! -f "$GLOBAL_SKILLS" ] && echo '[]' > "$GLOBAL_SKILLS"

  # Init git repo if missing
  [ ! -d "$HOME/.agent_workspace/.git" ] && (cd "$HOME/.agent_workspace" && git init -q && git add -A && git commit -q -m "init" 2>/dev/null) || true

  echo -e "${C_CYAN}  [3/3]${C_RESET} Configuring PATH..."
  local PATH_LINE="export PATH=\"\$HOME/.agent_workspace/bin:\$PATH\""
  local SHELL_RC=""
  [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
  [ -z "$SHELL_RC" ] && [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"

  if [ -n "$SHELL_RC" ]; then
    if ! grep -q ".agent_workspace/bin" "$SHELL_RC" 2>/dev/null; then
      { echo ""; echo "# Open-Paw CLI"; echo "$PATH_LINE"; } >> "$SHELL_RC"
      echo -e "${C_DIM}    → Added to $SHELL_RC${C_RESET}"
    else
      echo -e "${C_DIM}    → Already in $SHELL_RC${C_RESET}"
    fi
  fi
  export PATH="$HOME/.agent_workspace/bin:$PATH"

  echo ""
  if [ "$IS_UPGRADE" = true ]; then
    echo -e "${C_GREEN}${C_BOLD}  ✅ Open-Paw upgraded! v${INSTALLED_VER:-?} → v${NEW_VER:-?} | Model: ${SELECTED_MODEL}${C_RESET}"
  else
    echo -e "${C_GREEN}${C_BOLD}  ✅ Open-Paw installed! v${NEW_VER:-?} | Model: ${SELECTED_MODEL}${C_RESET}"
  fi
  echo ""
  echo -e "  ${C_BOLD}Quick start:${C_RESET}"
  echo -e "    ${C_CYAN}ai what is my IP address${C_RESET}          ${C_DIM}(Quick Mode)${C_RESET}"
  echo -e "    ${C_CYAN}ai create a backup of /etc${C_RESET}        ${C_DIM}(Agent Mode)${C_RESET}"
  echo ""
  [ -n "$SHELL_RC" ] && echo -e "  ${C_DIM}Restart your terminal or run: source $SHELL_RC${C_RESET}"
  echo ""
}

do_uninstall() {
  echo ""
  echo -e "${C_RED}${C_BOLD}── Uninstalling Open-Paw ───────────────────────${C_RESET}"
  echo ""
  echo -e "  ${C_YELLOW}This will remove:${C_RESET}"
  echo -e "    ${C_DIM}• $INSTALL_DIR/$AGENT_NAME${C_RESET}"
  echo -e "    ${C_DIM}• $AGENTS_DIR/ (all agent configs)${C_RESET}"
  echo -e "    ${C_DIM}• PATH entry from shell rc${C_RESET}"
  echo ""
  read -rp "  Are you sure? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${C_DIM}  Cancelled.${C_RESET}"
    return
  fi

  # Remove binary
  rm -f "$INSTALL_DIR/$AGENT_NAME"
  echo -e "${C_DIM}  → Removed $INSTALL_DIR/$AGENT_NAME${C_RESET}"

  # Remove agent configs
  if [ -d "$AGENTS_DIR" ]; then
    rm -rf "$AGENTS_DIR"
    echo -e "${C_DIM}  → Removed $AGENTS_DIR/${C_RESET}"
  fi

  # Remove PATH lines from rc files
  for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$RC" ] && grep -q ".agent_workspace/bin" "$RC" 2>/dev/null; then
      sed -i '/# Open-Paw CLI/d' "$RC"
      sed -i '/agent_workspace\/bin/d' "$RC"
      echo -e "${C_DIM}  → Cleaned $RC${C_RESET}"
    fi
  done

  echo ""
  echo -e "${C_GREEN}  ✅ Open-Paw uninstalled.${C_RESET}"
  echo ""
}

do_list_models() {
  echo ""
  echo -e "${C_CYAN}${C_BOLD}── Ollama Models ────────────────────────────────${C_RESET}"
  echo ""

  if ! check_ollama; then
    echo ""
    return
  fi

  local MODELS
  MODELS=$(get_local_models)

  # Current model from core.json
  local CURRENT_MODEL=""
  local CORE_FILE="$AGENTS_DIR/$AGENT_NAME/core.json"
  if [ -f "$CORE_FILE" ]; then
    CURRENT_MODEL=$(jq -r '.model' "$CORE_FILE" 2>/dev/null || true)
  fi

  if [ -z "$MODELS" ]; then
    echo -e "${C_YELLOW}  No local models found.${C_RESET}"
    echo -e "${C_DIM}  Pull one with: ollama pull qwen2.5-coder:7b${C_RESET}"
    echo ""
    return
  fi

  echo -e "  ${C_DIM}Locally installed models:${C_RESET}"
  echo ""
  while IFS= read -r m; do
    if [ "$m" = "$CURRENT_MODEL" ]; then
      echo -e "    ${C_GREEN}▶ $m${C_RESET} ${C_DIM}(active)${C_RESET}"
    else
      echo -e "    ${C_DIM}◦${C_RESET} $m"
    fi
  done <<< "$MODELS"

  echo ""
}

do_change_model() {
  echo ""
  echo -e "${C_CYAN}${C_BOLD}── Change Active Model ──────────────────────────${C_RESET}"
  echo ""

  local CORE_FILE="$AGENTS_DIR/$AGENT_NAME/core.json"
  if [ ! -f "$CORE_FILE" ]; then
    echo -e "${C_RED}  ✗ Open-Paw is not installed. Run Install first.${C_RESET}"
    echo ""
    return
  fi

  local CURRENT_MODEL
  CURRENT_MODEL=$(jq -r '.model' "$CORE_FILE" 2>/dev/null || echo "unknown")
  echo -e "  Current model: ${C_BOLD}$CURRENT_MODEL${C_RESET}"
  echo ""

  if ! command -v ollama &> /dev/null; then
    echo -e "${C_YELLOW}  ⚠ Ollama not found. Cannot list models.${C_RESET}"
    echo ""
    return
  fi

  local MODELS
  MODELS=$(get_local_models)

  if [ -z "$MODELS" ]; then
    echo -e "${C_YELLOW}  No local models available.${C_RESET}"
    echo -e "${C_DIM}  Pull one with: ollama pull <model>${C_RESET}"
    echo ""
    return
  fi

  echo -e "  ${C_DIM}Select a model:${C_RESET}"
  local i=1
  local MODEL_ARR=()
  while IFS= read -r m; do
    MODEL_ARR+=("$m")
    if [ "$m" = "$CURRENT_MODEL" ]; then
      echo -e "    ${C_BOLD}[$i]${C_RESET} $m ${C_GREEN}(current)${C_RESET}"
    else
      echo -e "    ${C_DIM}[$i]${C_RESET} $m"
    fi
    ((i++))
  done <<< "$MODELS"

  echo ""
  read -rp "  Model [1-${#MODEL_ARR[@]}]: " MODEL_CHOICE
  if [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]] && [ "$MODEL_CHOICE" -ge 1 ] && [ "$MODEL_CHOICE" -le "${#MODEL_ARR[@]}" ]; then
    local NEW_MODEL="${MODEL_ARR[$((MODEL_CHOICE - 1))]}"
    echo "{\"model\": \"$NEW_MODEL\"}" > "$CORE_FILE"
    echo ""
    echo -e "${C_GREEN}  ✅ Model changed to: ${C_BOLD}$NEW_MODEL${C_RESET}"
  else
    echo -e "${C_DIM}  No change.${C_RESET}"
  fi
  echo ""
}

# ==============================================================================
# Detect installation state
# ==============================================================================

is_installed() {
  [ -f "$INSTALL_DIR/$AGENT_NAME" ] && [ -f "$AGENTS_DIR/$AGENT_NAME/core.json" ]
}

# ==============================================================================
# Main Menu
# ==============================================================================

print_header

# If running non-interactively (piped), just install directly
if [ ! -t 0 ]; then
  do_install
  exit 0
fi

while true; do
  if is_installed; then
    CURRENT_MODEL=$(jq -r '.model' "$AGENTS_DIR/$AGENT_NAME/core.json" 2>/dev/null || echo "unknown")
    INSTALLED_VER=$(get_installed_version)
    echo -e "${C_GREEN}  ✔ Open-Paw v${INSTALLED_VER:-?} installed${C_RESET} ${C_DIM}(model: $CURRENT_MODEL)${C_RESET}"
  else
    echo -e "${C_YELLOW}  ◦ Open-Paw is not installed${C_RESET}"
  fi
  echo ""
  echo -e "${C_CYAN}${C_BOLD}  What would you like to do?${C_RESET}"
  echo ""

  if is_installed; then
    echo -e "    ${C_BOLD}[1]${C_RESET} Upgrade / Reinstall"
    echo -e "    ${C_BOLD}[2]${C_RESET} List available models"
    echo -e "    ${C_BOLD}[3]${C_RESET} Change active model"
    echo -e "    ${C_BOLD}[4]${C_RESET} Uninstall Open-Paw"
    echo -e "    ${C_DIM}[q]${C_RESET} Quit"
    echo ""
    read -rp "  Choice: " CHOICE
    case "$CHOICE" in
      1) do_install ;;
      2) do_list_models ;;
      3) do_change_model ;;
      4) do_uninstall ;;
      q|Q) echo ""; echo -e "${C_DIM}  Bye!${C_RESET}"; echo ""; exit 0 ;;
      *) echo -e "\n${C_DIM}  Invalid option.${C_RESET}\n" ;;
    esac
  else
    echo -e "    ${C_BOLD}[1]${C_RESET} Install Open-Paw"
    echo -e "    ${C_BOLD}[2]${C_RESET} List available models"
    echo -e "    ${C_DIM}[q]${C_RESET} Quit"
    echo ""
    read -rp "  Choice: " CHOICE
    case "$CHOICE" in
      1) do_install ;;
      2) do_list_models ;;
      q|Q) echo ""; echo -e "${C_DIM}  Bye!${C_RESET}"; echo ""; exit 0 ;;
      *) echo -e "\n${C_DIM}  Invalid option.${C_RESET}\n" ;;
    esac
  fi
done
