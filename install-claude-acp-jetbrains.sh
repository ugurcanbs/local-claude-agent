#!/usr/bin/env bash
#
# Installs and registers the Claude Agent SDK ACP agent
# (https://github.com/agentclientprotocol/claude-agent-acp) as a custom
# agent in JetBrains IDEs (2025.3+) via the Agent Client Protocol (ACP).
#
# Usage:
#   ./install-claude-acp-jetbrains.sh
#
# What it does:
#   1. Checks/installs Node.js >= 22 (required by the package).
#   2. Installs the pinned version of @agentclientprotocol/claude-agent-acp
#      globally via npm (override with CLAUDE_AGENT_ACP_VERSION=<version>), then
#      applies the local fixes stored in patches/claude-agent-acp/<version>/.
#   3. Checks for the Claude Code CLI (used for auth) and offers to install it.
#   4. Registers the agent in ~/.jetbrains/acp.json, merging with any
#      existing agents already configured there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="@agentclientprotocol/claude-agent-acp"
# The version the patches in patches/claude-agent-acp/ were made and tested against.
PINNED_VERSION="0.90.0"
AGENT_VERSION="${CLAUDE_AGENT_ACP_VERSION:-${PINNED_VERSION}}"
PATCH_ROOT="${SCRIPT_DIR}/patches/claude-agent-acp"
BIN_NAME="claude-agent-acp"
AGENT_DISPLAY_NAME="Claude Agent (ACP)"
MIN_NODE_MAJOR=22
CONFIG_DIR="${HOME}/.jetbrains"
CONFIG_FILE="${CONFIG_DIR}/acp.json"

c_reset="\033[0m"; c_green="\033[32m"; c_yellow="\033[33m"; c_red="\033[31m"; c_blue="\033[34m"

info()  { printf "${c_blue}==>${c_reset} %s\n" "$1"; }
ok()    { printf "${c_green}✔${c_reset} %s\n" "$1"; }
warn()  { printf "${c_yellow}⚠${c_reset} %s\n" "$1"; }
fail()  { printf "${c_red}✘ %s${c_reset}\n" "$1"; exit 1; }

OS="$(uname -s)"

# ---------------------------------------------------------------------------
# 1. Node.js
# ---------------------------------------------------------------------------

node_major_version() {
  node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0
}

install_node() {
  info "Node.js >= ${MIN_NODE_MAJOR} is required but was not found (or is too old). Attempting to install it."
  if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    info "Installing Node.js via Homebrew..."
    brew install node
  elif [[ "$OS" == "Linux" ]] && command -v apt-get >/dev/null 2>&1; then
    info "Installing Node.js ${MIN_NODE_MAJOR}.x via NodeSource + apt..."
    curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE_MAJOR}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v nvm >/dev/null 2>&1; then
    info "Installing Node.js via nvm..."
    nvm install "${MIN_NODE_MAJOR}"
    nvm use "${MIN_NODE_MAJOR}"
  else
    fail "Could not auto-install Node.js (no Homebrew, apt, or nvm found). Install Node.js ${MIN_NODE_MAJOR}+ manually from https://nodejs.org and re-run this script."
  fi
}

info "Checking Node.js..."
if ! command -v node >/dev/null 2>&1; then
  install_node
fi

if [[ "$(node_major_version)" -lt "$MIN_NODE_MAJOR" ]]; then
  warn "Found Node.js $(node -v), but ${BIN_NAME} requires Node.js >= ${MIN_NODE_MAJOR}."
  install_node
fi

command -v node >/dev/null 2>&1 || fail "Node.js installation failed."
[[ "$(node_major_version)" -ge "$MIN_NODE_MAJOR" ]] || fail "Node.js $(node -v) is still older than required (>= ${MIN_NODE_MAJOR}). Please upgrade manually and re-run."
ok "Node.js $(node -v) OK"

