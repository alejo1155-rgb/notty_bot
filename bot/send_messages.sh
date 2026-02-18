#!/bin/bash

# === ЧТЕНИЕ КОНФИГУРАЦИИ ИЗ .env ===
ENV_FILE="/home/$USER/git/mobile-testo/bot/.env"

if [ -f "$ENV_FILE" ] && [ -r "$ENV_FILE" ]; then
  BOT_TOKEN=$(grep -oP '^BOT_TOKEN\s*=\s*\K[a-zA-Z0-9_-]+:[a-zA-Z0-9_-]+' "$ENV_FILE" 2>/dev/null | head -n1 | tr -d '\r')
  CHAT_ID=$(grep -oP '^CHAT_ID\s*=\s*\K-100\d+' "$ENV_FILE" 2>/dev/null | head -n1 | tr -d '\r')
  THREAD_ID_TESTO=$(grep -oP '^THREAD_ID_TESTO\s*=\s*\K\d+' "$ENV_FILE" 2>/dev/null | head -n1 | tr -d '\r')
fi

# Если секреты не найдены — отключаем уведомления без ошибок
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
  export TELEGRAM_NOTIFICATIONS_DISABLED=1
  return 0 2>/dev/null || exit 0
fi

# === ФОРМАТИРОВАНИЕ ДЛИТЕЛЬНОСТИ ===
format_duration() {
  local s=$1 h=$((s/3600)) m=$(((s%3600)/60)) s=$((s%60)) r=""
  [ $h -gt 0 ] && r+="${h}ч "
  [ $m -gt 0 ] && r+="${m}м "
  [ $s -gt 0 ] && r+="${s}с"
  [ -z "$r" ] && r="менее 1с"
  echo "${r%% }"
}

# === ОТПРАВКА СООБЩЕНИЯ ===
send_to_testo() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && return 0
  
  local text="$1"
  local silent="${2:-true}"

  local params=(
    -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    -d "chat_id=${CHAT_ID}"
    -d "text=${text}"
    -d "parse_mode=HTML"
    -d "disable_web_page_preview=true"
  )

  [ -n "$THREAD_ID_TESTO" ] && params+=(-d "message_thread_id=${THREAD_ID_TESTO}")
  [ "$silent" = "true" ] && params+=(-d "disable_notification=true")

  curl "${params[@]}" >/dev/null 2>&1
}

# === УВЕДОМЛЕНИЕ О СТАРТЕ ===
notify_testrun_start() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && return 0
  
  local num="$1" ver="$2" os_mode="$3" vm="$4" testo_ver="$5" server_addr="$6"
  
  local jira_url="https://jira.astralinux.ru/secure/Tests.jspa#/testPlayer/BT-C${num}"
  
  local msg="<b>🚀 Запущен прогон BT-C${num}</b>"
  msg+=$'\n📱 Система: '"${ver}"
  msg+=$'\n🛡 Степень защиты: '"${os_mode}"
  msg+=$'\n💻 ВМ: '"${vm}"
  msg+=$'\n📍 Сервер: '"${server_addr}"
  msg+=$'\n🔧 testo: '"${testo_ver}"
  msg+=$'\n👤 '"${USER}"
  msg+=$'\n⏱ '"$(date '+%d.%m %H:%M:%S')"
  msg+=$'\n\n<a href="'"${jira_url}"'">🔗 Открыть прогон в Jira</a>'
  
  send_to_testo "$msg" "false"
}

