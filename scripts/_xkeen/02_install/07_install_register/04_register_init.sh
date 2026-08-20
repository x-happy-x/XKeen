Warning: truncated output (original token count: 41432)
Total output lines: 3960

#!/bin/sh

# Информация о службе: Запуск / Остановка XKeen

# Окружение
PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin"

# Цвета
green="\033[92m"
red="\033[91m"
yellow="\033[93m"
light_blue="\033[96m"
reset="\033[0m"

# Имена
name_client="xray"
name_app="XKeen"
name_policy="xkeen"
name_policy_full="xkeen_full"
name_profile="xkeen"
name_chain="xkeen"
name_ipset_deny_mac="xkeen_deny_mac"

# Директории
directory_os_modules="/lib/modules/$(uname -r)"
directory_user_modules="/opt/lib/modules"
directory_opkg_modules="/opt/lib/system-modules/$(uname -r)"
directory_system_modules="/lib/system-modules/$(uname -r)"
directory_configs_app="/opt/etc/$name_client"
directory_xray_config="$directory_configs_app/configs"
directory_xray_asset="$directory_configs_app/dat"
log_dir="/opt/var/log"
xkeen_cfg="/opt/etc/xkeen"
ipset_cfg="$xkeen_cfg/ipset"
install_dir="/opt/sbin"

# Файлы
file_netfilter_hook="/opt/etc/ndm/netfilter.d/proxy.sh"
file_schedule_hook="/opt/etc/ndm/schedule.d/00-xkeen-hotspot-sync.sh"
log_access="$log_dir/$name_client/access.log"
log_error="$log_dir/$name_client/error.log"
mihomo_config="$directory_configs_app/config.yaml"
file_port_proxying="$xkeen_cfg/port_proxying.lst"
file_port_exclude="$xkeen_cfg/port_exclude.lst"
file_ip_exclude="$xkeen_cfg/ip_exclude.lst"
xkeen_config="$xkeen_cfg/xkeen.json"
file_pid_fd="/var/run/xkeen_fd.pid"
file_ca="/opt/etc/ssl/certs/ca-certificates.crt"
ru_exclude_ipv4="$ipset_cfg/ru_exclude_ipv4.lst"
ru_exclude_ipv6="$ipset_cfg/ru_exclude_ipv6.lst"
ru_override="$ipset_cfg/ru_exclude_override.lst"

# Runtime state must stay in tmpfs, but must never be created in a
# world-writable location.  Recreate a squatted or incorrectly-modeled dir.
_xkeen_secure_rundir() {
    d="/tmp/.xkeen"
    if [ -e "$d" ] && [ ! -d "$d" ]; then
        rm -f "$d" 2>/dev/null
    fi
    if [ -d "$d" ]; then
        set -- $(ls -ld "$d" 2>/dev/null)
        mode="$1"
        owner="$3"
        if [ "$owner" != "root" ] || [ "$mode" != "drwx------" ]; then
            rm -rf "$d" 2>/dev/null
        fi
    fi
    [ -d "$d" ] || mkdir -m 700 "$d" 2>/dev/null || return 1
    chmod 700 "$d" 2>/dev/null || return 1
    printf '%s' "$d"
}
if ! xkeen_rundir=$(_xkeen_secure_rundir); then
    case "$1" in
        stop|status)
            xkeen_rundir="/tmp/.xkeen-unavailable"
            logger -p warning -t XKeen "Недоступен runtime-каталог; продолжаем $1 без runtime-state"
            ;;
        *)
            exit 1
            ;;
    esac
fi

# URL
url_server="127.0.0.1:79"
url_policy="rci/show/ip/policy"
url_keenetic_port="rci/ip/http"
url_redirect_port="rci/ip/static"
url_hotspot="rci/show/ip/hotspot"

# Настройки правил iptables
table_id="111"
table_mark="0x111"
table_redirect="nat"
table_tproxy="mangle"
comment_tag="xkeen_rule"
comment="-m comment --comment $comment_tag"
custom_mark=""

# DSCP-метки
dscp_enable="on"
dscp_force_proxy="61"
dscp_force_proxy_tag="force-proxy"
dscp_exclude="62"
dscp_proxy="63"

ipv4_proxy="127.0.0.1"
ipv4_exclude="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 255.255.255.255 78.47.125.180 198.51.100.11 198.51.100.37"
ipv6_proxy="::1"
ipv6_exclude="::/128 ::1/128 64:ff9b::/96 2001::/32 2002::/16 fd00::/8 ff00::/8 fe80::/10 2001:2:7847:1251:feee:ed78:4712:5180 2001:2::c633:640b 2001:2::c633:6425"

# Перехват DNS в прокси
proxy_dns="off"

# Проксирование трафика Entware
proxy_router="off"

# Строгая PBR-проверка mark / routing-mark
pbr_strict="off"

# Настройки запуска
start_verbose="on"
start_attempts=10
start_auto="on"
start_delay=20
init_delay=0

# Контроль файловых дескрипторов
check_fd="off"
arm64_fd=40000
other_fd=10000
delay_fd=60

# Поддержка IPv6
ipv6_support="on"

## Расширенные сообщения запуска
extended_msg="off"

## Резервное копирование XKeen при обновлении
backup="on"

## Клиенты XKeen под своими IP в журнале AdGuard Home
aghfix="off"

# Функции журналирования
log_info_router() { logger -p notice -t "$name_app" "$1"; }
log_warning_router() { logger -p warning -t "$name_app" "$1"; }
log_error_router() { logger -p error -t "$name_app" "$1"; }

log_info_terminal() { echo -e "\n${green}Информация${reset}: $1" >&2; }
log_warning_terminal() { echo -e "\n${yellow}Предупреждение${reset}: $1" >&2; }
log_error_terminal() { echo -e "\n${red}Ошибка${reset}: $1" >&2; exit 1; }

if [ "$dscp_enable" = "off" ]; then
    dscp_force_proxy=""
    dscp_exclude=""
    dscp_proxy=""
fi

# Дубль функции из 01_info_variable.sh: этот файл побайтово копируется в
# init.d/S05xkeen и модули не подключает, поэтому правки нужны в обоих местах.
# Обоснование разбора состоянием — там же.
strip_json_comments() {
    awk '
    {
        line = ""; i = 1; n = length($0); instr = 0; esc = 0
        while (i <= n) {
            c = substr($0, i, 1)
            if (inblk) {
                if (c == "*" && substr($0, i + 1, 1) == "/") { inblk = 0; i += 2 } else i++
                continue
            }
            if (instr) {
                line = line c
                if (esc) esc = 0
                else if (c == "\\") esc = 1
                else if (c == "\"") instr = 0
                i++
                continue
            }
            if (c == "\"") { instr = 1; line = line c; i++; continue }
            if (c == "/" && substr($0, i + 1, 1) == "*") { inblk = 1; i += 2; continue }
            if (c == "/" && substr($0, i + 1, 1) == "/") break
            line = line c; i++
        }
        print line
    }' "$@"
}

# Функция извлечения rci-токена
get_rci_token() {
    rci_token=""
    [ ! -f "$xkeen_config" ] && return 1

    local json_clean
    json_clean=$(strip_json_comments "$xkeen_config")

    rci_token=$(printf '%s' "$json_clean" | sed -n 's/.*"rci_token": *"\([^"]*\)".*/\1/p' | xargs 2>/dev/null)

    [ "$rci_token" = "null" ] && rci_token=""
}
get_rci_token

# Fail closed is deliberately opt-in.  Old configurations remain fail-open.
load_killswitch_settings() {
    local _ks_v
    killswitch="off"

    [ -f "$xkeen_config" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    _ks_v=$(strip_json_comments "$xkeen_config" | jq -r '.xkeen.killswitch // "off"' 2>/dev/null)

    [ "$_ks_v" = "on" ] && killswitch="on"
}
load_killswitch_settings

# GOMEMLIMIT для mihomo: доля RAM или абсолютный лимит из xkeen.json.
# Дефолт — 50% RAM (сохраняет прежнее поведение). Внешний
# GOMEMLIMIT в окружении всегда побеждает.
load_gomemlimit_settings() {
    gomemlimit_percent=50
    gomemlimit_mb=""

    [ ! -f "$xkeen_config" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    _gml_json=$(strip_json_comments "$xkeen_config")
    _gml_v=$(printf '%s' "$_gml_json" | jq -r '.xkeen.mihomo.gomemlimit_percent // empty' 2>/dev/null)
    if [ -n "$_gml_v" ] && [ "$_gml_v" -ge 1 ] 2>/dev/null && [ "$_gml_v" -le 90 ] 2>/dev/null; then
        gomemlimit_percent="$_gml_v"
    fi
    _gml_v=$(printf '%s' "$_gml_json" | jq -r '.xkeen.mihomo.gomemlimit_mb // empty' 2>/dev/null)
    if [ -n "$_gml_v" ] && [ "$_gml_v" -ge 64 ] 2>/dev/null; then
        gomemlimit_mb="$_gml_v"
    fi
    unset _gml_json _gml_v
}

# Выставляет GOMEMLIMIT и gomemlimit_value (для inject в netfilter-хук).
apply_gomemlimit() {
    [ -n "$GOMEMLIMIT" ] && { gomemlimit_value="$GOMEMLIMIT"; return 0; }

    load_gomemlimit_settings
    gomemlimit_value=""

    if [ -n "$gomemlimit_mb" ]; then
        gomemlimit_value="${gomemlimit_mb}MiB"
        export GOMEMLIMIT="$gomemlimit_value"
        return 0
    fi

    _mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$_mem_kb" ] && [ "$_mem_kb" -gt 0 ] 2>/dev/null; then
        _goml=$(( _mem_kb * gomemlimit_percent / 100 / 1024 ))
        [ "$_goml" -lt 64 ] && _goml=64
        gomemlimit_value="${_goml}MiB"
        export GOMEMLIMIT="$gomemlimit_value"
    fi
    unset _mem_kb _goml
}

wait_for_webui() {
    max_wait=20
    i=0

    while [ "$i" -lt "$max_wait" ]; do
        pidof nginx >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done

    return 1
}

wait_for_rci_token() {
    [ -n "$rci_token" ] || return 1

    wait_for_webui || {
        log_error_router "Веб-интерфейс недоступен"
        return 1
    }

    http_code=$(curl -ksS -o /dev/null -w "%{http_code}" -H "X-Ndma-Tkn: $rci_token" "${url_server}/${url_policy}")

    case "$http_code" in
        200) return 0 ;;
        401|403)
            log_error_router "Отсутствует или недействителен токен доступа к RCI роутера"
            log_error_terminal "Отсутствует или недействителен токен доступа к RCI роутера"
            ;;
        *)
            log_error_router "RCI не отвечает (http_code=$http_code)"
            log_error_terminal "RCI не отвечает (http_code=$http_code)"
            ;;
    esac
}
wait_for_rci_token

