#!/usr/bin/env bash
# checklist.sh — подзадачи Trello-карточки через чек-листы.
#
# Подзадача = пункт чек-листа внутри карточки (решение task-manager пайплайна:
# мелкие шаги живут в карточке, отдельные карточки — только для независимых
# кусков ценности). Агент пункты не выдумывает — тексты берёт из разбора задачи.
#
# Использование (из корня проекта):
#   checklist.sh (--id <id> | --url <url> | --card "<name>" [--from-board "<b>"]) --show
#   checklist.sh (--id ... ) --create "<checklist>" [--items "шаг 1;шаг 2;шаг 3"]
#   checklist.sh (... ) --add-item "<текст>" [--list "<checklist>"]
#   checklist.sh (... ) --complete "<пункт>" [--list "<checklist>"]
#   checklist.sh (... ) --uncomplete "<пункт>" [--list "<checklist>"]
#
# --show печатает в stdout только JSON (AI-first): карточка + чек-листы + пункты.
# Остальные действия печатают короткий итог (имя чек-листа/пункта + id).
# --list — точное имя чек-листа; если опущен и на карточке ровно один чек-лист —
# используется он, иначе скрипт перечислит доступные и выйдет с ошибкой.
# --items делит строку по ';' (пустые куски отбрасываются).

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

ID=""; URL=""; CARD=""; FROM_BOARD=""; LIST=""
ACTION=""; ARG=""; ITEMS=""

usage() {
  echo "Usage: checklist.sh (--id <card-id> | --url <card-url> | --card \"<exact name>\" [--from-board \"<b>\"]) (--show | --create \"<checklist>\" [--items \"a;b;c\"] | --add-item \"<text>\" [--list \"<l>\"] | --complete \"<item>\" [--list \"<l>\"] | --uncomplete \"<item>\" [--list \"<l>\"])"
  echo "  Карточка — ровно одним способом; --show возвращает JSON."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         ID="${2:?--id требует id карточки}"; shift 2 ;;
    --url)        URL="${2:?--url требует URL карточки}"; shift 2 ;;
    --card)       CARD="${2:?--card требует точное имя}"; shift 2 ;;
    --from-board) FROM_BOARD="${2:?--from-board требует имя доски}"; shift 2 ;;
    --list)       LIST="${2:?--list требует имя чек-листа}"; shift 2 ;;
    --show)       ACTION="show"; shift ;;
    --create)     ACTION="create"; ARG="${2:?--create требует имя чек-листа}"; shift 2 ;;
    --items)      ITEMS="${2:?--items требует строку}"; shift 2 ;;
    --add-item)   ACTION="add-item"; ARG="${2:?--add-item требует текст}"; shift 2 ;;
    --complete)   ACTION="complete"; ARG="${2:?--complete требует имя пункта}"; shift 2 ;;
    --uncomplete) ACTION="uncomplete"; ARG="${2:?--uncomplete требует имя пункта}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "task-manager: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$ACTION" ]] || { echo "task-manager: укажи действие: --show, --create, --add-item, --complete или --uncomplete" >&2; usage >&2; exit 1; }
if [[ -n "$ITEMS" && "$ACTION" != "create" ]]; then
  echo "task-manager: --items работает только вместе с --create" >&2; usage >&2; exit 1
fi

require_creds

SEL=()
[[ -n "$ID" ]] && SEL+=("--id" "$ID")
[[ -n "$URL" ]] && SEL+=("--url" "$URL")
[[ -n "$CARD" ]] && SEL+=("--card" "$CARD")
[[ -n "$FROM_BOARD" ]] && SEL+=("--from-board" "$FROM_BOARD")
CARD_ID="$(resolve_card_id "${SEL[@]}")" || exit 1
CARD_NAME="$(trello_get "/cards/${CARD_ID}" --data-urlencode "fields=name" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"

checklists_json() {
  trello_get "/cards/${CARD_ID}/checklists" \
    --data-urlencode "fields=name" \
    --data-urlencode "checkItems=all" \
    --data-urlencode "checkItem_fields=name,state,pos"
}

