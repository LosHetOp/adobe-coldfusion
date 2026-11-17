#!/usr/bin/env bash
# Local Ubuntu 24.04 installer, adapted from remote/install-cf2025.sh.
log() { printf '[install-cf2025] %s\n' "$*"; }
die() { printf '[install-cf2025] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
sudo bash setup.sh [options]
  --installer-url URL         Default: public Adobe Linux GUI installer URL
  --lockdown-url URL          Default: verified public Adobe lockdown download
  --download-config FILE      Root-owned mode 600 curl config (headers/cookies)
  --installer-sha256 HEX      Optional independently obtained SHA-256
  --lockdown-sha256 HEX       Optional independently obtained SHA-256
  --admin-password-file FILE  Root-owned mode 600, one line; never sourced
  --prompt-admin-password    Read silently from terminal
  --runtime-user NAME         Default cfuser (locked, non-login OS account)
  --install-dir PATH          Default /opt/coldfusion2025
  --work-dir PATH             Default /var/lib/cf2025-local
  --install-type TYPE         developer (default) or trial
  --no-lockdown               Updates still mandatory
  --update-only               Explicit update of existing installation; no credentials changed
  --help
USAGE
}
adobe_url() { [[ $1 =~ ^https://([a-zA-Z0-9-]+\.)*adobe\.com(:443)?/[^[:space:]]*$ && $1 != *\\* ]]; }
validate_paths() {
  local path
  for path in "$CF_INSTALL_DIR" "$WORK_DIR"; do
    [[ $path =~ ^/[-a-zA-Z0-9_/]+$ && $path != / ]] || die 'Use absolute non-root paths containing only letters, digits, underscores, hyphens, and slashes.'
    [[ $(realpath -m -- "$path") == "$path" ]] || die 'Install/work paths must be canonical, without symlinks, repeated/trailing slashes, or dot segments.'
  done
  [[ $WORK_DIR != "$CF_INSTALL_DIR" && $WORK_DIR != "$CF_INSTALL_DIR/"* && $CF_INSTALL_DIR != "$WORK_DIR/"* ]] || die 'Install and work directories must be separate.'
}
validate_admin_password() {
  [[ ${#CF_ADMIN_PASSWORD} -ge 16 && $CF_ADMIN_PASSWORD =~ ^[a-zA-Z0-9!@%_+=.,:-]+$ ]] || die 'Password needs at least 16 characters from the supported ASCII properties alphabet.'
  if [[ $LOCKDOWN == true && ( $CF_ADMIN_PASSWORD == *+* || $CF_ADMIN_PASSWORD == *%* ) ]]; then
    die 'Lockdown passwords cannot contain + or %: Adobe submits credentials without URL encoding.'
  fi
}
resolve_update_artifact() {
  # Only metadata parsing: callers validate Adobe ownership before fetching.
  python3 - "$1" "$2" "$3" <<'PY'
import html, re, sys, urllib.parse
mode, path, level = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = open(path, encoding='utf-8').read()
if mode == 'notes':
    values = {urllib.parse.urljoin('https://guides.adobe.com/', html.unescape(u))
              for u in re.findall(r'''href=["']([^"']*coldfusion-2025[^"']*update-''' + str(level) + r'''\.html)["']''', text, re.I)}
else:
    values = {html.unescape(m.group(0)) for m in re.finditer(
        r'https://cfdownload\.adobe\.com/[^"<>\s]+/hotfix-(\d+)-(\d+)\.jar', text)
        if int(m.group(1)) == level}
if len(values) != 1:
    raise SystemExit('Cannot resolve one Adobe ' + mode + ' URL for the required update.')
print(values.pop())
PY
}
assert_hotfix_log() {
  python3 - "$CF_INSTALL_DIR" "$LATEST_LEVEL" "${1:-0}" <<'PY'
import pathlib, re, sys
root, level, since = pathlib.Path(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
logs = []
for folder in (root / 'cfusion/hf-updates').glob('hf-2025-*'):
    match = re.fullmatch(r'hf-2025-(\d+)-(\d+)', folder.name)
    if match and int(match[1]) == level:
        logs.extend(p for p in folder.glob('*Install*.log') if p.stat().st_mtime >= since)
if not logs:
    raise SystemExit('No new core hotfix installation log for the required update.')
latest = max(logs, key=lambda p: p.stat().st_mtime)
data = latest.read_bytes()
text = data.decode('utf-16') if data.startswith((b'\xff\xfe', b'\xfe\xff')) else data.decode('utf-8-sig', errors='replace')
if not (re.search(r'Installation:\s*Successful\b', text)
        and re.search(r'^\s*0\s+FatalErrors\s*$', text, re.M)
        and re.search(r'^\s*0\s+NonFatalErrors\s*$', text, re.M)):
    raise SystemExit('Core hotfix did not report success with zero fatal/nonfatal errors: ' + str(latest))
print('Core hotfix log verified: ' + str(latest))
PY
}
bouncycastle_cleanup() {
  # Validate every filename and build the entire deletion plan before deleting.
  python3 - "$CF_INSTALL_DIR" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]).resolve()
remove = []
for directory in (root / 'cfusion/lib', root / 'bundles/repo'):
    if not directory.is_dir():
        continue
    for prefix in ('bcprov-jdk', 'bcpkix-jdk', 'bcutil-jdk', 'bcmail-jdk'):
        ordered = []
        for jar in directory.glob(prefix + '*.jar'):
            if jar.is_symlink() or jar.resolve().parent != directory:
                raise SystemExit('Refusing linked/out-of-directory library: ' + str(jar))
            match = re.search(r'-(\d+(?:\.\d+){1,3})\.jar$', jar.name)
            legacy = re.search(r'-(1)(\d{2})\.jar$', jar.name)
            if match:
                version = tuple(map(int, match[1].split('.')))
            elif legacy:
                version = (int(legacy[1]), int(legacy[2]))
            else:
                raise SystemExit('Unknown Bouncy Castle version; no files removed: ' + jar.name)
            ordered.append((version + (0,) * (4-len(version)), jar))
        ordered.sort(key=lambda item: (item[0], item[1].name))
        remove.extend(jar for _, jar in ordered[:-1])
for jar in remove:
    print('Removing older Bouncy Castle JAR: ' + str(jar))
    jar.unlink()
PY
}
runtime_pids() {
  python3 - "$CF_INSTALL_DIR" <<'PY'
import os, pathlib, sys
root = str(pathlib.Path(sys.argv[1]).resolve())
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit() or int(proc.name) == os.getpid():
        continue
    try:
        exe = os.readlink(proc / 'exe')
        args = (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
        if exe.startswith(root + '/') and root + '/cfusion' in args:
            print(proc.name)
    except (OSError, PermissionError):
        pass
PY
}
stop_cf() {
  local _
  timeout -k 10 120 "$CF_INSTALL_DIR/cfusion/bin/coldfusion" stop 9>&- 3>&- 4>&- || log 'Stop command failed/timed out; checking this installation for a leftover runtime.'
  for _ in {1..24}; do
    [[ -n $(runtime_pids) ]] || break
    sleep 5
  done
  [[ -z $(runtime_pids) ]] || die 'ColdFusion runtime remains active. Hotfix/cache changes were aborted; inspect logs before retrying.'
  python3 - "$CF_ADMIN_PORT" <<'PY'
import socket, sys
with socket.socket() as probe:
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        probe.bind(('127.0.0.1', int(sys.argv[1])))
    except OSError:
        raise SystemExit('ColdFusion port remains occupied; refusing hotfix/cache changes.')
PY
}
start_cf() {
  timeout -k 10 180 "$CF_INSTALL_DIR/cfusion/bin/coldfusion" start 9>&- 3>&- 4>&-
  wait_cf
}
patch_launcher() {
  local launcher="$CF_INSTALL_DIR/cfusion/bin/coldfusion"
  if grep -q 'Bootstrap -start &"' "$launcher"; then
    log 'Detaching the background runtime descriptors from the Adobe launcher.'
    sed -i 's/Bootstrap -start &"/Bootstrap -start <\/dev\/null >\/dev\/null 2>\&1 \&"/' "$launcher"
  fi
}
install_core_update() {
  local installed notes_url jar_url started status
  installed=$(find "$CF_INSTALL_DIR/cfusion/lib/updates" -maxdepth 1 -name 'chf2025[0-9]*.jar' -printf '%f\n' | sort -V | tail -1)
  if [[ $installed =~ ^chf2025([0-9]+)\.jar$ ]]; then
    ((10#${BASH_REMATCH[1]} <= LATEST_LEVEL)) || die 'Installed core is newer than the fetched catalog; refusing downgrade.'
    if ((10#${BASH_REMATCH[1]} == LATEST_LEVEL)); then assert_hotfix_log; return; fi
  fi
  notes_url=$(resolve_update_artifact notes "$WORK_DIR/adobe-updates.html" "$LATEST_LEVEL") || die 'Cannot resolve Adobe update notes.'
  fetch "$notes_url" "$WORK_DIR/adobe-update-notes.html" false
  jar_url=$(resolve_update_artifact jar "$WORK_DIR/adobe-update-notes.html" "$LATEST_LEVEL") || die 'Cannot resolve Adobe core hotfix.'
  fetch "$jar_url" "$WORK_DIR/core-hotfix.jar" false
  python3 - "$WORK_DIR/core-hotfix.jar" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    if 'META-INF/MANIFEST.MF' not in jar.namelist():
        raise SystemExit('Hotfix is not a runnable JAR')
PY
  cat >"$WORK_DIR/hotfix-silent.properties" <<PROPS
INSTALLER_UI=silent
USER_INSTALL_DIR=$CF_INSTALL_DIR
DOC_ROOT=$CF_INSTALL_DIR/cfusion/wwwroot/
INSTANCE_LIST=ALL
COMMAND_INSTALL=true
PROPS
  log 'Stopping ColdFusion fully before installing the core hotfix in a standalone JVM...'
  stop_cf
  started=$(date +%s)
  status=0
  (umask 022; timeout -k 10 1800 "$CF_INSTALL_DIR/jre/bin/java" "-Djava.io.tmpdir=$WORK_DIR/temp" -jar "$WORK_DIR/core-hotfix.jar" -i silent -f "$WORK_DIR/hotfix-silent.properties" \
    9>&- 3>&- 4>&-) >"$WORK_DIR/core-update-console.log" 2>"$WORK_DIR/core-update-error.log" || status=$?
  assert_hotfix_log "$started" || die 'Standalone hotfix did not produce a successful zero-error log.'
  ((status == 0 || status == 1)) || die "Core hotfix exited with code $status; inspect protected diagnostics."
  ((status == 0)) || log 'Hotfix warning exit code 1 accepted only after its zero-error success log was verified.'
  rm -f -- "$WORK_DIR/hotfix-silent.properties"
  # The updater normally restarts CF; do not start a second runtime.
  if [[ -z $(runtime_pids) ]]; then start_cf; else wait_cf; fi
}
verify_runtime_identity() {
  local pid expected actual found=false
  expected=$(id -u "$RUNTIME_USER")
  while IFS= read -r pid; do
    [[ -n $pid ]] || continue
    found=true
    actual=$(stat -c %u "/proc/$pid")
    [[ $actual == "$expected" && $actual != 0 ]] || die 'ColdFusion runtime is not running as the requested low-privilege account.'
  done < <(runtime_pids)
  [[ $found == true ]] || die 'No runtime belonging to this installation was found.'
}
export_admin_credentials() {
  # Export only portal credentials, never root/runtime passwords. Passwords are
  # read from the protected record, not passed in arguments or printed.
  python3 - "$WORK_DIR/README-credentials.md" "${SUDO_USER:-root}" <<'PY'
import os, pathlib, pwd, re, sys
record = pathlib.Path(sys.argv[1]).read_text()
account = pwd.getpwnam(sys.argv[2])
home = pathlib.Path(account.pw_dir)
desktop = home / 'Desktop'
destination = (desktop if desktop.is_dir() and not desktop.is_symlink() else home) / 'ColdFusion-Admin-Credentials.txt'
username = re.search(r'^ColdFusion Administrator: (.+)$', record, re.M)[1]
password = re.search(r'^Password: (.+)$', record, re.M)[1]
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.fchown(fd, account.pw_uid, account.pw_gid)
    with os.fdopen(fd, 'w') as output:
        fd = -1
        output.write('ColdFusion Administrator portal\nURL: http://localhost:8500/CFIDE/administrator/index.cfm\nUsername: ' + username + '\nPassword: ' + password + '\n')
finally:
    if fd != -1:
        os.close(fd)
print('Portal credentials saved to ' + str(destination))
PY
}
write_lab_receipt() {
  python3 - "$WORK_DIR" "$CF_INSTALL_DIR" "$LATEST_LEVEL" "$LOCKDOWN" "$CF_ADMIN_PORT" "$WEBROOT_PATH" "$RUNTIME_USER" <<'PY'
import datetime, json, os, pathlib, re, sys, tempfile
work, install, level, lockdown, port, webroot, runtime_user = sys.argv[1:]
work = pathlib.Path(work)
level = int(level)
if level < 1 or lockdown not in ('true', 'false'):
    raise SystemExit('Invalid verified lab state')
record = (work / 'README-credentials.md').read_text()
statuses = re.findall(r'^Status: (.+)$', record, re.M)
if not statuses or statuses[-1] != 'complete':
    raise SystemExit('Lab completion was not verified; refusing readiness receipt')
verified = re.findall(r'^Verified update: (\d+)$', record, re.M)
if not verified or int(verified[-1]) != level:
    raise SystemExit('Verified update record does not match required level')
username = re.search(r'^ColdFusion Administrator: (.+)$', record, re.M)[1]
password = re.search(r'^Password: (.+)$', record, re.M)[1]
admin_url = f'http://localhost:{port}/CFIDE/administrator/index.cfm'
checked = datetime.datetime.now(datetime.timezone.utc).isoformat()
credentials = {'administrator': {'url': admin_url, 'username': username, 'password': password}}
receipt = {
    'product': 'Adobe ColdFusion', 'release': '2025',
    'update_level': level, 'verified_utc': checked,
    'catalog_url': 'https://guides.adobe.com/coldfusion/en/docs/introduction-to-coldfusion/coldfusion-2025-updates.html',
    'lockdown': lockdown == 'true',
    'checks': {'core_hotfix_zero_errors': True, 'live_update_matches_catalog': True,
               'connector_cfml_executed': True, 'runtime_non_root': True,
               'lockdown_success_without_rollback': lockdown == 'true'},
    'runtime_user': runtime_user,
}
ready = {
    'status': 'ready', 'product': 'Adobe ColdFusion', 'release': '2025',
    'application_url': 'http://localhost/', 'administrator_url': admin_url,
    'install_directory': install, 'webroot': webroot, 'logs_directory': str(work),
    'credentials_file': str(work / 'credentials.json'),
    'security_receipt': str(work / 'security-receipt.json'),
    'update_level': level, 'lockdown': lockdown == 'true',
}
def save(name, value):
    fd, temporary = tempfile.mkstemp(prefix='.' + name + '-', dir=work)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, indent=2)
            output.write('\n')
        os.replace(temporary, work / name)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)
save('credentials.json', credentials)
save('security-receipt.json', receipt)
save('ready.json', ready)
print(json.dumps(ready))
PY
}
main() {
set +x
set -Eeuo pipefail
umask 077
LOCKDOWN=true UPDATE_ONLY=false PROMPT_PASSWORD=false
CF_INSTALL_DIR=/opt/coldfusion2025 WORK_DIR=/var/lib/cf2025-local
RUNTIME_USER=cfuser CF_ADMIN_USERNAME=admin CF_ADMIN_PORT=8500
CF_INSTALL_TYPE_CODE=3 CF_DEPLOYMENT_TYPE_CODE=1 CF_SECURE_PROFILE=true CF_DEV_PROFILE=false
CF_AUTO_ENABLE_UPDATES=true CF_UPDATE_TRUE=0 CF_AUTO_UPDATE_TRUE=0 CHANGE_SHUTDOWN_PORT=1
CF_URL=https://trials.adobe.com/AdobeProducts/CSTD/16/linux64/ColdFusion_2025_GUI_WWEJ_linux64.bin
AUTH_CONFIG='' PASSWORD_FILE='' CF_HASH='' LD_HASH=''
LD_URL=https://cfdownload.adobe.com/pub/adobe/coldfusion/2025/lockdown/ColdFusion_2025_Lockdown_WWEJ_linux64.bin
while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --no-lockdown) LOCKDOWN=false; shift ;;
    --update-only) UPDATE_ONLY=true; shift ;;
    --prompt-admin-password) PROMPT_PASSWORD=true; shift ;;
    --installer-url|--lockdown-url|--download-config|--admin-password-file|--runtime-user|--install-dir|--work-dir|--installer-sha256|--lockdown-sha256|--install-type)
      (($# >= 2)) || die "$1 needs a value"
      case "$1" in
        --installer-url) CF_URL=$2 ;; --lockdown-url) LD_URL=$2 ;;
        --download-config) AUTH_CONFIG=$2 ;; --admin-password-file) PASSWORD_FILE=$2 ;;
        --runtime-user) RUNTIME_USER=$2 ;; --install-dir) CF_INSTALL_DIR=$2 ;;
        --work-dir) WORK_DIR=$2 ;; --installer-sha256) CF_HASH=$2 ;; --lockdown-sha256) LD_HASH=$2 ;;
        --install-type) case "$2" in developer) CF_INSTALL_TYPE_CODE=3 ;; trial) CF_INSTALL_TYPE_CODE=2 ;; *) die 'Only developer/trial supported; a licensed install needs real FRL inputs.' ;; esac ;;
      esac
      shift 2 ;;
    *) die 'Unknown option; use --help.' ;;
  esac