# === УВЕДОМЛЕНИЕ ОБ ОКОНЧАНИИ ===
notify_testrun_finish() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && return 0
  
  local num="$1" retcode="$2" duration_str="$3" testo_ver="$4" server_addr="$5"

  local emoji="❓" status="НЕИЗВЕСТЕН"
  [ "$retcode" -eq 0 ] && { emoji="✅"; status="УСПЕШНО"; }
  [ "$retcode" -eq 1 ] && { emoji="❌"; status="ОШИБКИ"; }
  [ "$retcode" -gt 1 ] && { emoji="⚠️"; status="СБОЙ"; }

  local jira_url="https://jira.astralinux.ru/secure/Tests.jspa#/testPlayer/BT-C${num}"

  local msg="${emoji} <b>Прогон завершён: ${status}</b>"
  msg+=$'\n\n📋 BT-C'"${num}"
  msg+=$'\n⏱ Длительность: '"${duration_str}"  # ← готовая строка из вызывающего кода
  msg+=$'\n📍 Сервер: '"${server_addr}"
  msg+=$'\n🔧 testo: '"${testo_ver}"
  msg+=$'\n👤 '"${USER}"
  msg+=$'\n📅 '"$(date '+%d.%m %H:%M:%S')"
  msg+=$'\n\n<a href="'"${jira_url}"'">📊 Посмотреть результаты</a>'

  local silent="true"
  [ "$retcode" -ne 0 ] && silent="false"

  send_to_testo "$msg" "$silent"
}

# === УВЕДОМЛЕНИЕ ОБ АВАРИЙНОМ ЗАВЕРШЕНИИ ===
notify_testrun_aborted() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && { echo "[DEBUG] Уведомления отключены (нет .env)" >&2; return 0; }
  
  # Отладка параметров
  echo "[DEBUG] notify_testrun_aborted вызвана с параметрами:" >&2
  echo "[DEBUG]   num=$1, error_msg=$2, duration_str=$3, testo_ver=$4, server_addr=$5" >&2
  
  local num="$1" error_msg="$2" duration_str="$3" testo_ver="$4" server_addr="$5"

  local jira_url="https://jira.astralinux.ru/secure/Tests.jspa#/testPlayer/BT-C${num}"

  local msg="🚨 <b>Прогон ПРЕРВАН</b>"
  msg+=$'\n\n📋 BT-C'"${num}"
  msg+=$'\n⏱ Работал: '"${duration_str}"
  msg+=$'\n📍 Сервер: '"${server_addr}"
  msg+=$'\n🔧 testo: '"${testo_ver}"
  msg+=$'\n👤 '"${USER}"
  msg+=$'\n📅 '"$(date '+%d.%m %H:%M:%S')"
  [ -n "$error_msg" ] && msg+=$'\n\n<b>Ошибка:</b> '"${error_msg//&/&amp;}"
  msg+=$'\n\n<a href="'"${jira_url}"'">🔍 Проверить статус</a>'

  send_to_testo "$msg" "false"  # громкое уведомление (со звуком)
}

# === СПИСОК ОФИЦИАЛЬНЫХ АГЕНТОВ (из notify.py) ===
is_agent_server() {
  local ip="$1"
  [ "$ip" = "10.190.9.63" ] || [ "$ip" = "10.177.5.114" ]
}

