#!/bin/bash

ls /sys/module/ttm    2>/dev/null && echo "Confirming we are using ttm"

modinfo -p ttm    2>/dev/null || true

sudo tee /etc/modprobe.d/ttm.conf >/dev/null <<'EOF'
options ttm pages_limit=31457280 page_pool_size=31457280
EOF

sudo dracut -f --regenerate-all
sudo reboot