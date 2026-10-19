#!/bin/sh
set -e

QNUM="${ZAPRET_QNUM:-200}"
DESYNC_MODE="${ZAPRET_DESYNC:-split2}"
FOOLING="${ZAPRET_FOOLING:-md5sig,badseq}"

cleanup() {
    echo "[Zapret] Завершение работы, удаление правил NFQUEUE из iptables..."
    iptables -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM EXIT

echo "[Zapret] Установка правила iptables connbytes 1:6 в таблицу mangle (очередь $QNUM)..."
# Удаляем старое правило, если осталось от прошлого запуска
iptables -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true

# Вставляем правило в начало POSTROUTING с --queue-bypass (гарантия отсутствия блокировки трафика при остановке)
iptables -t mangle -I POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass

echo "[Zapret] Запуск nfqws (queue: $QNUM, desync: $DESYNC_MODE, fooling: $FOOLING)..."
exec nfqws --qnum="$QNUM" --dpi-desync="$DESYNC_MODE" --dpi-desync-fooling="$FOOLING"
