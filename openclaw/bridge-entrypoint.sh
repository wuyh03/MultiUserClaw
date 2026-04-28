#!/bin/bash
set -e

HOME="${HOME:-/root}"
export HOME

# OPENCLAW_HOME 是 openclaw 内部的 "home" 基准目录，内部代码会在其下拼接 .openclaw/
# 所以 OPENCLAW_HOME 应该指向 /root（而非 /root/.openclaw），
# 否则 resolveDefaultAgentWorkspaceDir() 会生成 /root/.openclaw/.openclaw/workspace
OPENCLAW_HOME="${OPENCLAW_HOME:-/root}"
export OPENCLAW_HOME

# STATE_DIR 和 CONFIG_PATH 直接指向 .openclaw 目录，这些变量被 resolveConfigDir() 优先使用
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw}"
export OPENCLAW_STATE_DIR
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/root/.openclaw/openclaw.json}"
export OPENCLAW_CONFIG_PATH
OPENCLAW_VERSION_FILE="${OPENCLAW_STATE_DIR}/version.txt"
export OPENCLAW_VERSION_FILE

TARGET_DEPLOY_VERSION="${DEPLOY_VERSION:-}"
CURRENT_DEPLOY_VERSION="$(cat "$OPENCLAW_VERSION_FILE" 2>/dev/null || true)"
FORCE_DEPLOY_SYNC=0

if [ -n "$TARGET_DEPLOY_VERSION" ]; then
  if [ "$CURRENT_DEPLOY_VERSION" != "$TARGET_DEPLOY_VERSION" ]; then
    FORCE_DEPLOY_SYNC=1
    echo "[entrypoint] Deploy version mismatch: current='${CURRENT_DEPLOY_VERSION:-<none>}' target='$TARGET_DEPLOY_VERSION'"
  else
    echo "[entrypoint] Deploy version unchanged: $TARGET_DEPLOY_VERSION"
  fi
else
  echo "[entrypoint] DEPLOY_VERSION not set, using missing-only sync mode"
fi

copy_deploy_file() {
  src="$1"
  dst="$2"
  label="$3"

  if [ "$FORCE_DEPLOY_SYNC" = "1" ] || [ ! -f "$dst" ]; then
    parent="$(dirname "$dst")"
    if [ -f "$parent" ]; then
      rm -rf "$parent"
    fi
    mkdir -p "$parent"
    cp "$src" "$dst"
    if [ "$FORCE_DEPLOY_SYNC" = "1" ]; then
      echo "[entrypoint]   = $label (forced)"
    else
      echo "[entrypoint]   + $label"
    fi
  fi
}

# 快速创建必需目录（并行执行以提高速度）
mkdir -p "$OPENCLAW_STATE_DIR"/{workspace,uploads,sessions,skills,extensions,agents,memory/{weekly,archive}}

# 快速清理 Chromium 锁文件（优化：使用 -delete 标志）
find "$OPENCLAW_STATE_DIR/browser" -type f \( -name "SingletonLock" -o -name "SingletonCookie" -o -name "SingletonSocket" \) -delete 2>/dev/null || true

# 如果不存在默认 openclaw.json 文件，初始化一个空的
if [ ! -f "$OPENCLAW_STATE_DIR/openclaw.json" ]; then
  echo "{}" > "$OPENCLAW_STATE_DIR/openclaw.json"
  echo "[entrypoint] Initialized $OPENCLAW_STATE_DIR/openclaw.json"
fi

