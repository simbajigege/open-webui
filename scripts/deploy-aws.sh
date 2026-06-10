#!/bin/bash
set -e

# ============================================================
# Open WebUI - AWS Deployment Script
# Deploys open-webui to the production server.
# Connects to hermes-agent API server on port 8642.
#
# Usage: bash scripts/deploy-aws.sh
#
# Reads API key from your LOCAL ~/.hermes/.env
# ============================================================

PORT=22
SSH_URL=root@34.230.59.2
APP_DIR=/app/open-webui

# --- Read API key from local hermes env ---
LOCAL_ENV=~/.hermes/.env

if [ ! -f "$LOCAL_ENV" ]; then
  echo "ERROR: $LOCAL_ENV not found"
  exit 1
fi

API_SERVER_KEY=$(grep '^API_SERVER_KEY=' "$LOCAL_ENV" | cut -d= -f2-)

if [ -z "$API_SERVER_KEY" ]; then
  echo "ERROR: API_SERVER_KEY not found in $LOCAL_ENV"
  exit 1
fi

echo "Deploying Open WebUI to $SSH_URL..."

ssh -p $PORT $SSH_URL bash << ENDSSH
set -e

# 1. Clone or pull latest code
if [ -d "$APP_DIR" ]; then
  echo "Pulling latest code..."
  cd $APP_DIR && git pull --ff-only
else
  echo "Cloning repo..."
  cd /app && git clone https://github.com/simbajigege/open-webui
fi

cd $APP_DIR

# 2. Install Node.js 22 if needed (open-webui requires >=18 <=22)
NODE_MAJOR=\$(node -e 'process.exit(parseInt(process.versions.node))' 2>/dev/null; echo \$?)
if ! command -v node &>/dev/null || node -e 'const v=parseInt(process.versions.node); if(v<18||v>22) process.exit(1)' 2>/dev/null; then
  echo "Installing Node.js 22..."
  curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
  yum install -y nodejs 2>/dev/null || apt-get install -y nodejs 2>/dev/null || true
  hash -r
fi

# 3. Build frontend
echo "Building frontend..."
npm_config_engine_strict=false npm ci --quiet
npm run build

# 4. Install Python backend dependencies
echo "Installing Python dependencies..."
pip install -r backend/requirements.txt --quiet

# 5. Write .env
WEBUI_SECRET_KEY=\$(openssl rand -hex 32)

# Preserve existing secret key if already set (avoids invalidating all sessions)
EXISTING_ENV="$APP_DIR/.env"
if [ -f "\$EXISTING_ENV" ]; then
  EXISTING_SECRET=\$(grep '^WEBUI_SECRET_KEY=' "\$EXISTING_ENV" | cut -d= -f2-)
  if [ -n "\$EXISTING_SECRET" ]; then
    WEBUI_SECRET_KEY=\$EXISTING_SECRET
  fi
fi

cat > $APP_DIR/.env << EOF
OPENAI_API_BASE_URL=http://127.0.0.1:8642/v1
OPENAI_API_KEY=${API_SERVER_KEY}
ENABLE_OLLAMA_API=false
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-User-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-User-Name
WEBUI_SECRET_KEY=\${WEBUI_SECRET_KEY}
PORT=8080
EOF

# 6. Stop existing process if running
if [ -f "$APP_DIR/webui.pid" ]; then
  OLD_PID=\$(cat "$APP_DIR/webui.pid")
  if kill -0 "\$OLD_PID" 2>/dev/null; then
    echo "Stopping existing Open WebUI (PID \$OLD_PID)..."
    kill "\$OLD_PID"
    sleep 2
  fi
  rm -f "$APP_DIR/webui.pid"
fi

# 7. Start Open WebUI
cd $APP_DIR
nohup env \$(cat .env | grep -v '^#' | xargs) \
  PYTHONPATH=./backend \
  uvicorn open_webui.main:app --host 127.0.0.1 --port 8080 \
  > $APP_DIR/webui.log 2>&1 &
echo \$! > $APP_DIR/webui.pid
echo "Open WebUI started (PID \$(cat $APP_DIR/webui.pid))"

# 8. Wait and verify
sleep 15
if curl -sf http://127.0.0.1:8080/health > /dev/null; then
  echo "Open WebUI is up at http://127.0.0.1:8080"
else
  echo "WARNING: Health check failed. Check $APP_DIR/webui.log"
  tail -20 $APP_DIR/webui.log
fi

ENDSSH

echo ""
echo "Deploy complete."
echo "Tail logs: ssh $SSH_URL 'tail -f $APP_DIR/webui.log'"