done
[[ $EUID == 0 ]] || die 'Run as root.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Requires Ubuntu 24.04 LTS.'
[[ $(uname -m) == x86_64 ]] || die 'Requires x86_64.'
validate_paths
[[ $RUNTIME_USER =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die 'Invalid runtime user.'
[[ ! -L $WORK_DIR && ! -L $CF_INSTALL_DIR ]] || die 'Symlinked install/work paths are refused.'
if [[ -e $WORK_DIR ]]; then
  [[ $(stat -c %u "$WORK_DIR") == 0 && $(stat -c %a "$WORK_DIR") == 700 ]] || die 'Existing work directory must be root-owned mode 700.'
else
  install -d -m 700 "$WORK_DIR"
fi
exec 9>"$WORK_DIR/install.lock"
flock -n 9 || die 'Another local installer is running.'
[[ $WORK_DIR != "$CF_INSTALL_DIR" && $WORK_DIR != "$CF_INSTALL_DIR/"* && $CF_INSTALL_DIR != "$WORK_DIR/"* ]] || die 'Install and work directories must be separate.'
if [[ $UPDATE_ONLY == true ]]; then
  [[ -x $CF_INSTALL_DIR/cfusion/bin/coldfusion ]] || die 'No installation at --install-dir.'
else
  [[ ! -e $CF_INSTALL_DIR && ! -e $WORK_DIR/README-credentials.md ]] || die 'Existing/partial install or credentials detected. Use --update-only for a completed installation; otherwise review/restore the VM.'
  ! id "$RUNTIME_USER" >/dev/null 2>&1 || die 'Runtime account already exists; refusing to adopt or reset it.'
  ! pgrep -f '/[c]fusion/(runtime|bin)' >/dev/null || die 'Another ColdFusion installation appears to be running.'
  [[ -n $CF_URL ]] || die 'Supply an authorized Adobe installer URL (see --help).'
fi
protected_file() {
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == 600 ]] || die 'Input file must be root-owned mode 600, without symlinks.'
}
cleanup() {
  local result=$?
  rm -f -- "$WORK_DIR/cf-silent.properties" "$WORK_DIR/lockdown-silent.properties" "$WORK_DIR/hotfix-silent.properties"
  [[ -z ${PROBE_PATH:-} ]] || rm -f -- "$PROBE_PATH"
  if ((result)); then log "Failed. Inspect protected diagnostics in $WORK_DIR and Adobe logs; no automatic troubleshooting attempted."; fi
}
trap cleanup EXIT
[[ -z $AUTH_CONFIG ]] || protected_file "$AUTH_CONFIG"
[[ -z $PASSWORD_FILE ]] || protected_file "$PASSWORD_FILE"
# Authentication config is trusted curl configuration. It must contain only auth/header/cookie options.
# Redirects are followed one hop at a time, validating Adobe ownership before every request.
fetch() {
  local url=$1 dest=$2 authenticate=${3:-true} headers code location _
  local -a auth=()
  [[ -z $AUTH_CONFIG || $authenticate != true ]] || auth=(--config "$AUTH_CONFIG")
  for _ in {1..8}; do
    adobe_url "$url" || die 'Download/redirect must be HTTPS on adobe.com or an Adobe subdomain.'
    headers="$WORK_DIR/response.headers"
    code=$(curl "${auth[@]}" --silent --proto '=https' --max-time 2400 --connect-timeout 30 --max-redirs 0 -D "$headers" -o "$dest.part" -w '%{http_code}' "$url" 2>"$WORK_DIR/download-error.log") || die 'Download transport failed; inspect protected download-error.log.'
    case "$code" in
      200) mv -f -- "$dest.part" "$dest"; rm -f -- "$headers"; return ;;
      301|302|303|307|308)
        location=$(sed -n 's/^[Ll]ocation: *//p' "$headers" | tr -d '\r' | tail -1)
        url=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urljoin(sys.argv[1],sys.argv[2]))' "$url" "$location") ;;
      *) die "Adobe download returned HTTP $code. Refresh authorized URL/authentication; see protected diagnostics." ;;
    esac
  done
  die 'Too many Adobe redirects.'
}
check_binary() {
  local file=$1 hash=$2 header
  [[ $(stat -c %s "$file") -gt 1048576 ]] || die 'Download is too small to be an installer.'
  header=$(head -c 4 "$file")
  [[ $header == '#!'* || $header == $'\x7fELF' ]] || die 'Download is not a Linux shell/ELF installer.'
  if [[ -n $hash ]]; then
    [[ $hash =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid SHA-256.'
    [[ $(sha256sum "$file" | cut -d' ' -f1) == "${hash,,}" ]] || die 'Installer SHA-256 mismatch.'
  fi
}
wait_cf() {
  local _
  for _ in {1..60}; do
    if curl -fsS --max-time 3 "http://127.0.0.1:$CF_ADMIN_PORT/CFIDE/administrator/index.cfm" >/dev/null 2>&1; then return; fi
    sleep 5
  done
  die 'ColdFusion HTTP readiness timed out; inspect cfusion/logs.'
}
verify_update() {
  local installed result _ name
  installed=$(find "$CF_INSTALL_DIR/cfusion/lib/updates" -maxdepth 1 -name 'chf2025[0-9]*.jar' -printf '%f\n' | sort -V | tail -1)
  installed=${installed#chf2025}; installed=${installed%.jar}
  [[ $installed =~ ^[0-9]+$ && $((10#$installed)) == "$LATEST_LEVEL" ]] || die 'Installed hotfix JAR does not match latest Adobe update.'
  name="cfverify$(openssl rand -hex 16).cfm"
  PROBE_PATH="$CF_INSTALL_DIR/cfusion/wwwroot/$name"
  printf '%s' '<cfif cgi.remote_addr NEQ "127.0.0.1"><cfheader statuscode="404"><cfabort></cfif><cfcontent type="text/plain" reset="true"><cfoutput>#server.coldfusion.updatelevel#</cfoutput>' >"$PROBE_PATH"
  chmod 644 "$PROBE_PATH"
  for _ in {1..30}; do
    result=$(curl -fsS --max-time 5 "http://127.0.0.1:$CF_ADMIN_PORT/$name" 2>/dev/null) || result=
    if [[ $result =~ ^[0-9]+$ && $((10#$result)) == "$LATEST_LEVEL" ]]; then
      rm -f -- "$PROBE_PATH"; PROBE_PATH=; log "Verified live update level $LATEST_LEVEL against Adobe's catalog and installed hotfix JAR."; return
    fi
    sleep 5
  done
  die 'Live ColdFusion update level did not match latest Adobe catalog.'
}
# Install native prerequisites before HTTPS metadata retrieval.
export DEBIAN_FRONTEND=noninteractive
apt-get update >"$WORK_DIR/prerequisites.log" 2>&1
apt-get install -y curl ca-certificates openssl python3 >>"$WORK_DIR/prerequisites.log" 2>&1
if [[ -n $AUTH_CONFIG ]]; then
  python3 - "$AUTH_CONFIG" <<'PY' || die 'Curl auth config permits only quoted header/user/cookie/oauth2-bearer assignments.'
import re, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line and not line.startswith('#'):
        if not re.fullmatch(r'(header|user|cookie|oauth2-bearer)\s*=\s*"(?:[^"\\]|\\["\\])*"', line):
            raise SystemExit('Unsupported curl authentication configuration option')
PY
fi
install -d -m 700 "$WORK_DIR/temp"
export IATEMPDIR="$WORK_DIR/temp"
[[ ,$(findmnt -n -o OPTIONS -T "$WORK_DIR/temp"), != *,noexec,* ]] || die 'Work directory is on a noexec filesystem; choose an executable --work-dir.'
fetch https://guides.adobe.com/coldfusion/en/docs/introduction-to-coldfusion/coldfusion-2025-updates.html "$WORK_DIR/adobe-updates.html" false
LATEST_LEVEL=$(python3 -c 'import re,sys; s=open(sys.argv[1]).read(); n=re.findall(r"ColdFusion\s*(?:\(2025 release\)|2025)\s*Update\s+(\d+)",s,re.I); assert n,"Adobe update catalog format not recognized"; print(max(map(int,n)))' "$WORK_DIR/adobe-updates.html")
[[ $LATEST_LEVEL =~ ^[1-9][0-9]*$ ]] || die 'Could not establish latest update from Adobe.'
if [[ $UPDATE_ONLY == false ]]; then
  CF_ADMIN_PASSWORD=
  if [[ -n $PASSWORD_FILE ]]; then CF_ADMIN_PASSWORD=$(cat -- "$PASSWORD_FILE"); fi
  if [[ $PROMPT_PASSWORD == true ]]; then read -r -s -p 'ColdFusion admin password: ' CF_ADMIN_PASSWORD </dev/tty; printf '\n' >/dev/tty; fi
  [[ -n $CF_ADMIN_PASSWORD ]] || CF_ADMIN_PASSWORD="Cf9!$(openssl rand -hex 20)"
  validate_admin_password
  SHUTDOWN_PORT_NEW=$(shuf -i 10000-60000 -n 1)
  cat >"$WORK_DIR/README-credentials.md" <<CREDS
# ColdFusion 2025 local installation credentials
Status: pending (a failure leaves this recovery record intact).
License selection code: $CF_INSTALL_TYPE_CODE (3=Developer, default; 2=trial; no license file).
ColdFusion Administrator: $CF_ADMIN_USERNAME
Password: $CF_ADMIN_PASSWORD
Purpose: ColdFusion configuration and package administration.
URL: http://localhost:$CF_ADMIN_PORT/CFIDE/administrator/index.cfm
Apache URL: http://localhost/ (Administrator uses the built-in port).
Runtime OS account: $RUNTIME_USER; password: none (locked system account, non-login shell).
Purpose: low-privilege ColdFusion runtime. Apache uses existing www-data (no password).
Existing root/OS administrator credentials are not changed or recorded.
Install path: $CF_INSTALL_DIR
Webroot: /var/www/html; Apache config: /etc/apache2
Logs: $WORK_DIR/*.log; $CF_INSTALL_DIR/Adobe_ColdFusion*;
$CF_INSTALL_DIR/cfusion/logs; $CF_INSTALL_DIR/cfusion/hf-updates;
$CF_INSTALL_DIR/lockdown/cfusion/Logs; /var/log/apache2
Lockdown enabled: $LOCKDOWN
Tomcat shutdown port requested: $SHUTDOWN_PORT_NEW
Latest Adobe update required at start: $LATEST_LEVEL
CREDS
  export_admin_credentials
  fetch "$CF_URL" "$WORK_DIR/coldfusion.bin"; check_binary "$WORK_DIR/coldfusion.bin" "$CF_HASH"
  if [[ $LOCKDOWN == true ]]; then fetch "$LD_URL" "$WORK_DIR/lockdown.bin"; check_binary "$WORK_DIR/lockdown.bin" "$LD_HASH"; fi
fi
OS_FAMILY=debian APACHE_PACKAGE=apache2 APACHE_SERVICE=apache2 APACHE_CONF_DIR=/etc/apache2
APACHE_BIN_PATH=/usr/sbin/apache2 APACHE_CTL_PATH=/usr/sbin/apachectl APACHE_USER=www-data APACHE_GROUP=www-data
WEBROOT_PATH=/var/www/html
PKG_INSTALL=(apt-get install -y) PKG_UPDATE=(apt-get update -y)
# Vendor output may contain sensitive values. Keep it inside the root-only work directory.
exec 3>&1 4>&2
exec >>"$WORK_DIR/provisioning.log" 2>&1
log() { printf '[install-cf2025] %s\n' "$*" >&3; }
die() { printf '[install-cf2025] ERROR: %s\n' "$*" >&4; exit 1; }

# --- Install and start Apache ------------------------------------------------
if [[ $UPDATE_ONLY == false ]]; then
log "Installing ${APACHE_PACKAGE}..."
"${PKG_UPDATE[@]}" >/dev/null
"${PKG_INSTALL[@]}" "${APACHE_PACKAGE}" curl ca-certificates openssl python3 fontconfig libxext6 libxi6 libxtst6 libxrender1 libnss3 >/dev/null

export APACHE_CONFDIR="$APACHE_CONF_DIR"
set -a
source /etc/apache2/envvars
set +a
a2enmod headers rewrite >/dev/null
systemctl enable --now "${APACHE_SERVICE}"
log "Apache (${APACHE_SERVICE}) is running."
fi

if [[ "$UPDATE_ONLY" == false ]]; then
# --- Dedicated runtime user for ColdFusion ----------------------------------
# Matches Lockdown Guide section 6.2: run ColdFusion as a low-privileged
# dedicated user, never root/nobody.
if ! id -u "${RUNTIME_USER}" >/dev/null 2>&1; then
  log "Creating dedicated ColdFusion runtime user: ${RUNTIME_USER}"
  useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "${RUNTIME_USER}"
else
  log "Runtime user ${RUNTIME_USER} already exists."
fi

# --- ColdFusion silent install -----------------------------------------------
CF_INSTALLER_PATH="${WORK_DIR}/coldfusion.bin"
[[ -f "${CF_INSTALLER_PATH}" ]] || die "ColdFusion installer not found at ${CF_INSTALLER_PATH}"
chmod +x "${CF_INSTALLER_PATH}"

SILENT_LICENSE_ACTIVATION_MODE_VAL=
SILENT_LICENSE_FILE_PATH_VAL=
SILENT_LICENSE_EDITION_VAL=
CF_PROPS_PATH="${WORK_DIR}/cf-silent.properties"
cat > "${CF_PROPS_PATH}" <<PROPS
#Silent properties for ColdFusion 2025 GUI Installer (generated by install-cf2025.sh)
INSTALLER_UI=SILENT
SILENT_INSTALL_TYPE=${CF_INSTALL_TYPE_CODE}
SILENT_LICENSE_ACTIVATION_MODE=${SILENT_LICENSE_ACTIVATION_MODE_VAL}
SILENT_LICENSE_FILE_PATH=${SILENT_LICENSE_FILE_PATH_VAL}
SILENT_LICENSE_EDITION=${SILENT_LICENSE_EDITION_VAL}
SILENT_DEPLOYMENT_TYPE=${CF_DEPLOYMENT_TYPE_CODE}
SILENT_SERVER_TYPE=3
SILENT_INSTALL_JNBRIDGE=false
SILENT_INSTALL_ADMIN=false
SILENT_INSTALL_SOLR=false
SILENT_INSTALL_PDFG=false
SILENT_INSTALL_FOLDER=${CF_INSTALL_DIR}
USER_INSTALL_DIR=${CF_INSTALL_DIR}
SILENT_ENABLE_PROD_SECURE_PROFILE=${CF_SECURE_PROFILE}
SILENT_ENABLE_PROD_DEFAULT_PROFILE=false
SILENT_ENABLE_DEV_PROFILE=${CF_DEV_PROFILE}
SILENT_ADMIN_IP=
SILENT_JETTY_IP=
SILENT_ADMIN_USERNAME=${CF_ADMIN_USERNAME}
SILENT_ADMIN_PASSWORD=${CF_ADMIN_PASSWORD}
SILENT_ENABLE_RDS=false
SILENT_RUNTIME_USER=${RUNTIME_USER}
SILENT_RDS_PASSWORD=
SILENT_JETTY_USERNAME=admin
SILENT_JETTY_PASSWORD=${CF_ADMIN_PASSWORD}
SILENT_CONTEXT_ROOT=
SILENT_AUTO_ENABLE_UPDATES=${CF_AUTO_ENABLE_UPDATES}
SILENT_PREV_CF_MIGR_DIR=
ENABLE_RDS=false
ENABLE_WSRP=false
ENABLE_JSDEBUG=false
ENABLE_CFR=false
ENABLE_CFSWF=false
ENABLE_CFFORMS=false
PROPS
chmod 600 "${CF_PROPS_PATH}"

if [[ -x "${CF_INSTALL_DIR}/cfusion/bin/coldfusion" ]]; then
  log "ColdFusion already appears installed at ${CF_INSTALL_DIR}, skipping installer."
else
  log "Running ColdFusion 2025 silent installer (this takes a few minutes)..."
  (umask 022; timeout -k 10 1800 "${CF_INSTALLER_PATH}" -f "${CF_PROPS_PATH}" 9>&- 3>&- 4>&-) >"${WORK_DIR}/installer.log" 2>&1
fi

[[ -x "${CF_INSTALL_DIR}/cfusion/bin/coldfusion" ]] || \
  die "ColdFusion installer did not produce ${CF_INSTALL_DIR}/cfusion/bin/coldfusion; check Adobe_ColdFusion_2025_Install*.log under ${CF_INSTALL_DIR}"

patch_launcher
log "Starting ColdFusion..."
if [[ -z $(runtime_pids) ]]; then start_cf; else wait_cf; fi

log "Waiting for the ColdFusion built-in web server to respond on port ${CF_ADMIN_PORT}..."
for _ in $(seq 1 60); do
  if curl -ks -o /dev/null -m 3 "https://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm" \
    || curl -ks -o /dev/null -m 3 "http://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm"; then
    log "ColdFusion Administrator is responding."
    break
  fi
  sleep 5
done

fi # fresh install
wait_cf
patch_launcher
install_core_update
# --- Update ColdFusion to the latest version ---------------------------------
CFPM="${CF_INSTALL_DIR}/cfusion/bin/cfpm.sh"
if [[ -f "${CFPM}" ]]; then
  chmod +x "${CFPM}"
  log "Updating ColdFusion to the latest version via cfpm..."

  # cfpm.sh update all prompts "Press Y to proceed:" even in non-interactive
  # mode. Pipe "y" so it proceeds without waiting for user input.
  printf "y\n" | (umask 022; timeout -k 10 2400 "${CFPM}" update all 9>&- 3>&- 4>&-) >"${WORK_DIR}/update.log" 2>&1 || die "Mandatory cfpm update failed; inspect protected update.log."
  ! grep -qF 'There are errors in the installation of this update' "$WORK_DIR/update.log" || die 'cfpm reported a core installation error despite its exit status.'
  assert_hotfix_log || die 'Core hotfix log verification failed after package update.'

  # The update installer leaves old BouncyCastle JARs alongside new ones in
  # cfusion/lib. Java loads classes from both signed JARs, and the signer
  # info conflicts, preventing the license service from initializing.
  # Remove old versions, keeping only the newest of each family.
  log "Cleaning up duplicate BouncyCastle JARs..."
  bouncycastle_cleanup

  # Determine the installed update level from the hotfix JAR filename.
  # The JAR is named chf2025NNNN.jar where NNNN is the zero-padded update
  # number (e.g. chf20250014.jar for update 14).
  UPDATES_DIR="${CF_INSTALL_DIR}/cfusion/lib/updates"
  HF_JAR=$(find "${UPDATES_DIR}" -maxdepth 1 -name 'chf2025*.jar' 2>/dev/null | sort | tail -1)
  if [[ -n "${HF_JAR}" ]]; then
    HF_JAR_NAME=$(basename "${HF_JAR}")
    UPDATE_NUM="${HF_JAR_NAME#chf2025}"
    UPDATE_NUM="${UPDATE_NUM%.jar}"
    UPDATE_LEVEL=$(echo "${UPDATE_NUM}" | sed 's/^0*//')
    : "${UPDATE_LEVEL:=0}"

    # Extract build number from the hf-updates subdirectory name
    BUILD_NUMBER=""
    HF_DIR=$(python3 - "$CF_INSTALL_DIR/cfusion/hf-updates" "$UPDATE_LEVEL" <<'PY'
import pathlib, re, sys
folders = [p for p in pathlib.Path(sys.argv[1]).iterdir()
           if p.is_dir() and (m := re.fullmatch(r'hf-2025-(\d+)-(\d+)', p.name)) and int(m[1]) == int(sys.argv[2])]
if len(folders) != 1:
    raise SystemExit('Cannot resolve one installed hotfix folder for the update level.')
print(folders[0])
PY
)
    if [[ -n "${HF_DIR}" ]]; then
      BUILD_NUMBER="${HF_DIR##*-}"
    fi

    # Update the tracking XML so CF Admin and cfpm report the correct level
    UPDATES_XML="${CF_INSTALL_DIR}/cfusion/hf-updates/updates.xml"
    if ! python3 - "$UPDATES_XML" "$UPDATE_LEVEL" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    levels = [int(n.text.strip()) for n in ET.parse(sys.argv[1]).iter('cfhf_updatelevel')]
    sys.exit(0 if int(sys.argv[2]) in levels else 1)
except (OSError, ET.ParseError, ValueError, AttributeError):
    sys.exit(1)
PY
    then
      log "Updating updates.xml to reflect update level ${UPDATE_NUM} (build ${BUILD_NUMBER})..."
      BACKUP_DIR=""
      if [[ -n "${HF_DIR}" ]]; then BACKUP_DIR="${HF_DIR}/backup"; fi

      NEW_ITEM="    <item>
         <title>ColdFusion 2025 Update ${UPDATE_LEVEL}</title>
         <description>ColdFusion (2025 release) Update ${UPDATE_LEVEL}</description>
         <cfhf_id>hf-2025-${UPDATE_NUM}</cfhf_id>
         <cfhf_technotelink>http://www.adobe.com/go/cf2025_update${UPDATE_LEVEL}</cfhf_technotelink>
         <cfhf_type>General</cfhf_type>
         <cfhf_updatelevel>${UPDATE_NUM}</cfhf_updatelevel>
         <cfhf_buildnumber>${BUILD_NUMBER}</cfhf_buildnumber>
         <cfhf_installdate></cfhf_installdate>
         <cfhf_backupdir>${BACKUP_DIR}</cfhf_backupdir>
    </item>"

      if [[ -f "${UPDATES_XML}" ]] && grep -q '<updates>' "${UPDATES_XML}"; then
        NEW_ITEM="${NEW_ITEM}" awk '
          { print }
          /<updates>/ { print ENVIRON["NEW_ITEM"] }
        ' "${UPDATES_XML}" > "${UPDATES_XML}.tmp"
        # Atomic replacement must retain the runtime-readable vendor attributes.
        chmod --reference="$UPDATES_XML" "$UPDATES_XML.tmp"
        chown --reference="$UPDATES_XML" "$UPDATES_XML.tmp"
        mv -- "$UPDATES_XML.tmp" "$UPDATES_XML"
      else
        cat > "${UPDATES_XML}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<updates>
${NEW_ITEM}
</updates>
EOF
        chown --reference="$(dirname -- "$UPDATES_XML")" "$UPDATES_XML"
        chmod 644 "$UPDATES_XML"
      fi
    fi
    log "Installed hotfix artifact level ${UPDATE_NUM} (build ${BUILD_NUMBER}); live verification follows."
  else
    die "No installed hotfix JAR; update verification failed."
  fi

  # Purge the OSGi bundle cache and restart so the updated classes load cleanly
  log "Purging felix cache and restarting ColdFusion after update..."
  stop_cf
  rm -rf "${CF_INSTALL_DIR}/cfusion/bin/felix-cache"
  start_cf

  log "Waiting for ColdFusion to start after update..."
  for _ in $(seq 1 60); do
    if curl -ks -o /dev/null -m 3 "https://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm" \
      || curl -ks -o /dev/null -m 3 "http://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm"; then
      log "ColdFusion is running after update."
      break
    fi
    sleep 5
  done
else
  die "cfpm.sh is missing; cannot perform mandatory update."
fi

wait_cf
verify_update
verify_runtime_identity
if [[ "$UPDATE_ONLY" == true ]]; then
  if [[ -f $WORK_DIR/README-credentials.md ]]; then
    printf '\nUpdate-only verification: %s at %s\n' "$LATEST_LEVEL" "$(date -u +%FT%TZ)" >>"$WORK_DIR/README-credentials.md"
  fi
  log "Update-only verification succeeded. Existing credentials and lockdown were retained."
  exit 0
fi
# --- Web server connector / lockdown -----------------------------------------
if [[ "${LOCKDOWN}" == "true" ]]; then
  log "Accessing ColdFusion Administrator once, as required by the Lockdown Tool prerequisites..."
  curl -ks -o /dev/null -m 10 "https://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm" \
    || curl -ks -o /dev/null -m 10 "http://127.0.0.1:${CF_ADMIN_PORT}/CFIDE/administrator/index.cfm" \
    || log "WARNING: could not reach the Administrator; the Lockdown Tool may refuse to run."

  LOCKDOWN_INSTALLER_PATH="${WORK_DIR}/lockdown.bin"
  [[ -f "${LOCKDOWN_INSTALLER_PATH}" ]] || die "Lockdown installer not found at ${LOCKDOWN_INSTALLER_PATH}"
  chmod +x "${LOCKDOWN_INSTALLER_PATH}"

  # Adobe's docs define CF_SCRIPTS_ALIAS as a *replacement* name for
  # /cf_scripts, chosen specifically so the Lockdown Tool's own
  # "RedirectMatch 404 .*cf_scripts.*" rule (which blocks the default name
  # everywhere) doesn't also block the alias itself. Using "cf_scripts" here
  # (the default/blocked name) makes the Apache Alias unreachable, 404ing
  # cfajax.js/cfmessage.js and breaking the Administrator login page's JS.
  CF_SCRIPTS_ALIAS="cfs$(openssl rand -hex 4)"

  LOCKDOWN_PROPS_PATH="${WORK_DIR}/lockdown-silent.properties"
  cat > "${LOCKDOWN_PROPS_PATH}" <<PROPS
# Silent Properties file for Adobe ColdFusion Server Auto-Lockdown Installer
# Web Server : Apache
# Platform : Linux
# (generated by install-cf2025.sh)
INSTALLER_UI=SILENT
SILENT_CF_SERVER_LOCATION=${CF_INSTALL_DIR}
SERVER_APACHE=1
SERVER_IIS=0
APP_SERVER_INSTANCE=cfusion
UPDATE_CF_TRUE=${CF_UPDATE_TRUE}
AUTO_UPDATE_CF_TRUE=${CF_AUTO_UPDATE_TRUE}
HF_UPDATE_JAR_PATH=
CF_ADMIN_USERNAME=${CF_ADMIN_USERNAME}
CF_ADMIN_PASSWORD=${CF_ADMIN_PASSWORD}
CF_ADMIN_PORT=${CF_ADMIN_PORT}
SYSTEM_ADMIN_USER=root
SYSTEM_ADMIN_PWD=
SYSTEM_ADMIN_DOMAIN=localhost
USER_CF_SERVICE_TRUE=1
CF_USER_UNAME=${RUNTIME_USER}
CF_USER_PWD=
CF_USER_GRP=${RUNTIME_USER}
APACHE_DEFAULT_USER_TRUE=1
APACHE_DEFAULT_USERNAME=${APACHE_USER}
APACHE_DEFAULT_GROUP=${APACHE_GROUP}
APACHE_DEFAULT_PASSWORD=
WEBSERVER_CONF_DIR=${APACHE_CONF_DIR}
APACHE_BIN_FILE_PATH=${APACHE_BIN_PATH}
WEBROOT_PATH=${WEBROOT_PATH}
USER_FILE_UPLOAD_TRUE=0
USER_FILE_UPLOAD_PATH=
CF_SCRIPTS_ALIAS=${CF_SCRIPTS_ALIAS}
CHANGE_SHUTDOWN_PORT_TRUE=${CHANGE_SHUTDOWN_PORT}
SHUTDOWN_PORT_NEW=${SHUTDOWN_PORT_NEW}
PROPS
  chmod 600 "${LOCKDOWN_PROPS_PATH}"

  # Workaround for an Adobe Lockdown Tool bug: it resolves SYSTEM_ADMIN_DOMAIN
  # as a Unix *group* name when setting ColdFusion directory ownership, so a
  # group literally named "localhost" must exist or the permissions step
  # fails silently ("Failed to change the permissions!").
  getent group localhost >/dev/null 2>&1 || groupadd localhost

  # Root-cause fix for an Adobe Lockdown Tool bug: the tool restarts
  # ColdFusion (for the runtime-user change) by shelling out to this
  # "coldfusion" launcher script, which backgrounds the Java process via
  # "... -start &" without redirecting its stdin/stdout/stderr away from
  # the launcher's own. Because the Lockdown Tool is itself invoked with
  # its stdout/stderr as a pipe, the backgrounded (and never-exiting) CF
  # JVM inherits that same pipe as its stderr, and every thread in the JVM
  # holds its own copy of that file descriptor open indefinitely. The
  # Lockdown Tool then blocks forever doing a blocking read waiting for
  # that pipe to reach EOF, even though the restart itself finishes in
  # seconds and all of the tool's own work is otherwise done. Patch the
  # launcher so the backgrounded JVM's fds are fully detached from
  # whatever invoked it; safe to run even if already patched.
  CF_LAUNCHER="${CF_INSTALL_DIR}/cfusion/bin/coldfusion"
  if [[ -f "${CF_LAUNCHER}" ]] && grep -q 'Bootstrap -start &"' "${CF_LAUNCHER}"; then
    log "Patching coldfusion launcher to detach backgrounded JVM fds (Lockdown Tool hang workaround)..."
    sed -i 's/Bootstrap -start &"/Bootstrap -start <\/dev\/null >\/dev\/null 2>\&1 \&"/' "${CF_LAUNCHER}"
  fi

  log "Running the ColdFusion 2025 Server Auto-Lockdown Tool (Linux/Apache)..."
  # Bound with a generous timeout as a last-resort safety net in case some
  # other, still-unknown step hangs; the explicit "coldfusion restart" later
  # in this script is a further safety net in case a restart hadn't
  # finished yet.
  lockdown_status=0
  (umask 022; timeout -k 10 900 "${LOCKDOWN_INSTALLER_PATH}" -f "${LOCKDOWN_PROPS_PATH}" -i silent 9>&- 3>&- 4>&-) >"${WORK_DIR}/lockdown-console.log" 2>&1 || lockdown_status=$?
  log "Lockdown process exit status: $lockdown_status; checking Adobe's success marker and rollback log."

  LOCKDOWN_LOG_DIR="${CF_INSTALL_DIR}/lockdown/cfusion/Logs"
  if [[ -d "${LOCKDOWN_LOG_DIR}" ]] && grep -rEq 'ColdFusion Server has been locked down successfully|Successfully locked down ColdFusion!' "${LOCKDOWN_LOG_DIR}" 2>/dev/null && ! grep -riq "rolling back" "${LOCKDOWN_LOG_DIR}"; then
    log "Lockdown Tool completed successfully. Logs: ${LOCKDOWN_LOG_DIR}"
  else
    die "Lockdown did not report success or rolled back. Inspect ${LOCKDOWN_LOG_DIR}."
  fi

  shred -u "${LOCKDOWN_PROPS_PATH}" 2>/dev/null || rm -f "${LOCKDOWN_PROPS_PATH}"

  # Workaround for an Adobe Lockdown Tool bug: it writes the new cf_scripts
  # alias into the "Default ScriptSrc Directory" CF Admin setting
  # (neo-runtime.xml's CFFormScriptSrc) without a leading "/". Pages below
  # site root (e.g. /CFIDE/administrator/index.cfm) then resolve the
  # relative script src wrong (.../CFIDE/administrator/<alias>/... instead
  # of /<alias>/...), 404ing cfajax.js/cfmessage.js and breaking the
  # Administrator login page's password hashing JS.
  NEO_RUNTIME_XML="${CF_INSTALL_DIR}/cfusion/lib/neo-runtime.xml"
  if [[ -f "${NEO_RUNTIME_XML}" ]] && grep -q "<string>${CF_SCRIPTS_ALIAS}/</string>" "${NEO_RUNTIME_XML}"; then
    log "Fixing missing leading slash on the Default ScriptSrc Directory setting (Lockdown Tool bug)..."
    sed -i "s|<string>${CF_SCRIPTS_ALIAS}/</string>|<string>/${CF_SCRIPTS_ALIAS}/</string>|" "${NEO_RUNTIME_XML}"
  fi

  # Same Lockdown Tool leading-slash bug, but in Apache's own config this
  # time: cf_lockdown.conf gets "Alias ${CF_SCRIPTS_ALIAS} ..." instead of
  # "Alias /${CF_SCRIPTS_ALIAS} ...". Apache's Alias directive requires the
  # URL-path argument to start with "/", so without this fix the alias is
  # silently ignored (not just misconfigured) and cfajax.js/cfmessage.js
  # 404 through Apache even though they work fine via CF's own port 8500.
  CF_LOCKDOWN_CONF="${APACHE_CONF_DIR}/cf_lockdown.conf"
  if [[ -f "${CF_LOCKDOWN_CONF}" ]] && grep -q "^Alias ${CF_SCRIPTS_ALIAS} " "${CF_LOCKDOWN_CONF}"; then
    log "Fixing missing leading slash on the Apache cf_scripts Alias (Lockdown Tool bug)..."
    sed -i "s|^Alias ${CF_SCRIPTS_ALIAS} |Alias /${CF_SCRIPTS_ALIAS} |" "${CF_LOCKDOWN_CONF}"
  fi

  # The Lockdown Tool is supposed to wire ColdFusion into Apache itself, but
  # it reliably hangs (see timeout above) right after the runtime-user
  # restart and before it ever reaches that step, so the connector never
  # gets configured. Do it explicitly here; wsconfig is safe to (re)run.
  log "Ensuring ColdFusion is connected to Apache (wsconfig)..."
  if "${CF_INSTALL_DIR}/jre/bin/java" -jar "${CF_INSTALL_DIR}/cfusion/runtime/lib/wsconfig.jar" -list -ws Apache 2>/dev/null \
      | grep -qF "${APACHE_CONF_DIR}"; then
    log "Apache connector already configured for ${APACHE_CONF_DIR}."
  else
    "${CF_INSTALL_DIR}/jre/bin/java" -jar "${CF_INSTALL_DIR}/cfusion/runtime/lib/wsconfig.jar" \
      -ws Apache \
      -dir "${APACHE_CONF_DIR}" \
      -bin "${APACHE_BIN_PATH}" \
      -script "${APACHE_CTL_PATH}" \
      -v
  fi
  systemctl restart "${APACHE_SERVICE}"

  # The Lockdown Tool hang (above) also means the shutdown-port change never
  # ran. Apply it directly to server.xml if it's still on the default; the
  # unconditional "coldfusion restart" at the end of this script picks it up.
  if [[ "${CHANGE_SHUTDOWN_PORT}" == "1" && -n "${SHUTDOWN_PORT_NEW}" ]]; then
    CF_SERVER_XML="${CF_INSTALL_DIR}/cfusion/runtime/conf/server.xml"
    if [[ -f "${CF_SERVER_XML}" ]] && ! grep -q "port=\"${SHUTDOWN_PORT_NEW}\" shutdown=" "${CF_SERVER_XML}"; then
      log "Setting Tomcat shutdown port to ${SHUTDOWN_PORT_NEW} in server.xml..."
      sed -i -E "s/(<Server port=\")[0-9]+(\" shutdown=)/\1${SHUTDOWN_PORT_NEW}\2/" "${CF_SERVER_XML}"
    fi
  fi
else
  log "Skipping lockdown; connecting ColdFusion to Apache with wsconfig instead..."
  "${CF_INSTALL_DIR}/jre/bin/java" -jar "${CF_INSTALL_DIR}/cfusion/runtime/lib/wsconfig.jar" \
    -ws Apache \
    -dir "${APACHE_CONF_DIR}" \
    -bin "${APACHE_BIN_PATH}" \
    -script "${APACHE_CTL_PATH}" \
    -v
  systemctl restart "${APACHE_SERVICE}"
fi

# Workaround for a wsconfig.jar bug: the cf_scripts <PreResources> entry it
# writes into server.xml uses webAppMount="<alias>" (missing the leading
# "/" that server.xml's own comments say is mandatory). Tomcat's
# DirResourceSet then fails to initialize with a NullPointerException on
# every subsequent start, so ColdFusion looks like it started (logs say
# "ColdFusion started") but the web context never comes up and it exits
# moments later. Patch it in place; safe to run even if already fixed. The
# alias here is "cf_scripts" when lockdown is skipped (wsconfig's default)
# or the random CF_SCRIPTS_ALIAS generated above when lockdown ran.
CF_SERVER_XML="${CF_INSTALL_DIR}/cfusion/runtime/conf/server.xml"
SCRIPTS_ALIAS_FOR_FIX="${CF_SCRIPTS_ALIAS:-cf_scripts}"
if [[ -f "${CF_SERVER_XML}" ]] && grep -q "webAppMount=\"${SCRIPTS_ALIAS_FOR_FIX}\"" "${CF_SERVER_XML}"; then
  log "Fixing invalid webAppMount in server.xml (wsconfig bug)..."
  sed -i "s|webAppMount=\"${SCRIPTS_ALIAS_FOR_FIX}\"|webAppMount=\"/${SCRIPTS_ALIAS_FOR_FIX}\"|" "${CF_SERVER_XML}"
fi

stop_cf
start_cf

shred -u "${CF_PROPS_PATH}" 2>/dev/null || rm -f "${CF_PROPS_PATH}"



wait_cf
verify_update
verify_runtime_identity
"${APACHE_CTL_PATH}" configtest >"${WORK_DIR}/apache-configtest.log" 2>&1
connector_name="cfconnector$(openssl rand -hex 16).cfm"
connector_token=$(openssl rand -hex 16)
PROBE_PATH="${WEBROOT_PATH}/$connector_name"
printf '<cfif cgi.remote_addr NEQ "127.0.0.1"><cfheader statuscode="404"><cfabort></cfif><cfcontent type="text/plain" reset="true"><cfoutput>%s</cfoutput>' "$connector_token" >"$PROBE_PATH"
chmod 644 "$PROBE_PATH"
connector_response=$(curl -fsS --max-time 30 "http://127.0.0.1/$connector_name")
[[ $connector_response == "$connector_token" ]] || die 'Apache did not execute the ColdFusion connector probe.'
rm -f -- "$PROBE_PATH"; PROBE_PATH=
printf "\nVerified update: %s\nScripts alias: /%s/\nStatus: complete\n" "$LATEST_LEVEL" "${CF_SCRIPTS_ALIAS:-cf_scripts}" >>"${WORK_DIR}/README-credentials.md"
log "Done. ColdFusion is installed at ${CF_INSTALL_DIR}, Apache (${APACHE_SERVICE}) is fronting it."
write_lab_receipt >&3
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
