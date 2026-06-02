#!/usr/bin/env bash
set -euo pipefail

mode="check"
assume_yes=0
dry_run=0
skip_install=0
skip_pam=0
skip_portal=0
skip_alias=0
pam_service=""
timestamp="$(date +%Y%m%d%H%M%S)"
changed_pam=0
changed_portal=0
changed_group=0
changed_secret_service=0

usage() {
  cat <<'EOF'
Configure a Linux Secret Service backend for OpenChat.

OpenChat stores sessions and private keys through flutter_secure_storage.
On Linux that requires a working Secret Service backend such as GNOME Keyring
or KWallet. This helper is aimed at desktops where that is missing or not wired
into login, especially COSMIC on Arch/CachyOS.

Usage:
  ./tool/configure_linux_keyring.sh --check
  ./tool/configure_linux_keyring.sh --apply

Options:
  --check                 Inspect only. This is the default.
  --apply                 Apply safe fixes and prompt before host-level edits.
  -y, --yes               Do not prompt in --apply mode.
  --dry-run               Print commands that would run.
  --pam-service SERVICE   PAM service to inspect/patch, for example login.
  --no-install            Skip package installation.
  --no-pam                Skip PAM checks and edits.
  --no-portal             Skip COSMIC xdg-desktop-portal preference.
  --no-alias              Skip Secret Service default-alias repair.
  -h, --help              Show this help.

The script must be run as the desktop user, not with sudo. It invokes sudo only
for package installation, PAM backups/edits, and optional group changes.
EOF
}

info() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

lower() {
  printf '%s' "$*" | tr '[:upper:]' '[:lower:]'
}

confirm() {
  local prompt="$1"
  if [ "$assume_yes" -eq 1 ]; then
    return 0
  fi

  local reply=""
  read -r -p "$prompt [y/N] " reply
  case "$(lower "$reply")" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

run_sudo() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run] sudo'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  sudo "$@"
}

run_user() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      mode="check"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      ;;
    -y|--yes)
      assume_yes=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --pam-service)
      pam_service="${2:-}"
      [ -n "$pam_service" ] || die "--pam-service requires a value"
      shift 2
      ;;
    --no-install)
      skip_install=1
      shift
      ;;
    --no-pam)
      skip_pam=1
      shift
      ;;
    --no-portal)
      skip_portal=1
      shift
      ;;
    --no-alias)
      skip_alias=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "This helper only supports Linux."
[ "${EUID:-$(id -u)}" -ne 0 ] || die "Run as the desktop user, not with sudo."

os_id="unknown"
os_like=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-unknown}"
  os_like="${ID_LIKE:-}"
fi

target_user="${USER:-$(id -un)}"
desktop="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}"
desktop_lc="$(lower "$desktop")"

is_cosmic() {
  [ -f /etc/greetd/cosmic-greeter.toml ] || [[ "$desktop_lc" == *cosmic* ]]
}

package_manager() {
  if command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
  else
    printf 'unknown'
  fi
}

pkg_exists() {
  local pm="$1"
  local pkg="$2"

  case "$pm" in
    pacman) pacman -Si "$pkg" >/dev/null 2>&1 ;;
    apt) apt-cache show "$pkg" >/dev/null 2>&1 ;;
    dnf) dnf list --available "$pkg" >/dev/null 2>&1 || rpm -q "$pkg" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive search --exact-match "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_installed() {
  local pm="$1"
  local pkg="$2"

  case "$pm" in
    pacman) pacman -Q "$pkg" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf|zypper) rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

