#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_PORT="${PORT:-3000}"
NOVNC_BACKEND_PORT="${NOVNC_BACKEND_PORT:-6080}"
TTYD_BACKEND_PORT="${TTYD_BACKEND_PORT:-7681}"

DISPLAY_NUM="${DISPLAY_NUM:-7}"
DISPLAY=":${DISPLAY_NUM}"
VNC_PORT="$((5900 + DISPLAY_NUM))"
SCREEN_SIZE="${SCREEN_SIZE:-1368x768x24}"

TERMINAL_USER="${TERMINAL_USER:-user}"
TERMINAL_PASSWORD="${TERMINAL_PASSWORD:-1010}"
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-1010}"

ROOT_DIR="${ROOT_DIR:-$PWD/.ubuntu24}"
ROOTFS="$ROOT_DIR/rootfs"
STATE_DIR="$ROOT_DIR/state"
NOVNC_DIR="$STATE_DIR/novnc"
VNC_DIR="$STATE_DIR/vnc"
LOG_DIR="$STATE_DIR/logs"
RUNTIME_DIR="$STATE_DIR/runtime"
LOGIN_SCRIPT="$STATE_DIR/terminal-login.sh"
UBUNTU_SHELL="$STATE_DIR/ubuntu-shell.sh"
CADDYFILE="$STATE_DIR/Caddyfile"

PROOT="${PROOT:-$(command -v proot 2>/dev/null || true)}"

log() {
  printf '\033[1;35m[ubuntu24]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[ubuntu24] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Missing '$1'. Reload the Repl so replit.nix can install it."
}

for cmd in bash curl tar caddy ttyd Xvfb xdpyinfo x11vnc websockify fluxbox xterm; do
  need "$cmd"
done

[[ -x "$PROOT" ]] || die "PRoot is unavailable."
[[ -x "$ROOTFS/bin/bash" ]] || die "Ubuntu rootfs is missing at $ROOTFS."

mkdir -p "$STATE_DIR" "$NOVNC_DIR" "$VNC_DIR" "$LOG_DIR" "$RUNTIME_DIR"
chmod 700 "$VNC_DIR" "$RUNTIME_DIR"

export DISPLAY
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

PIDS=()
NAMES=()

register_service() {
  NAMES+=("$1")
  PIDS+=("$2")
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  log "Stopping services..."

  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done

  pkill -f "Xvfb :${DISPLAY_NUM}" 2>/dev/null || true
  pkill -f "x11vnc.*${VNC_PORT}" 2>/dev/null || true
  pkill -f "websockify.*${NOVNC_BACKEND_PORT}" 2>/dev/null || true
  pkill -f "ttyd.*${TTYD_BACKEND_PORT}" 2>/dev/null || true

  exit "$status"
}

trap cleanup EXIT INT TERM

wait_for_port() {
  local host="$1"
  local port="$2"
  local label="$3"

  for _ in $(seq 1 100); do
    if bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
      exec 3>&-
      exec 3<&-
      return 0
    fi
    sleep 0.1
  done

  die "$label did not open $host:$port"
}

clean_stale() {
  log "Cleaning stale services..."

  pkill -f "Xvfb :${DISPLAY_NUM}" 2>/dev/null || true
  pkill -f "x11vnc.*${VNC_PORT}" 2>/dev/null || true
  pkill -f "websockify.*${NOVNC_BACKEND_PORT}" 2>/dev/null || true
  pkill -f "ttyd.*${TTYD_BACKEND_PORT}" 2>/dev/null || true
  pkill -f "caddy.*${CADDYFILE}" 2>/dev/null || true
  pkill -f fluxbox 2>/dev/null || true
  pkill -f xterm 2>/dev/null || true

  sleep 1

  rm -f \
    "/tmp/.X${DISPLAY_NUM}-lock" \
    "/tmp/.X11-unix/X${DISPLAY_NUM}" \
    "$RUNTIME_DIR/bus" \
    2>/dev/null || true
}

ubuntu_exec() {
  "$PROOT" \
    -0 \
    -r "$ROOTFS" \
    -b /dev \
    -b /proc \
    -b /sys \
    -b /tmp \
    -b "$PWD:/workspace" \
    -w /root \
    /usr/bin/env -i \
      HOME=/root \
      USER=root \
      LOGNAME=root \
      SHELL=/bin/bash \
      TERM="${TERM:-xterm-256color}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 \
      LC_ALL=C.UTF-8 \
      PS1='\[\033[01;32m\]root@ubuntu24\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]# ' \
      "$@"
}