# Параметры curl
curl_api() {
    if [ -n "$rci_token" ]; then
        curl --connect-timeout 2 -m 5 -kfsS -H "X-Ndma-Tkn: $rci_token" "$@"
    else
        curl --connect-timeout 2 -m 5 -kfsS "$@"
    fi
}

detect_architecture() {
    arm_cpu="false"
    command -v opkg >/dev/null 2>&1 || return
    case "$(opkg print-architecture | awk '!/all/ {print $2; exit}')" in
        aarch64*) arm_cpu="true" ;;
    esac
}

print_policy_info() {
    found="$1"
    has_custom="$2"
    ignored_custom="$3"

    ignore_line=""
    if [ "$ignored_custom" = "yes" ]; then
        ignore_line="
  Пользовательские политики из '${yellow}xkeen.json${reset}' будут проигнорированы"
    fi

    if [ "$extended_msg" != "on" ]; then
        if [ "$found" = "no" ]; then
            log_info_terminal "
  Политика '${yellow}$name_policy${reset}' не найдена в веб-интерфейсе роутера${ignore_line}
  Прокси будет запущен для всех клиентов устройства"
        fi
        return
    fi

    if [ "$found" = "yes" ]; then

        if [ "$has_custom" = "yes" ]; then
            custom_names=$(echo "$user_policies" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
            policies="${name_policy}, ${custom_names}"

            detail_list=""
            if [ -n "$port_donor" ]; then
                detail_list="  - ${yellow}$name_policy${reset} на портах ${green}${port_donor}${reset}"
            elif [ -n "$port_exclude" ]; then
                detail_list="  - ${yellow}$name_policy${reset} на всех портах кроме ${green}${port_exclude}${reset}"
            else
                detail_list="  - ${yellow}$name_policy${reset} на всех портах"
            fi

            custom_details=$(echo "$user_policies" | while IFS='|' read -r p_name p_mark p_mode p_ports; do
                if [ "$p_mode" = "include" ]; then
                    echo "  - ${yellow}$p_name${reset} на портах ${green}${p_ports}${reset}"
                elif [ "$p_mode" = "exclude" ]; then
                    echo "  - ${yellow}$p_name${reset} на всех портах кроме ${green}${p_ports}${reset}"
                else
                    echo "  - ${yellow}$p_name${reset} на всех портах"
                fi
            done)

            log_info_terminal "
  Найдены политики '${yellow}${policies}${reset}'
  Прокси будет запущен для клиентов политик:
${detail_list}
${custom_details}"
        else
            if [ -z "$port_donor" ] && [ -z "$port_exclude" ]; then
                log_info_terminal "
  Найдена политика '${yellow}$name_policy${reset}'
  Не определены целевые порты для XKeen
  Прокси будет запущен для клиентов политики '${yellow}$name_policy${reset}' на всех портах"
            elif [ -n "$port_donor" ]; then
                log_info_terminal "
  Найдена политика '${yellow}$name_policy${reset}'
  Определены целевые порты для XKeen
  Прокси будет запущен для клиентов политики '${yellow}$name_policy${reset}'
  на портах ${green}${port_donor}${reset}"
            else
                log_info_terminal "
  Найдена политика '${yellow}$name_policy${reset}'
  Определены порты исключения для XKeen
  Прокси будет запущен для клиентов политики '${yellow}$name_policy${reset}'
  на всех портах кроме ${green}${port_exclude}${reset}"
            fi
        fi
    else
        if [ -n "$port_donor" ]; then
            log_info_terminal "
  Политика '${yellow}$name_policy${reset}' не найдена в веб-интерфейсе роутера${ignore_line}
  Определены целевые порты для XKeen
  Прокси будет запущен для всех клиентов
  на портах ${green}${port_donor}${reset}"
        elif [ -n "$port_exclude" ]; then
            log_info_terminal "
  Политика '${yellow}$name_policy${reset}' не найдена в веб-интерфейсе роутера${ignore_line}
  Определены порты исключения для XKeen
  Прокси будет запущен для всех клиентов
  на всех портах кроме ${green}${port_exclude}${reset}"
        else
            log_info_terminal "
  Политика '${yellow}$name_policy${reset}' не найдена в веб-интерфейсе роутера${ignore_line}
  Не определены целевые порты для XKeen
  Прокси будет запущен для всех клиентов на всех портах"
        fi
    fi
}

utils="jq curl grep awk sed ipset ip"
[ "$name_client" = "mihomo" ] && utils="$utils yq"
for cmd in $utils; do
    command -v "$cmd" >/dev/null 2>&1 || log_error_terminal "Не найдена необходимая утилита: ${yellow}$cmd${reset}"
done

if readlink $(which ip) | grep -q 'busybox'; then
    log_error_terminal "Обнаружена урезанная версия ip (BusyBox). Необходим пакет: ${yellow}ip-full${reset}"
fi

log_clean() { [ "$name_client" = "xray" ] && : > "$log_access" && : > "$log_error"; }

api_cache_init() {
    api_policy_json=$(curl_api "${url_server}/${url_policy}" 2>/dev/null)
    api_port_json=$(curl_api "${url_server}/${url_keenetic_port}" 2>/dev/null)
    api_static_json=$(curl_api "${url_server}/${url_redirect_port}" 2>/dev/null)
}

refresh_port_cache() { api_port_json=$(curl_api "${url_server}/${url_keenetic_port}" 2>/dev/null); }

json_get_ports() { [ -n "$api_port_json" ] && printf '%s' "$api_port_json" | jq -r '.port, (.ssl.port // empty)' 2>/dev/null; }

# Получение портов Keenetic
get_keenetic_port() {
    ports=""
    ports=$(json_get_ports)

    case " $ports " in
        *" 443 "*) return 1 ;;
    esac

    if [ -z "$ports" ]; then
        ndmc -c 'ip http port 8080' >/dev/null 2>&1
        ndmc -c 'ip http port 80' >/dev/null 2>&1
        ndmc -c 'system configuration save' >/dev/null 2>&1
        sleep 2
        refresh_port_cache
        ports=$(json_get_ports)
    fi

    [ -n "$ports" ] || return 1

    echo "$ports"
    return 0
}

apply_ipv6_state() {
    ipv6_disabled=
    ipv6_disabled=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "0")

    [ "$ipv6_disabled" -eq 1 ] && return 0

    [ "$ipv6_support" != "off" ] && return 0

    ip -6 addr show 2>/dev/null | grep -q "inet6 fe80::" || return 0

    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

    for dir in /proc/sys/net/ipv6/conf/*; do
        [ -d "$dir" ] || continue
        iface="${dir##*/}"

        case "$iface" in
            all|ezcfg0|t2s*)
                continue
                ;;
            *)
                [ -f "$dir/disable_ipv6" ] && echo "1" > "$dir/disable_ipv6" 2>/dev/null
                ;;
        esac
    done

    sleep 2

    if [ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" -eq 1 ]; then
        log_info_router "Отключение IPv6 выполнено"
        return 0
    fi
}

get_ipver_support() {
    ip4_supported=$(ip -4 addr show 2>/dev/null | grep -q "inet " && echo true || echo false)
    ip6_supported=$(ip -6 addr show 2>/dev/null | grep -q "inet6 fe80::" && echo true || echo false)

    iptables_supported=$([ "$ip4_supported" = "true" ] && command -v iptables >/dev/null 2>&1 && echo true || echo false)
    ip6tables_supported=$([ "$ip6_supported" = "true" ] && command -v ip6tables >/dev/null 2>&1 && echo true || echo false)
}

append_multiline() {
    current_value="$1"
    new_value="$2"

    if [ -n "$current_value" ]; then
        printf '%s\n%s' "$current_value" "$new_value"
    else
        printf '%s' "$new_value"
    fi
}

format_routing_mark_items() {
    item_label="$1"
    mark_label="$2"
    raw_items="$3"

    printf '%b\n' "$raw_items" | awk -F '\t' -v item_label="$item_label" -v mark_label="$mark_label" '
        NF == 0 || seen[$0]++ { next }
        {
            status = ($2 == "" ? mark_label " отсутствует" : "найден " mark_label " " $2)
            print "  - " item_label " " $1 ": " status
        }
    '
}