candidate_packages() {
  local pm="$1"

  case "$pm" in
    pacman)
      printf '%s\n' gnome-keyring libsecret seahorse xdg-desktop-portal xdg-desktop-portal-gtk
      if is_cosmic; then
        printf '%s\n' xdg-desktop-portal-cosmic
      fi
      ;;
    apt)
      printf '%s\n' gnome-keyring libsecret-1-0 libsecret-tools seahorse xdg-desktop-portal xdg-desktop-portal-gtk
      if is_cosmic; then
        printf '%s\n' xdg-desktop-portal-cosmic
      fi
      ;;
    dnf)
      printf '%s\n' gnome-keyring libsecret libsecret-tools seahorse xdg-desktop-portal xdg-desktop-portal-gtk
      if is_cosmic; then
        printf '%s\n' xdg-desktop-portal-cosmic
      fi
      ;;
    zypper)
      printf '%s\n' gnome-keyring libsecret-tools seahorse xdg-desktop-portal xdg-desktop-portal-gtk
      if is_cosmic; then
        printf '%s\n' xdg-desktop-portal-cosmic
      fi
      ;;
  esac
}

ensure_packages() {
  [ "$skip_install" -eq 0 ] || {
    info "Package installation: skipped"
    return
  }

  local pm
  pm="$(package_manager)"
  if [ "$pm" = "unknown" ]; then
    warn "No supported package manager found; install GNOME Keyring/libsecret manually."
    return
  fi

  local pkg=""
  local available=()
  local missing=()
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if ! pkg_exists "$pm" "$pkg"; then
      warn "Package not found in enabled repositories: $pkg"
      continue
    fi
    available+=("$pkg")
    if ! pkg_installed "$pm" "$pkg"; then
      missing+=("$pkg")
    fi
  done < <(candidate_packages "$pm")

  if [ "${#available[@]}" -eq 0 ]; then
    warn "No Secret Service packages could be matched for package manager: $pm"
    return
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    info "Packages: required Secret Service packages are installed"
    return
  fi

  warn "Packages missing: ${missing[*]}"
  if [ "$mode" != "apply" ]; then
    warn "Run with --apply to install them."
    return
  fi

  confirm "Install missing keyring packages with $pm?" || {
    warn "Package installation skipped by user."
    return
  }

  case "$pm" in
    pacman)
      run_sudo pacman -S --needed "${missing[@]}"
      ;;
    apt)
      run_sudo apt-get update
      run_sudo apt-get install -y "${missing[@]}"
      ;;
    dnf)
      run_sudo dnf install -y "${missing[@]}"
      ;;
    zypper)
      run_sudo zypper --non-interactive install "${missing[@]}"
      ;;
  esac
}

cosmic_pam_service() {
  local file="/etc/greetd/cosmic-greeter.toml"
  [ -r "$file" ] || return 1

  awk -F= '
    /^[[:space:]]*service[[:space:]]*=/ {
      gsub(/[[:space:]\042]/, "", $2)
      print $2
      exit
    }
  ' "$file"
}

detect_pam_service() {
  if [ -n "$pam_service" ]; then
    printf '%s' "$pam_service"
    return
  fi

  local service=""
  service="$(cosmic_pam_service || true)"
  if [ -n "$service" ] && [ -f "/etc/pam.d/$service" ]; then
    printf '%s' "$service"
    return
  fi

  for service in gdm-password sddm lightdm login; do
    if [ -f "/etc/pam.d/$service" ]; then
      printf '%s' "$service"
      return
    fi
  done

  printf 'login'
}

pam_module_exists() {
  local dir=""
  for dir in /usr/lib/security /lib/security /lib64/security /usr/lib64/security; do
    [ -e "$dir/pam_gnome_keyring.so" ] && return 0
  done
  return 1
}