download_novnc() {
  if [[ -f "$NOVNC_DIR/vnc.html" ]]; then
    return
  fi

  log "Downloading noVNC..."

  local archive="$STATE_DIR/novnc.tar.gz"

  rm -f "$archive"
  rm -rf "$NOVNC_DIR" "$STATE_DIR/noVNC-1.5.0"

  curl -fL --retry 4 \
    "https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz" \
    -o "$archive"

  tar -xzf "$archive" -C "$STATE_DIR"
  mv "$STATE_DIR/noVNC-1.5.0" "$NOVNC_DIR"
}

install_ubuntu_ui() {
  mkdir -p "$NOVNC_DIR/custom"

  cat > "$NOVNC_DIR/custom/ubuntu.css" <<'EOF'
:root {
  color-scheme: dark;
  --ubuntu-orange: #e95420;
  --ubuntu-aubergine: #772953;
  --ubuntu-dark: #2c001e;
  --ubuntu-panel: rgba(44, 0, 30, .96);
  --ubuntu-line: rgba(255, 255, 255, .14);
  --ubuntu-text: #ffffff;
}

html,
body {
  background: var(--ubuntu-dark) !important;
  font-family: Ubuntu, Cantarell, system-ui, sans-serif !important;
}

#noVNC_status_bar {
  min-height: 44px !important;
  color: var(--ubuntu-text) !important;
  background: linear-gradient(90deg, #2c001e, #5e2750) !important;
  border-bottom: 1px solid var(--ubuntu-line) !important;
  box-shadow: 0 8px 28px rgba(0, 0, 0, .35) !important;
}

#noVNC_status {
  color: var(--ubuntu-text) !important;
  font-weight: 700 !important;
  letter-spacing: .01em !important;
}

#noVNC_control_bar {
  margin: 12px !important;
  padding: 8px !important;
  background: var(--ubuntu-panel) !important;
  border: 1px solid var(--ubuntu-line) !important;
  border-radius: 18px !important;
  box-shadow: 0 20px 60px rgba(0, 0, 0, .48) !important;
  backdrop-filter: blur(16px) !important;
}

.noVNC_button,
#noVNC_control_bar button {
  border-radius: 11px !important;
  transition: transform .15s ease, background .15s ease !important;
}

.noVNC_button:hover,
#noVNC_control_bar button:hover {
  transform: translateY(-1px) !important;
  background: rgba(255, 255, 255, .1) !important;
}

#noVNC_canvas {
  background:
    radial-gradient(circle at top, #5e2750 0, #2c001e 58%) !important;
}

#noVNC_connect_dlg,
#noVNC_credentials_dlg,
#noVNC_settings,
.noVNC_dialog {
  color: var(--ubuntu-text) !important;
  background: rgba(44, 0, 30, .98) !important;
  border: 1px solid var(--ubuntu-line) !important;
  border-radius: 18px !important;
  box-shadow: 0 26px 80px rgba(0, 0, 0, .58) !important;
}

input,
select,
textarea {
  color: var(--ubuntu-text) !important;
  background: #3b0b2b !important;
  border: 1px solid var(--ubuntu-line) !important;
  border-radius: 10px !important;
}

