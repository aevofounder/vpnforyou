#!/bin/bash
# PreToolUse-хук: ищет секреты gitleaks до того, как они уйдут на GitHub.
#   git commit        -> всё, что может попасть в коммит (индекс, изменения, новые файлы)
#   git push          -> коммиты, которых ещё нет на удалённом репозитории
#   GitHub MCP запись -> содержимое файлов из вызова
# Находка, ошибка gitleaks или отсутствие gitleaks блокируют вызов (exit 2).
# Секреты в вывод не попадают: печатаются только правило, файл и строка.

set -u

input=$(cat)
hook_dir=$(cd "$(dirname "$0")" && pwd)
template="$hook_dir/gitleaks-findings.tmpl"

json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$1 // empty"
  fi
}

tool=$(json_field '.tool_name')
[ -n "$tool" ] || tool=$(printf '%s' "$input" | grep -Eo '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/')
mode=""
if [[ "$tool" == mcp__*github*__push_files || "$tool" == mcp__*github*__create_or_update_file ]]; then
  mode="mcp"
else
  cmd=$(json_field '.tool_input.command')
  [ -n "$cmd" ] || cmd=$input
  git_re='(^|[^[:alnum:]_./-])git([[:space:]]+[^;&|]*)?[[:space:]]'
  if printf '%s\n' "$cmd" | grep -Eq "${git_re}commit([[:space:]]|$)"; then
    mode="commit"
  elif printf '%s\n' "$cmd" | grep -Eq "${git_re}push([[:space:]]|$)"; then
    mode="push"
  fi
fi
[ -n "$mode" ] || exit 0

block() {
  printf '%s\n' "$@" >&2
  exit 2
}

if ! command -v gitleaks >/dev/null 2>&1; then
  block "Проверка секретов не выполнена: gitleaks не установлен, поэтому команда остановлена." \
    "Установи и повтори:" \
    "  облако: GOBIN=/usr/local/bin go install github.com/zricethezav/gitleaks/v8@v8.30.1" \
    "  мак:    brew install gitleaks"
fi

repo_root=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null) \
  || block "Проверка секретов не выполнена: не найден git-репозиторий проекта."
cd "$repo_root" || exit 2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --ignore-gitleaks-allow: комментарий `gitleaks:allow` не отключает проверку.
args=(--no-banner --no-color --redact --log-level error --exit-code 3 --ignore-gitleaks-allow
      --report-path "$tmp/report.txt" --report-format template --report-template "$template")
[ -f .gitleaks.toml ] && args+=(--config .gitleaks.toml)

case "$mode" in
  commit)
    # Копия индекса + `git add -A`: так проверяется и то, что добавит
    # `git add` или `git commit -a` в этой же команде. Настоящий индекс не меняется.
    cp "$(git rev-parse --git-path index)" "$tmp/index" 2>/dev/null
    GIT_INDEX_FILE="$tmp/index" git add -A >/dev/null 2>&1
    GIT_INDEX_FILE="$tmp/index" gitleaks git --pre-commit --staged "${args[@]}" . 2>"$tmp/log"
    status=$?
    what="изменениях, которые попадут в коммит"
    ;;
  push)
    if [ -z "$(git log --branches --not --remotes --format=%H -1 2>/dev/null)" ]; then
      exit 0
    fi
    gitleaks git --log-opts="--branches --not --remotes" "${args[@]}" . 2>"$tmp/log"
    status=$?
    what="коммитах, которых ещё нет на GitHub"
    ;;
  mcp)
    command -v jq >/dev/null 2>&1 \
      || block "Проверка секретов не выполнена: для записи через GitHub MCP нужен jq. Используй git commit и git push."
    printf '%s' "$input" | jq -r '.tool_input | ((.files // [])[] | .content), (.content // empty)' \
      | gitleaks stdin "${args[@]}" 2>"$tmp/log"
    status=$?
    what="файлах, которые отправляются через GitHub MCP"
    ;;
esac

case "$status" in
  0) exit 0 ;;
  3)
    block "gitleaks нашёл похожее на секрет в $what. Команда остановлена." \
      "$(sed '/^$/d' "$tmp/report.txt")" \
      "Убери секрет или замени его ненастоящими данными (SECURITY.md, раздел «Тестовые данные»)." \
      "Не обходи проверку и не ослабляй .gitleaks.toml без согласия пользователя." \
      "Если находка ложная, покажи её пользователю и спроси, что делать."
    ;;
  *)
    block "Проверка секретов не выполнена: gitleaks завершился с кодом $status. Команда остановлена." \
      "$(tail -n 5 "$tmp/log")"
    ;;
esac