ensure_pam_hooks() {
  [ "$skip_pam" -eq 0 ] || {
    info "PAM hooks: skipped"
    return
  }

  local service path needs_auth needs_session tmp backup
  service="$(detect_pam_service)"
  path="/etc/pam.d/$service"

  if [ ! -f "$path" ]; then
    warn "PAM service not found: $path"
    return
  fi

  if ! pam_module_exists; then
    warn "pam_gnome_keyring.so was not found. Install gnome-keyring first."
    return
  fi

  needs_auth=1
  needs_session=1
  grep -Eq '^[[:space:]]*auth[[:space:]].*pam_gnome_keyring\.so' "$path" && needs_auth=0
  grep -Eq '^[[:space:]]*session[[:space:]].*pam_gnome_keyring\.so' "$path" && needs_session=0

  if [ "$needs_auth" -eq 0 ] && [ "$needs_session" -eq 0 ]; then
    info "PAM hooks: $service already includes GNOME Keyring auth/session hooks"
    return
  fi

  warn "PAM hooks missing in $path"
  if [ "$mode" != "apply" ]; then
    warn "Run with --apply to add pam_gnome_keyring.so hooks with a backup."
    return
  fi

  confirm "Patch $path for login-time GNOME Keyring unlock?" || {
    warn "PAM patch skipped by user."
    return
  }

  tmp="$(mktemp)"
  awk -v add_auth="$needs_auth" -v add_session="$needs_session" '
    function is_auth(line) {
      return line ~ /^[[:space:]]*auth[[:space:]]/ && line !~ /^[[:space:]]*#/
    }
    function is_session(line) {
      return line ~ /^[[:space:]]*session[[:space:]]/ && line !~ /^[[:space:]]*#/
    }
    {
      lines[NR] = $0
      if (is_auth($0)) last_auth = NR
      if (is_session($0)) last_session = NR
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (add_auth == "1" && i == last_auth) {
          print "auth       optional     pam_gnome_keyring.so"
        }
        if (add_session == "1" && i == last_session) {
          print "session    optional     pam_gnome_keyring.so auto_start"
        }
      }
      if (add_auth == "1" && last_auth == 0) {
        print "auth       optional     pam_gnome_keyring.so"
      }
      if (add_session == "1" && last_session == 0) {
        print "session    optional     pam_gnome_keyring.so auto_start"
      }
    }
  ' "$path" > "$tmp"

  backup="${path}.openchat-backup-${timestamp}"
  run_sudo cp "$path" "$backup"
  run_sudo install -m 0644 -o root -g root "$tmp" "$path"
  rm -f "$tmp"
  changed_pam=1
  info "PAM hooks: patched $path (backup: $backup)"
}

