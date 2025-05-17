#!/bin/bash

cat <<EOF | sudo tee /etc/systemd/system/ssh-log.service
[Unit]
Description=SSH Log Redirect

[Service]
ExecStart=/usr/bin/journalctl -f -u ssh.service
StandardOutput=append:/var/log/auth.log
StandardError=append:/var/log/auth.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

sudo systemctl enable --now ssh-log.service

sudo systemctl status ssh-log.service