#noVNC_connect_button {
  color: white !important;
  font-weight: 800 !important;
  background: var(--ubuntu-orange) !important;
  border: 0 !important;
  border-radius: 10px !important;
}
EOF

  if ! grep -q 'custom/ubuntu.css' "$NOVNC_DIR/vnc.html"; then
    sed -i \
      '/<\/head>/i\    <link rel="stylesheet" href="custom/ubuntu.css">' \
      "$NOVNC_DIR/vnc.html"
  fi

  cat > "$NOVNC_DIR/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Ubuntu 24.04</title>
  <style>
    * { box-sizing: border-box; }

    html, body {
      min-height: 100%;
      margin: 0;
    }

    body {
      display: grid;
      place-items: center;
      padding: 24px;
      color: #f7f2f5;
      background: #2c001e;
      font-family: Ubuntu, Cantarell, system-ui, sans-serif;
    }

    main {
      width: min(720px, 100%);
    }

    header {
      margin-bottom: 24px;
    }

    h1 {
      margin: 0 0 6px;
      font-size: 32px;
      font-weight: 500;
    }

    p {
      margin: 0;
      color: #cabdc5;
      line-height: 1.5;
    }

    nav {
      overflow: hidden;
      background: #3b0b2b;
      border: 1px solid rgba(255,255,255,.12);
      border-radius: 10px;
      box-shadow: 0 18px 45px rgba(0,0,0,.32);
    }

    a {
      display: flex;
      align-items: center;
      gap: 16px;
      padding: 20px;
      color: #fff;
      text-decoration: none;
      border-bottom: 1px solid rgba(255,255,255,.1);
    }

    a:last-child {
      border-bottom: 0;
    }

    a:hover {
      background: #4b1238;
    }

    .icon {
      display: grid;
      place-items: center;
      width: 42px;
      height: 42px;
      flex: 0 0 auto;
      background: #e95420;
      border-radius: 8px;
      font-size: 21px;
    }

    strong {
      display: block;
      margin-bottom: 3px;
      font-size: 17px;
      font-weight: 600;
    }

    span {
      color: #cbbdc6;
      font-size: 14px;
    }

    footer {
      margin-top: 16px;
      color: #a995a2;
      font-size: 13px;
    }

    code {
      color: #ffb59a;
    }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Ubuntu 24.04</h1>
      <p>Select a workspace.</p>
    </header>

    <nav>
      <a href="/desktop/vnc.html?autoconnect=true&resize=scale&path=websockify">
        <div class="icon">▣</div>
        <div>
          <strong>Desktop</strong>
          <span>Open the graphical desktop.</span>
        </div>
      </a>

      <a href="/terminal/">
        <div class="icon">›_</div>
        <div>
          <strong>Terminal</strong>
          <span>Open the Ubuntu shell.</span>
        </div>
      </a>
    </nav>

    <footer>
      Paste in terminal with <code>Ctrl+Shift+V</code>.
      Use the noVNC clipboard panel for the desktop.
    </footer>
  </main>
</body>
</html>
EOF
}

create_shell_scripts() {
  cat > "$UBUNTU_SHELL" <<EOF
#!/usr/bin/env bash
exec "$PROOT" \
  -0 \
  -r "$ROOTFS" \
  -b /dev \
  -b /proc \
  -b /sys \
  -b /tmp \
  -b "$PWD:/workspace" \
  -w /root \
  /usr/bin/env -i \
    HOME=/root \
    USER=root \
    LOGNAME=root \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PS1='\\[\\033[01;32m\\]root@ubuntu24\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]# ' \
    /bin/bash --noprofile --norc -i
EOF
  chmod 700 "$UBUNTU_SHELL"

  cat > "$LOGIN_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_USER='${TERMINAL_USER}'
EXPECTED_PASSWORD='${TERMINAL_PASSWORD}'

clear 2>/dev/null || true
printf '\033[1;35mUbuntu 24.04 LTS terminal\033[0m\n\n'

for attempt in 1 2 3; do
  printf 'login: '
  IFS= read -r username || exit 1

  printf 'password: '
  IFS= read -rs password || exit 1
  printf '\n'

  if [[ "\$username" == "\$EXPECTED_USER" &&
        "\$password" == "\$EXPECTED_PASSWORD" ]]; then
    exec "$UBUNTU_SHELL"
  fi

  printf '\nLogin incorrect.\n\n'
done

exit 1
EOF
  chmod 700 "$LOGIN_SCRIPT"
}

start_desktop() {
  x11vnc -storepasswd "$DESKTOP_PASSWORD" "$VNC_DIR/passwd" >/dev/null
  chmod 600 "$VNC_DIR/passwd"

  log "Starting virtual display :$DISPLAY_NUM..."
  Xvfb "$DISPLAY" \
    -screen 0 "$SCREEN_SIZE" \
    -ac \
    -nolisten tcp \
    >"$LOG_DIR/xvfb.log" 2>&1 &
  XSERVER_PID="$!"

  for _ in $(seq 1 80); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.1
  done

  xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 ||
    die "Xvfb failed. Check $LOG_DIR/xvfb.log"

  log "Starting Fluxbox..."
  fluxbox >"$LOG_DIR/fluxbox.log" 2>&1 &
  FLUXBOX_PID="$!"

  log "Opening Ubuntu terminal on desktop..."
  xterm \
    -geometry 112x34+30+30 \
    -title "Ubuntu 24.04 Terminal" \
    -e "$UBUNTU_SHELL" \
    >"$LOG_DIR/xterm.log" 2>&1 &
  XTERM_PID="$!"

  log "Starting VNC..."
  x11vnc \
    -display "$DISPLAY" \
    -rfbport "$VNC_PORT" \
    -rfbauth "$VNC_DIR/passwd" \
    -localhost \
    -forever \
    -shared \
    -noxdamage \
    -nowf \
    >"$LOG_DIR/x11vnc.log" 2>&1 &
  X11VNC_PID="$!"
  sleep 1

  log "Starting noVNC backend..."
  websockify \
    "127.0.0.1:$NOVNC_BACKEND_PORT" \
    "127.0.0.1:$VNC_PORT" \
    >"$LOG_DIR/websockify.log" 2>&1 &
  register_service "websockify" "$!"
  wait_for_port 127.0.0.1 "$NOVNC_BACKEND_PORT" "websockify"
}