# 同步需要预先拷贝的配置，skills和agents到容器
if [ -d /deploy-copy ]; then
  if [ "$FORCE_DEPLOY_SYNC" = "1" ]; then
    echo "[entrypoint]  强制同步deploy模版到本容器.."
  else
    echo "[entrypoint] 仅仅同步缺失的部分deploy模版到本容器..."
  fi

  # Sync Agents — each subdirectory becomes a registered agent
  if [ -d /deploy-copy/Agents ]; then
    for agent_src in /deploy-copy/Agents/*/; do
      [ -d "$agent_src" ] || continue
      agent_name="$(basename "$agent_src")"
      agent_id="$(echo "$agent_name" | tr '[:upper:]' '[:lower:]')"

      # 1. Create agents/<id>/ directory (for gateway disk discovery)
      mkdir -p "$OPENCLAW_STATE_DIR/agents/$agent_id"

      # 2. Sync workspace files — main uses workspace/, others use workspace-<id>/
      if [ "$agent_id" = "main" ]; then
        workspace_dir="$OPENCLAW_STATE_DIR/workspace"
      else
        workspace_dir="$OPENCLAW_STATE_DIR/workspace-$agent_id"
      fi
      mkdir -p "$workspace_dir"
      find "$agent_src" -type f | while read src; do
        rel="${src#$agent_src}"
        dst="$workspace_dir/$rel"
        mkdir -p "$(dirname "$dst")"
        base="$(basename "$rel")"
        # Platform-managed files are always overwritten.
        # Other files are only overwritten during an explicit deploy-version upgrade.
        case "$base" in
          SOUL.md|AGENTS.md|IDENTITY.md)
            cp "$src" "$dst"
            echo "[entrypoint]   = workspace-$agent_id/$rel (updated)"
            ;;
          *)
            if [ "$FORCE_DEPLOY_SYNC" = "1" ] || [ ! -f "$dst" ]; then
              cp "$src" "$dst"
              if [ "$FORCE_DEPLOY_SYNC" = "1" ]; then
                echo "[entrypoint]   = workspace-$agent_id/$rel (forced)"
              else
                echo "[entrypoint]   + workspace-$agent_id/$rel"
              fi
            fi
            ;;
        esac
      done

      echo "[entrypoint]   Agent discovered: $agent_name → workspace-$agent_id/"
    done

  fi

  # Sync extensions (openclaw plugins)
  if [ -d /deploy-copy/extensions ]; then
    mkdir -p "$OPENCLAW_STATE_DIR/extensions"
    find /deploy-copy/extensions -type f | while read src; do
      rel="${src#/deploy-copy/extensions/}"
      dst="$OPENCLAW_STATE_DIR/extensions/$rel"
      copy_deploy_file "$src" "$dst" "extensions/$rel"
    done
  fi

  # Sync skills
  if [ -d /deploy-copy/skills ]; then
    find /deploy-copy/skills -type f | while read src; do
      rel="${src#/deploy-copy/skills/}"
      dst="$OPENCLAW_STATE_DIR/skills/$rel"
      copy_deploy_file "$src" "$dst" "skills/$rel"
    done
  fi

  # Deep merge openclaw_defaults.json into openclaw.json (add missing keys at any depth)
  if [ -f /deploy-copy/openclaw_defaults.json ]; then
    if command -v node &> /dev/null; then
      node -e "
        const fs = require('fs');
        const defaultsPath = '/deploy-copy/openclaw_defaults.json';
        const configPath = '$OPENCLAW_STATE_DIR/openclaw.json';
        const defaults = JSON.parse(fs.readFileSync(defaultsPath, 'utf-8'));

        // If config doesn't exist, just copy defaults
        if (!fs.existsSync(configPath)) {
          fs.writeFileSync(configPath, JSON.stringify(defaults, null, 2));
          console.log('[entrypoint]   Created openclaw.json from defaults');
          process.exit(0);
        }

        const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));

        // Recursive deep merge: add missing keys without overwriting existing leaf values
        // For arrays of objects with 'id' field, merge by matching id
        function deepMerge(base, override) {
          let changed = false;
          for (const [key, value] of Object.entries(override)) {
            if (!(key in base)) {
              base[key] = JSON.parse(JSON.stringify(value));
              changed = true;
            } else if (value && typeof value === 'object' && !Array.isArray(value)
                       && base[key] && typeof base[key] === 'object' && !Array.isArray(base[key])) {
              if (deepMerge(base[key], value)) changed = true;
            } else if (Array.isArray(value) && Array.isArray(base[key])) {
              // For arrays of objects with 'id', merge by id
              if (value.length > 0 && value[0] && typeof value[0] === 'object' && 'id' in value[0]
                  && base[key].length > 0 && base[key][0] && typeof base[key][0] === 'object' && 'id' in base[key][0]) {
                const baseById = {};
                for (const item of base[key]) {
                  if (item && typeof item === 'object' && 'id' in item) baseById[item.id] = item;
                }
                for (const overrideItem of value) {
                  if (!overrideItem || typeof overrideItem !== 'object' || !('id' in overrideItem)) continue;
                  if (overrideItem.id in baseById) {
                    if (deepMerge(baseById[overrideItem.id], overrideItem)) changed = true;
                  } else {
                    base[key].push(JSON.parse(JSON.stringify(overrideItem)));
                    changed = true;
                  }
                }
              }
              // Other arrays: keep base value, don't overwrite
            }
            // Other types (string, number, bool): keep base value, don't overwrite
          }
          return changed;
        }

        if (deepMerge(config, defaults)) {
          fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
          console.log('[entrypoint]   Deep merged openclaw_defaults.json');
        }

        // Force-override critical settings that must always match defaults
        const forceOverrides = [
          ['tools.sessions.visibility', defaults.tools?.sessions?.visibility],
          ['memory.backend', defaults.memory?.backend],
          ['memory.qmd.searchMode', defaults.memory?.qmd?.searchMode],
          ['agents.defaults.timeoutSeconds', defaults.agents?.defaults?.timeoutSeconds],
          ['agents.defaults.subagents.maxSpawnDepth', defaults.agents?.defaults?.subagents?.maxSpawnDepth],
          ['agents.defaults.subagents.maxChildrenPerAgent', defaults.agents?.defaults?.subagents?.maxChildrenPerAgent],
          ['agents.defaults.subagents.maxConcurrent', defaults.agents?.defaults?.subagents?.maxConcurrent],
          ['agents.defaults.subagents.runTimeoutSeconds', defaults.agents?.defaults?.subagents?.runTimeoutSeconds],
        ];
        let forceChanged = false;
        for (const [dotPath, value] of forceOverrides) {
          if (value === undefined) continue;
          const keys = dotPath.split('.');
          let obj = config;
          for (let i = 0; i < keys.length - 1; i++) {
            if (!obj[keys[i]] || typeof obj[keys[i]] !== 'object') obj[keys[i]] = {};
            obj = obj[keys[i]];
          }
          const lastKey = keys[keys.length - 1];
          if (obj[lastKey] !== value) {
            obj[lastKey] = value;
            forceChanged = true;
            console.log('[entrypoint]   Force override: ' + dotPath + ' = ' + JSON.stringify(value));
          }
        }
        if (forceChanged) {
          fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        }

        // Force-override agent model fields from defaults (by id)
        const defaultAgentModels = {};
        for (const da of (defaults.agents?.list || [])) {
          if (da?.id && da?.model !== undefined) defaultAgentModels[da.id.toLowerCase()] = da.model;
        }
        let agentModelChanged = false;
        for (const a of (config.agents?.list || [])) {
          if (!a?.id) continue;
          const defaultModel = defaultAgentModels[a.id.toLowerCase()];
          if (defaultModel !== undefined && a.model !== defaultModel) {
            console.log('[entrypoint]   Force override agent model: ' + a.id + ' = ' + defaultModel);
            a.model = defaultModel;
            agentModelChanged = true;
          }
        }
        if (agentModelChanged) {
          fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
        }
      "
    fi
  fi

  # Ensure all default agents exist in openclaw.json, deduplicate, fix workspace paths
  if [ -f "$OPENCLAW_STATE_DIR/openclaw.json" ] && command -v node &> /dev/null; then
    node -e "
      const fs = require('fs');
      const configPath = '$OPENCLAW_STATE_DIR/openclaw.json';
      const openclawHome = '$OPENCLAW_STATE_DIR';
      const defaultsPath = '/deploy-copy/openclaw_defaults.json';

      const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
      if (!config.agents) config.agents = {};
      if (!Array.isArray(config.agents.list)) config.agents.list = [];

      // Load default agents from deploy defaults
      let defaultAgents = [];
      try {
        const defaults = JSON.parse(fs.readFileSync(defaultsPath, 'utf-8'));
        defaultAgents = defaults.agents?.list || [];
      } catch (e) {
        console.log('[entrypoint]   WARN: could not read defaults:', e.message);
      }

      // Ensure all default agents exist in config (add missing ones)
      const existingIds = new Set(config.agents.list.map(a => a?.id?.toLowerCase()).filter(Boolean));
      for (const da of defaultAgents) {
        if (da?.id && !existingIds.has(da.id.toLowerCase())) {
          config.agents.list.push(JSON.parse(JSON.stringify(da)));
          console.log('[entrypoint]   + Added missing agent: ' + da.id);
        }
      }

      // Deduplicate by id — keep last occurrence
      const seen = new Map();
      for (let i = 0; i < config.agents.list.length; i++) {
        const a = config.agents.list[i];
        if (a && a.id) seen.set(a.id.toLowerCase(), i);
      }
      const deduped = [];
      for (const idx of seen.values()) {
        deduped.push(config.agents.list[idx]);
      }

      // Fix workspace paths for all agents
      for (const a of deduped) {
        if (a.id === 'main') {
          a.workspace = openclawHome + '/workspace';
          a.default = true;
        } else {
          // Remove relative workspace paths (e.g. 'Agents/manager') — let gateway
          // resolve to the correct default: \$OPENCLAW_STATE_DIR/workspace-<id>
          if (a.workspace && !a.workspace.startsWith('/')) {
            delete a.workspace;
          }
        }
      }

      // Sort: main first, then alphabetical
      deduped.sort((a, b) => {
        if (a.id === 'main') return -1;
        if (b.id === 'main') return 1;
        return a.id.localeCompare(b.id);
      });

      config.agents.list = deduped;
      fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
      console.log('[entrypoint]   Agents: ' + deduped.map(a => a.id).join(', '));
    "
  fi

  # Sync SSH keys
  if [ -d /deploy-copy/ssh ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    for keyfile in /deploy-copy/ssh/*; do
      [ -f "$keyfile" ] || continue
      dst="/root/.ssh/$(basename "$keyfile")"
      # Strip Windows \r line endings — OpenSSH rejects keys with CRLF
      sed 's/\r$//' "$keyfile" > "$dst"
      # Private keys need 600, public keys and config 644
      case "$(basename "$keyfile")" in
        *.pub|config|known_hosts) chmod 644 "$dst" ;;
        *) chmod 600 "$dst" ;;
      esac
      echo "[entrypoint]   + .ssh/$(basename "$keyfile")"
    done
    echo "[entrypoint] SSH keys synced"
  fi

  # Sync qmd-runner.sh wrapper script
  if [ -f /deploy-copy/qmd-runner.sh ]; then
    sed 's/\r$//' /deploy-copy/qmd-runner.sh > "$OPENCLAW_STATE_DIR/qmd-runner.sh"
    chmod +x "$OPENCLAW_STATE_DIR/qmd-runner.sh"
    echo "[entrypoint] qmd-runner.sh synced"
  fi

  # Create MEMORY.md if it doesn't exist
  if [ ! -f "$OPENCLAW_STATE_DIR/memory/MEMORY.md" ]; then
    cat > "$OPENCLAW_STATE_DIR/memory/MEMORY.md" << 'MEMEOF'
# Long-Term Memory

> Only write info here that you'd make mistakes without. Event logs stay in daily files.
> Hard limit: 80 lines / 5KB. Must compress before adding when over limit.

## User Preferences

## Active Projects

## Key Decisions

## Important Contacts
MEMEOF
    echo "[entrypoint] MEMORY.md template created"
  fi

  # Initialize qmd memory collection (BM25 search mode, no embedding needed)
  if command -v qmd >/dev/null 2>&1; then
    qmd collection add "$OPENCLAW_STATE_DIR/memory" 2>/dev/null || true
    qmd update 2>/dev/null || true
    echo "[entrypoint] qmd memory collection initialized"
  else
    echo "[entrypoint] WARN: qmd not found, memory search unavailable"
  fi

  echo "[entrypoint] Deploy templates synced"

  if [ -n "$TARGET_DEPLOY_VERSION" ]; then
    printf '%s\n' "$TARGET_DEPLOY_VERSION" > "$OPENCLAW_VERSION_FILE"
    echo "[entrypoint] 记录部署版本 deploy version: $TARGET_DEPLOY_VERSION"
  fi
fi

# If NANOBOT_PROXY__URL is set, we're running in platform mode
if [ -n "$NANOBOT_PROXY__URL" ]; then
  echo "[entrypoint] Platform mode detected"
  echo "[entrypoint] Proxy URL: $NANOBOT_PROXY__URL"
  echo "[entrypoint] Model: $NANOBOT_AGENTS__DEFAULTS__MODEL"
fi

# Register memory cron jobs in background after gateway starts.
_register_memory_crons() {
  # Wait for gateway to be ready
  for i in $(seq 1 12); do
    sleep 10
    if openclaw cron list >/dev/null 2>&1; then
      break
    fi
    if [ "$i" -eq 12 ]; then
      echo "[entrypoint] WARN: gateway not ready after 120s, skipping cron registration"
      return
    fi
  done

#  existing_crons=$(openclaw cron list 2>/dev/null || echo "")

#  if ! echo "$existing_crons" | grep -q "memory-sync"; then
#    timeout 30 openclaw cron add \
#      --name "memory-sync" \
#      --cron "0 10,14,18,22 * * *" \
#      --tz "Asia/Shanghai" \
#      --session isolated \
#      --wake now \
#      --no-deliver \
#      --message "You are a memory sync agent. Execute these steps NOW using tools. Do NOT just describe them. Step 1: Use the sessions tool to list all sessions from the last 4 hours. Step 2: For each non-isolated session with at least 2 user messages, use the sessions tool to get its history. Step 3: Use shell to get today's date (run: date +%Y-%m-%d), then read the file /root/.openclaw/memory/<TODAY>.md (create it if it does not exist). Step 4: For each session, check if its first 8 ID chars already appear in the file. If yes skip it. Step 5: Extract 3-10 key items (user requests, decisions, results) from each new session. Step 6: Append to the file under heading: ## HH:MM session:FIRST8CHARS | N messages. Step 7: Run shell command: /root/.openclaw/qmd-runner.sh update. Step 8: If no valid sessions found, do nothing." \
#      2>/dev/null && echo "[entrypoint] memory-sync cron registered" || echo "[entrypoint] WARN: memory-sync cron failed"
#  fi

#  if ! echo "$existing_crons" | grep -q "memory-tidy"; then
#    timeout 30 openclaw cron add \
#      --name "memory-tidy" \
#      --cron "0 3 * * *" \
#      --tz "Asia/Shanghai" \
#      --session isolated \
#      --wake now \
#      --no-deliver \
#      --message "You are a memory tidy agent. Execute these steps NOW using tools. Phase 1 - Weekly compression: Use shell to list /root/.openclaw/memory/*.md files older than 7 days. Group them by ISO week. For each week, read all daily files, extract key Decisions/Discoveries/Preferences/Tasks, and write a summary to /root/.openclaw/memory/weekly/YYYY-Www.md. Skip weeks that already have a weekly file. Phase 2 - Long-term distillation: Read the last 7 daily files and /root/.openclaw/memory/MEMORY.md. Identify facts that meet ALL criteria: agent would make errors without it, applies broadly, self-contained, not already in MEMORY.md. Back up MEMORY.md first, then append new entries. Hard limit 80 lines in MEMORY.md. Phase 3 - Archive: Move compressed daily files older than 14 days to /root/.openclaw/memory/archive/YYYY/. Finally run: /root/.openclaw/qmd-runner.sh update" \
#      2>/dev/null && echo "[entrypoint] memory-tidy cron registered" || echo "[entrypoint] WARN: memory-tidy cron failed"
#  fi

}

# 异步执行，不阻塞主进程启动
#_register_memory_crons &

echo "[entrypoint] Main startup sequence complete, background tasks running in parallel"

exec "$@"
