# =============================================================
#  ГЕНЕРАЦИЯ ВЫБРАННОЙ ВЕБ-МАСКИ
# =============================================================
    log "Формирование выбранного маскировочного портала..."

    if [ "$DECOY_MODE" = "1" ]; then
    # 1. DataSphere Analytics (SPA с 3D-сферой и телеметрией)
    mkdir -p "$WEBROOT/assets/css" "$WEBROOT/assets/js" "$WEBROOT/assets/img"

cat << 'EOF' > $WEBROOT/assets/img/favicon.svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="sphereGrad" cx="35%" cy="35%" r="65%">
      <stop offset="0%" stop-color="#a8c7fa"/>
      <stop offset="45%" stop-color="#008dd5"/>
      <stop offset="100%" stop-color="#0a192f"/>
    </radialGradient>
    <clipPath id="circleMask"><circle cx="50" cy="50" r="48"/></clipPath>
  </defs>
  <g clip-path="url(#circleMask)">
    <circle cx="50" cy="50" r="48" fill="url(#sphereGrad)"/>
    <g stroke="#ffffff" stroke-width="1.5" stroke-opacity="0.45" fill="none">
      <ellipse cx="50" cy="50" rx="46" ry="18"/>
      <ellipse cx="50" cy="50" rx="46" ry="32"/>
      <ellipse cx="50" cy="50" rx="18" ry="46"/>
      <ellipse cx="50" cy="50" rx="32" ry="46"/>
      <line x1="4" y1="50" x2="96" y2="50"/>
      <line x1="50" y1="4" x2="50" y2="96"/>
    </g>
    <circle cx="50" cy="50" r="6" fill="#81c995"/>
    <circle cx="28" cy="38" r="3.5" fill="#fdd663"/>
    <circle cx="72" cy="62" r="3.5" fill="#c58af9"/>
    <circle cx="70" cy="35" r="3" fill="#a8c7fa"/>
    <circle cx="32" cy="65" r="3" fill="#ffffff"/>
  </g>
  <circle cx="50" cy="50" r="48" fill="none" stroke="#a8c7fa" stroke-width="3" stroke-opacity="0.6"/>
</svg>
EOF
ln -sf $WEBROOT/assets/img/favicon.svg $WEBROOT/favicon.svg
ln -sf $WEBROOT/assets/img/favicon.svg $WEBROOT/favicon.ico

cat << 'EOF' > $WEBROOT/robots.txt
User-agent: *
Disallow: /api/
Disallow: /console/
Disallow: /telemetry/
Disallow: /cluster-internal/
Allow: /
EOF