# Функция валидации xkeen.json
validate_xkeen_json() {
    [ ! -f "$xkeen_config" ] && return 0

    if ! strip_json_comments "$xkeen_config" | jq -e . >/dev/null 2>&1; then
        log_error_terminal "
  Валидация JSON: файл '${yellow}xkeen.json${reset}' содержит синтаксические ошибки
  Запуск прокси невозможен
"
    fi

    jq_check=
    jq_check='
      if has("xkeen") and .xkeen != null then
        if .xkeen.policy then
          .xkeen.policy | type == "array" and ([.[] | select(has("name") | not)] | length == 0)
        else
          true
        end
      else
        true
      end
    '

    if ! strip_json_comments "$xkeen_config" | jq -e "$jq_check" >/dev/null 2>&1; then
        log_error_terminal "
  Файл '${yellow}xkeen.json${reset}' имеет неверную структуру
  Запуск прокси невозможен
"
    fi

    return 0
}

# Функция поиска резервных копий конфигурационных файлов Xray
check_xray_backups() {
    [ "$name_client" != "xray" ] && return 0

    # Ищем json-файлы с типичными признаками копий
    bad_files=$(find "$directory_xray_config" -maxdepth 1 -type f \( -iname "*bak*.json" -o -iname "*old*.json" -o -iname "*copy*.json" -o -iname "*копия*.json" -o -iname "*orig*.json" -o -iname "*save*.json" -o -iname "*temp*.json" -o -iname "*tmp*.json" -o -name "*(*).json" \))

    if [ -n "$bad_files" ]; then
        bad_list=$(printf '%s\n' "$bad_files" | awk -F/ '{print "  - " $NF}')
        
        log_error_terminal "
  В директории конфигурации Xray найдены резервные копии:
${light_blue}${bad_list}${reset}

  Измените расширение резервных копий, например, на ${yellow}.bak${reset}
  Либо переместите их в поддиректорию
  Запуск ${yellow}$name_client${reset} ${red}отменен${reset}
"
    fi
    return 0
}

