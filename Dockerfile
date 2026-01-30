FROM node:20-bookworm

# ===========================================
# RAILWAY CLAUDE CODE - Ultimate Security Setup
# ===========================================
# Access via: ttyd web terminal or SSH
# Persistent tmux sessions survive reconnects

ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=UTC
ENV TZ="$TZ"

# Install everything we need
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core tools
    tmux \
    git \
    git-lfs \
    curl \
    wget \
    vim \
    nano \
    zsh \
    fzf \
    jq \
    procps \
    sudo \
    less \
    man-db \
    unzip \
    gnupg2 \
    gh \
    # Network tools
    iproute2 \
    dnsutils \
    netcat-openbsd \
    nmap \
    # SSH server for remote access
    openssh-server \
    # ttyd for web terminal
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install ttyd for web-based terminal
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ARCH}" -O /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd

# Install git-delta for better diffs
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Create user with sudo
RUN useradd -m -s /bin/zsh -G sudo rainkode && \
    echo "rainkode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/rainkode && \
    chmod 0440 /etc/sudoers.d/rainkode

# Set up directories
RUN mkdir -p /home/rainkode/.claude \
             /home/rainkode/.config \
             /home/rainkode/.ssh \
             /home/rainkode/workspace \
             /home/rainkode/.d3bugr \
             /commandhistory && \
    touch /commandhistory/.bash_history /commandhistory/.zsh_history && \
    chown -R rainkode:rainkode /home/rainkode /commandhistory

# SSH server config
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Switch to user
USER rainkode
WORKDIR /home/rainkode

# Set up npm global
ENV NPM_CONFIG_PREFIX=/home/rainkode/.npm-global
ENV PATH="$PATH:/home/rainkode/.npm-global/bin"
RUN mkdir -p /home/rainkode/.npm-global

# Install Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install oh-my-zsh with plugins
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# Configure zsh
RUN cat >> ~/.zshrc << 'EOF'
# Plugins
plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)

# History
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=50000
export SAVEHIST=50000

# Claude Code
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

# Tmux auto-attach
if [[ -z "$TMUX" ]] && [[ -n "$SSH_CONNECTION" || -n "$TTYD" ]]; then
    tmux attach-session -t main 2>/dev/null || tmux new-session -s main
fi

# Aliases
alias ll='ls -la'
alias cc='claude'
alias ccc='claude --continue'

# Start in workspace
cd ~/workspace 2>/dev/null || true
EOF

# Tmux config for persistent sessions
RUN cat > ~/.tmux.conf << 'EOF'
# Modern tmux config
set -g default-terminal "screen-256color"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1

# Status bar
set -g status-style bg=black,fg=white
set -g status-left '#[fg=green][#S] '
set -g status-right '#[fg=yellow]%H:%M #[fg=cyan]%Y-%m-%d'

# Easy splits
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded"

# Keep sessions alive
set -g destroy-unattached off
set -g detach-on-destroy off
EOF

# D3BUGR MCP proxy - connects to your Railway d3bugr instance
RUN cat > ~/.d3bugr/proxy.js << 'EOF'
#!/usr/bin/env node
const http = require('http');
const HOST = process.env.D3BUGR_HOST || 'ballast.proxy.rlwy.net';
const PORT = parseInt(process.env.D3BUGR_PORT) || 47811;

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('readable', () => {
    let c;
    while ((c = process.stdin.read()) !== null) {
        buf += c;
        let i;
        while ((i = buf.indexOf('\n')) !== -1) {
            const l = buf.slice(0, i);
            buf = buf.slice(i + 1);
            if (l.trim()) fwd(JSON.parse(l));
        }
    }
});

function fwd(req) {
    const d = JSON.stringify(req);
    const o = {
        hostname: HOST,
        port: PORT,
        path: '/mcp',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(d) }
    };
    const r = http.request(o, res => {
        let b = '';
        res.on('data', c => b += c);
        res.on('end', () => process.stdout.write(b + '\n'));
    });
    r.on('error', e => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: req.id, error: { code: -32603, message: e.message } }) + '\n'));
    r.setTimeout(120000);
    r.write(d);
    r.end();
}
EOF

