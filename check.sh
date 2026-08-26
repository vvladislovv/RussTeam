#!/bin/bash
# Проверка всех модулей плагина: синтаксис, потерянные связи, несуществующие вызовы.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILE="$DIR/.tools/luau-compile"
ANALYZE="$DIR/.tools/luau-analyze"

KNOWN="game|plugin|task|Instance|Enum|CFrame|Vector3|Vector2|Color3|UDim|UDim2|NumberRange|BrickColor|DockWidgetPluginGuiInfo|workspace|script|shared|typeof|warn|tick|delay|spawn|wait|settings|Random|Rect|NumberSequence|ColorSequence|PhysicalProperties|TweenInfo|Ray|Region3|Font|version|require|utf8|os|debug|buffer|bit32|coroutine"

FAIL=0

for f in "$DIR"/plugin/*.lua; do
	NAME=$(basename "$f")

	if ! "$COMPILE" --binary "$f" >/dev/null 2>"$DIR/.syntax.err"; then
		echo "$NAME: ОШИБКА СИНТАКСИСА"
		head -3 "$DIR/.syntax.err" | sed 's/^/   /'
		FAIL=1
		continue
	fi

	# Потерянные связи видны только в строгом режиме
	TMP="$(mktemp -t russteam).lua"
	{ echo "--!strict"; tail -n +2 "$f"; } > "$TMP"
	BAD="$("$ANALYZE" "$TMP" 2>&1 \
		| grep -oE "\(([0-9]+),[0-9]+\): TypeError: Unknown global '[^']*'" \
		| sed -E "s/\(([0-9]+),.*'([^']*)'/строка \1: \2/" \
		| sort -u | grep -Ev ": ($KNOWN)$" || true)"
	rm -f "$TMP"
	if [ -n "$BAD" ]; then
		echo "$NAME: ПОТЕРЯННЫЕ СВЯЗИ"
		echo "$BAD" | sed 's/^/   /'
		FAIL=1
	fi
done

rm -f "$DIR/.syntax.err"

# Вызовы между модулями: не зовём ли то, чего нет
MISSING="$(cd "$DIR" && python3 - <<'PY'
import re, glob, os
exports = {}
for path in glob.glob('plugin/*.lua'):
    name = os.path.basename(path)[:-4]
    if name == 'init.server': continue
    src = open(path).read()
    names = set(re.findall(rf'^{name}\.(\w+)\s*=', src, re.M))
    names |= set(re.findall(rf'^function {name}\.(\w+)', src, re.M))
    names |= set(re.findall(rf'^\t{name}\.(\w+)\s*=', src, re.M))
    exports[name] = names
late = {'create','refresh','fields','setFields','widget','showSetup'}
bad = set()
for path in glob.glob('plugin/*.lua'):
    src, who = open(path).read(), os.path.basename(path)
    mine = who[:-4]
    for mod, names in exports.items():
        if mod == mine: continue
        for used in set(re.findall(rf'(?<![\w.]){mod}\.(\w+)', src)):
            if used not in names and used not in late:
                bad.add(f"{who}: {mod}.{used}")
for b in sorted(bad): print(b)
PY
)"
if [ -n "$MISSING" ]; then
	echo "ВЫЗЫВАЕТСЯ, НО НЕ СУЩЕСТВУЕТ:"
	echo "$MISSING" | sed 's/^/   /'
	FAIL=1
fi

[ $FAIL -eq 0 ] && echo "проверка пройдена: $(ls "$DIR"/plugin/*.lua | wc -l | tr -d ' ') модулей"
exit $FAIL