command -v npm >/dev/null 2>&1 || fail "npm was not found even though Node.js is installed. Please check your Node.js installation."
ok "npm $(npm -v) OK"

# ---------------------------------------------------------------------------
# 2. Install the ACP agent package
# ---------------------------------------------------------------------------

info "Installing ${PACKAGE}@${AGENT_VERSION} globally via npm..."
if ! npm install -g "${PACKAGE}@${AGENT_VERSION}"; then
  warn "Global npm install failed (this is often a permissions issue with a system Node.js install)."
  warn "Retrying with sudo..."
  sudo npm install -g "${PACKAGE}@${AGENT_VERSION}" || fail "Failed to install ${PACKAGE}@${AGENT_VERSION}. Consider using nvm to manage Node.js so global installs don't need sudo."
fi
ok "${PACKAGE}@${AGENT_VERSION} installed"

# ---------------------------------------------------------------------------
# 2b. Apply local patches to the installed package
# ---------------------------------------------------------------------------
# Patches live in patches/claude-agent-acp/<version>/ and are made against that
# exact published version. A version with no folder of its own gets the pinned
# version's patches: applying them is an unexpected success (warning, check the
# result), failing to apply them is an error, since the bugs they fix may still
# be there.

apply_patches() {
  local pkg_dir="$1" installed_version="$2" patch_dir source_version patches run=() opts=(-p1 -F0 -s -f)
  if [[ -d "${PATCH_ROOT}/${installed_version}" ]]; then
    source_version="${installed_version}"
  else
    source_version="${PINNED_VERSION}"
    warn "No patches recorded for ${installed_version}; trying those made for ${source_version}."
  fi
  patch_dir="${PATCH_ROOT}/${source_version}"
  # A missing folder is not "nothing to patch": only an existing folder without
  # a .patch file records that a version needs no fix.
  [[ -d "${patch_dir}" ]] || fail "Patch folder ${patch_dir} is missing; run this script from a full checkout of the repository."
  shopt -s nullglob
  patches=("${patch_dir}"/*.patch)
  shopt -u nullglob
  if [[ "${#patches[@]}" -eq 0 ]]; then
    ok "No patches to apply for ${installed_version}"
    return
  fi
  command -v patch >/dev/null 2>&1 || fail "The 'patch' command is required to apply ${patch_dir}/*.patch."
  [[ -w "${pkg_dir}/dist" ]] || run=(sudo)
  # GNU patch leaves a .orig backup when a hunk applies at an offset; BSD patch
  # only backs up when asked to.
  if patch --version 2>/dev/null | grep -q 'GNU patch'; then
    opts+=(--no-backup-if-mismatch)
  fi
  local p name
  for p in "${patches[@]}"; do
    name="$(basename "$p")"
    if patch "${opts[@]}" -d "${pkg_dir}" -R --dry-run <"$p" >/dev/null 2>&1; then
      if [[ "${source_version}" == "${installed_version}" ]]; then
        ok "Patch ${name} already applied"
      else
        warn "Patch ${name}, made for ${source_version}, is already present in ${installed_version}: check whether upstream shipped the fix."
      fi
    elif patch "${opts[@]}" -d "${pkg_dir}" --dry-run <"$p" >/dev/null 2>&1; then
      ${run[@]+"${run[@]}"} patch "${opts[@]}" -d "${pkg_dir}" <"$p" || fail "Patch ${name} passed its dry run but failed to apply to ${pkg_dir}."
      if [[ "${source_version}" == "${installed_version}" ]]; then
        ok "Applied patch ${name}"
      else
        warn "Applied patch ${name}, made for ${source_version}, to ${installed_version}: unexpected success, check the fix is still needed and correct."
      fi
    else
      fail "Patch ${name} (made for ${source_version}) does not apply to ${PACKAGE} ${installed_version} in ${pkg_dir}. Its fix may be missing: update the patch, or, if upstream fixed it, create ${PATCH_ROOT}/${installed_version}/ holding a README and no .patch file."
    fi
  done
  # A hunk can apply in the wrong place and still report success: prove the
  # result loads and that each fix behaves, before the IDE launches it.
  node --check "${pkg_dir}/dist/acp-agent.js" || fail "The patched ${pkg_dir}/dist/acp-agent.js no longer parses."
  local check
  for check in "${patch_dir}"/*.check.mjs; do
    [[ -f "${check}" ]] || continue
    node "${check}" "${pkg_dir}" || fail "Check $(basename "${check}") failed against ${pkg_dir}: the patched agent does not behave as the patch intends."
  done
}

AGENT_PATH="$(command -v "${BIN_NAME}" 2>/dev/null || true)"
if [[ -z "${AGENT_PATH}" ]]; then
  NPM_GLOBAL_BIN="$(npm prefix -g)/bin"
  if [[ -x "${NPM_GLOBAL_BIN}/${BIN_NAME}" ]]; then
    AGENT_PATH="${NPM_GLOBAL_BIN}/${BIN_NAME}"
  fi
fi
[[ -n "${AGENT_PATH}" ]] || fail "Could not locate the installed '${BIN_NAME}' executable after installation."
ok "Resolved agent executable: ${AGENT_PATH}"

# Patch the package the IDE will launch: the executable links to
# <package>/dist/index.js. `npm root -g` can name another copy when the install
# fell back to sudo and root's npm prefix differs from this user's.
PKG_DIR="$(node -p 'require("path").resolve(require("fs").realpathSync(process.argv[1]), "../..")' "${AGENT_PATH}")"
[[ -f "${PKG_DIR}/package.json" ]] || fail "Could not find the package behind ${AGENT_PATH} (expected ${PKG_DIR}/package.json)."
[[ "$(node -p 'require(process.argv[1]).name' "${PKG_DIR}/package.json")" == "${PACKAGE}" ]] || fail "${AGENT_PATH} does not belong to ${PACKAGE} (resolved to ${PKG_DIR})."
INSTALLED_VERSION="$(node -p 'require(process.argv[1]).version' "${PKG_DIR}/package.json")"
info "Applying local patches to ${PACKAGE} ${INSTALLED_VERSION} in ${PKG_DIR}..."
apply_patches "${PKG_DIR}" "${INSTALLED_VERSION}"

# ---------------------------------------------------------------------------
# 3. Claude Code CLI (auth)
# ---------------------------------------------------------------------------
# claude-agent-acp uses the Claude Agent SDK, which authenticates either via
# an ANTHROPIC_API_KEY or via the credentials stored by the Claude Code CLI
# (subscription login). Since JetBrains launches the agent as a subprocess
# without your shell profile, storing the OAuth credentials on disk via the
# Claude Code CLI is the more reliable path (no secrets in the ACP config).

info "Checking for the Claude Code CLI (used for authentication)..."
if ! command -v claude >/dev/null 2>&1; then
  info "Claude Code CLI not found. Installing @anthropic-ai/claude-code globally..."
  if ! npm install -g "@anthropic-ai/claude-code"; then
    sudo npm install -g "@anthropic-ai/claude-code" || warn "Could not install the Claude Code CLI automatically. Install it yourself (npm install -g @anthropic-ai/claude-code) and run 'claude' once to log in, or set ANTHROPIC_API_KEY."
  fi
fi

claude_is_logged_in() {
  if [[ "$OS" == "Darwin" ]]; then
    security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1
  else
    [[ -f "${HOME}/.claude/.credentials.json" ]]
  fi
}

CLAUDE_ENV_BLOCK="{}"
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code CLI found: $(command -v claude)"
  if claude_is_logged_in; then
    ok "Existing Claude Code login detected — the ACP agent will reuse it."
  else
    warn "Claude Code CLI is installed but you don't appear to be logged in yet."
    warn "Run 'claude' once in your terminal to complete login before using the agent in your IDE."
  fi
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  warn "ANTHROPIC_API_KEY is set in this shell. Embedding it into ${CONFIG_FILE} (plaintext) so JetBrains can pass it to the agent."
  read -r -p "Proceed with embedding ANTHROPIC_API_KEY in ${CONFIG_FILE}? [y/N] " REPLY
  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    CLAUDE_ENV_BLOCK=$(node -e 'console.log(JSON.stringify({ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY}))')
  else
    warn "Skipping. You'll need to add auth (ANTHROPIC_API_KEY or 'claude' login) before the agent works."
  fi
else
  warn "No Claude Code CLI login and no ANTHROPIC_API_KEY found."
  warn "Before using the agent, either run 'claude' once to log in, or set ANTHROPIC_API_KEY and re-run this script."
fi

# ---------------------------------------------------------------------------
# 4. Register the agent in ~/.jetbrains/acp.json
# ---------------------------------------------------------------------------

info "Registering agent in ${CONFIG_FILE}..."
mkdir -p "${CONFIG_DIR}"

if [[ -f "${CONFIG_FILE}" ]]; then
  cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

MERGE_SCRIPT="$(mktemp)"
cat > "${MERGE_SCRIPT}" <<'NODE'
const fs = require("fs");
const [, , configFile, agentName, agentPath, envBlockJson] = process.argv;

let config = { default_mcp_settings: { use_custom_mcp: true, use_idea_mcp: false }, agent_servers: {} };
if (fs.existsSync(configFile)) {
  try {
    config = JSON.parse(fs.readFileSync(configFile, "utf8"));
  } catch (e) {
    console.error(`Existing ${configFile} is not valid JSON, a backup was kept; starting from a fresh config.`);
  }
}

config.agent_servers = config.agent_servers || {};
const env = JSON.parse(envBlockJson);

config.agent_servers[agentName] = {
  command: agentPath,
  args: [],
  use_idea_mcp: true,
  use_custom_mcp: true,
  ...(Object.keys(env).length ? { env } : {}),
};

fs.writeFileSync(configFile, JSON.stringify(config, null, 2) + "\n");
NODE

node "${MERGE_SCRIPT}" "${CONFIG_FILE}" "${AGENT_DISPLAY_NAME}" "${AGENT_PATH}" "${CLAUDE_ENV_BLOCK}"
rm -f "${MERGE_SCRIPT}"

ok "Registered '${AGENT_DISPLAY_NAME}' in ${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 5. Detect installed JetBrains IDEs (informational only)
# ---------------------------------------------------------------------------

if [[ "$OS" == "Darwin" ]]; then
  FOUND_IDES=()
  for app in /Applications/*.app "${HOME}/Applications/JetBrains Toolbox/"*.app; do
    [[ -d "$app" ]] || continue
    base="$(basename "$app")"
    case "$base" in
      IntelliJ*|PyCharm*|WebStorm*|GoLand*|CLion*|PhpStorm*|RubyMine*|Rider*|DataGrip*|"Android Studio"*|RustRover*)
        FOUND_IDES+=("$base")
        ;;
    esac
  done
  if [[ "${#FOUND_IDES[@]}" -gt 0 ]]; then
    ok "Detected JetBrains IDE(s): ${FOUND_IDES[*]}"
  else
    warn "No JetBrains IDE detected in /Applications. Install one (2025.3+) to use this agent."
  fi
fi

echo
ok "Done."
echo "Next steps:"
echo "  1. Make sure your JetBrains IDE is on version 2025.3 or later, with the AI Assistant plugin updated."
echo "  2. If you haven't already, run 'claude' once in a terminal to log in (or ensure ANTHROPIC_API_KEY is set)."
echo "  3. Restart the IDE, open the AI Chat tool window, and select '${AGENT_DISPLAY_NAME}' from the agent picker."
