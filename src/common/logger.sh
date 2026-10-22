# Standard Logging Functions
log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK:-✔}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  {
    echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2
    if is_true "${DEBUG_MODE:-0}" && command -v offer_debug_log_export >/dev/null 2>&1; then
        offer_debug_log_export || true
    fi
    exit 1
}
