# SQLite WAL-safe live database backup and verification
get_sqlite_backup_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import sqlite3" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import sqlite3" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import sqlite3" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="$2"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ]; then
        "$py_cmd" -c "
import sqlite3, sys
try:
    conn = sqlite3.connect(sys.argv[1])
    res = conn.execute('PRAGMA integrity_check;').fetchall()
    conn.close()
    if res and res[0][0] == 'ok':
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$bkp" 2>/dev/null && return 0
    elif command -v sqlite3 >/dev/null 2>&1; then
        local check
        check=$(sqlite3 "$bkp" "PRAGMA integrity_check;" 2>/dev/null || true)
        [ "$check" = "ok" ] && return 0
    fi
    return 1
}

backup_sqlite_db() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        return 1
    fi
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || true)

    local backup_ok=0

    # 1. Primary: Python SQLite Online Backup API (atomic, WAL-safe)
    if [ -n "$py_cmd" ]; then
        if "$py_cmd" -c "
import sqlite3, sys
src_p, dst_p = sys.argv[1], sys.argv[2]
try:
    try:
        src_conn = sqlite3.connect(f'file:{src_p}?mode=ro', uri=True)
    except Exception:
        src_conn = sqlite3.connect(src_p)
    dst_conn = sqlite3.connect(dst_p)
    with dst_conn:
        src_conn.backup(dst_conn)
    dst_conn.close()
    src_conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$src" "$dst" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    # 2. Secondary: sqlite3 CLI .backup command (atomic, WAL-safe)
    if [ "$backup_ok" -eq 0 ] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$src" ".backup '$dst'" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    if [ "$backup_ok" -eq 1 ]; then
        chmod 600 "$dst" 2>/dev/null || true
        return 0
    fi

    # Never silently downgrade to raw cp of a live WAL database; fail safe and clean up
    rm -f "$dst" 2>/dev/null || true
    return 1
}
