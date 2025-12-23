#!/usr/bin/env bash
# agave-update-fixed.sh — всегда рестартует и печатает запущенную версию
set -Eeuo pipefail
log(){ printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
trap 'log "❌ Ошибка на строке $LINENO. Прерываю."' ERR

# >>> РЕДАКТИРУЙ ТОЛЬКО ЭТО <<<
VERSION="3.1.5"        # нужная версия Agave (без префикса v)
MIN_IDLE_MINUTES=5     # сколько ждать «тихое окно» перед рестартом
# <<< РЕДАКТИРУЙ ТОЛЬКО ЭТО >>>

INSTALL_ROOT="/root/.local/share/solana/install"
INSTALL_DIR="$INSTALL_ROOT/releases/$VERSION/solana-release"
ACTIVE_LINK="$INSTALL_ROOT/active_release"
WORK="/tmp/agave-src-$VERSION"
TARBALL="v$VERSION.tar.gz"
URL="https://github.com/anza-xyz/agave/archive/refs/tags/$TARBALL"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { log "Нужен root"; exit 1; }

log "▶️  Обновление Agave до v$VERSION"

# 0) deps
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y build-essential pkg-config libssl-dev zlib1g-dev \
  libudev-dev llvm clang libclang-dev cmake protobuf-compiler curl git jq

# 1) cargo
if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi

# 2) прочитаем пути из service-файла (ТОЛЬКО чтение)
SERVICE_FILE="$(systemctl show -p FragmentPath solana | awk -F= '{print $2}')"
[[ -z "$SERVICE_FILE" || ! -f "$SERVICE_FILE" ]] && SERVICE_FILE="/etc/systemd/system/solana.service"
LEDGER="$(grep -Po '(?<=--ledger )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
SNAPS="$(grep -Po '(?<=--snapshots )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
[[ -z "$LEDGER" ]] && LEDGER="/mnt/ramdisk/ledger"
log "📌 ledger: ${LEDGER}"; [[ -n "$SNAPS" ]] && log "📌 snapshots: $SNAPS" || log "ℹ️ snapshots не указан"

# 3) сборка версии (если ещё не собрана)
if [[ ! -x "$INSTALL_DIR/bin/agave-validator" ]]; then
  log "⬇️  Качаю исходники $URL"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
  curl -fsSL -o "$TARBALL" "$URL"; tar -xzf "$TARBALL"
  log "🛠️  Собираю validator-only в $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  export OPENSSL_DIR=/usr OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
  bash "agave-$VERSION/scripts/cargo-install-all.sh" --validator-only "$INSTALL_DIR"
else
  log "✅ Версия v$VERSION уже собрана: $INSTALL_DIR"
fi

# 4) переключаем active_release (ВСЕГДА)
ln -sfn "$INSTALL_DIR" "$ACTIVE_LINK"
BIN="$ACTIVE_LINK/bin/agave-validator"
log "🔗 active_release -> $(readlink -f "$ACTIVE_LINK")"

# 5) ждём «тихое окно» и ВСЕГДА рестартуем
ARGS=(wait-for-restart-window --min-idle-time "$MIN_IDLE_MINUTES" --max-delinquent-stake 10)
log "⏳ Жду окно ~${MIN_IDLE_MINUTES} мин перед рестартом..."
if [[ -n "$SNAPS" ]]; then
  "$BIN" --ledger "$LEDGER" --snapshots "$SNAPS" "${ARGS[@]}"
else
  "$BIN" --ledger "$LEDGER" "${ARGS[@]}"
fi

log "♻️  Перезапускаю сервис solana..."
systemctl restart solana

# 6) ждём, пока поднимется процесс, и печатаем ФАКТИЧЕСКУЮ версию запущенного exe
log "🔍 Жду процесс agave-validator..."
for i in {1..60}; do
  if pidof agave-validator >/dev/null; then break; fi
  sleep 1
done

if pidof agave-validator >/dev/null; then
  EXE="$(readlink -f /proc/$(pidof agave-validator)/exe)"
  RUN_VER="$("$EXE" --version 2>/dev/null || true)"
  log "✅ Запущено: $EXE"
  log "✅ Версия процесса: ${RUN_VER:-<не удалось прочитать>}"
else
  log "⚠️  Процесс не найден. Проверь: journalctl -u solana -f"
fi