build_allowed_policy_marks() {
    include_service_mark="$1"
    allowed_marks=""
    policy_hex_marks="$policy_mark"

    if [ "$include_service_mark" = "yes" ]; then
        # 255 bypasses XKeen; 256 is intentionally recaptured for nested
        # proxy transports such as Mihomo's embedded Tailscale outbound.
        allowed_marks="255 256"
    fi

    if [ -n "$user_policies" ]; then
        user_policy_hex_marks=$(printf '%s\n' "$user_policies" | awk -F'|' '$2 != "" {print "0x"$2}')
        policy_hex_marks="$policy_hex_marks $user_policy_hex_marks"
    fi

    for policy_hex_mark in $policy_hex_marks; do
        policy_mark_dec=$(hex_mark_to_decimal "$policy_hex_mark" 2>/dev/null)
        [ -n "$policy_mark_dec" ] && allowed_marks="$allowed_marks $policy_mark_dec"
    done

    if [ -n "$allowed_marks" ]; then
        allowed_marks=$(printf '%s\n' $allowed_marks | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
    fi

    printf '%s\n' "$allowed_marks"
}

format_allowed_marks_display() {
    printf '%s\n' "$1" | tr ' ' '\n' | awk '
        NF && !seen[$0]++ {
            if (out != "") {
                out = out ", " $0
            } else {
                out = $0
            }
        }
        END {
            print out
        }
    '
}

format_single_line_error() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

convert_mihomo_yaml_to_json() {
    config_file="$1"
    tmp_base="${TMPDIR:-/tmp}/xkeen_mihomo_json.$$"
    out_file="${tmp_base}.out"
    err_file="${tmp_base}.err"

    rm -f "$out_file" "$err_file"

    if yq -o=json '.' "$config_file" >"$out_file" 2>"$err_file" \
        && jq -e . <"$out_file" >/dev/null 2>&1; then
        cat "$out_file"
        rm -f "$out_file" "$err_file"
        return 0
    fi

    last_stderr=$(format_single_line_error "$(cat "$err_file" 2>/dev/null)")
    rm -f "$out_file" "$err_file"

    if [ -n "$last_stderr" ]; then
        printf '%s' "не удалось преобразовать YAML в JSON через yq: $last_stderr"
    else
        printf '%s' "yq не вернул валидный JSON"
    fi

    return 1
}

validate_client_routing_mark() {
    validation_mode="$1"
    include_service_mark="$2"

    bad_items=""
    has_items="false"
    allowed_marks=$(build_allowed_policy_marks "$include_service_mark")
    validation_errors=""
    mark_msg=""
    item_label=""
    item_label_plural=""
    config_hint=""
    needs_attention="false"
    allowed_marks_display=""
    global_mark_valid="false"
    provider_mark_valid="false"

    allowed_marks_display=$(format_allowed_marks_display "$allowed_marks")
    if [ "$name_client" = "xray" ]; then
        mark_msg="mark"
        item_label="outbound"
        item_label_plural="outbounds"
        config_hint="  Для Xray задайте ${green}mark${reset} в ${yellow}streamSettings.sockopt${reset} у всех реальных outbounds, кроме служебных (${yellow}blackhole${reset}, ${yellow}loopback${reset})"

        for file in "$directory_xray_config"/*.json; do
            [ -f "$file" ] || continue

            outbounds_state=$(strip_json_comments "$file" | jq -r '
                if .outbounds == null then
                    "missing"
                elif (.outbounds | type) == "array" then
                    "array"
                else
                    "invalid"
                end
            ' 2>&1)
            outbounds_state_rc=$?

            if [ "$outbounds_state_rc" -ne 0 ]; then
                validation_errors=$(append_multiline "$validation_errors" "$(basename "$file"): $outbounds_state")
                continue
            fi

            case "$outbounds_state" in
                missing)
                    continue
                    ;;
                invalid)
                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$file"): поле .outbounds должно быть массивом")
                    continue
                    ;;
                array)
                    has_items="true"
                    ;;
            esac

            current_bad=$(strip_json_comments "$file" | jq -r --arg allowed "$allowed_marks" '
                def flatten_nested_arrays:
                    if type == "array" then
                        .[] | flatten_nested_arrays
                    else
                        .
                    end;

                (.outbounds // [])
                | .[]?
                | flatten_nested_arrays
                | select(type == "object")
                | select((.protocol // "") != "blackhole" and (.protocol // "") != "loopback")
                | (.streamSettings? | if type == "object" then . else {} end) as $stream
                | ($stream.sockopt? | if type == "object" then . else {} end) as $sockopt
                | ($sockopt.mark? // null) as $mark
                | select(($allowed | split(" ") | index((if $mark == null or $mark == "" then "" else ($mark | tostring) end))) | not)
                | [(.tag // .protocol // "<unnamed>"), (if $mark == null or $mark == "" then "" else ($mark | tostring) end)] | @tsv
            ' 2>&1)
            current_bad_rc=$?

            if [ "$current_bad_rc" -ne 0 ]; then
                validation_errors=$(append_multiline "$validation_errors" "$(basename "$file"): $current_bad")
                continue
            fi

            if [ -n "$current_bad" ]; then
                bad_items=$(append_multiline "$bad_items" "$current_bad")
            fi
        done

    elif [ "$name_client" = "mihomo" ]; then
        mark_msg="routing-mark"
        item_label="proxy"
        item_label_plural="proxies"
        config_hint="  Для Mihomo задайте ${green}routing-mark${reset} глобально либо у нужных ${yellow}proxies${reset}/${yellow}proxy-providers${reset}"

        if [ -f "$mihomo_config" ]; then
            mihomo_json=$(convert_mihomo_yaml_to_json "$mihomo_config")
            mihomo_json_rc=$?

            if [ "$mihomo_json_rc" -ne 0 ]; then
                validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $mihomo_json")
            else
                if ! printf '%s' "$mihomo_json" | jq -e . >/dev/null 2>&1; then
                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): yq не вернул валидный JSON")
                else
                root_kind=$(printf '%s' "$mihomo_json" | jq -r 'type' 2>&1)
                root_kind_rc=$?

                if [ "$root_kind_rc" -ne 0 ]; then
                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $root_kind")
                elif [ "$root_kind" != "object" ]; then
                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): корень config.yaml должен быть map/object")
                else
                    global_mark_valid=$(printf '%s' "$mihomo_json" | jq -r --arg allowed "$allowed_marks" '
                        .["routing-mark"] as $mark
                        | if $mark != null and (($allowed | split(" ") | index($mark | tostring)) != null) then
                            "true"
                        else
                            "false"
                        end
                    ' 2>&1)
                    global_mark_valid_rc=$?
                    [ "$global_mark_valid_rc" -ne 0 ] && validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $global_mark_valid")

                    provider_mark_valid=$(printf '%s' "$mihomo_json" | jq -r --arg allowed "$allowed_marks" '
                        def values_or_items:
                            if type == "object" or type == "array" then
                                .[]?
                            else
                                empty
                            end;

                        [
                            (.["proxy-providers"] // empty)
                            | values_or_items
                            | select(type == "object")
                            | (.override? | if type == "object" then . else {} end)
                            | .["routing-mark"]? as $mark
                            | select($mark != null)
                            | (($allowed | split(" ") | index($mark | tostring)) != null)
                        ] | any
                    ' 2>&1)
                    provider_mark_valid_rc=$?
                    [ "$provider_mark_valid_rc" -ne 0 ] && validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $provider_mark_valid")

                    proxies_state=$(printf '%s' "$mihomo_json" | jq -r '
                        if .proxies == null then
                            "missing"
                        elif (.proxies | type) == "array" then
                            "array"
                        else
                            "invalid"
                        end
                    ' 2>&1)
                    proxies_state_rc=$?

                    if [ "$proxies_state_rc" -ne 0 ]; then
                        validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $proxies_state")
                    else
                        case "$proxies_state" in
                            missing)
                                if [ "$global_mark_valid" != "true" ] && [ "$provider_mark_valid" != "true" ]; then
                                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): не найдены proxies и нет глобального/provider routing-mark для проверки")
                                fi
                                ;;
                            invalid)
                                validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): поле .proxies должно быть массивом")
                                ;;
                            array)
                                has_items="true"
                                current_bad=$(printf '%s' "$mihomo_json" | jq -r --arg allowed "$allowed_marks" --arg global_valid "$global_mark_valid" '
                                    def flatten_nested_arrays:
                                        if type == "array" then
                                            .[] | flatten_nested_arrays
                                        else
                                            .
                                        end;

                                    (.proxies // [])
                                    | .[]?
                                    | flatten_nested_arrays
                                    | select(type == "object")
                                    | (.["routing-mark"]? // null) as $mark
                                    | select(
                                        if $mark == null or $mark == "" then
                                            $global_valid != "true"
                                        else
                                            (($allowed | split(" ") | index($mark | tostring)) == null)
                                        end
                                    )
                                    | [(.name // .type // "<unnamed>"), (if $mark == null or $mark == "" then "" else ($mark | tostring) end)] | @tsv
                                ' 2>&1)
                                current_bad_rc=$?

                                if [ "$current_bad_rc" -ne 0 ]; then
                                    validation_errors=$(append_multiline "$validation_errors" "$(basename "$mihomo_config"): $current_bad")
                                elif [ -n "$current_bad" ]; then
                                    bad_items=$(append_multiline "$bad_items" "$current_bad")
                                fi
                                ;;
                        esac
                    fi
                fi
                fi
            fi
        else
            validation_errors=$(append_multiline "$validation_errors" "config.yaml: файл не найден")
        fi
    fi

    if [ -n "$validation_errors" ] || [ -n "$bad_items" ] || { [ "$name_client" = "xray" ] && [ "$has_items" != "true" ]; }; then
        needs_attention="true"
    fi

    [ "$needs_attention" != "true" ] && return 0

    error_details=""

    if [ "$name_client" = "xray" ] && [ "$has_items" != "true" ] && [ -z "$validation_errors" ]; then
        validation_errors=$(append_multiline "$validation_errors" "Не найдены реальные outbounds для проверки")
    fi

    if [ -n "$validation_errors" ]; then
        validation_list=$(printf "%b\n" "$validation_errors" | awk '!seen[$0]++ {print "  - " $0}')
        error_details="${error_details}

  Не удалось полностью проверить конфигурацию:
${light_blue}${validation_list}${reset}"
    fi

    if [ -n "$bad_items" ]; then
        bad_list=$(format_routing_mark_items "$item_label" "$mark_msg" "$bad_items")
        error_details="${error_details}

  Проблемные ${item_label_plural}:
${light_blue}${bad_list}${reset}"
    fi

    if [ -n "$bad_items" ] || { [ "$name_client" = "xray" ] && [ "$has_items" != "true" ] && [ -z "$validation_errors" ]; }; then
        validation_summary="не найден"
        pbr_validation_summary="не найден корректный"
    else
        validation_summary="не удалось проверить"
        pbr_validation_summary="не удалось проверить корректный"
    fi

    if [ "$validation_mode" = "pbr" ]; then
        log_error_terminal "
  Включена strict PBR-проверка, но у исходящих подключений ${yellow}${name_client}${reset} ${pbr_validation_summary} ${yellow}mark/routing-mark${reset} политики Keenetic$error_details

  Разрешённые policy marks Keenetic: ${yellow}${allowed_marks_display}${reset}
$config_hint
  Служебная метка ${yellow}255${reset} не является policy mark и не подходит для PBR
  Получите код политики командой ${yellow}xkeen -pbr codes${reset} и укажите его в конфигурации
  Управление режимом: ${yellow}xkeen -pbr on${reset} | ${yellow}xkeen -pbr off${reset} | ${yellow}xkeen -pbr status${reset}
"
    else
        log_warning_terminal "
  Для проксирования трафика Entware требуется его маркировка
  В конфигурации ${yellow}${name_client}${reset} ${validation_summary} ${yellow}mark/routing-mark${reset} для bypass$error_details

  Для обычного Entware proxy можно использовать служебную метку ${yellow}255${reset}
  Метка ${yellow}256${reset} предназначена только для повторного захвата вложенного proxy-транспорта
  Разрешённые service marks: ${yellow}${allowed_marks_display}${reset}
$config_hint
  Если нужно направить сам ${yellow}${name_client}${reset} через конкретную политику Keenetic, используйте код из ${yellow}xkeen -pbr codes${reset}

  Отсутствие маркировки в этом режиме приведет к петле трафика и зависанию роутера
  Проксирование трафика Entware ${red}отключено${reset} для безопасности
"
        proxy_router="off"
    fi

    return 0
}

validate_entware_proxy_mark() {
    [ "$proxy_router" != "on" ] && return 0
    validate_client_routing_mark "entware" "yes"
}

validate_pbr_routing_mark() {
    [ "$pbr_strict" != "on" ] && return 0

    allowed_policy_marks=$(build_allowed_policy_marks "no")
    if [ -z "$allowed_policy_marks" ]; then
        log_error_terminal "
  Не удалось получить коды политик Keenetic для PBR
  Создайте или проверьте политику в веб-интерфейсе Keenetic и повторите ${yellow}xkeen -pbr codes${reset}
  Служебная метка ${yellow}255${reset} не является policy mark и не подходит для PBR
"
    fi

    validate_client_routing_mark "pbr" "no"
}

load_user_ipset_family() {
    set_name="$1"
    family="$2"
    addr_regex="$3"
    source_file="$4"
    tmp="${set_name}_tmp"

    # Заполняем tmp; основной набор подменяется только после успешного pipeline
    ipset create "$set_name" hash:net family "$family" -exist
    ipset create "$tmp" hash:net family "$family" -exist
    ipset flush "$tmp"

    if sed -e 's/\r$//' -e 's/#.*//' -e '/^[[:space:]]*$/d' "$source_file" |
       grep -Eo "$addr_regex" |
       awk -v s="$tmp" '{print "add "s" "$1}' | ipset restore -exist; then
        ipset swap "$set_name" "$tmp"
    fi
    ipset destroy "$tmp"
}

# Функция загрузки пользовательских исключений в ipset
load_user_ipset() {
    [ ! -f "$file_ip_exclude" ] && return
    [ "$iptables_supported" = "true" ] && load_user_ipset_family user_exclude inet '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$file_ip_exclude"
    [ "$ip6tables_supported" = "true" ] && load_user_ipset_family user_exclude6 inet6 '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?' "$file_ip_exclude"

    # Обработка списка исключений из geo_exclude
    if [ -f "$ru_override" ]; then
        [ "$iptables_supported" = "true" ] && load_user_ipset_family geo_override inet '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$ru_override"
        [ "$ip6tables_supported" = "true" ] && load_user_ipset_family geo_override6 inet6 '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?' "$ru_override"
    else
        # Если файла исключений нет, создаем пустые сеты, чтобы iptables не ругался на их отсутствие
        [ "$iptables_supported" = "true" ] && ipset create geo_override hash:net family inet -exist
        [ "$ip6tables_supported" = "true" ] && ipset create geo_override6 hash:net family inet6 -exist
    fi
}

# Функция чтения пользовательских портов из файлов
read_ports_from_file() {
    file_ports="$1"
    [ -f "$file_ports" ] || return

    sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$file_ports"
}

# Функция обработки, валидации и нормализации списка портов
validate_and_clean_ports() {
    input_ports="$1"
    mandatory_ports="$2"
    [ -z "$input_ports" ] && [ -z "$mandatory_ports" ] && return 1

    echo "${mandatory_ports}${mandatory_ports:+,}${input_ports}" | tr ',' '\n' | awk '
        function is_valid(p) {
            return p ~ /^[0-9]+$/ && p > 0 && p <= 65535
        }
        {
            gsub(/[[:space:]]/, "", $0)
            gsub(/-/, ":", $0)
            if ($0 == "") next

            n = split($0, a, ":")

            if (n == 1) {
                if (is_valid(a[1])) {
                    print a[1]
                }
            }

            else if (n == 2) {
                if (is_valid(a[1]) && is_valid(a[2])) {
                    start = a[1]
                    end   = a[2]

                    if (start > end) {
                        tmp = start
                      …21432 tokens truncated…        [ "$ip6tables_supported" = "true" ] && configure_route 6
        _xkeen_apply
        [ -n "$_xkeen_cur_wan" ] && printf '%s' "$_xkeen_cur_wan" > "$_xkeen_wan_state"
        _xkeen_release_nf_lock
        _xkeen_sync_deny_mac_ipset
        exit 0
    fi

    if [ -n "$port_donor" ] || [ -n "$port_exclude" ]; then
        [ "$file_dns" = "true" ] && [ "$proxy_dns" = "on" ] && [ -n "$port_donor" ] && port_donor="53,$port_donor"
    fi
    for family in iptables ip6tables; do

        [ "$family" = "ip6tables" ] && [ "$ip6tables_supported" != "true" ] && continue
        [ "$family" = "iptables" ] && [ "$iptables_supported" != "true" ] && continue

        if [ "$family" = "ip6tables" ]; then
            exclude_list="$val_exclude_ip6"
            proxy_ip="$ipv6_proxy"
            configure_route 6
        else
            exclude_list="$val_exclude_ip4"
            proxy_ip="$ipv4_proxy"
            configure_route 4
        fi
        if [ -n "$port_redirect" ] && [ -n "$port_tproxy" ]; then
            for table in "$table_tproxy" "$table_redirect"; do
                add_ipt_rule "$family" "$table" "$name_chain"
                add_force_ipt_rule "$family" "$table" "${name_chain}_force"
                add_prerouting "$family" "$table"
                add_output "$family" "$table"
            done
        elif [ -z "$port_redirect" ] && [ -n "$port_tproxy" ]; then
            table="$table_tproxy"
            add_ipt_rule "$family" "$table" "$name_chain"
            add_force_ipt_rule "$family" "$table" "${name_chain}_force"
            add_prerouting "$family" "$table"
            add_output "$family" "$table"
        elif [ -n "$port_redirect" ] && [ -z "$port_tproxy" ]; then
            table="$table_redirect"
            add_ipt_rule "$family" "$table" "$name_chain"
            add_prerouting "$family" "$table"
            add_output "$family" "$table"
        fi

        dns_redir "$family"
    done

    # Атомарно применяем все аккумулированные правила одним
    # iptables-restore --noflush per (family, table).
    _xkeen_apply

    # Блобы детерминированы конфигурацией — сохраняем для быстрых
    # последующих прогонов (см. _xkeen_cache_* выше).
    _xkeen_cache_save

    # Медленная часть (curl к hotspot API) — строго после восстановления
    # правил и после снятия nf-lock: см. комментарий у _xkeen_sync_deny_mac_ipset.
    [ -n "$_xkeen_cur_wan" ] && printf '%s' "$_xkeen_cur_wan" > "$_xkeen_wan_state"
    _xkeen_release_nf_lock
    _xkeen_sync_deny_mac_ipset
else
    # mkdir-lock с PID: обычный touch-файл залипал навсегда после OOM
    # посреди respawn mihomo из хука — следующие события NDM тихо no-op.
    _xkeen_start_lock="$_xkeen_rundir/starting.lock.d"
    if ! mkdir "$_xkeen_start_lock" 2>/dev/null; then
        _sl_pid=$(cat "$_xkeen_start_lock/pid" 2>/dev/null)
        if [ -n "$_sl_pid" ] && kill -0 "$_sl_pid" 2>/dev/null; then
            exit 0
        fi
        rm -rf "$_xkeen_start_lock" 2>/dev/null
        mkdir "$_xkeen_start_lock" 2>/dev/null || exit 0
    fi
    printf '%s' "$$" > "$_xkeen_start_lock/pid"
    trap 'rm -rf "$_xkeen_start_lock"' EXIT INT TERM

    fd_limit="$other_fd"
    [ "$arm_cpu" = "true" ] && fd_limit="$arm64_fd"
    ulimit -SHn "$fd_limit"

    export SSL_CERT_FILE="$file_ca"
    case "$name_client" in
        xray)
            export XRAY_LOCATION_CONFDIR="$directory_xray_config"
            export XRAY_LOCATION_ASSET="$directory_xray_asset"
            "$name_client" run >/dev/null 2>&1 &
        ;;
        mihomo)
            export CLASH_HOME_DIR="$directory_configs_app"
            # Мягкий лимит памяти для Go GC. Значение запекается при
            # configure_firewall из xkeen.json (gomemlimit_percent /
            # gomemlimit_mb) или внешнего GOMEMLIMIT.
            if [ -z "$GOMEMLIMIT" ] && [ -n "$gomemlimit_value" ]; then
                export GOMEMLIMIT="$gomemlimit_value"
            fi
            "$name_client" >/dev/null 2>&1 &
        ;;
    esac
    _probe=0
    while [ "$_probe" -lt 60 ]; do
        pidof "$name_client" >/dev/null 2>&1 && break
        _probe=$((_probe + 1))
        usleep 100000
    done
    unset _probe
    rm -rf "$_xkeen_start_lock"
    trap - EXIT INT TERM
    if pidof "$name_client" >/dev/null; then
        restart_script "$@"
    else
        exit 1
    fi
fi
EOL
    sed -i '1,2!{/^[[:space:]]*#/d; /^[[:space:]]*$/d}' "$file_netfilter_hook"
    chmod 700 "$file_netfilter_hook"
    mv -f "$file_netfilter_hook" "$_hook_live" || {
        rm -f "$file_netfilter_hook"
        file_netfilter_hook="$_hook_live"
        log_error_router "Не удалось атомарно обновить netfilter-хук"
        return 1
    }
    file_netfilter_hook="$_hook_live"

    # Schedule.d-хук: NDM вызывает scripts/schedule.d при start/stop расписаний
    # (родительский контроль). Хук дёргает netfilter.d/proxy.sh, который
    # ре-синхронизирует ipset deny-MAC из актуального hotspot API.
    mkdir -p "$(dirname "$file_schedule_hook")" 2>/dev/null
    cat > "$file_schedule_hook" <<'SCHEDULE_EOL'
#!/bin/sh
# XKeen: re-sync deny MAC ipset on schedule start/stop. Auto-generated. DO NOT EDIT!
[ "$1" = "start" ] || [ "$1" = "stop" ] || exit 0
[ -x /opt/etc/ndm/netfilter.d/proxy.sh ] && /opt/etc/ndm/netfilter.d/proxy.sh
SCHEDULE_EOL
    chmod 755 "$file_schedule_hook"

    return 0
}

# Удаление правил iptables
clean_firewall() {
    _acquire_nf_lock
    _cf_nf_rc=$?

    # Атомарно гасим хук: truncate live mid-renew больше не оставляем.
    if [ -f "$file_netfilter_hook" ] || [ -e "$file_netfilter_hook" ]; then
        _cf_hook_tmp="${file_netfilter_hook}.clean.$$"
        : > "$_cf_hook_tmp"
        mv -f "$_cf_hook_tmp" "$file_netfilter_hook" 2>/dev/null || : > "$file_netfilter_hook"
    fi

    get_ipver_support

    for family in iptables ip6tables; do
        [ "$family" = "iptables" ] && [ "$iptables_supported" != "true" ] && continue
        [ "$family" = "ip6tables" ] && [ "$ip6tables_supported" != "true" ] && continue

        if "$family" -w -t nat -nL _NDM_HOTSPOT_DNSREDIR >/dev/null 2>&1; then
            "$family" -w -t nat -S _NDM_HOTSPOT_DNSREDIR | grep -E -- "$comment_tag" | sed 's/^-A /-D /' | while IFS= read -r rule; do
                [ -n "$rule" ] && "$family" -w -t nat $rule >/dev/null 2>&1
            done
        fi
    done

    clean_run() {
        family="$1"
        table="$2"
        name_chain="$3"

        for sys_chain in PREROUTING OUTPUT; do
            "$family" -w -t "$table" -S "$sys_chain" 2>/dev/null | grep -E -- "$comment_tag" | sed 's/^-A /-D /' | while IFS= read -r rule; do
                [ -n "$rule" ] && "$family" -w -t "$table" $rule >/dev/null 2>&1
            done
        done

        if "$family" -w -t "$table" -nL "$name_chain" >/dev/null 2>&1; then
            "$family" -w -t "$table" -F "$name_chain" >/dev/null 2>&1
            "$family" -w -t "$table" -X "$name_chain" >/dev/null 2>&1
        fi

        out_chain="${name_chain}_out"
        if "$family" -w -t "$table" -nL "$out_chain" >/dev/null 2>&1; then
            "$family" -w -t "$table" -F "$out_chain" >/dev/null 2>&1
            "$family" -w -t "$table" -X "$out_chain" >/dev/null 2>&1
        fi

        force_chain="${name_chain}_force"
        if "$family" -w -t "$table" -nL "$force_chain" >/dev/null 2>&1; then
            "$family" -w -t "$table" -F "$force_chain" >/dev/null 2>&1
            "$family" -w -t "$table" -X "$force_chain" >/dev/null 2>&1
        fi

        killswitch_chain="${name_chain}_killswitch"
        if "$family" -w -t "$table" -nL "$killswitch_chain" >/dev/null 2>&1; then
            "$family" -w -t "$table" -F "$killswitch_chain" >/dev/null 2>&1
            "$family" -w -t "$table" -X "$killswitch_chain" >/dev/null 2>&1
        fi
    }

    for family in iptables ip6tables; do
        for chain in nat mangle; do
            clean_run "$family" "$chain" "$name_chain"
        done
    done

    if command -v ip >/dev/null 2>&1; then
        for family in 4 6; do
            while ip -"$family" rule del fwmark "$table_mark" lookup "$table_id" >/dev/null 2>&1; do :; done
            ip -"$family" route flush table "$table_id" >/dev/null 2>&1 || true
        done
    fi

    # Очистка и удаление списков ipset
    if command -v ipset >/dev/null 2>&1; then
        for set in geo_override geo_override6 geo_exclude geo_exclude6 user_exclude user_exclude6 "$name_ipset_deny_mac"; do
            ipset flush "$set" >/dev/null 2>&1
            ipset destroy "$set" >/dev/null 2>&1
        done
    fi

    # Schedule.d-hook идемпотентно перегенерируется в configure_firewall,
    # на остановке убираем чтобы NDM не дёргал мёртвый netfilter.d/proxy.sh.
    [ -f "$file_schedule_hook" ] && rm -f "$file_schedule_hook"

    # rc=2 — re-entrant (тот же PID уже держал lock), чужой замок не снимаем.
    [ "$_cf_nf_rc" -ne 2 ] && _release_nf_lock
}

# Мониторинг файловых дескрипторов
monitor_fd() {
    while true; do
        client_pid=$(pidof "$name_client" | awk '{print $1}')
        if [ -n "$client_pid" ] && [ -d "/proc/$client_pid/fd" ]; then
            limit=$(awk '/Max open files/ {print $4}' "/proc/$client_pid/limits")
            set -- /proc/$client_pid/fd/*
            [ -e "$1" ] || set --
            current=$#
            if [ "$limit" -gt 0 ] && [ "$current" -gt $((limit * 90 / 100)) ]; then
                log_warning_router "$name_client открыл $current из $limit файловых дескрипторов, инициирован перезапуск"
                rm -f "$file_pid_fd"
                fd_out=true
                proxy_stop
                proxy_start "on"
                exit 0
            fi
        fi
        sleep "$delay_fd"
    done
}

load_ipset() {
    set="$1"
    file="$2"
    family="$3"
    tmp="${set}_tmp"

    # Заполняем tmp; основной набор подменяется только после успешного restore
    ipset create "$set" hash:net family "$family" -exist
    ipset create "$tmp" hash:net family "$family" -exist
    ipset flush "$tmp"

    if [ -f "$file" ] && sed -e 's/\r$//' -e 's/#.*//' -e '/^[[:space:]]*$/d' "$file" | awk '{print "add '"$tmp"' "$1}' | ipset restore -exist; then
        ipset swap "$set" "$tmp"
    fi
    ipset destroy "$tmp"
}

cleanup_fd_monitor() {
    [ -f "$file_pid_fd" ] || return 0
    kill "$(cat "$file_pid_fd")" 2>/dev/null
    rm -f "$file_pid_fd"
}

missing_files_template='
  '"${light_blue}"'Отсутствуют исполняемые файлы:'"${reset}"'
  '"${yellow}"'%b'"${reset}"'

  '"${green}"'Возможные причины:'"${reset}"'
  • XKeen установлен во внутреннюю память и на ней недостаточно места
  • У файла отсутствуют права на выполнение

  '"${green}"'Рекомендуемые действия:'"${reset}"'
  • Переустановите XKeen на внешний накопитель
  • Скопируйте недостающий файл вручную и сделайте исполняемым
'

check_binary() {
    file="$1"
    path="$install_dir/$file"

    if [ ! -f "$path" ] || [ ! -x "$path" ]; then
        return 1
    fi

    check_cmd="version"
    [ "$file" = "xray" ] && check_cmd="version"
    [ "$file" = "yq" ] && check_cmd="--version"
    [ "$file" = "mihomo" ] && check_cmd="-v"

    if ! "$file" $check_cmd >/dev/null 2>&1; then
        log_error_router "Бинарный файл $file аварийно остановлен"
        log_error_terminal "
  Бинарный файл ${yellow}$file${reset} аварийно остановлен
  ${red}Файл повреждён или несовместим с процессором${reset} вашего роутера
  Установите другую версию ${yellow}$file${reset}
"
    fi

    return 0
}

info_health_binary() {
    missing_files=""

    add_to_missing() {
        file_name="$1"
        prefix="  - " 
        
        if [ -z "$missing_files" ]; then
            missing_files="${prefix}${yellow}${file_name}${reset}"
        else
            missing_files="${missing_files}\n  ${prefix}${yellow}${file_name}${reset}"
        fi
    }

    case "$name_client" in
        xray)
            if ! check_binary xray; then add_to_missing "xray"; fi
            ;;
       mihomo)
            for file in mihomo yq; do
                if ! check_binary "$file"; then add_to_missing "$file"; fi
            done
            ;;
        esac

    if [ -n "$missing_files" ]; then
        log_error_terminal "$(printf "$missing_files_template" "$missing_files")"
    fi
}

# Атомарный single-instance guard на cold_start. mkdir — POSIX-атомарен,
# единственный надёжный lock в busybox-ash без flock. Закрывает гонку
# повторного S05xkeen start от NDM (fs.d + init.d + reconnect-триггеры).
# Flag-файл xkeen_coldstart.lock сохранён для совместимости с условиями
# подавления логов в proxy_start/proxy_stop ("[ -f lock ] || log_info_router").
# PID владельца записывает _set_coldstart_pid после `nohup cold_start &` —
# текущий $$ это caller (S05xkeen start), который завершается сразу;
# проверка живости должна идти по PID фонового cold_start ($!).
_acquire_coldstart_guard() {
    if mkdir "$xkeen_rundir/coldstart.lock.d" 2>/dev/null; then
        printf '%s\n' "$$" > "$xkeen_rundir/coldstart.lock.d/pid"
        : > "$xkeen_rundir/coldstart.lock"
        return 0
    fi
    _gpid=$(cat "$xkeen_rundir/coldstart.lock.d/pid" 2>/dev/null)
    if [ -n "$_gpid" ] && kill -0 "$_gpid" 2>/dev/null; then
        return 1
    fi
    # PID is written together with mkdir.  A guard without it is stale, not a
    # permanent denial of service.
    # PID exists but its process died → reclaim stale guard.
    rm -rf "$xkeen_rundir/coldstart.lock.d"
    mkdir "$xkeen_rundir/coldstart.lock.d" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$xkeen_rundir/coldstart.lock.d/pid"
    : > "$xkeen_rundir/coldstart.lock"
    return 0
}

_set_coldstart_pid() {
    [ -d "$xkeen_rundir/coldstart.lock.d" ] || return 0
    printf '%s\n' "$1" > "$xkeen_rundir/coldstart.lock.d/pid"
}

_release_coldstart_guard() {
    rm -rf "$xkeen_rundir/coldstart.lock.d"
    rm -f "$xkeen_rundir/coldstart.lock"
}

# Защита от параллельного входа в proxy_start/proxy_stop из двух
# триггеров (cold_start vs xkeen -restart, два S05xkeen start
# подряд от NDM и т.п.). Второй конкурент тихо выходит.
# rc=0  — захватили; rc=1 — реальный конкурент; rc=2 — re-entrant
# (тот же процесс уже владеет mutex'ом, например proxy_start вложенно
# вызывает proxy_stop при TProxy 443-конфликте — не релизим).
_acquire_proxy_mutex() {
    if mkdir "$xkeen_rundir/proxy.mutex.d" 2>/dev/null; then
        printf '%s\n' "$$" > "$xkeen_rundir/proxy.mutex.d/pid"
        return 0
    fi
    _mpid=$(cat "$xkeen_rundir/proxy.mutex.d/pid" 2>/dev/null)
    if [ "$_mpid" = "$$" ]; then
        return 2
    fi
    if [ -n "$_mpid" ] && kill -0 "$_mpid" 2>/dev/null; then
        return 1
    fi
    rm -rf "$xkeen_rundir/proxy.mutex.d"
    mkdir "$xkeen_rundir/proxy.mutex.d" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$xkeen_rundir/proxy.mutex.d/pid"
    return 0
}

_release_proxy_mutex() {
    rm -rf "$xkeen_rundir/proxy.mutex.d"
}

# Тот же mkdir-lock, что у netfilter-хука. Нужен stop/emergency_clear,
# чтобы не сносить цепочки посреди iptables-restore на DHCP renew.
_acquire_nf_lock() {
    _xkeen_nf_lock="$xkeen_rundir/netfilter.lock.d"
    _xkeen_lock_owned=""
    _lock_try=0
    while [ "$_lock_try" -lt 50 ]; do
        if mkdir "$_xkeen_nf_lock" 2>/dev/null; then
            _xkeen_lock_owned=1
            printf '%s' "$$" > "$_xkeen_nf_lock/pid"
            return 0
        fi
        _lock_pid=$(cat "$_xkeen_nf_lock/pid" 2>/dev/null)
        if [ "$_lock_pid" = "$$" ]; then
            return 2
        fi
        if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
            rm -rf "$_xkeen_nf_lock" 2>/dev/null
            continue
        fi
        _lock_try=$((_lock_try + 1))
        usleep 100000 2>/dev/null || sleep 1
    done
    # Stop/emergency важнее застрявшего хука: забираем замок силой.
    rm -rf "$_xkeen_nf_lock" 2>/dev/null
    if mkdir "$_xkeen_nf_lock" 2>/dev/null; then
        _xkeen_lock_owned=1
        printf '%s' "$$" > "$_xkeen_nf_lock/pid"
        return 0
    fi
    return 1
}

_release_nf_lock() {
    if [ "$_xkeen_lock_owned" = "1" ]; then
        rm -rf "$xkeen_rundir/netfilter.lock.d" 2>/dev/null
        _xkeen_lock_owned=""
    fi
}

# Install an explicit fail-closed policy only after an unintentional core
# failure.  Only traffic already selected by xkeen policy marks is dropped;
# LAN/management and all unmarked traffic remain untouched.  The restore blob
# is atomic and uses the same netfilter lock as normal cleanup.
enable_killswitch() {
    [ "$killswitch" = "on" ] || return 0
    _ks_marks="$policy_mark $policy_mark_full"
    if [ -n "$user_policies" ]; then
        _ks_user_marks=$(printf '%s\n' "$user_policies" | awk -F'|' '$2 != "" {print "0x"$2}')
        _ks_marks="$_ks_marks $_ks_user_marks"
    fi
    [ -n "$(printf '%s' "$_ks_marks" | tr -d ' ')" ] || {
        log_warning_router "Kill-switch не установлен: нет policy-mark для безопасной выборки трафика"
        return 1
    }

    _acquire_nf_lock || return 1
    for _ks_family in iptables ip6tables; do
        if [ "$_ks_family" = "iptables" ] && [ "$iptables_supported" != "true" ]; then continue; fi
        if [ "$_ks_family" = "ip6tables" ] && [ "$ip6tables_supported" != "true" ]; then continue; fi
        _ks_restore="${_ks_family}-restore"
        _ks_blob=$( {
            printf '*mangle\n'
            printf ':%s_killswitch -\n' "$name_chain"
            for _ks_mark in $_ks_marks; do
                [ -n "$_ks_mark" ] || continue
                printf '%s\n' "-A ${name_chain}_killswitch -m conntrack ! --ctstate INVALID -m mark --mark ${_ks_mark} $comment -j DROP"
            done
            printf '%s\n' "-A PREROUTING $comment -j ${name_chain}_killswitch"
            printf 'COMMIT\n'
        } )
        printf '%s' "$_ks_blob" | "$_ks_restore" --noflush || {
            _release_nf_lock
            return 1
        }
    done
    _release_nf_lock
    log_warning_router "Kill-switch включён: трафик политики xkeen заблокирован до явного stop/start"
}

# Очистка при аварийной остановке прокси-клиента
emergency_clear() {
    _acquire_proxy_mutex
    _ec_mutex_rc=$?
    # Идёт нормальный start/stop/restart — не сносим чужие правила.
    if [ "$_ec_mutex_rc" -eq 1 ]; then
        return 0
    fi
    rm -f "$xkeen_rundir/ready"
    _release_coldstart_guard
    cleanup_fd_monitor
    clean_firewall
    enable_killswitch
    if [ "$_ec_mutex_rc" -eq 0 ]; then
        _release_proxy_mutex
    fi
}

# Запуск прокси-клиента
proxy_start() {
    _acquire_proxy_mutex
    _ps_mutex_rc=$?
    if [ "$_ps_mutex_rc" -eq 1 ]; then
        _ps_wait=0
        while [ "$_ps_wait" -lt 5 ]; do
            sleep 1
            _acquire_proxy_mutex
            _ps_mutex_rc=$?
            [ "$_ps_mutex_rc" -ne 1 ] && break
            _ps_wait=$((_ps_wait + 1))
        done
        if [ "$_ps_mutex_rc" -eq 1 ]; then
            log_warning_terminal "Запуск занят другим процессом, повторите команду"
            return 1
        fi
    fi
    if [ "$_ps_mutex_rc" -eq 0 ]; then
        trap '_release_proxy_mutex; trap - INT TERM HUP' INT TERM HUP
    fi
    start_manual="$1"
    if [ "$start_manual" = "on" ] || [ "$start_auto" = "on" ]; then
        _invalidate_inbounds_cache
        apply_ipv6_state
        get_ipver_support
        info_health_binary
        validate_xkeen_json
        check_policy_name_conflict
        check_xray_backups
        api_cache_init
        policy_mark=$(get_policy_mark "$name_policy")
        policy_mark_cache="$xkeen_cfg/.last_policy_mark"
        if [ -n "$policy_mark" ]; then
            _pm_tmp="${policy_mark_cache}.tmp.$$"
            (umask 077; printf '%s\n' "$policy_mark" > "$_pm_tmp") &&
                chmod 600 "$_pm_tmp" && mv -f "$_pm_tmp" "$policy_mark_cache"
        elif [ -s "$policy_mark_cache" ]; then
            _cached_mark=$(cat "$policy_mark_cache" 2>/dev/null)
            case "$_cached_mark" in
                0x[0-9A-Fa-f]*) policy_mark="$_cached_mark"; log_warning_router "RCI не вернул mark xkeen; используется последний успешный mark" ;;
            esac
        else
            log_warning_router "RCI не вернул mark xkeen; без policy-mark будет применён явный режим проксирования всех"
        fi
        policy_mark_full=$(get_policy_mark "$name_policy_full")
        user_policies=$(resolve_user_policies)
        validate_entware_proxy_mark
        validate_pbr_routing_mark
        log_clean
        sync_deny_mac_ipset
        process_user_ports
        process_custom_mark
        detect_architecture
        port_redirect=$(get_port_redirect)
        network_redirect=$(get_network_redirect)
        port_tproxy=$(get_port_tproxy)
        network_tproxy=$(get_network_tproxy)
        mode_proxy=$(get_mode_proxy)
        if [ "$mode_proxy" != "Other" ]; then

            if [ -n "$policy_mark" ]; then
                if [ -n "$user_policies" ]; then
                    print_policy_info "yes" "yes"
                else
                    print_policy_info "yes" "no"
                fi
            else
                raw_user_policies=$(get_user_policies)
                ignored_custom="no"

                if [ -n "$raw_user_policies" ]; then
                    ignored_custom="yes"
                fi

                print_policy_info "no" "no" "$ignored_custom"

                user_policies=""
            fi

            networks=$(printf '%s\n' $network_redirect $network_tproxy | tr ',' ' ' | tr -s ' ' '\n' | sort -u | tr '\n' ' ')
            networks=${networks% }

            if [ -n "$policy_mark" ] && [ -z "$port_donor" ]; then
                port_exclude=$(get_port_exclude)
            fi
            if ! proxy_status && { [ -n "$port_donor" ] || [ -n "$port_exclude" ] || [ "$mode_proxy" = "TProxy" ] || [ "$mode_proxy" = "Hybrid" ]; }; then
                get_modules
            fi
            configure_dscp_force_proxy
            if [ "$mode_proxy" = "TProxy" ]; then
                keenetic_ssl="$(get_keenetic_port)" || {
                    proxy_stop
                    log_error_router "Порт 443 занят сервисами Keenetic"
                    log_error_terminal "
  Необходимый для режима ${light_blue}TProxy${reset} ${red}443 порт занят${reset} сервисами Keenetic

  Освободите его на странице 'Пользователи и доступ' веб-интерфейса роутера
"
                }
            fi
        fi
        if proxy_status; then
            echo -e "  Прокси-клиент уже ${green}запущен${reset}"
            if [ "$mode_proxy" != "Other" ] && ! configure_firewall; then
                rm -f "$xkeen_rundir/ready"
                log_error_terminal "Не удалось записать netfilter-хук"
                _release_coldstart_guard
                if [ "$_ps_mutex_rc" -eq 0 ]; then
                    _release_proxy_mutex
                    trap - INT TERM HUP
                fi
                return 1
            fi
            : > "$xkeen_rundir/ready"
            if [ "$mode_proxy" != "Other" ] && ! sh "$file_netfilter_hook"; then
                rm -f "$xkeen_rundir/ready"
                log_error_terminal "Не удалось применить netfilter-хук"
                _release_coldstart_guard
                if [ "$_ps_mutex_rc" -eq 0 ]; then
                    _release_proxy_mutex
                    trap - INT TERM HUP
                fi
                return 1
            fi
            if [ "$start_manual" = "on" ]; then
                log_error_terminal "Не удалось запустить ${yellow}$name_client${reset}, так как он уже запущен"
            else
                log_info_router "Прокси-клиент успешно запущен в режиме $mode_proxy"
                _release_coldstart_guard
            fi
        else
            log_info_router "Инициирован запуск прокси-клиента"
            attempt=1

            fd_limit="$other_fd"
            [ "$arm_cpu" = "true" ] && fd_limit="$arm64_fd"
            ulimit -SHn "$fd_limit"

            export SSL_CERT_FILE="$file_ca"
            while [ "$attempt" -le "$start_attempts" ]; do
                case "$name_client" in
                    xray)
                        export XRAY_LOCATION_CONFDIR="$directory_xray_config"
                        export XRAY_LOCATION_ASSET="$directory_xray_asset"
                        find "$directory_xray_config" -maxdepth 1 -name '._*.json' -type f -delete
                        if [ -n "$fd_out" ]; then
                            nohup "$name_client" run >/dev/null 2>&1 &
                            unset fd_out
                        else
                            if [ "$start_verbose" = "on" ]; then
                                "$name_client" run &
                            else
                                "$name_client" run >/dev/null 2>&1 &
                            fi
                        fi
                    ;;
                    mihomo)
                        export CLASH_HOME_DIR="$directory_configs_app"
                        # См. apply_gomemlimit: доля/лимит из xkeen.json,
                        # минимум 64MiB, внешний GOMEMLIMIT не игнорируется.
                        apply_gomemlimit
                        if [ -n "$fd_out" ]; then
                            nohup "$name_client" >/dev/null 2>&1 &
                            unset fd_out
                        else
                            if [ "$start_verbose" = "on" ]; then
                                "$name_client" &
                            else
                                "$name_client" >/dev/null 2>&1 &
                            fi
                        fi
                        ;;
                    *) log_error_terminal "Неизвестный прокси-клиент: ${yellow}$name_client${reset}" ;;
                esac
                _probe_attempt=0
                while [ "$_probe_attempt" -lt 60 ]; do
                    proxy_status && break
                    _probe_attempt=$((_probe_attempt + 1))
                    usleep 50000
                done
                unset _probe_attempt
                if proxy_status; then
                    if [ "$mode_proxy" != "Other" ] && ! configure_firewall; then
                        rm -f "$xkeen_rundir/ready"
                        log_error_terminal "Не удалось записать netfilter-хук"
                        _release_coldstart_guard
                        if [ "$_ps_mutex_rc" -eq 0 ]; then
                            _release_proxy_mutex
                            trap - INT TERM HUP
                        fi
                        return 1
                    fi
                    : > "$xkeen_rundir/ready"
                    if [ "$mode_proxy" != "Other" ] && ! sh "$file_netfilter_hook"; then
                        rm -f "$xkeen_rundir/ready"
                        log_error_terminal "Не удалось применить netfilter-хук"
                        _release_coldstart_guard
                        if [ "$_ps_mutex_rc" -eq 0 ]; then
                            _release_proxy_mutex
                            trap - INT TERM HUP
                        fi
                        return 1
                    fi
                    # Последовательно: параллельный ipset restore больших RU-списков
                    # сразу после fork mihomo даёт пик RAM / OOM на слабых роутерах.
                    [ "$iptables_supported" = "true" ] && [ -f "$ru_exclude_ipv4" ] && load_ipset geo_exclude "$ru_exclude_ipv4" inet
                    [ "$ip6tables_supported" = "true" ] && [ -f "$ru_exclude_ipv6" ] && load_ipset geo_exclude6 "$ru_exclude_ipv6" inet6
                    load_user_ipset
                    echo -e "  Прокси-клиент ${green}запущен${reset} в режиме ${light_blue}${mode_proxy}${reset}"
                    (
                        # Даём ядру прокси время полностью инициализироваться
                        # Это защищает от ситуаций, когда xray/mihomo
                        # успевает создать PID, но затем аварийно завершается,
                        # например, из-за битой конфигурации
                        _crash_pid=$(pidof "$name_client" 2>/dev/null | awk '{print $1}')
                        sleep 3

                        if [ -n "$_crash_pid" ] && ! kill -0 "$_crash_pid" 2>/dev/null \
                           && ! proxy_status; then
                            echo
                            echo -e "  Прокси-клиент ${red}аварийно завершился${reset}"
                            echo -e "  ${green}Выполняется очистка${reset} правил прозрачного проксирования"
                            log_error_router "Прокси-клиент аварийно завершился после запуска"
                            emergency_clear
                            printf '\n~ # '
                        fi
                    ) &
                    if [ -n "$api_policy_json" ]; then
                        if echo "$api_policy_json" | jq --arg policy "$name_policy" -e 'any(.[]; .description | ascii_downcase == $policy)' > /dev/null; then
                            if [ -e "/tmp/noinet" ]; then
                                echo
                                echo -e "  У политики ${yellow}$name_policy${reset} ${red}нет доступа в интернет${reset}"
                                echo "  Проверьте, установлена ли галка на подключении к провайдеру"
                            fi
                        fi
                    fi
                    [ "$mode_proxy" = "Other" ] && echo -e "  Функция прозрачного прокси ${red}не активна${reset}. Направляйте соединения на ${yellow}${name_client}${reset} вручную"
                    log_info_router "Прокси-клиент успешно запущен в режиме $mode_proxy"
                    _release_coldstart_guard
                    if [ "$check_fd" = "on" ]; then
                        cleanup_fd_monitor
                        monitor_fd &
                        echo $! > "$file_pid_fd"
                        log_info_router "Запущен контроль файловых дескрипторов $name_client"
                    fi
                    if [ "$_ps_mutex_rc" -eq 0 ]; then
                        _release_proxy_mutex
                        trap - INT TERM HUP
                    fi
                    return 0
                fi
                attempt=$((attempt + 1))
            done
            echo -e "  ${red}Не удалось запустить${reset} прокси-клиент"
            clean_firewall
            enable_killswitch
            log_error_terminal "Не удалось запустить прокси-клиент"
            _release_coldstart_guard
        fi
    else
        clean_firewall
    fi
    if [ "$_ps_mutex_rc" -eq 0 ]; then
        _release_proxy_mutex
        trap - INT TERM HUP
    fi
}

