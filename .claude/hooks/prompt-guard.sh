#!/bin/bash
# UserPromptSubmit-хук: останавливает сообщение, в котором похоже на настоящий
# ключ VPN (ссылка vless://, vmess://..., UUID или пароль из конфига, приватный ключ).
# Остановленное сообщение не попадает к модели. Ненастоящие тестовые данные
# (example.com, 192.0.2.x, UUID из нулей) пропускаются, как и в .gitleaks.toml.

set -u

input=$(cat)
if command -v jq >/dev/null 2>&1; then
  prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
else
  prompt=$input
fi
[ -n "$prompt" ] || exit 0

hook_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$hook_dir/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Запасная проверка без gitleaks: только ссылки-ключи, с теми же исключениями
# для тестовых адресов, что в .gitleaks.toml.
grep_links() {
  printf '%s' "$prompt" \
    | grep -Eio '(vless|vmess|trojan|ss|ssr|hysteria|hysteria2|hy2|tuic|anytls|wireguard|wg)://[]A-Za-z0-9+/=_%.:@[?&#!~*,;-]{12,}' \
    | grep -Eiv '@([a-z0-9-]+\.)*example\.(com|net|org)([:/?#]|$)|@(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]{1,3}([:/?#]|$)|@\[2001:db8:' \
    | sed -E 's/^([A-Za-z0-9]+):.*/  - ссылка \1:\/\/…/'
}

# UUID рядом с ключом uuid в любом формате: JSON, YAML (подписки mihomo), key=value.
grep_uuid() {
  printf '%s' "$prompt" \
    | grep -Eio "uuid[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" \
    | grep -Eiv '0{8}-0{4}-0{4}-0{4}-0{12}' \
    | head -n 1 | sed 's/.*/  - uuid в конфиге/'
}

found=""
status=1
if command -v gitleaks >/dev/null 2>&1 && [ -f "$repo_root/.gitleaks.toml" ]; then
  # Все собственные правила проекта (их id из .gitleaks.toml) и приватные ключи.
  # Общие правила gitleaks не включаются: в обычном тексте они дают ложные срабатывания.
  rules=(--enable-rule private-key)
  while IFS= read -r id; do
    rules+=(--enable-rule "$id")
  done < <(sed -nE 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$repo_root/.gitleaks.toml")
  printf '%s' "$prompt" | gitleaks stdin --no-banner --no-color --redact --log-level error \
    --exit-code 3 --ignore-gitleaks-allow --config "$repo_root/.gitleaks.toml" "${rules[@]}" \
    --report-path "$tmp/report.txt" --report-format template \
    --report-template "$hook_dir/gitleaks-findings.tmpl" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 3 ] && found=$(sed '/^$/d' "$tmp/report.txt")
fi
# gitleaks нет или он упал: не пропускаем молча, проверяем хотя бы ссылки.
if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
  found=$(grep_links)
fi
# UUID в YAML правила .gitleaks.toml не видят, поэтому проверяем его отдельно.
if ! printf '%s' "$found" | grep -q 'uuid'; then
  extra=$(grep_uuid)
  [ -n "$extra" ] && found=$(printf '%s\n%s' "$found" "$extra" | sed '/^$/d')
fi

[ -n "$found" ] || exit 0

{
  echo "Сообщение остановлено и не отправлено модели: в нём похоже на настоящий ключ VPN."
  echo "$found"
  echo "Настоящие ключи вводятся только в само приложение на маке."
  echo "Для разработки хватает ненастоящих: example.com, 192.0.2.x, UUID 00000000-0000-0000-0000-000000000000 (SECURITY.md)."
  echo "Если нужно показать, какой у ключа протокол, хватит начала ссылки, например «vless://…»."
} >&2
exit 2
