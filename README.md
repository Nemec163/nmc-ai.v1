# nmc-ai.v1

`nmc-ai.v1` — двухрежимный Bash installer для Ubuntu VPS (22.04/24.04) для чистой установки OpenClaw с hardening и доступом только через Tailscale.

## Режимы

1. `infra` — подготавливает инфраструктуру:
- базовые пакеты
- `openclaw` user (в `sudo`, без `NOPASSWD`)
- Docker CE (без группы `docker` для `openclaw`)
- Node.js 22 + pnpm
- UFW + fail2ban + unattended-upgrades
- Tailscale + lock-down SSH до tailnet-only
- SSH hardening (только ключи)
- sudo hardening для `openclaw` (`passwd_tries=3`, `timestamp_timeout=10`)

2. `openclaw` — ставит OpenClaw до production-ready:
- попытка official installer endpoint
- fallback на `pnpm install -g openclaw@latest`
- `openclaw onboard --install-daemon` + форс `gateway.bind=loopback`
- форс `gateway.tailscale.mode=serve` (tailnet HTTPS URL)
- обязательный запуск gateway через `openclaw-gateway*.service` (или fallback `openclaw-gateway-host.service`, если user-systemd недоступен)
- health checks (`openclaw status`, `openclaw doctor`, `openclaw gateway probe`)

## Быстрый старт

```bash
chmod +x ./nmc-ai.v1.sh
./nmc-ai.v1.sh --mode infra
./nmc-ai.v1.sh --mode openclaw
```

## Non-interactive

```bash
cp installer.env.example installer.env
# отредактируйте значения
./nmc-ai.v1.sh --mode infra --non-interactive --config ./installer.env
./nmc-ai.v1.sh --mode openclaw --non-interactive --config ./installer.env
```

## Сброс второго этапа (clean retry)

Если `openclaw`-этап запускался неудачно или частично, выполните полный сброс только второго этапа:

```bash
chmod +x ./reset-openclaw-stage.sh
./reset-openclaw-stage.sh
```

Скрипт сброса удаляет user-units OpenClaw, system fallback unit `openclaw-gateway-host.service`,
`~/.openclaw`, установленные `openclaw` бинарники и сбрасывает `tailscale serve` publish из второго этапа.

Полезные режимы:

```bash
./reset-openclaw-stage.sh --dry-run
./reset-openclaw-stage.sh --force
```

После сброса снова запустите:

```bash
./nmc-ai.v1.sh --mode openclaw
```

## Параметры CLI

- `--mode <infra|openclaw>`
- `--config /path/to/installer.env`
- `--non-interactive`
- `--dry-run`
- `--verbose`

## Контракт installer.env

- `MODE=infra|openclaw`
- `OPENCLAW_PASSWORD=...` (обязательно для `infra` в non-interactive)
- `TAILSCALE_AUTH_MODE=authkey|interactive`
- `TAILSCALE_AUTHKEY=...` (если `authkey`)
- `EXTRA_SSH_KEYS="ssh-ed25519 ...;ssh-ed25519 ..."`
- `OPENCLAW_ONBOARD=interactive|non_interactive`
- `OPENCLAW_PROVIDER=anthropic|openai|gemini|custom`
- `ANTHROPIC_API_KEY=...`
- `OPENAI_API_KEY=...`
- `GEMINI_API_KEY=...`
- `OPENCLAW_MODEL=...`
- `OPENCLAW_OFFICIAL_INSTALLER_URLS="url1 url2"` (опционально)

## Exit codes

- `0` success
- `10` preflight/config error
- `20` infra mode failed
- `30` openclaw mode failed
- `40` lockout safety stop

## Важные замечания

- Скрипт можно запускать от `root` или от обычного sudo-пользователя.
- После `infra` публичный SSH закрывается; доступ только через Tailscale.
- Root вход по SSH остаётся разрешён только по ключу (`PermitRootLogin prohibit-password`).
- Второй этап считается успешным только если gateway реально поднят и проходит probe.
- Права `sudo` у `openclaw` требуют пароль; `NOPASSWD` не используется.