start_terminal() {
  log "Starting browser terminal..."
  ttyd \
    --interface 127.0.0.1 \
    --port "$TTYD_BACKEND_PORT" \
    --base-path /terminal \
    --writable \
    --client-option fontSize=15 \
    --client-option cursorBlink=true \
    --client-option scrollback=10000 \
    --client-option copyOnSelect=true \
    "$LOGIN_SCRIPT" \
    >"$LOG_DIR/ttyd.log" 2>&1 &
  register_service "ttyd" "$!"
  wait_for_port 127.0.0.1 "$TTYD_BACKEND_PORT" "ttyd"
}

start_gateway() {
  cat > "$CADDYFILE" <<EOF
{
  auto_https off
  admin off
}

:$PUBLIC_PORT {
  encode gzip

  @terminal path /terminal /terminal/*
  handle @terminal {
    reverse_proxy 127.0.0.1:$TTYD_BACKEND_PORT
  }

  handle /websockify {
    reverse_proxy 127.0.0.1:$NOVNC_BACKEND_PORT
  }

  handle_path /desktop/* {
    root * $NOVNC_DIR
    file_server
  }

  handle {
    root * $NOVNC_DIR
    file_server
  }
}
EOF

  log "Starting web gateway..."
  caddy run \
    --config "$CADDYFILE" \
    --adapter caddyfile \
    >"$LOG_DIR/caddy.log" 2>&1 &
  register_service "caddy" "$!"
  wait_for_port 127.0.0.1 "$PUBLIC_PORT" "caddy"
}

case "${1:-start}" in
  shell)
    exec ubuntu_exec /bin/bash --noprofile --norc -i
    ;;
  start|"")
    ;;
  *)
    die "Usage: ./main.sh [shell]"
    ;;
esac

clean_stale
download_novnc
install_ubuntu_ui
create_shell_scripts
start_desktop
start_terminal
start_gateway

cat <<EOF

Ubuntu workspace is running.

Home:
  /

Desktop:
  /desktop/vnc.html?autoconnect=true&resize=scale&path=websockify

Terminal:
  /terminal/

Prompt:
  root@ubuntu24:~#

Important:
  You are already root inside Ubuntu.
  Use apt directly; do not use sudo.

EOF

while true; do
  for index in "${!PIDS[@]}"; do
    pid="${PIDS[$index]}"
    name="${NAMES[$index]}"

    if ! kill -0 "$pid" 2>/dev/null; then
      status=unknown
      wait "$pid" 2>/dev/null || status="$?"
      die "$name exited with status $status. Check $LOG_DIR/${name}.log"
    fi
  done

  if [[ -n "${XSERVER_PID:-}" ]] && ! kill -0 "$XSERVER_PID" 2>/dev/null; then
    log "Xvfb launcher exited; keeping web services alive."
    unset XSERVER_PID
  fi

  if [[ -n "${FLUXBOX_PID:-}" ]] && ! kill -0 "$FLUXBOX_PID" 2>/dev/null; then
    log "Fluxbox exited; keeping web services alive."
    unset FLUXBOX_PID
  fi

  if [[ -n "${XTERM_PID:-}" ]] && ! kill -0 "$XTERM_PID" 2>/dev/null; then
    log "Desktop terminal exited; browser terminal remains available."
    unset XTERM_PID
  fi

  if [[ -n "${X11VNC_PID:-}" ]] && ! kill -0 "$X11VNC_PID" 2>/dev/null; then
    log "x11vnc exited; restarting it..."

    x11vnc \
      -display "$DISPLAY" \
      -rfbport "$VNC_PORT" \
      -rfbauth "$VNC_DIR/passwd" \
      -localhost \
      -forever \
      -shared \
      -noxdamage \
      >"$LOG_DIR/x11vnc.log" 2>&1 &

    X11VNC_PID="$!"
    sleep 1

    if ! kill -0 "$X11VNC_PID" 2>/dev/null; then
      log "x11vnc restart failed. Desktop is unavailable, but terminal remains online."
      unset X11VNC_PID
    fi
  fi

  sleep 2
done