# Активная проба готовности окружения вместо sleep $start_delay.
# Ждём ndmc, default route и insmod-ability xt_TPROXY (deps ndm
# подгружает асинхронно уже после ndmc-ready). $start_delay сохранён
# как safety cap (FAQ #12).
wait_for_ready() {
    _max=$(( ${start_delay:-60} * 2 ))
    _attempt=0
    _probe_ko=$(find_module_path "xt_TPROXY.ko")

    while [ "$_attempt" -lt "$_max" ]; do
        if ip route show default 2>/dev/null | grep -q '^default'; then
            # Проверка готовности API политик и модуля xt_TPROXY
            api_policy_json=$(curl_api "${url_server}/${url_policy}" 2>/dev/null)
            case "$api_policy_json" in
                ""|"{}"|"[]") return 0 ;;
                \{*|\[*)
                    if [ -z "$_probe_ko" ] \
                       || grep -q '^xt_TPROXY ' /proc/modules 2>/dev/null \
                       || insmod "$_probe_ko" >/dev/null 2>&1
                    then
                        return 0
                    fi
                    ;;
            esac
        fi
        usleep 500000
        _attempt=$((_attempt + 1))
    done
    return 0
}

# Остановка прокси-клиента
proxy_stop() {
    _acquire_proxy_mutex
    _pstop_mutex_rc=$?
    if [ "$_pstop_mutex_rc" -eq 1 ]; then
        _pstop_wait=0
        while [ "$_pstop_wait" -lt 5 ]; do
            sleep 1
            _acquire_proxy_mutex
            _pstop_mutex_rc=$?
            [ "$_pstop_mutex_rc" -ne 1 ] && break
            _pstop_wait=$((_pstop_wait + 1))
        done
        if [ "$_pstop_mutex_rc" -eq 1 ]; then
            log_warning_terminal "Остановка занята другим процессом, повторите команду"
            return 1
        fi
    fi
    if [ "$_pstop_mutex_rc" -eq 0 ]; then
        trap '_release_proxy_mutex; trap - INT TERM HUP' INT TERM HUP
    fi
    rm -f "$xkeen_rundir/ready"
    if ! proxy_status; then
        echo -e "  Прокси-клиент ${red}не запущен${reset}"
        cleanup_fd_monitor
    else
        [ -f "$xkeen_rundir/coldstart.lock" ] || log_info_router "Инициирована остановка прокси-клиента"
        cleanup_fd_monitor
        attempt=1
        while [ "$attempt" -le "$start_attempts" ]; do
            clean_firewall
            killall -q "$name_client" 2>/dev/null
            _stop_attempt=0
            while [ "$_stop_attempt" -lt 30 ]; do
                pidof "$name_client" >/dev/null 2>&1 || break
                _stop_attempt=$((_stop_attempt + 1))
                usleep 50000
            done
            unset _stop_attempt
            if pidof "$name_client" >/dev/null 2>&1; then
                killall -q -9 "$name_client" 2>/dev/null
                usleep 200000
            fi
            if ! proxy_status; then
                echo -e "  Прокси-клиент ${red}остановлен${reset}"
                [ -f "$xkeen_rundir/coldstart.lock" ] || log_info_router "Прокси-клиент успешно остановлен"
                _release_coldstart_guard
                if [ "$_pstop_mutex_rc" -eq 0 ]; then
                    _release_proxy_mutex
                    trap - INT TERM HUP
                fi
                return 0
            fi
            attempt=$((attempt + 1))
        done
        echo -e "  Прокси-клиент ${red}не удалось остановить${reset}"
        log_error_terminal "Не удалось остановить прокси-клиент"
    fi
    if [ "$_pstop_mutex_rc" -eq 0 ]; then
        _release_proxy_mutex
        trap - INT TERM HUP
    fi
}

