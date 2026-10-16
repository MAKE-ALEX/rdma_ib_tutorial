#!/bin/bash
# =============================================================================
# DOCA/OFED 24.10 (DOCA 2.9.4) 在 Ubuntu 24.04 新内核上 DKMS 编译失败的修复
#
# 现象：
#   sudo apt-get install doca-ofed 后报
#     mlnx-ofed-kernel-dkms: Error! Bad return status for module build ...
#   随后 isert-dkms / iser-dkms / srp-dkms / doca-ofed 全部
#     "dependency problems - leaving unconfigured"
#   日志 /var/lib/dkms/mlnx-ofed-kernel/<ver>/build/make.log 里的真错误：
#     mlx5/core/en_main.c: error: 'UDP_TUNNEL_NIC_INFO_MAY_SLEEP' undeclared
#
# 原因：
#   内核 6.8.0-147（GA）与 7.0.0-38（HWE）起删除了 UDP_TUNNEL_NIC_INFO_MAY_SLEEP
#   这个 flag，并把其余 flag 的 BIT 位整体前移；OFED 24.10 的 mlx5 代码硬引用该
#   flag 且没有 compat 保护，于是编译失败。NVIDIA 在 OFED 25.10 / DOCA 3.2.3 里
#   才加上同样的 #ifdef 判断（DOCA 2.9.5 / 2.10.0 都还没有）。
#
# 适用范围（实测各内核头文件）：
#   有该 flag，无需修复：GA 6.8.0-31 … 6.8.0-146、HWE 6.11、HWE 6.14
#   已删除该 flag，需要修复：GA 6.8.0-147 及以后、HWE 7.0.0-38 及以后
#
# 用法：sudo bash ofed-maysleep-fix.sh
#       可重复执行；源码已打过补丁会自动跳过，内核已是旧版也会自动跳过。
#
# 回滚（万一）：cp -a <TARGET>.orig-<内核版本> <TARGET>
#               sudo rm -rf /var/lib/dkms/mlnx-ofed-kernel/<ver>/build
#               sudo dkms install mlnx-ofed-kernel/<ver> -k $(uname -r) --force
# =============================================================================
set -euo pipefail

OFED_VER=$(dkms status 2>/dev/null | awk -F'[/,]' '/^mlnx-ofed-kernel\// {print $2; exit}')
[ -n "${OFED_VER}" ] || OFED_VER=$(ls -d /usr/src/mlnx-ofed-kernel-* 2>/dev/null | head -1 | sed 's#.*/mlnx-ofed-kernel-##')
KVER=$(uname -r)
SRC="/usr/src/mlnx-ofed-kernel-${OFED_VER}"
TARGET="${SRC}/drivers/net/ethernet/mellanox/mlx5/core/en_main.c"

echo "== OFED 版本 : ${OFED_VER}"
echo "== 内核版本  : ${KVER}"
echo "== 目标文件  : ${TARGET}"

# --- 0. 先确认这个内核确实删掉了该 flag（grep 命中 = 旧内核，无需修） --------
if grep -q UDP_TUNNEL_NIC_INFO_MAY_SLEEP "/usr/src/linux-headers-${KVER}/include/net/udp_tunnel.h"; then
	echo "== 该内核仍提供 UDP_TUNNEL_NIC_INFO_MAY_SLEEP，无需修复，退出。"
	exit 0
fi

# --- 1. 备份原文件 ----------------------------------------------------------
if [ ! -f "${TARGET}.orig-${KVER}" ]; then
	cp -a "${TARGET}" "${TARGET}.orig-${KVER}"
	echo "== 已备份到 ${TARGET}.orig-${KVER}"
fi

# --- 2. 打补丁：用内核宏自身做条件，兼容 flag 存在与不存在两种情况 ----------
python3 - "${TARGET}" <<'PYEOF'
import sys
p = sys.argv[1]
guard = "#ifdef UDP_TUNNEL_NIC_INFO_MAY_SLEEP"
old = "\tpriv->nic_info.flags = UDP_TUNNEL_NIC_INFO_MAY_SLEEP |\n\t\t\t\tUDP_TUNNEL_NIC_INFO_STATIC_IANA_VXLAN;\n"
new = (guard + "\n"
       "\tpriv->nic_info.flags = UDP_TUNNEL_NIC_INFO_MAY_SLEEP |\n"
       "\t\t\t\tUDP_TUNNEL_NIC_INFO_STATIC_IANA_VXLAN;\n"
       "#else\n"
       "\t/* UDP_TUNNEL_NIC_INFO_MAY_SLEEP was removed from newer kernels */\n"
       "\tpriv->nic_info.flags = UDP_TUNNEL_NIC_INFO_STATIC_IANA_VXLAN;\n"
       "#endif\n")
s = open(p).read()
if guard in s:
	print("== 补丁已存在，跳过修改")
	sys.exit(0)
n = s.count(old)
if n != 1:
	sys.exit("== 错误：期望匹配 1 处，实际匹配 %d 处，未做任何修改" % n)
open(p, "w").write(s.replace(old, new))
print("== 补丁已写入 " + p)
PYEOF

# --- 3. 重建 DKMS（删掉上次失败的 build 目录，强制从打过补丁的源码重拷） ----
rm -rf "/var/lib/dkms/mlnx-ofed-kernel/${OFED_VER}/build"
dkms install "mlnx-ofed-kernel/${OFED_VER}" -k "${KVER}" --force

# --- 4. 收尾：把被依赖关系卡住的包配置完 ------------------------------------
dpkg --configure -a

# --- 5. 验证 ---------------------------------------------------------------
echo "========== 验证 =========="
dkms status
dpkg -l | grep -E 'mlnx-ofed-kernel-dkms|isert-dkms|iser-dkms|srp-dkms|doca-ofed' || true
ofed_info -s || true
if modprobe mlx5_core 2>/dev/null; then
	lsmod | grep -q mlx5_core && echo "== mlx5_core 加载正常"
	modprobe -r mlx5_core 2>/dev/null || true
else
	echo "== 提示：mlx5_core 加载失败（若机器上有网卡正在使用，属正常）"
fi
echo "== 完成"
