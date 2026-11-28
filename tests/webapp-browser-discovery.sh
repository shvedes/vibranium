#!/bin/bash
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox"/{bin,home,data/applications,system/applications}

touch "$sandbox/bin/vb-lib-core"
cat > "$sandbox/bin/xdg-mime" <<'STUB'
#!/bin/bash
[[ $* == 'query default x-scheme-handler/https' ]] || exit 1
printf '%s\n' "$TEST_DEFAULT"
STUB
cat > "$sandbox/bin/setsid" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ROOT/launch"
STUB
cat > "$sandbox/bin/notify-send" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ROOT/notification"
STUB
for browser in chromium vivaldi firefox; do
  printf '#!/bin/bash\nexit 0\n' > "$sandbox/bin/$browser"
done
chmod +x "$sandbox/bin/"{xdg-mime,setsid,notify-send,chromium,vivaldi,firefox}

entry() {
  local path="$1" executable="$2"
  printf '[Desktop Entry]\nType=Application\nExec=%s %%U\n' "$executable" > "$path"
}

url='https://example.org/?a=1&b=2'
run_launcher() {
  rm -f "$sandbox/launch" "$sandbox/notification"
  HOME="$sandbox/home" XDG_DATA_HOME="$sandbox/data" XDG_DATA_DIRS="$sandbox/system" \
    PATH="$sandbox/bin:$repo/bin" TEST_ROOT="$sandbox" TEST_DEFAULT="$1" \
    /bin/bash "$repo/bin/vb-launch-webapp" "${@:2}" "$url" \
    > "$sandbox/stdout" 2> "$sandbox/stderr"
}

expect_launch() {
  local expected
  expected=$(printf '%s\n' -f app2unit -- "$@")
  [[ $(< "$sandbox/launch") == "$expected" ]]
  [[ ! -e $sandbox/notification ]]
}

entry "$sandbox/data/applications/chromium.desktop" chromium
entry "$sandbox/system/applications/vivaldi-stable.desktop" vivaldi
entry "$sandbox/data/applications/firefox.desktop" firefox

run_launcher vivaldi-stable.desktop
expect_launch vivaldi "$url"

entry "$sandbox/data/applications/chromium.desktop" missing
run_launcher chromium.desktop
expect_launch firefox --new-tab "$url"

run_launcher firefox.desktop --own-profile
expect_launch vivaldi "--user-data-dir=$sandbox/data/webapps/example-org" "$url"

run_launcher firefox.desktop
expect_launch firefox --new-tab "$url"

# A user-level entry can hide the system entry with the same desktop ID.
printf '[Desktop Entry]\nHidden=true\n' > "$sandbox/data/applications/vivaldi-stable.desktop"
rm "$sandbox/data/applications/chromium.desktop"
run_launcher "" --own-profile
expect_launch chromium "--user-data-dir=$sandbox/data/webapps/example-org" "$url"

rm "$sandbox/bin/chromium" "$sandbox/bin/firefox"
if run_launcher firefox.desktop; then
  printf 'Expected failure when no compatible browser is installed\n' >&2
  exit 1
fi
[[ ! -e $sandbox/launch ]]
[[ $(< "$sandbox/stderr") == *'No compatible browser was found'* ]]
[[ $(< "$sandbox/notification") == *'Cannot open web app'* ]]

printf 'Web-app browser discovery tests passed\n'