# Менеджер команд
case "$1" in
    start)
        ipset create ext_exclude hash:ip family inet -exist
        ipset create ext_exclude6 hash:ip family inet6 -exist
        if [ -z "$2" ]; then
            [ "$start_auto" != "on" ] && exit 0
            # Атомарный guard ДО spawn — повторный S05xkeen start от
            # NDM (fs.d / init.d / reconnect) увидит каталог и выйдет.
            _acquire_coldstart_guard || exit 0
            log_info_router "Подготовка к запуску прокси-клиента"
            nohup "$0" cold_start >/dev/null 2>&1 &
            # PID фонового cold_start — caller ($$) умрёт через exit 0,
            # а живость guard'а проверяется именно по этому PID.
            _set_coldstart_pid "$!"
            exit 0
        fi
        proxy_start "$2"
    ;;
    stop) proxy_stop ;;
    status)
        if proxy_status; then
            mode_proxy=""
            if [ -f "$file_netfilter_hook" ]; then
                mode_proxy=$(grep '^mode_proxy=' "$file_netfilter_hook" | awk -F"=" '{print $2}' | tr -d "'" 2>/dev/null)
            fi
            [ -z "$mode_proxy" ] && mode_proxy="Other"
            echo -e "  Прокси-клиент ${yellow}$name_client${reset} ${green}запущен${reset} в режиме ${light_blue}$mode_proxy${reset}"
        else
            echo -e "  Прокси-клиент ${red}не запущен${reset}"
        fi
        ;;
    dscp)
        if [ "$dscp_enable" != "off" ]; then
            echo
            print_dscp_force_proxy_status
        fi
        ;;
    restart) proxy_stop; proxy_start "$2" ;;
    cold_start)
        # Подстраховка: переписываем PID guard'а на свой ($$) на случай,
        # если caller-S05xkeen умер до того, как успел _set_coldstart_pid "$!".
        _set_coldstart_pid "$$"
        # Гарантированная задержка перед попыткой запуска прокси-клиента
        if [ -n "$init_delay" ] && [ "$init_delay" -gt 0 ] 2>/dev/null; then
            log_info_router "Ожидание перед проверкой готовности к запуску XKeen (${init_delay} сек...)"
            sleep "$init_delay"
        fi
        # Re-spawn в чистый S05xkeen: sh-функции (wait_for_ready) не
        # наследуются через nohup sh -c, поэтому пробу зовём отсюда.
        wait_for_ready
        proxy_start ""
        ;;
    *) echo -e "  Команды: ${green}start${reset} | ${red}stop${reset} | ${yellow}restart${reset} | status" ;;
esac

exit 0