# Резолвит чек-лист: точное имя из --list, иначе единственный на карточке.
resolve_list_id() {
  local json="$1" want="$2" hit n
  if [[ -n "$want" ]]; then
    hit="$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1]
for cl in json.load(sys.stdin):
    if cl.get("name") == want:
        print(cl["id"])
' "$want")"
    if [[ -z "$hit" ]]; then
      echo "task-manager: чек-лист '$want' не найден на карточке '$CARD_NAME'. Доступные:" >&2
      printf '%s' "$json" | python3 -c 'import json, sys; [print(" -", cl.get("name")) for cl in json.load(sys.stdin)]' >&2
      return 1
    fi
    printf '%s' "$hit"
    return 0
  fi
  n="$(printf '%s' "$json" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')"
  if [[ "$n" -eq 0 ]]; then
    echo "task-manager: на карточке '$CARD_NAME' нет чек-листов — создай: --create \"<имя>\"" >&2
    return 1
  fi
  if [[ "$n" -gt 1 ]]; then
    echo "task-manager: на карточке '$CARD_NAME' несколько чек-листов — уточни --list:" >&2
    printf '%s' "$json" | python3 -c 'import json, sys; [print(" -", cl.get("name")) for cl in json.load(sys.stdin)]' >&2
    return 1
  fi
  printf '%s' "$json" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["id"])'
}

# Резолвит пункт по точному имени в пределах чек-листа (уникальность обязательна).
resolve_item_id() {
  local json="$1" list_id="$2" want="$3" hits n
  hits="$(printf '%s' "$json" | python3 -c '
import json, sys
lid, want = sys.argv[1], sys.argv[2]
for cl in json.load(sys.stdin):
    if cl["id"] == lid:
        for it in cl.get("checkItems") or []:
            if it.get("name") == want:
                print(it["id"])
' "$list_id" "$want")"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [[ "$n" -eq 0 ]]; then
    echo "task-manager: пункт '$want' не найден. Пункты чек-листа:" >&2
    printf '%s' "$json" | python3 -c '
import json, sys
lid = sys.argv[1]
for cl in json.load(sys.stdin):
    if cl["id"] == lid:
        [print(" -", it.get("name"), "[" + it.get("state", "?") + "]") for it in cl.get("checkItems") or []]
' "$list_id" >&2
    return 1
  fi
  if [[ "$n" -gt 1 ]]; then
    echo "task-manager: пунктов с именем '$want' несколько ($n) — переименуй дубли" >&2
    return 1
  fi
  printf '%s' "$hits"
}

case "$ACTION" in
  show)
    LISTS_JSON="$(checklists_json)"
    CARD_ID="$CARD_ID" CARD_NAME="$CARD_NAME" LISTS_JSON="$LISTS_JSON" python3 -c '
import json, os
print(json.dumps({
    "card": {"id": os.environ["CARD_ID"], "name": os.environ["CARD_NAME"]},
    "checklists": [
        {"id": cl["id"], "name": cl.get("name", ""),
         "items": [{"id": it["id"], "name": it.get("name", ""),
                    "state": it.get("state", "incomplete"),
                    "complete": it.get("state") == "complete"}
                   for it in cl.get("checkItems") or []]}
        for cl in json.loads(os.environ["LISTS_JSON"])
    ],
}, ensure_ascii=False))
'
    ;;
  create)
    EXISTS="$(checklists_json | python3 -c '
import json, sys
want = sys.argv[1]
for cl in json.load(sys.stdin):
    if cl.get("name") == want:
        print(cl["id"])
