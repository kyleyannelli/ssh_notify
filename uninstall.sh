#!/usr/bin/env bash
if [ "$EUID" -ne 0 ]; then
  echo "⚠️  Please run as root: sudo $0"
  exit 1
fi

echo "🚨 Stopping and disabling service..."
systemctl stop discord-ssh-notify.service || true
systemctl disable discord-ssh-notify.service || true

echo "🗑️  Removing systemd unit and reloading daemon..."
rm -f /etc/systemd/system/discord-ssh-notify.service
systemctl daemon-reload

echo "🗑️  Removing notifier script..."
rm -f /usr/local/bin/discord_ssh_notify.py

echo "🗑️  Removing config files..."
rm -rf /etc/discord_ssh_notify

echo "✅ Uninstall complete."
