#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "⚠️  Please run as root: sudo $0"
  exit 1
fi

apt update
apt install -y python3 curl

cat << 'PYTHON_EOF' > /usr/local/bin/discord_ssh_notify.py
#!/usr/bin/env python3
import re, time, json, logging, socket
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

CONFIG_PATH = Path('/etc/discord_ssh_notify/config.json')
LOG_PATH = '/var/log/auth.log'

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

if not CONFIG_PATH.exists():
    logging.error(f"Config file not found: {CONFIG_PATH}")
    exit(1)
cfg = json.loads(CONFIG_PATH.read_text())
WEBHOOK_URL = cfg.get('webhook_url')
SERVER_NAME = cfg.get('server_name', socket.gethostname()) or 'unknown'
if not WEBHOOK_URL:
    logging.error("Missing webhook_url in config.")
    exit(1)

RE_LOGIN      = re.compile(r"sshd\[(?P<pid>\d+)\]: Accepted .* for (?P<user>\S+) from (?P<ip>\d+\.\d+\.\d+\.\d+)")
RE_FAIL_SSH   = re.compile(r"sshd\[(?P<pid>\d+)\]: Failed (?:password|publickey|keyboard-interactive) for (?:invalid user )?(?P<user>\S+) from (?P<ip>\d+\.\d+\.\d+\.\d+)")
RE_PREAUTH    = re.compile(r"sshd\[(?P<pid>\d+)\]: Connection closed by authenticating user (?P<user>\S+) (?P<ip>\d+\.\d+\.\d+\.\d+)")
RE_FAIL_PAM   = re.compile(r"sshd\[(?P<pid>\d+)\]: authentication failure;.*rhost=(?P<ip>\d+\.\d+\.\d+\.\d+)")
RE_SUDO       = re.compile(r"sudo: (?P<user>\S+) : TTY=.* ; PWD=.* ; USER=(?P<target>\S+) ; COMMAND=(?P<cmd>.+)")
RE_DISCONNECT = re.compile(r"sshd\[(?P<pid>\d+)\]: Disconnected from user (?P<user>\S+) (?P<ip>\d+\.\d+\.\d+\.\d+)")
RE_PAM_CLOSE  = re.compile(r"sshd\[(?P<pid>\d+)\]: pam_unix\(sshd:session\): session closed for user (?P<user>\S+)")

sessions = {}

def send_webhook(content: str):
    data = json.dumps({"content": content}).encode('utf-8')
    headers = {'Content-Type': 'application/json', 'User-Agent': 'DiscordSSHNotifier/1.0'}
    req = Request(WEBHOOK_URL, data=data, headers=headers)
    try:
        with urlopen(req) as resp:
            if resp.status not in (200, 204): logging.warning(f"Unexpected status: {resp.status}")
    except (HTTPError, URLError) as e:
        logging.error(f"Webhook error: {e}")

if __name__ == '__main__':
    logging.info("Starting Discord SSH notifier…")
    try:
        with open(LOG_PATH, 'r', encoding='utf-8', errors='ignore') as f:
            f.seek(0, 2)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.2)
                    continue
                m = RE_LOGIN.search(line)
                if m:
                    pid, user, ip = m.group('pid'), m.group('user'), m.group('ip')
                    sessions[pid] = ip
                    send_webhook(f"🔓 **{SERVER_NAME}**: `{user}` logged in from `{ip}` (pid {pid})")
                    continue
                if (m := RE_FAIL_SSH.search(line)):
                    send_webhook(f"❗ **{SERVER_NAME}**: Failed login for `{m.group('user')}` from `{m.group('ip')}`")
                    continue
                if (m := RE_PREAUTH.search(line)):
                    send_webhook(f"❗ **{SERVER_NAME}**: Connection closed during auth for `{m.group('user')}` from `{m.group('ip')}`")
                    continue
                if (m := RE_FAIL_PAM.search(line)):
                    send_webhook(f"❗ **{SERVER_NAME}**: Authentication failure from `{m.group('ip')}`")
                    continue
                if (m := RE_SUDO.search(line)):
                    send_webhook(f"🛡️ **{SERVER_NAME}**: `{m.group('user')}` ran `{m.group('cmd').strip()}` as `{m.group('target')}`")
                    continue
                if (m := RE_DISCONNECT.search(line)):
                    pid, user, ip = m.group('pid'), m.group('user'), m.group('ip')
                    if pid in sessions:
                        send_webhook(f"🔌 **{SERVER_NAME}**: `{user}` disconnected from `{ip}` (pid {pid})")
                    continue
                if (m := RE_PAM_CLOSE.search(line)):
                    pid, user = m.group('pid'), m.group('user')
                    ip = sessions.pop(pid, None)
                    if ip:
                        send_webhook(f"🔒 **{SERVER_NAME}**: `{user}` logged out from `{ip}` (pid {pid})")
                    continue
    except KeyboardInterrupt:
        logging.info("Shutting down.")
PYTHON_EOF

chmod +x /usr/local/bin/discord_ssh_notify.py
echo "✔️  Installed /usr/local/bin/discord_ssh_notify.py"

read -p "Server name (leave blank to use hostname): " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-$(hostname)}

while true; do
  read -p "Enter your Discord Webhook URL: " WEBHOOK_URL
  echo "⏳ Testing webhook..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: DiscordSSHNotifier/1.0" \
    -d "{\"content\":\"✅ Test notification from installer on $SERVER_NAME.\"}" \
    "$WEBHOOK_URL")
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    echo "✅ Webhook is valid."
    break
  else
    echo "❌ Received HTTP $HTTP_CODE. Please try again."
  fi
done

mkdir -p /etc/discord_ssh_notify
cat << EOF > /etc/discord_ssh_notify/config.json
{
  "webhook_url": "$WEBHOOK_URL"$( [ -n "$SERVER_NAME" ] && echo ",
  \"server_name\": \"$SERVER_NAME\"" )
}
EOF
chmod 600 /etc/discord_ssh_notify/config.json
echo "✔️  Wrote /etc/discord_ssh_notify/config.json"

cat << 'SERVICE_EOF' > /etc/systemd/system/discord-ssh-notify.service
[Unit]
Description=Discord SSH Login/Logout/Fail Notifier
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/discord_ssh_notify.py
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable --now discord-ssh-notify
echo "✔️  Service discord-ssh-notify enabled and started."

echo "🚀 Tailing notifier logs. Press Ctrl-C to exit."
exec journalctl -u discord-ssh-notify -f