cat << 'EOF' > $WEBROOT/assets/css/datasphere.css
:root {
    --bg-base: #0b0d10;
    --bg-surface: #13171d;
    --bg-card: #181d24;
    --border: rgba(255, 255, 255, 0.08);
    --border-hover: rgba(168, 199, 250, 0.35);
    --accent: #a8c7fa;
    --accent-glow: rgba(168, 199, 250, 0.15);
    --accent-purple: #c58af9;
    --text-primary: #e6edf3;
    --text-muted: #8b949e;
    --success: #81c995;
    --warning: #fdd663;
    --error: #f28b82;
    --terminal-bg: #090c10;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Google Sans", sans-serif;
    background-color: var(--bg-base);
    background-image:
        radial-gradient(circle at 50% -10%, rgba(66, 133, 244, 0.14) 0%, rgba(155, 114, 207, 0.08) 35%, transparent 70%),
        radial-gradient(circle at 100% 100%, rgba(129, 201, 149, 0.04) 0%, transparent 40%),
        var(--bg-base);
    color: var(--text-primary); line-height: 1.6; overflow-x: hidden; min-height: 100vh;
}
header {
    display: flex; justify-content: space-between; align-items: center; padding: 18px 6%;
    border-bottom: 1px solid var(--border); backdrop-filter: blur(20px);
    position: sticky; top: 0; z-index: 50; background: rgba(11, 13, 16, 0.82);
}
.brand { display: flex; align-items: center; gap: 12px; font-size: 20px; font-weight: 700; color: #fff; letter-spacing: -0.4px; }
.btn {
    background: var(--bg-card); border: 1px solid var(--border); color: var(--text-primary);
    padding: 10px 22px; border-radius: 999px; font-size: 14px; font-weight: 600; cursor: pointer;
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1); display: inline-flex; align-items: center; gap: 8px;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.2); user-select: none;
}
.btn:hover { transform: translateY(-1px); border-color: var(--border-hover); background: #202630; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.4); }
.btn:active { transform: translateY(0); }
.btn-primary { background: #1f3a60; border-color: #388bfd; color: #fff; }
.btn-primary:hover { background: #264a7a; border-color: #58a6ff; }
.hero-split {
    display: grid; grid-template-columns: 1.1fr 0.9fr; gap: 40px; align-items: center;
    max-width: 1240px; margin: 40px auto; padding: 40px 6%;
}
@media (max-width: 900px) { .hero-split { grid-template-columns: 1fr; text-align: center; } }
.hero-text h1 { font-size: clamp(34px, 4.5vw, 52px); font-weight: 700; line-height: 1.15; margin-bottom: 20px; letter-spacing: -0.8px; }
.hero-text p { font-size: 17px; color: var(--text-muted); line-height: 1.65; margin-bottom: 30px; }
.badge {
    display: inline-flex; align-items: center; gap: 8px; padding: 6px 14px; background: var(--bg-card);
    border: 1px solid var(--border); border-radius: 999px; font-size: 13px; font-weight: 500; color: var(--accent); margin-bottom: 20px;
}
.badge-dot { width: 7px; height: 7px; background: var(--success); border-radius: 50%; box-shadow: 0 0 8px var(--success); }
.canvas-wrapper {
    position: relative; width: 100%; aspect-ratio: 1; max-width: 480px; margin: 0 auto;
    display: flex; align-items: center; justify-content: center;
}
#sphereCanvas { width: 100%; height: 100%; border-radius: 50%; filter: drop-shadow(0 0 35px rgba(56, 139, 253, 0.2)); }
.stats-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; max-width: 1140px; margin: 0 auto 50px; padding: 0 6%; }
.stat-card { background: var(--bg-card); border: 1px solid var(--border); padding: 22px; border-radius: 18px; text-align: center; }
.stat-card h3 { font-size: 28px; font-weight: 700; color: #fff; }
.stat-card p { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
.features { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 20px; max-width: 1140px; margin: 0 auto 60px; padding: 0 6%; }
.feature-card {
    background: var(--bg-card); border: 1px solid var(--border); padding: 30px 24px; border-radius: 20px;
    cursor: pointer; transition: all 0.25s ease; display: flex; flex-direction: column; justify-content: space-between;
}
.feature-card:hover { transform: translateY(-3px); border-color: var(--border-hover); background: #1c222b; }
.feature-card h3 { font-size: 18px; font-weight: 600; margin-bottom: 10px; color: #fff; }
.feature-card p { font-size: 14px; color: var(--text-muted); line-height: 1.55; }
.card-action { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 600; color: var(--accent); margin-top: 16px; }
.telemetry-section { max-width: 1140px; margin: 0 auto 80px; padding: 0 6%; }
.terminal-card {
    background: var(--terminal-bg); border: 1px solid var(--border); border-radius: 20px; overflow: hidden;
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4);
}
.terminal-header {
    background: #161b22; padding: 12px 18px; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid var(--border);
}
.term-dot { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
.term-dot.r { background: #ff5f56; } .term-dot.y { background: #ffbd2e; } .term-dot.g { background: #27c93f; }
.term-title { font-size: 12px; font-family: monospace; color: var(--text-muted); margin-left: 8px; }
.terminal-body { padding: 20px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 13px; color: #c9d1d9; }
.telemetry-canvas-wrap { width: 100%; height: 160px; margin-bottom: 18px; position: relative; }
#chartCanvas { width: 100%; height: 100%; }
.terminal-logs { max-height: 180px; overflow-y: auto; display: flex; flex-direction: column; gap: 6px; }
.log-line { line-height: 1.4; color: #8b949e; word-break: break-all; }
.log-line span.ts { color: #58a6ff; }
.log-line span.hl { color: #7ee787; font-weight: 600; }
.cli-prompt { display: flex; align-items: center; gap: 8px; margin-top: 14px; padding-top: 12px; border-top: 1px solid rgba(255, 255, 255, 0.05); }
.cli-prompt input {
    background: transparent; border: none; outline: none; color: #fff; font-family: inherit; font-size: 13px; flex: 1;
}
.modal-overlay {
    position: fixed; inset: 0; background: rgba(5, 7, 10, 0.85); backdrop-filter: blur(16px);
    display: flex; align-items: center; justify-content: center; padding: 20px; z-index: 100;
    opacity: 0; visibility: hidden; transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}
.modal-overlay.active { opacity: 1; visibility: visible; }
.modal-card {
    background: var(--bg-surface); border: 1px solid var(--border); border-radius: 24px; width: 100%; max-width: 480px;
    padding: 32px; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.7); transform: translateY(20px); transition: transform 0.3s ease;
}
.modal-overlay.active .modal-card { transform: translateY(0); }
.modal-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 18px; }
.modal-header h2 { font-size: 20px; font-weight: 700; color: #fff; }
.modal-header p { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
.modal-close { background: transparent; border: none; color: var(--text-muted); cursor: pointer; padding: 4px; display: flex; }
.modal-close:hover { color: #fff; }
.form-group { margin-bottom: 16px; }
.form-group label { display: block; font-size: 13px; font-weight: 500; color: #c4c7c5; margin-bottom: 6px; }
.form-control {
    width: 100%; padding: 12px 14px; background: #090c10; border: 1px solid var(--border); border-radius: 12px;
    color: #fff; font-size: 14px; outline: none; transition: all 0.2s ease;
}
.form-control:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(168, 199, 250, 0.2); }
.alert-box {
    background: rgba(239, 68, 68, 0.12); border: 1px solid rgba(239, 68, 68, 0.3); color: #fca5a5;
    padding: 12px 14px; border-radius: 12px; font-size: 13px; margin-bottom: 18px; display: none; align-items: center; gap: 10px;
}
.toast-hud {
    position: fixed; bottom: 30px; right: 30px; background: var(--bg-card); border: 1px solid var(--border-hover);
    border-radius: 16px; padding: 16px 20px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.6); display: flex; align-items: flex-start; gap: 12px;
    z-index: 200; max-width: 360px; transform: translateY(100px); opacity: 0; visibility: hidden; transition: all 0.3s ease;
}
.toast-hud.active { transform: translateY(0); opacity: 1; visibility: visible; }
.spinner { width: 16px; height: 16px; border: 2px solid rgba(255, 255, 255, 0.3); border-top: 2px solid #fff; border-radius: 50%; animation: spin 0.8s linear infinite; }
footer { text-align: center; padding: 40px 20px; color: var(--text-muted); font-size: 13px; border-top: 1px solid var(--border); }
@keyframes spin { 100% { transform: rotate(360deg); } }
EOF

cat << 'EOF' > $WEBROOT/assets/js/datasphere.js
"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const sCanvas = document.getElementById("sphereCanvas");
    if (sCanvas) {
        const ctx = sCanvas.getContext("2d");
        let width, height;
        const dpr = window.devicePixelRatio || 1;

        const resizeSphere = () => {
            const rect = sCanvas.getBoundingClientRect();
            width = rect.width;
            height = rect.height;
            sCanvas.width = width * dpr;
            sCanvas.height = height * dpr;
            ctx.scale(dpr, dpr);
        };
        resizeSphere();
        window.addEventListener("resize", resizeSphere);

        const nodesCount = 92;
        const nodes = [];
        const radius = 150;

        for (let i = 0; i < nodesCount; i++) {
            const phi = Math.acos(-1 + (2 * i) / nodesCount);
            const theta = Math.sqrt(nodesCount * Math.PI) * phi;
            nodes.push({
                x: radius * Math.cos(theta) * Math.sin(phi),
                y: radius * Math.sin(theta) * Math.sin(phi),
                z: radius * Math.cos(phi)
            });
        }

        let rotX = 0.003;
        let rotY = 0.005;
        let targetRotX = 0.003;
        let targetRotY = 0.005;

        window.addEventListener("mousemove", (e) => {
            const nx = (e.clientX / window.innerWidth) - 0.5;
            const ny = (e.clientY / window.innerHeight) - 0.5;
            targetRotX = ny * 0.015;
            targetRotY = nx * 0.015;
        });

        let isVisible = true;
        document.addEventListener("visibilitychange", () => {
            isVisible = !document.hidden;
        });

        const project = (p) => {
            const fov = 340;
            const factor = fov / (fov + p.z);
            return {
                x: p.x * factor + width / 2,
                y: p.y * factor + height / 2,
                scale: factor
            };
        };

        const renderSphere = () => {
            if (!isVisible) {
                requestAnimationFrame(renderSphere);
                return;
            }

            rotX += (targetRotX - rotX) * 0.05;
            rotY += (targetRotY - rotY) * 0.05;

            ctx.clearRect(0, 0, width, height);

            const cosX = Math.cos(rotX), sinX = Math.sin(rotX);
            const cosY = Math.cos(rotY), sinY = Math.sin(rotY);

            for (let i = 0; i < nodes.length; i++) {
                let p = nodes[i];
                let y1 = p.y * cosX - p.z * sinX;
                let z1 = p.y * sinX + p.z * cosX;
                let x2 = p.x * cosY + z1 * sinY;
                let z2 = -p.x * sinY + z1 * cosY;
                nodes[i] = { x: x2, y: y1, z: z2 };
            }

            ctx.lineWidth = 0.7;
            for (let i = 0; i < nodes.length; i++) {
                const p1 = project(nodes[i]);
                for (let j = i + 1; j < nodes.length; j++) {
                    const dx = nodes[i].x - nodes[j].x;
                    const dy = nodes[i].y - nodes[j].y;
                    const dz = nodes[i].z - nodes[j].z;
                    const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
                    if (dist < 64) {
                        const p2 = project(nodes[j]);
                        const alpha = (1 - dist / 64) * 0.35 * Math.min(p1.scale, p2.scale);
                        ctx.strokeStyle = `rgba(168, 199, 250, ${alpha})`;
                        ctx.beginPath();
                        ctx.moveTo(p1.x, p1.y);
                        ctx.lineTo(p2.x, p2.y);
                        ctx.stroke();
                    }
                }
            }

            for (let i = 0; i < nodes.length; i++) {
                const p = project(nodes[i]);
                const alpha = Math.max(0.1, (nodes[i].z + radius) / (2 * radius));
                ctx.fillStyle = `rgba(129, 201, 149, ${alpha})`;
                ctx.beginPath();
                ctx.arc(p.x, p.y, 2 * p.scale, 0, Math.PI * 2);
                ctx.fill();
            }

            requestAnimationFrame(renderSphere);
        };
        requestAnimationFrame(renderSphere);
    }

    const cCanvas = document.getElementById("chartCanvas");
    if (cCanvas) {
        const cCtx = cCanvas.getContext("2d");
        const pointsCount = 40;
        const dataPoints = Array.from({ length: pointsCount }, () => 80 + Math.random() * 18);

        const renderChart = () => {
            const w = cCanvas.parentElement.clientWidth;
            const h = cCanvas.parentElement.clientHeight;
            cCanvas.width = w * window.devicePixelRatio;
            cCanvas.height = h * window.devicePixelRatio;
            cCtx.scale(window.devicePixelRatio, window.devicePixelRatio);

            cCtx.clearRect(0, 0, w, h);

            cCtx.strokeStyle = "rgba(255, 255, 255, 0.05)";
            cCtx.lineWidth = 1;
            cCtx.beginPath();
            for (let y = 20; y < h; y += 30) {
                cCtx.moveTo(0, y); cCtx.lineTo(w, y);
            }
            cCtx.stroke();

            const step = w / (pointsCount - 1);
            cCtx.beginPath();
            cCtx.moveTo(0, h - (dataPoints[0] / 100) * h);

            for (let i = 0; i < pointsCount - 1; i++) {
                const x0 = i * step;
                const y0 = h - (dataPoints[i] / 100) * (h * 0.85);
                const x1 = (i + 1) * step;
                const y1 = h - (dataPoints[i + 1] / 100) * (h * 0.85);
                const mx = (x0 + x1) / 2;
                cCtx.quadraticCurveTo(x0, y0, mx, (y0 + y1) / 2);
            }

            cCtx.strokeStyle = "#58a6ff";
            cCtx.lineWidth = 2;
            cCtx.stroke();

            cCtx.lineTo(w, h);
            cCtx.lineTo(0, h);
            cCtx.closePath();
            const grad = cCtx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, "rgba(88, 166, 255, 0.25)");
            grad.addColorStop(1, "rgba(88, 166, 255, 0.0)");
            cCtx.fillStyle = grad;
            cCtx.fill();
        };

        renderChart();
        window.addEventListener("resize", renderChart);

        setInterval(() => {
            const randArr = new Uint32Array(1);
            window.crypto.getRandomValues(randArr);
            const delta = (randArr[0] / 0xffffffff - 0.5) * 6;
            let last = dataPoints[dataPoints.length - 1] + delta;
            if (last > 99.8) last = 96.0;
            if (last < 75.0) last = 78.0;
            dataPoints.shift();
            dataPoints.push(last);
            renderChart();
        }, 1200);
    }

    const termLogs = document.getElementById("terminalLogs");
    const cliInput = document.getElementById("cliInput");
    const authModal = document.getElementById("authModal");
    const detailModal = document.getElementById("detailModal");
    const toastHud = document.getElementById("toastHud");

    const showToast = (title, desc) => {
        document.getElementById("toastTitle").innerText = title;
        document.getElementById("toastDesc").innerText = desc;
        toastHud.classList.add("active");
        setTimeout(() => toastHud.classList.remove("active"), 4500);
    };

    const addLog = (msg, hl = false) => {
        if (!termLogs) return;
        const now = new Date().toISOString().split("T")[1].slice(0, 8);
        const div = document.createElement("div");
        div.className = "log-line";
        div.innerHTML = `<span class="ts">[${now}]</span> ${hl ? '<span class="hl">' + msg + '</span>' : msg}`;
        termLogs.appendChild(div);
        termLogs.scrollTop = termLogs.scrollHeight;
    };

    cliInput?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
            const val = cliInput.value.trim().toLowerCase();
            cliInput.value = "";
            addLog(`$ ${val}`, true);

            if (val === "help") {
                addLog("Доступные команды: status, nodes, crypto, telemetry, clear");
            } else if (val === "status") {
                addLog("Ядро Anycast: ONLINE | Ингресс H2C/TLS: 100 Gbps | Потери: 0.000%");
            } else if (val === "nodes") {
                addLog("Активно узлов: 148 PoP (EU: 62, US: 54, APAC: 32) | Балансировка: FQ/BBR");
            } else if (val === "crypto") {
                addLog("Шифрование сессий: TLS 1.3 (RFC 8446) / ChaCha20-Poly1305 / AES-256-GCM");
            } else if (val === "clear") {
                termLogs.innerHTML = "";
            } else {
                addLog(`Команда не найдена: '${val}'. Введите 'help' для справки.`);
            }
        }
    });

    const openAuth = () => { authModal.classList.add("active"); };
    const closeModals = () => {
        authModal.classList.remove("active");
        detailModal.classList.remove("active");
    };

    document.getElementById("headerConsoleBtn")?.addEventListener("click", openAuth);
    document.getElementById("connectNodeBtn")?.addEventListener("click", openAuth);
    document.getElementById("authModalClose")?.addEventListener("click", closeModals);
    document.getElementById("detailModalClose")?.addEventListener("click", closeModals);
    document.getElementById("detailModalOk")?.addEventListener("click", closeModals);

    document.getElementById("netStatusBtn")?.addEventListener("click", () => {
        showToast("Сетевой кластер DataSphere", "Anycast-маршрутизация активна: RTT < 1.2 ms.");
    });

    document.getElementById("authForm")?.addEventListener("submit", (e) => {
        e.preventDefault();
        const submitBtn = document.getElementById("submitBtn");
        submitBtn.innerHTML = '<span class="spinner"></span> Верификация...';
        submitBtn.disabled = true;

        setTimeout(() => {
            document.getElementById("errorMsg").innerText = "Ошибка 401: Доступ отклонен. Ключ узла не сертифицирован.";
            document.getElementById("errorAlert").style.display = "flex";
            submitBtn.innerHTML = "Подключиться к кластеру";
            submitBtn.disabled = false;
        }, 800);
    });

    const details = {
        cardCrypto: {
            title: "Сквозное квантовое шифрование",
            desc: "Аппаратная акселерация ML-KEM-768",
            content: "Сессии терминируются с использованием постквантовой криптографии на базе решеток (ML-KEM-768) в связке с X25519. Срок жизни сессионного ключа строго ограничен 300 секундами."
        },
        cardTelemetry: {
            title: "Распределенная Anycast-телеметрия",
            desc: "Многопоточный конвейер синхронизации",
            content: "Метрики сетевого потока агрегируются в режиме реального времени на границе датацентров. Потери пакетов устранены за счет алгоритмов упреждающей маршрутизации FQ/BBR."
        },
        cardIpc: {
            title: "Изоляция сокетов In-Memory IPC",
            desc: "Zero-Copy архитектура обмена",
            content: "Межсервисный транспорт внутри хоста маршрутизируется через энергонезависимые сокеты в Shared Memory (/dev/shm) без накладных расходов сетевого стека ядра."
        },
        cardOffload: {
            title: "Аппаратная терминация очередей",
            desc: "Масштабирование сокетов somaxconn",
            content: "Сетевой стек оптимизирован под максимальную утилизацию очередей ядра (somaxconn = 65535, rmem/wmem до 64 MB), полностью исключая дропы при пиках входящих соединений."
        }
    };

    Object.keys(details).forEach(id => {
        document.getElementById(id)?.addEventListener("click", () => {
            const item = details[id];
            document.getElementById("detailTitle").innerText = item.title;
            document.getElementById("detailSubtitle").innerText = item.desc;
            document.getElementById("detailContent").innerHTML = `<p style="color:#8b949e; font-size:14px; line-height:1.6;">${item.content}</p>`;
            detailModal.classList.add("active");
        });
    });
});
EOF

cat << 'EOF' > $WEBROOT/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DataSphere Analytics — Платформа распределенной аналитики данных</title>
    <meta name="description" content="Корпоративная среда распределенной обработки данных с квантово-устойчивым шифрованием ML-KEM-768, аппаратной акселерацией L4/L7 и Anycast-маршрутизацией узлов.">
    <link rel="icon" type="image/svg+xml" href="/assets/img/favicon.svg">
    <link rel="stylesheet" href="/assets/css/datasphere.css">
    <script defer src="/assets/js/datasphere.js"></script>
</head>
<body>
    <header>
        <div class="brand">
            <svg viewBox="0 0 100 100" width="28" height="28" xmlns="http://www.w3.org/2000/svg">
                <circle cx="50" cy="50" r="46" fill="#008dd5"/>
                <ellipse cx="50" cy="50" rx="42" ry="16" fill="none" stroke="#fff" stroke-width="3"/>
                <circle cx="50" cy="50" r="7" fill="#81c995"/>
            </svg>
            DataSphere Analytics
        </div>
        <button type="button" id="headerConsoleBtn" class="btn">Консоль инженера</button>
    </header>

    <main>
        <section class="hero-split">
            <div class="hero-text">
                <div class="badge"><span class="badge-dot"></span><span>DataSphere Core v4.0 — Доступность 99.998%</span></div>
                <h1>Распределенная сеть обработки и защиты корпоративных данных</h1>
                <p>Высоконагруженная инфраструктура с аппаратной изоляцией памяти, поддержкой современных стандартов шифрования TLS 1.3 и магистральной Anycast-маршрутизацией.</p>
                <div style="display:flex; gap:14px; flex-wrap:wrap;">
                    <button type="button" id="connectNodeBtn" class="btn btn-primary">Подключить вычислительный узел</button>
                    <button type="button" id="netStatusBtn" class="btn">Статус Anycast-магистрали</button>
                </div>
            </div>
            <div class="canvas-wrapper">
                <canvas id="sphereCanvas"></canvas>
            </div>
        </section>

        <section class="stats-bar">
            <div class="stat-card"><h3>&lt; 1.2 ms</h3><p>Задержка магистрали</p></div>
            <div class="stat-card"><h3>100 Gbps</h3><p>Пропускная способность</p></div>
            <div class="stat-card"><h3>ML-KEM-768</h3><p>Постквантовый обмен</p></div>
            <div class="stat-card"><h3>Zero-Copy</h3><p>IPC Shared Memory</p></div>
        </section>

        <section class="features">
            <div class="feature-card" id="cardCrypto">
                <div>
                    <h3>Квантово-стойкое шифрование</h3>
                    <p>Терминация трафика осуществляется на базе криптографических стандартов ML-KEM-768 с ротацией сессионных ключей каждые 300 секунд.</p>
                </div>
                <span class="card-action">Спецификация криптомодуля &rarr;</span>
            </div>
            <div class="feature-card" id="cardTelemetry">
                <div>
                    <h3>Anycast-телеметрия</h3>
                    <p>Автоматическая балансировка потоков между 148 географически распределенными точками присутствия без деградации RTT.</p>
                </div>
                <span class="card-action">Топология узлов &rarr;</span>
            </div>
            <div class="feature-card" id="cardIpc">
                <div>
                    <h3>Изоляция сокетов IPC</h3>
                    <p>Прямая маршрутизация очередей данных через сегменты Shared Memory (/dev/shm) без накладных расходов сетевого стека.</p>
                </div>
                <span class="card-action">Zero-Copy конвейер &rarr;</span>
            </div>
            <div class="feature-card" id="cardOffload">
                <div>
                    <h3>Масштабирование сокетов</h3>
                    <p>Глубокая оптимизация somaxconn и буферов сокетов rmem/wmem до 64 МБ для защиты от сброса сессий при всплесках трафика.</p>
                </div>
                <span class="card-action">Аудит сетевого ядра &rarr;</span>
            </div>
        </section>

        <section class="telemetry-section">
            <div class="terminal-card">
                <div class="terminal-header">
                    <span class="term-dot r"></span>
                    <span class="term-dot y"></span>
                    <span class="term-dot g"></span>
                    <span class="term-title">datasphere-edge-telemetry — 100 Gbps Ingress/Egress Stream Monitor</span>
                </div>
                <div class="terminal-body">
                    <div class="telemetry-canvas-wrap">
                        <canvas id="chartCanvas"></canvas>
                    </div>
                    <div class="terminal-logs" id="terminalLogs">
                        <div class="log-line"><span class="ts">[INIT]</span> Магистральный конвейер BGP Anycast инициализирован. Шлюз активен.</div>
                        <div class="log-line"><span class="ts">[INFO]</span> Криптографический модуль ML-KEM-768 синхронизирован с HSM-кластером.</div>
                        <div class="log-line"><span class="ts">[METRIC]</span> Текущая загрузка буферов ядра: <span class="hl">0.02%</span>. Сессии обслуживаются без задержек.</div>
                    </div>
                    <div class="cli-prompt">
                        <span style="color:#58a6ff;">datasphere@edge:~$</span>
                        <input type="text" id="cliInput" placeholder="Введите команду (help, status, nodes, crypto, clear)..." autocomplete="off">
                    </div>
                </div>
            </div>
        </section>
    </main>

    <div id="authModal" class="modal-overlay">
        <div class="modal-card">
            <div class="modal-header">
                <div>
                    <h2>Вход в консоль узла</h2>
                    <p>Введите идентификатор для авторизации в кластере</p>
                </div>
                <button type="button" id="authModalClose" class="modal-close">
                    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
                </button>
            </div>
            <div id="errorAlert" class="alert-box">
                <span id="errorMsg">Ошибка доступа</span>
            </div>
            <form id="authForm">
                <div class="form-group">
                    <label for="nodeUser">Идентификатор узла (Node ID)</label>
                    <input type="text" id="nodeUser" class="form-control" placeholder="node-edge-01@datasphere.cloud" required>
                </div>
                <div class="form-group">
                    <label for="nodeKey">Секретный токен API</label>
                    <input type="password" id="nodeKey" class="form-control" placeholder="••••••••••••••••" required>
                </div>
                <button type="submit" id="submitBtn" class="btn btn-primary" style="width:100%; justify-content:center;">Подключиться к кластеру</button>
            </form>
        </div>
    </div>

    <div id="detailModal" class="modal-overlay">
        <div class="modal-card">
            <div class="modal-header">
                <div>
                    <h2 id="detailTitle">Спецификация</h2>
                    <p id="detailSubtitle">Параметры подсистемы DataSphere</p>
                </div>
                <button type="button" id="detailModalClose" class="modal-close">
                    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
                </button>
            </div>
            <div id="detailContent" style="margin-bottom:20px;"></div>
            <button type="button" id="detailModalOk" class="btn" style="width:100%; justify-content:center;">Понятно</button>
        </div>
    </div>

    <div id="toastHud" class="toast-hud">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#81c995" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
        <div>
            <div id="toastTitle" style="font-weight:600; font-size:14px; color:#fff;">Оповещение</div>
            <div id="toastDesc" style="font-size:12px; color:#8b949e;">Информация о сети</div>
        </div>
    </div>

    <footer>&copy; 2026 DataSphere Cloud Systems Inc. Платформа распределенной аналитики и защиты данных.</footer>
</body>
</html>
EOF


elif [ "$DECOY_MODE" = "2" ]; then
    # 2. CosmosCloud NextGen (с ассетами и оригинальным logo.webp)
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>My Cloud</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0">
    <style>
        body { margin:0; padding:20px; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background-color:#cbcae0; background-image:linear-gradient(135deg,#e2e1ec 0%,#bcbbcb 100%); display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:100vh; color:#333; box-sizing:border-box; }
        .page-wrapper { width:100%; max-width:420px; display:flex; flex-direction:column; align-items:center; box-shadow:0 15px 35px rgba(0,0,0,0.15); border-radius:12px; overflow:hidden; }
        .banner-img { width:100%; height:auto; display:block; }
        .login-container { background:#fff; width:100%; text-align:center; padding:35px 30px; box-sizing:border-box; }
        .header-title { font-size:20px; color:#4a4557; margin-bottom:25px; font-weight:400; }
        .input-group { position:relative; margin-bottom:14px; }
        input { width:100%; padding:12px 15px; border:1px solid #ccc; border-radius:6px; box-sizing:border-box; font-size:15px; outline:none; transition:border-color .2s,box-shadow .2s; background:#fdfdfd; }
        input:focus { border-color:#735b8c; box-shadow:0 0 0 3px rgba(115,91,140,.15); background:#fff; }
        button { width:100%; padding:12px; background:#735b8c; color:#fff; border:none; border-radius:6px; font-size:16px; font-weight:600; cursor:pointer; margin-top:10px; transition:background .2s,opacity .2s; display:flex; justify-content:center; align-items:center; height:44px; }
        button:hover { background:#5d4874; }
        button:disabled { opacity:.7; cursor:not-allowed; }
        .message-box { background:#e74c3c; color:#fff; padding:11px; border-radius:6px; margin-bottom:20px; font-size:14px; text-align:left; display:none; animation:fadeIn .3s ease; }
        .spinner { display:inline-block; width:18px; height:18px; border:2px solid rgba(255,255,255,.3); border-top:2px solid #fff; border-radius:50%; animation:spin .8s linear infinite; }
        .footer-text { margin-top:25px; color:rgba(60,55,70,.6); font-size:13px; text-align:center; width:100%; }
        .footer-text a { color:#735b8c; text-decoration:none; font-weight:500; }
        @keyframes spin { 100% { transform:rotate(360deg); } }
        @keyframes fadeIn { from { opacity:0; transform:translateY(-5px); } to { opacity:1; transform:translateY(0); } }
    </style>
</head>
<body>
    <div class="page-wrapper">
        <img class="banner-img" src="logo.webp" alt="Cloud Header" onerror="this.style.display='none'">
        <div class="login-container">
            <div class="header-title">Вход в облако</div>
            <div id="errorBox" class="message-box"></div>
            <form id="loginForm" onsubmit="handleLogin(event)">
                <div class="input-group"><input id="user" type="text" placeholder="Имя пользователя или email" autocomplete="username" required></div>
                <div class="input-group"><input id="pass" type="password" placeholder="Пароль" autocomplete="current-password" required></div>
                <button type="submit" id="loginBtn">Войти</button>
            </form>
        </div>
    </div>
    <div class="footer-text">
        <a href="#">Cosmos Cloud</a> – безопасный дом для ваших данных
    </div>
    <script>
        function setFakeCookie() { document.cookie = "cosmos_session=" + Math.random().toString(36).substring(2) + "; path=/; Secure; SameSite=Lax"; }
        async function handleLogin(e) {
            e.preventDefault();
            const btn = document.getElementById("loginBtn"), errBox = document.getElementById("errorBox");
            errBox.style.display = "none"; btn.disabled = true; btn.innerHTML = '<div class="spinner"></div>';
            try {
                const response = await fetch("/api/v1/auth/login", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ user: document.getElementById("user").value, pass: document.getElementById("pass").value })
                });
                const data = await response.json();
                errBox.innerText = data.error || "Wrong nickname or password.";
                errBox.style.display = "block";
            } catch (err) {
                errBox.innerText = "Ошибка сетевого соединения с облаком.";
                errBox.style.display = "block";
            } finally {
                btn.disabled = false; btn.innerHTML = 'Войти';
            }
        }
        setFakeCookie();
    </script>
</body>
</html>
EOF

    log "Загрузка оригинальных графических ассетов Cosmos Cloud..."
    if curl -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/logo.webp" -o "$WEBROOT/logo.webp" 2>/dev/null; then
        ok "Логотип успешно загружен из основного репозитория GitHub."
    else
        warn "Прямое подключение к GitHub не удалось. Переключаемся на резервное зеркало CDN..."
        if curl -fsSL --connect-timeout 10 "https://cdn.jsdelivr.net/gh/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui@main/logo.webp" -o "$WEBROOT/logo.webp" 2>/dev/null; then
            ok "Логотип успешно загружен из резервного зеркала CDN (jsDelivr)."
        else
            warn "Не удалось загрузить логотип. Веб-маска будет работать в режиме текстовой заглушки."
        fi
    fi

    if [ -f "$WEBROOT/logo.webp" ]; then
        magic_riff=$(head -c 4 "$WEBROOT/logo.webp" | tr -d '\0' || true)
        magic_webp=$(dd if="$WEBROOT/logo.webp" bs=1 skip=8 count=4 status=none 2>/dev/null | tr -d '\0' || true)
        if [[ "$magic_riff" != "RIFF" || "$magic_webp" != "WEBP" ]]; then
            warn "Файл logo.webp имеет неверный формат. Удаление поврежденного файла..."
            rm -f "$WEBROOT/logo.webp"
        else
            ok "Файл logo.webp успешно верифицирован по сигнатуре формата."
        fi
    fi

else
    # 3. Welcome to nginx
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html><head><title>Welcome to nginx!</title><style>body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }</style></head><body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working.</p></body></html>
EOF
fi

cat << 'EOF' > /var/www/html/404.html
<!DOCTYPE html>
<html><head><title>404 Not Found</title></head><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>
EOF

    [ -f "$WEBROOT/robots.txt" ] || cat << 'EOF_ROBOTS' > "$WEBROOT/robots.txt"
User-agent: *
Disallow: /
EOF_ROBOTS

    chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT"
    chmod -R 755 "$WEBROOT"
