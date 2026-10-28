# Dokploy Coexistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable zero-conflict, seamless coexistence between Dokploy (Traefik on ports 80/443) and our VPN stack (AmneziaWG, 3X-UI, Wstunnel, Next-Gen protocols).

**Architecture:** Dokploy retains exclusive ownership of ports 80/443 (HTTP/HTTPS) and its dashboard (port 3000). Our VPN stack runs in Coexistence Mode: 3X-UI runs locally (:10443) and is exposed via Traefik; AmneziaWG runs natively in the Linux kernel on UDP (:8443/:51820) with Wstunnel WebSocket fallback via Traefik; and Next-Gen protocols (MASQUE, ShadowTLS, Zapret) run alongside in Docker/Dokploy Compose.

**Tech Stack:** Bash, Python 3, Docker, Traefik v2/v3, WireGuard/AmneziaWG DKMS, Xray-core / 3X-UI.

---

### Task 1: Auto-detection and CLI flag for Dokploy (`--dokploy`)

**Files:**
- Modify: `src/entrypoints/setup.main.sh:45-90`
- Modify: `src/common/preflight.sh:230-250`
- Modify: `src/tui/prompts.sh` / `src/tui/wizard.sh`
- Test: `tests/test_dokploy_coexistence.py`

**Step 1: Write the failing test**
Create `tests/test_dokploy_coexistence.py` testing `--dokploy` flag parsing and Dokploy detection logic.

**Step 2: Run test to verify it fails**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: FAIL (file or feature not found).

**Step 3: Write minimal implementation**
- Support `--dokploy` in CLI arguments in `src/entrypoints/setup.main.sh`.
- Detect running Dokploy container or `dokploy-network` Docker network.
- When detected or requested, set `DOKPLOY_COEXISTENCE="y"`.

**Step 4: Run test to verify it passes**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: PASS.

**Step 5: Rebuild & Commit**
Run: `python scripts/build.py`

---

### Task 2: Fix Installation Plan & Config Validation for Dokploy Coexistence

**Files:**
- Modify: `src/system/env.sh`
- Modify: `src/installer/plan.sh`
- Test: `tests/test_dokploy_coexistence.py`

**Step 1: Write test for plan generation under Dokploy Coexistence**
Verify that when `DOKPLOY_COEXISTENCE=y`:
- `validate_installation_config` succeeds.
- `INSTALLATION_PLAN` includes `packages`, `kernel`, `panel` (3X-UI), `awg` (if selected), `firewall`, `verify`.
- Host Nginx stream router on 80/443 is omitted from the plan.

**Step 2: Run test to verify it fails**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: FAIL (currently dies or drops panel).

**Step 3: Write minimal implementation**
- Update `src/system/env.sh` and `src/installer/plan.sh` so `DOKPLOY_COEXISTENCE=y` keeps `panel` enabled without requiring Nginx on 80/443.
- Adjust firewall rules so UFW allows Traefik ports and AWG ports without conflicting with Docker chains.

**Step 4: Run test to verify it passes**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: PASS.

---

### Task 3: Traefik Dynamic Provider Configuration Generator

**Files:**
- Create: `src/panel/dokploy_traefik.py`
- Modify: `src/installer/panel.sh`
- Modify: `compose/docker-compose.dokploy.yml`
- Test: `tests/test_dokploy_coexistence.py`

**Step 1: Write test for Traefik dynamic router generator**
Verify that generating dynamic config produces valid Traefik YAML with routers for 3X-UI panel (`panel.<domain>`), Subscriptions (`sub.<domain>`), and optional xHTTP stream (`vless.<domain>`).

**Step 2: Run test to verify it fails**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: FAIL.

**Step 3: Implement Traefik config generator**
- Generate `compose/dokploy-traefik-dynamic.yml` with routers pointing to `host.docker.internal:10443` and `host.docker.internal:55443` with TLS certresolver `letsencrypt`.
- Provide instructions and export helpers.

**Step 4: Run test to verify it passes**
Run: `python -m unittest tests.test_dokploy_coexistence`
Expected: PASS.

---

### Task 4: Dokploy Management CLI Helpers (`manage-services.sh`)

**Files:**
- Modify: `src/entrypoints/manage-services.main.sh`
- Modify: `docs/NEXTGEN_PROTOCOLS_DOKPLOY.md`
- Test: `tests/test_dokploy_coexistence.py`

**Step 1: Write test for manage-services dokploy commands**
Verify `./manage-services.sh status` and `./manage-services.sh dokploy-export` return correct output.

**Step 2: Run test and implement updates**
Enhance `./manage-services.sh` to output clear step-by-step instructions for the Dokploy UI.

**Step 3: Rebuild monolithic scripts & Run full test suite**
Run: `python scripts/build.py`
Run: `pytest`
Expected: ALL PASS.
