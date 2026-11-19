#!/bin/sh
# Builds corne-companion into ~/.local/bin and (re)loads its LaunchAgent.
# render.js is embedded in the binary, so rerun this script after changing it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
label=dev.brainsaysno.corne-companion
bin="$HOME/.local/bin/corne-companion"
agent="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/corne-companion.log"
domain="gui/$(id -u)"
config="$HOME/.config/corne-companion/config.json"

mkdir -p "$(dirname "$bin")" "$(dirname "$agent")" "$(dirname "$logfile")" "$(dirname "$config")"
if [ ! -f "$config" ]; then
  cp "$here/config.example.json" "$config"
  echo "Created $config from config.example.json; edit it, then rerun this script."
fi

# The embedded Info.plist carries the usage descriptions TCC needs to prompt under launchd.
# Built beside the target and moved into place: rewriting a running binary in place
# invalidates its code signature and gets it killed.
swiftc -O "$here"/*.swift -o "$bin.new" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$here/Info.plist" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __render_js -Xlinker "$here/render.js"
mv -f "$bin.new" "$bin"

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bin</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$logfile</string>
	<key>StandardErrorPath</key>
	<string>$logfile</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
EOF

launchctl bootout "$domain/$label" 2>/dev/null || true
# bootstrap fails while the old job is still being torn down.
tries=0
while launchctl print "$domain/$label" >/dev/null 2>&1 && [ "$tries" -lt 50 ]; do
  tries=$((tries + 1))
  sleep 0.2
done
launchctl bootstrap "$domain" "$agent"
echo "corne-companion running; config: $config; log: $logfile"
