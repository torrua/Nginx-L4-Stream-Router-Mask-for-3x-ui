# SQLite WAL-safe live database backup
backup_sqlite_db() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        return 1
    fi
    local py_cmd="${PYTHON_CMD:-python3}"
    if ! command -v "$py_cmd" >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            py_cmd="python3"
        elif command -v python >/dev/null 2>&1; then
            py_cmd="python"
        fi
    fi

    if command -v "$py_cmd" >/dev/null 2>&1; then
        if "$py_cmd" -c "
import sqlite3, sys
src_p, dst_p = sys.argv[1], sys.argv[2]
try:
    src_conn = sqlite3.connect(f'file:{src_p}?mode=ro', uri=True)
    dst_conn = sqlite3.connect(dst_p)
    with dst_conn:
        src_conn.backup(dst_conn)
    dst_conn.close()
    src_conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$src" "$dst" 2>/dev/null; then
            chmod 600 "$dst" 2>/dev/null || true
            return 0
        fi
    fi

    if command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$src" ".backup '$dst'" 2>/dev/null; then
            chmod 600 "$dst" 2>/dev/null || true
            return 0
        fi
    fi

    cp -a "$src" "$dst" 2>/dev/null && chmod 600 "$dst" 2>/dev/null || return 1
}