# === ПРЯМОЕ БРОНИРОВАНИЕ СЕРВЕРА (без бота) ===
occupy_agent_server() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && return 0
  
  local server_ip="$1"
  local cycle="${2:-unknown}"
  
  is_agent_server "$server_ip" || return 0
  
  local occupancy_file="/home/$USER/server_occupancy.json"
  
  # Проверяем, не занят ли уже
  if [ -f "$occupancy_file" ]; then
    if grep -q "\"${server_ip}\"" "$occupancy_file" 2>/dev/null; then
      local current_user=$(grep -A5 "\"$server_ip\"" "$occupancy_file" 2>/dev/null | grep '"user"' | grep -oP ':\s*"\K[^"]+')
      if [ "$current_user" = "$USER" ]; then
        echo -e "\e[93mℹ️  Сервер ${server_ip} уже занят вами — бронирование пропущено\e[0m" >&2
        return 0
      else
        echo -e "\e[91m❌ Сервер ${server_ip} уже занят пользователем ${current_user}\e[0m" >&2
        return 1
      fi
    fi
  else
    # Создаём пустой файл если не существует
    echo "{}" > "$occupancy_file"
  fi
  
  # Бронируем сервер (прямая запись в JSON)
  local timestamp=$(date +%s)
  local until=$((timestamp + 7200))  # 2 часа по умолчанию
  
  if command -v jq &>/dev/null; then
    # Способ 1: через jq (надёжно)
    jq --arg ip "$server_ip" --arg user "$USER" --argjson ts "$timestamp" --argjson until "$until" \
      '.[$ip] = {user: $user, timestamp: $ts, until: $until}' \
      "$occupancy_file" > "${occupancy_file}.tmp" && \
    mv "${occupancy_file}.tmp" "$occupancy_file"
  else
    # Способ 2: через ручное форматирование (без jq)
    local json_content=$(cat "$occupancy_file" | tr -d '\n')
    # Удаляем старую запись для этого IP если есть
    json_content=$(echo "$json_content" | sed "s/\"$server_ip\":{[^}]*},\?//g" | sed "s/,$/}/")
    # Добавляем новую запись
    if [ "$json_content" = "{}" ]; then
      json_content="{\"$server_ip\":{\"user\":\"$USER\",\"timestamp\":$timestamp,\"until\":$until}}"
    else
      json_content="${json_content%,}}},\"$server_ip\":{\"user\":\"$USER\",\"timestamp\":$timestamp,\"until\":$until}}"
    fi
    echo "$json_content" > "$occupancy_file"
  fi
  
  # Проверяем результат
  if [ -f "$occupancy_file" ] && grep -q "\"${server_ip}\"" "$occupancy_file" 2>/dev/null; then
    echo -e "\e[92m✅ Сервер ${server_ip} успешно забронирован\e[0m" >&2
    return 0
  else
    echo -e "\e[91m❌ Не удалось забронировать сервер ${server_ip}\e[0m" >&2
    return 1
  fi
}

# === ПРЯМОЕ ОСВОБОЖДЕНИЕ СЕРВЕРА (без бота) ===
release_agent_server() {
  [ -n "$TELEGRAM_NOTIFICATIONS_DISABLED" ] && return 0
  
  local server_ip="$1"
  local occupancy_file="/home/$USER/server_occupancy.json"
  
  is_agent_server "$server_ip" || return 0
  
  # Проверяем, занят ли сервер этим пользователем
  if [ -f "$occupancy_file" ] && grep -q "\"${server_ip}\"" "$occupancy_file" 2>/dev/null; then
    local current_user=$(grep -A5 "\"$server_ip\"" "$occupancy_file" 2>/dev/null | grep '"user"' | grep -oP ':\s*"\K[^"]+')
    [ "$current_user" != "$USER" ] && return 0  # занят другим — не трогаем
  else
    return 0  # не занят — ничего делать не нужно
  fi
  
  # Освобождаем сервер (удаляем запись из JSON)
  if command -v jq &>/dev/null; then
    # Способ 1: через jq
    jq "del(.\"$server_ip\")" "$occupancy_file" > "${occupancy_file}.tmp" && \
    mv "${occupancy_file}.tmp" "$occupancy_file"
  else
    # Способ 2: через ручное форматирование
    local json_content=$(cat "$occupancy_file" | tr -d '\n')
    json_content=$(echo "$json_content" | sed "s/\"$server_ip\":{[^}]*},\?//g" | sed "s/,$/}/")
    [ "$json_content" = "{}" ] && json_content="{}"
    echo "$json_content" > "$occupancy_file"
  fi
  
  # Проверяем результат
  if [ ! -f "$occupancy_file" ] || ! grep -q "\"${server_ip}\"" "$occupancy_file" 2>/dev/null; then
    echo -e "\e[92m✅ Сервер ${server_ip} успешно освобождён\e[0m" >&2
    return 0
  else
    echo -e "\e[93m⚠️  Не удалось освободить сервер ${server_ip}\e[0m" >&2
    return 1
  fi
}