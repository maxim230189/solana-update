#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Agave updater (fixed version, NO service edits)
# - Ставит зависимости и Rust/cargo (идемпотентно)
# - Качает исходники ТОЛЬКО нужного тега v$VERSION
# - Собирает ТОЛЬКО валидатор в .../releases/$VERSION/solana-release
# - Переключает .../active_release -> нужный релиз
# - Берёт --ledger/--snapshots из service-файла (ТОЛЬКО ЧТЕНИЕ)
# - Ждёт «окно рестарта» и мягко рестартит service
# -----------------------------------------------------------------------------
set -Eeuo pipefail
log(){ printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
trap 'log "❌ Ошибка на строке $LINENO. Прерываю."' ERR

# >>>>>>>>>>>>>>> РЕДАКТИРУЙ ТОЛЬКО ЭТО <<<<<<<<<<<<<<
VERSION="3.0.1"           # нужная версия Agave (без 'v'), например 3.0.1
MIN_IDLE_MINUTES=10        # сколько ждать «тихое окно», минут (обычно 5–10)
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

# Пути установки
INSTALL_ROOT="/root/.local/share/solana/install"
INSTALL_DIR="$INSTALL_ROOT/releases/$VERSION/solana-release"
ACTIVE_LINK="$INSTALL_ROOT/active_release"

WORK="/tmp/agave-src-$VERSION"
TARBALL="v$VERSION.tar.gz"
URL="https://github.com/anza-xyz/agave/archive/refs/tags/$TARBALL"

# Проверка прав
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "⚠️  Нужны root-права. Запусти: sudo bash agave-update-fixed.sh"; exit 1
fi

log "▶️  Обновление Agave до v$VERSION (юнит НЕ изменяем)"

# 0) Зависимости
export DEBIAN_FRONTEND=noninteractive
log "🔧 Устанавливаю зависимости (idempotent)..."
apt-get update -y
apt-get install -y build-essential pkg-config libssl-dev zlib1g-dev \
  libudev-dev llvm clang libclang-dev cmake protobuf-compiler curl git jq

# 1) Rust/cargo
if ! command -v cargo >/dev/null 2>&1; then
  log "🦀 Устанавливаю Rust toolchain..."
  curl -sSf https://sh.rustup.rs | sh -s -- -y
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
log "✅ Cargo: $(cargo --version 2>/dev/null || echo 'не найден')"

# 2) Читаем активный service-файл (ТОЛЬКО ЧТЕНИЕ)
SERVICE_FILE="$(systemctl show -p FragmentPath solana | awk -F= '{print $2}')"
[[ -z "$SERVICE_FILE" || ! -f "$SERVICE_FILE" ]] && SERVICE_FILE="/etc/systemd/system/solana.service"
log "📄 Читаю пути из service-файла: $SERVICE_FILE"

LEDGER="$(grep -Po '(?<=--ledger )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
SNAPS="$(grep -Po '(?<=--snapshots )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
if [[ -z "$LEDGER" ]]; then
  LEDGER="/mnt/ramdisk/ledger"
  log "ℹ️  --ledger не найден, использую дефолт: $LEDGER"
else
  log "📌 ledger: $LEDGER"
fi
[[ -n "$SNAPS" ]] && log "📌 snapshots: $SNAPS" || log "ℹ️  --snapshots не задан"

# Подсказки (не правим юнит)
if ! grep -q 'LimitMEMLOCK=2000000000' "$SERVICE_FILE" 2>/dev/null; then
  log "⚠️  Рекомендую добавить LimitMEMLOCK=2000000000 в [Service] (требование Agave 3.x)"
fi
if grep -q -- '--dynamic-port-range [0-9]\{1,5\}-[0-9]\{1,5\}' "$SERVICE_FILE"; then
  WIDTH="$(grep -Po -- '--dynamic-port-range \K[0-9]+-[0-9]+' "$SERVICE_FILE" | awk -F- '{print $2-$1}' | head -n1 || echo 0)"
  [[ "${WIDTH:-0}" -lt 25 ]] && log "⚠️  Расширь --dynamic-port-range минимум до 25 портов"
fi

# 3) Сборка указанной версии (если ещё не собрана)
if [[ -x "$INSTALL_DIR/bin/agave-validator" ]]; then
  log "✅ Уже собрано: $INSTALL_DIR (пропускаю сборку)"
else
  log "⬇️  Скачиваю исходники: $URL"
  rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
  curl -fsSL -o "$TARBALL" "$URL"
  tar -xzf "$TARBALL"

  log "🛠️  Собираю ТОЛЬКО валидатор в $INSTALL_DIR ..."
  mkdir -p "$INSTALL_DIR"
  export OPENSSL_DIR=/usr
  export OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu
  export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
  bash "agave-$VERSION/scripts/cargo-install-all.sh" --validator-only "$INSTALL_DIR"
fi

# 4) Переключаем active_release на нужный релиз
log "🔗 Переключаю active_release -> $INSTALL_DIR"
ln -sfn "$INSTALL_DIR" "$ACTIVE_LINK"

# 5) Если уже активна нужная версия — выходим без рестарта
if [[ -x "$ACTIVE_LINK/bin/agave-validator" ]]; then
  ACTIVE_VER="$("$ACTIVE_LINK/bin/agave-validator" --version 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$ACTIVE_VER" == "$VERSION" ]]; then
    log "✅ Указанная версия уже активна: $ACTIVE_VER. Рестарт не требуется."
    exit 0
  fi
fi

# 6) Ждём «окно рестарта» и перезапускаем сервис
BIN="$ACTIVE_LINK/bin/agave-validator"
log "⏳ Жду «окно» ~${MIN_IDLE_MINUTES} мин (max delinquent 10%)..."
ARGS=(wait-for-restart-window --min-idle-time "$MIN_IDLE_MINUTES" --max-delinquent-stake 10)
if [[ -n "$SNAPS" ]]; then
  "$BIN" --ledger "$LEDGER" --snapshots "$SNAPS" "${ARGS[@]}"
else
  "$BIN" --ledger "$LEDGER" "${ARGS[@]}"
fi

log "♻️  Перезапускаю сервис solana (юнит не меняю)..."
systemctl restart solana

# 7) Отчёт
sleep 2
NEW_VER="$("$BIN" --version 2>/dev/null || true)"
log "✅ Готово. Текущая версия: ${NEW_VER:-<не удалось прочитать>}"
log "📂 active_release -> $(readlink -f "$ACTIVE_LINK")"
log "📌 ledger: $LEDGER"
[[ -n "$SNAPS" ]] && log "📌 snapshots: $SNAPS"
