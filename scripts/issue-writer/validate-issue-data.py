#!/usr/bin/env python3
"""
Шаг 2b пайплайна: валидация JSON, который сгенерировал LLM-агент issue-writer.
Чистый код, никакого LLM. Читает JSON из stdin (или из файла-аргумента),
сверяет со schema/issue.schema.json. При ошибке — ненулевой exit code
и понятное сообщение, чтобы агент мог перегенерировать ответ.

Зависимость: pip install jsonschema
"""
import json
import sys
from pathlib import Path

try:
    from jsonschema import validate, ValidationError
except ImportError:
    print("Нужен пакет jsonschema: pip install jsonschema", file=sys.stderr)
    sys.exit(2)

SCHEMA_PATH = Path(__file__).parent / "schema" / "issue.schema.json"


def main() -> int:
    raw = sys.argv[1] if len(sys.argv) > 1 else None
    data_text = Path(raw).read_text(encoding="utf-8") if raw else sys.stdin.read()

    try:
        data = json.loads(data_text)
    except json.JSONDecodeError as e:
        print(f"Невалидный JSON: {e}", file=sys.stderr)
        return 1

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    try:
        validate(instance=data, schema=schema)
    except ValidationError as e:
        print(f"Данные не соответствуют схеме: {e.message}", file=sys.stderr)
        print(f"  путь: {'/'.join(str(p) for p in e.path) or '(root)'}", file=sys.stderr)
        return 1

    # Валидно — печатаем обратно нормализованный JSON (со значениями по умолчанию)
    for key, prop in schema.get("properties", {}).items():
        if key not in data and "default" in prop:
            data[key] = prop["default"]

    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