portal_config_path() {
  printf '%s/xdg-desktop-portal/cosmic-portals.conf' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

write_new_portal_config() {
  local path="$1"
  cat > "$path" <<'EOF'
[preferred]
default=cosmic;gtk;
org.freedesktop.impl.portal.Secret=gnome-keyring;
EOF
}

merge_portal_config() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"

  awk '
    BEGIN {
      in_preferred = 0
      saw_preferred = 0
      saw_default = 0
      saw_secret = 0
    }
    /^[[:space:]]*\[preferred\][[:space:]]*$/ {
      saw_preferred = 1
      in_preferred = 1
      print
      next
    }
    /^[[:space:]]*\[/ && in_preferred {
      if (!saw_default) print "default=cosmic;gtk;"
      if (!saw_secret) print "org.freedesktop.impl.portal.Secret=gnome-keyring;"
      in_preferred = 0
    }
    in_preferred && /^[[:space:]]*default[[:space:]]*=/ {
      saw_default = 1
    }
    in_preferred && /^[[:space:]]*org\.freedesktop\.impl\.portal\.Secret[[:space:]]*=/ {
      if (!saw_secret) print "org.freedesktop.impl.portal.Secret=gnome-keyring;"
      saw_secret = 1
      next
    }
    {
      print
    }
    END {
      if (in_preferred) {
        if (!saw_default) print "default=cosmic;gtk;"
        if (!saw_secret) print "org.freedesktop.impl.portal.Secret=gnome-keyring;"
      }
      if (!saw_preferred) {
        print ""
        print "[preferred]"
        print "default=cosmic;gtk;"
        print "org.freedesktop.impl.portal.Secret=gnome-keyring;"
      }
    }
  ' "$path" > "$tmp"

  mv "$tmp" "$path"
}

restart_user_portals() {
  command -v systemctl >/dev/null 2>&1 || return 0
  run_user systemctl --user try-restart xdg-desktop-portal.service >/dev/null 2>&1 || true
  run_user systemctl --user try-restart xdg-desktop-portal-cosmic.service >/dev/null 2>&1 || true
}

secret_service_pid() {
  busctl --user status org.freedesktop.secrets 2>/dev/null |
    awk -F= '/^PID=/{print $2; exit}'
}

restart_secret_service() {
  local pid
  pid="$(secret_service_pid)"
  if [ -n "$pid" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf '[dry-run] kill %q\n' "$pid"
    else
      kill "$pid" || true
    fi
    sleep 1
  fi

  run_user busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service ReadAlias s default >/dev/null 2>&1 || true
  changed_secret_service=1
}

ensure_portal_config() {
  [ "$skip_portal" -eq 0 ] || {
    info "Portal preference: skipped"
    return
  }

  local path
  path="$(portal_config_path)"

  if ! is_cosmic && [ ! -f "$path" ]; then
    info "Portal preference: not COSMIC, leaving xdg-desktop-portal config unchanged"
    return
  fi

  if [ -f "$path" ] &&
    grep -Eq '^[[:space:]]*org\.freedesktop\.impl\.portal\.Secret[[:space:]]*=[[:space:]]*gnome-keyring;' "$path"; then
    info "Portal preference: Secret portal already prefers gnome-keyring"
    return
  fi

  warn "Portal preference missing: $path"
  if [ "$mode" != "apply" ]; then
    warn "Run with --apply to prefer GNOME Keyring for the COSMIC Secret portal."
    return
  fi

  confirm "Write COSMIC Secret portal preference to $path?" || {
    warn "Portal preference skipped by user."
    return
  }

  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ]; then
    cp "$path" "${path}.openchat-backup-${timestamp}"
    merge_portal_config "$path"
  else
    write_new_portal_config "$path"
  fi

  changed_portal=1
  info "Portal preference: updated $path"
  restart_user_portals
}

secret_alias_path() {
  local output
  output="$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service ReadAlias s default 2>/dev/null || true)"
  sed -n 's/^o "\([^"]*\)".*/\1/p' <<<"$output"
}

collection_exists() {
  local path="$1"
  [ -n "$path" ] || return 1
  busctl --user get-property org.freedesktop.secrets "$path" \
    org.freedesktop.Secret.Collection Label >/dev/null 2>&1
}

collection_locked() {
  local path="$1"
  busctl --user get-property org.freedesktop.secrets "$path" \
    org.freedesktop.Secret.Collection Locked 2>/dev/null | awk '{print $2}'
}

ensure_secret_service_started() {
  command -v busctl >/dev/null 2>&1 || return 1

  if busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service ReadAlias s default >/dev/null 2>&1; then
    return 0
  fi

  if [ "$mode" = "apply" ] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
    run_user gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1 || true
  fi

  busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service ReadAlias s default >/dev/null 2>&1
}

ensure_default_alias() {
  [ "$skip_alias" -eq 0 ] || {
    info "Secret Service alias: skipped"
    return
  }

  if ! ensure_secret_service_started; then
    warn "Secret Service is not available on the user D-Bus session."
    return
  fi

  local alias locked candidate
  alias="$(secret_alias_path)"
  if [ -n "$alias" ] && [ "$alias" != "/" ]; then
    locked="$(collection_locked "$alias")"
    info "Secret Service alias: default -> $alias (locked: ${locked:-unknown})"
    if [ "$locked" = "true" ]; then
      warn "Default keyring is locked. Unlock it in Seahorse/KWallet or log in with your password."
    fi
    return
  fi

  warn "Secret Service alias: default collection alias is missing"
  for candidate in \
    /org/freedesktop/secrets/collection/login \
    /org/freedesktop/secrets/collection/Default; do
    if collection_exists "$candidate"; then
      if [ "$mode" != "apply" ]; then
        warn "Run with --apply to set default alias to $candidate."
        return
      fi

      confirm "Set Secret Service default alias to $candidate?" || {
        warn "Default alias repair skipped by user."
        return
      }

      run_user busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
        org.freedesktop.Secret.Service SetAlias so default "$candidate"
      info "Secret Service alias: default -> $candidate"
      return
    fi
  done

  warn "No login or Default collection was found. Open Seahorse and create/unlock a Login keyring."
}

probe_libsecret_collection_load() {
  command -v python3 >/dev/null 2>&1 || return 10

  python3 - <<'PY'
try:
    import gi
    gi.require_version('Secret', '1')
    from gi.repository import Secret
except Exception as error:
    print(error)
    raise SystemExit(10)

try:
    flags = Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS
    service = Secret.Service.get_sync(flags, None)
    collection = Secret.Collection.for_alias_sync(
        service,
        Secret.COLLECTION_DEFAULT,
        Secret.CollectionFlags.NONE,
        None,
    )
    if collection is None:
        print('default collection alias did not resolve')
        raise SystemExit(11)
    print(f'{collection.get_label()} locked={str(collection.get_locked()).lower()}')
except Exception as error:
    print(error)
    raise SystemExit(11)
PY
}

ensure_libsecret_collection_load() {
  [ "$skip_alias" -eq 0 ] || return

  local output status retry_output retry_status
  set +e
  output="$(probe_libsecret_collection_load 2>&1)"
  status=$?
  set -e

  case "$status" in
    0)
      info "Libsecret warmup: $output"
      return
      ;;
    10)
      warn "Libsecret warmup probe skipped; Python GI Secret bindings are unavailable."
      return
      ;;
  esac

  warn "Libsecret warmup failed: $output"
  if [ "$mode" != "apply" ]; then
    warn "Run with --apply to restart the user Secret Service and clear stale GNOME Keyring item paths."
    return
  fi

  confirm "Restart the user Secret Service to clear stale keyring item paths?" || {
    warn "Secret Service restart skipped by user."
    return
  }

  restart_secret_service

  set +e
  retry_output="$(probe_libsecret_collection_load 2>&1)"
  retry_status=$?
  set -e

  if [ "$retry_status" -eq 0 ]; then
    info "Libsecret warmup after restart: $retry_output"
  else
    warn "Libsecret warmup still fails after restart: $retry_output"
  fi
}

