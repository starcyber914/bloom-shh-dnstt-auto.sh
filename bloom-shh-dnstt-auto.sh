#!/bin/bash
# ============================================
# BLOOM SSH DNSTT AUTO INSTALL (INTERACTIVE TDOMAIN)
# Stable • Clean • Production ready
# NO AUTO RESTART • NO AUTO REBOOT
# ============================================
set -euo pipefail

############################
# CONFIG (Interactive)
############################
read -p "Enter your TDOMAIN (e.g., ns-sn.example.online): " TDOMAIN
MTU=1800
DNSTT_PORT=5300
DNS_PORT=53
############################

echo "==> BLOOM SSH DNSTT AUTO INSTALL STARTING..."

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Run as root: sudo bash bloom-ssh-dnstt-auto.sh"
  exit 1
fi

# Stop conflicting services
echo "==> Stopping old services..."
for svc in dnstt dnstt-server slowdns dnstt-smart dnstt-bloom-ssh dnstt-bloom-ssh-proxy; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

# systemd-resolved fix
if [ -f /etc/systemd/resolved.conf ]; then
  echo "==> Configuring systemd-resolved..."
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf || true
  grep -q '^DNS=' /etc/systemd/resolved.conf \
    && sed -i 's/^DNS=.*/DNS=8.8.8.8 8.8.4.4/' /etc/systemd/resolved.conf \
    || echo "DNS=8.8.8.8 8.8.4.4" >> /etc/systemd/resolved.conf
  systemctl restart systemd-resolved
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

# Dependencies
echo "==> Installing dependencies..."
apt update -y
apt install -y curl python3

# Install dnstt-server
echo "==> Installing dnstt-server..."
install -m 755 <(curl -fsSL https://dnstt.network/dnstt-server-linux-amd64) /usr/local/bin/dnstt-server

# Keys
echo "==> Generating keys..."
mkdir -p /etc/dnstt
if [ ! -f /etc/dnstt/server.key ]; then
  dnstt-server -gen-key \
    -privkey-file /etc/dnstt/server.key \
    -pubkey-file  /etc/dnstt/server.pub
fi
chmod 600 /etc/dnstt/server.key
chmod 644 /etc/dnstt/server.pub

# DNSTT service
echo "==> Creating bloom-ssh-dnstt.service..."
cat >/etc/systemd/system/bloom-ssh-dnstt.service <<EOF
[Unit]
Description=Bloom SSH DNSTT Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server \\
  -udp :${DNSTT_PORT} \\
  -mtu ${MTU} \\
  -privkey-file /etc/dnstt/server.key \\
  ${TDOMAIN} 127.0.0.1:22
Restart=no
KillSignal=SIGTERM
TimeoutStopSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# EDNS proxy
echo "==> Installing EDNS proxy..."
cat >/usr/local/bin/dnstt-edns-proxy.py <<'EOF'
#!/usr/bin/env python3
import socket, threading, struct

LISTEN_HOST="0.0.0.0"
LISTEN_PORT=53
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT=5300

EXTERNAL_EDNS_SIZE=512
INTERNAL_EDNS_SIZE=1800

def patch(data,size):
    if len(data)<12: return data
    try:
        qd,an,ns,ar=struct.unpack("!HHHH",data[4:12])
    except: return data
    off=12
    def skip_name(b,o):
        while o<len(b):
            l=b[o]; o+=1
            if l==0: break
            if l&0xC0==0xC0: o+=1; break
            o+=l
        return o
    for _ in range(qd):
        off=skip_name(data,off); off+=4
    for _ in range(an+ns):
        off=skip_name(data,off)
        if off+10>len(data): return data
        _,_,_,l=struct.unpack("!HHIH",data[off:off+10])
        off+=10+l
    new=bytearray(data)
    for _ in range(ar):
        off=skip_name(data,off)
        if off+10>len(data): return data
        t=struct.unpack("!H",data[off:off+2])[0]
        if t==41:
            new[off+2:off+4]=struct.pack("!H",size)
            return bytes(new)
        _,_,l=struct.unpack("!HIH",data[off+2:off+10])
        off+=10+l
    return data

def handle(sock,data,addr):
    u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    u.settimeout(5)
    try:
        u.sendto(patch(data,INTERNAL_EDNS_SIZE),(UPSTREAM_HOST,UPSTREAM_PORT))
        r,_=u.recvfrom(4096)
        sock.sendto(patch(r,EXTERNAL_EDNS_SIZE),addr)
    except:
        pass
    finally:
        u.close()

s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind((LISTEN_HOST,LISTEN_PORT))
while True:
    d,a=s.recvfrom(4096)
    threading.Thread(target=handle,args=(s,d,a),daemon=True).start()
EOF

chmod +x /usr/local/bin/dnstt-edns-proxy.py

# Proxy service
echo "==> Creating bloom-ssh-dnstt-proxy.service..."
cat >/etc/systemd/system/bloom-ssh-dnstt-proxy.service <<EOF
[Unit]
Description=Bloom SSH DNSTT EDNS Proxy
After=network-online.target bloom-ssh-dnstt.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/dnstt-edns-proxy.py
Restart=no
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

# Firewall
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp || true
  ufw allow 53/udp || true
fi

# Start services
systemctl daemon-reload
systemctl enable bloom-ssh-dnstt.service
systemctl enable bloom-ssh-dnstt-proxy.service
systemctl start bloom-ssh-dnstt.service
systemctl start bloom-ssh-dnstt-proxy.service

echo "======================================"
echo " BLOOM SSH DNSTT INSTALLED SUCCESSFULLY "
echo "======================================"
echo "DOMAIN  : ${TDOMAIN}"
echo "MTU     : ${MTU}"
echo "PUBLIC KEY:"
cat /etc/dnstt/server.pub
echo "======================================"