# Pre-configure Claude with d3bugr MCP
RUN mkdir -p ~/.claude && cat > ~/.claude.json << 'EOF'
{
  "mcpServers": {
    "d3bugr": {
      "type": "stdio",
      "command": "node",
      "args": ["/home/rainkode/.d3bugr/proxy.js"],
      "env": {}
    }
  }
}
EOF

# Startup script
USER root
RUN cat > /usr/local/bin/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "[*] Railway Claude Code - Starting up..."

# ===========================================
# CREDENTIAL INJECTION (the magic!)
# ===========================================
# Pass your credentials via CLAUDE_CREDENTIALS env var (base64 encoded)
# Generate with: cat ~/.claude/.credentials.json | base64 -w0
if [ -n "$CLAUDE_CREDENTIALS" ]; then
    echo "[+] Injecting Claude credentials..."
    echo "$CLAUDE_CREDENTIALS" | base64 -d > /home/rainkode/.claude/.credentials.json
    chmod 600 /home/rainkode/.claude/.credentials.json
    chown rainkode:rainkode /home/rainkode/.claude/.credentials.json
    echo "[+] Credentials injected - you're authenticated!"
else
    echo "[!] No CLAUDE_CREDENTIALS set - you'll need to run 'claude login'"
fi

# Inject claude.json config if provided
if [ -n "$CLAUDE_CONFIG" ]; then
    echo "[+] Injecting Claude config..."
    echo "$CLAUDE_CONFIG" | base64 -d > /home/rainkode/.claude.json
    chown rainkode:rainkode /home/rainkode/.claude.json
fi

# Inject settings if provided
if [ -n "$CLAUDE_SETTINGS" ]; then
    echo "[+] Injecting Claude settings..."
    echo "$CLAUDE_SETTINGS" | base64 -d > /home/rainkode/.claude/settings.json
    chown rainkode:rainkode /home/rainkode/.claude/settings.json
fi

# ===========================================
# SSH SERVER (optional)
# ===========================================
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "$SSH_PUBLIC_KEY" > /home/rainkode/.ssh/authorized_keys
    chmod 600 /home/rainkode/.ssh/authorized_keys
    chown rainkode:rainkode /home/rainkode/.ssh/authorized_keys
    /usr/sbin/sshd
    echo "[+] SSH server started on port 22"
fi

# ===========================================
# TMUX SESSION
# ===========================================
su - rainkode -c "tmux new-session -d -s main 2>/dev/null || true"
echo "[+] tmux session 'main' ready"

# ===========================================
# WEB TERMINAL (ttyd)
# ===========================================
echo "[+] Starting web terminal on port ${PORT:-7681}"
echo "[i] Login: ${TTYD_USER:-admin} / [password set via TTYD_PASS]"

export TTYD=1
exec ttyd -W -p ${PORT:-7681} -c ${TTYD_USER:-admin}:${TTYD_PASS:-changeme} \
    su - rainkode -c "tmux attach-session -t main || tmux new-session -s main"
EOF
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose ports
EXPOSE 7681 22

# Environment variables (override via Railway)
ENV PORT=7681
ENV SSH_PUBLIC_KEY=""
ENV TTYD_USER="admin"
ENV TTYD_PASS=""
ENV D3BUGR_HOST="ballast.proxy.rlwy.net"
ENV D3BUGR_PORT="47811"

# CREDENTIAL INJECTION (base64 encoded JSON)
# Generate: cat ~/.claude/.credentials.json | base64 -w0
ENV CLAUDE_CREDENTIALS=""
# Generate: cat ~/.claude.json | base64 -w0
ENV CLAUDE_CONFIG=""
# Generate: cat ~/.claude/settings.json | base64 -w0
ENV CLAUDE_SETTINGS=""

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