' "$ARG")"
    if [[ -n "$EXISTS" ]]; then
      echo "task-manager: чек-лист '$ARG' уже есть на карточке '$CARD_NAME' (id $EXISTS)."
      LIST_ID="$EXISTS"
    else
      LIST_ID="$(trello_post "/cards/${CARD_ID}/checklists" --data-urlencode "name=${ARG}" \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
      echo "== чек-лист создан =="
      echo "card: $CARD_NAME"
      echo "list: $ARG"
      echo "id:   $LIST_ID"
    fi
    if [[ -n "$ITEMS" ]]; then
      ADDED=0
      IFS=';' read -ra PARTS <<< "$ITEMS"
      for raw in "${PARTS[@]}"; do
        item="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$item" ]] && continue
        ITEM_ID="$(trello_post "/checklists/${LIST_ID}/checkItems" \
          --data-urlencode "name=${item}" --data-urlencode "pos=bottom" \
          | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
        echo " + [$ITEM_ID] $item"
        ADDED=$((ADDED+1))
      done
      echo "пунктов добавлено: $ADDED"
    fi
    ;;
  add-item)
    LISTS_JSON="$(checklists_json)"
    LIST_ID="$(resolve_list_id "$LISTS_JSON" "$LIST")" || exit 1
    LIST_NAME="$(printf '%s' "$LISTS_JSON" | python3 -c '
import json, sys
lid = sys.argv[1]
for cl in json.load(sys.stdin):
    if cl["id"] == lid:
        print(cl.get("name", ""))
' "$LIST_ID")"
    ITEM_ID="$(trello_post "/checklists/${LIST_ID}/checkItems" \
      --data-urlencode "name=${ARG}" --data-urlencode "pos=bottom" \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
    echo "== пункт добавлен =="
    echo "card: $CARD_NAME"
    echo "list: $LIST_NAME"
    echo "item: $ARG"
    echo "id:   $ITEM_ID"
    ;;
  complete|uncomplete)
    LISTS_JSON="$(checklists_json)"
    if [[ -n "$LIST" ]]; then
      LIST_ID="$(resolve_list_id "$LISTS_JSON" "$LIST")" || exit 1
    else
      # Поиск пункта по всем чек-листам — годится, только если имя уникально.
      HITS="$(printf '%s' "$LISTS_JSON" | python3 -c '
import json, sys
want = sys.argv[1]
for cl in json.load(sys.stdin):
    for it in cl.get("checkItems") or []:
        if it.get("name") == want:
            print(it["id"] + "\t" + cl["id"] + "\t" + cl.get("name", ""))
' "$ARG")"
      N="$(printf '%s' "$HITS" | grep -c . || true)"
      if [[ "$N" -eq 0 ]]; then
        echo "task-manager: пункт '$ARG' не найден на карточке '$CARD_NAME'." >&2
        exit 1
      fi
      if [[ "$N" -gt 1 ]]; then
        echo "task-manager: пункт '$ARG' есть в нескольких чек-листах — уточни --list:" >&2
        printf '%s' "$HITS" | cut -f3 | sort -u | sed 's/^/ - /' >&2
        exit 1
      fi
      ITEM_ID="$(printf '%s' "$HITS" | cut -f1)"
      LIST_ID="$(printf '%s' "$HITS" | cut -f2)"
      LIST_NAME="$(printf '%s' "$HITS" | cut -f3)"
      STATE="complete"; [[ "$ACTION" == "uncomplete" ]] && STATE="incomplete"
      trello_put "/cards/${CARD_ID}/checkItem/${ITEM_ID}" --data-urlencode "state=${STATE}" >/dev/null
      echo "== пункт обновлён =="
      echo "card: $CARD_NAME"
      echo "list: $LIST_NAME"
      echo "item: $ARG ($STATE)"
      exit 0
    fi
    ITEM_ID="$(resolve_item_id "$LISTS_JSON" "$LIST_ID" "$ARG")" || exit 1
    LIST_NAME="$LIST"
    STATE="complete"; [[ "$ACTION" == "uncomplete" ]] && STATE="incomplete"
    trello_put "/cards/${CARD_ID}/checkItem/${ITEM_ID}" --data-urlencode "state=${STATE}" >/dev/null
    echo "== пункт обновлён =="
    echo "card: $CARD_NAME"
    echo "list: $LIST_NAME"
    echo "item: $ARG ($STATE)"
    ;;
esac