ensure_password_login_group() {
  if ! getent group nopasswdlogin >/dev/null 2>&1; then
    return
  fi

  if ! id -nG "$target_user" | tr ' ' '\n' | grep -qx nopasswdlogin; then
    return
  fi

  warn "User $target_user is in nopasswdlogin; passwordless login cannot unlock a login keyring."
  if [ "$mode" != "apply" ]; then
    warn "Run with --apply to remove $target_user from nopasswdlogin."
    return
  fi

  confirm "Remove $target_user from nopasswdlogin?" || {
    warn "nopasswdlogin group change skipped by user."
    return
  }

  run_sudo gpasswd -d "$target_user" nopasswdlogin
  changed_group=1
}

info "OpenChat Linux keyring helper"
info "Mode: $mode"
info "OS: $os_id ${os_like:+(like: $os_like)}"
info "Desktop: $desktop"

ensure_packages
ensure_portal_config
ensure_pam_hooks
ensure_password_login_group
ensure_default_alias
ensure_libsecret_collection_load

if [ "$mode" = "check" ]; then
  info "Check complete. Re-run with --apply to make the suggested changes."
else
  info "Apply complete."
fi

if [ "$changed_pam" -eq 1 ] || [ "$changed_group" -eq 1 ]; then
  warn "Log out and sign back in with your password for PAM/group changes to take effect."
elif [ "$changed_portal" -eq 1 ]; then
  warn "Restart OpenChat. If Flatpak still sees the old portal, log out and back in."
elif [ "$changed_secret_service" -eq 1 ]; then
  warn "Restart OpenChat so it reconnects to the refreshed Secret Service."
fi
