#!/bin/bash
# ============================================================================
# Test: community extensions port-binding sweep
# ============================================================================
# Every community extension compose file under
# ods/extensions/library/services/ must publish host ports on loopback by
# default: either a literal 127.0.0.1 or ${VAR:-127.0.0.1}. A port with no
# host part, or a default other than loopback, publishes on every interface
# the moment the extension is installed.
#
# This is the same rule resolve-compose-stack.sh enforces when it validates
# an installed extension (_host_part_is_loopback). The loopback regex is read
# from the resolver itself, so the two cannot drift apart.
#
# Both documented styles pass:
#   - "127.0.0.1:${EXT_PORT:-NNNN}:NNNN"            loopback-only recipes
#   - "${BIND_ADDRESS:-127.0.0.1}:${EXT_PORT:-NNNN}:NNNN"  follows the LAN opt-in
#
# Scope: ports: entries only, read by parsing the YAML, so container-internal
# addresses in healthcheck/command arguments are never mistaken for bindings.
#
# Usage: bash tests/test-bind-address-sweep.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

EXT_DIR="$ROOT_DIR/extensions/library/services"
RESOLVER="$ROOT_DIR/scripts/resolve-compose-stack.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [[ ! -d "$EXT_DIR" ]]; then
    echo -e "  ${RED}FAIL${NC} community extensions directory missing: $EXT_DIR"
    exit 1
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} PyYAML is required to parse compose ports (python3 -m pip install pyyaml)"
    exit 1
fi

if ! python3 - "$EXT_DIR" "$RESOLVER" <<'PY'
import pathlib
import re
import sys

import yaml

ext_dir = pathlib.Path(sys.argv[1])
resolver = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

match = re.search(r'_LOOPBACK_VAR_DEFAULT_RE\s*=\s*re\.compile\(\s*r"([^"]+)"', resolver)
if not match:
    print("  resolve-compose-stack.sh no longer defines _LOOPBACK_VAR_DEFAULT_RE; update this sweep")
    sys.exit(1)
loopback_var_default = re.compile(match.group(1))


def is_loopback(host):
    return host == "127.0.0.1" or bool(loopback_var_default.fullmatch(host))


def split_host(port):
    # Mirrors _split_port_host in resolve-compose-stack.sh.
    if port.startswith("${"):
        end = port.find("}")
        if end == -1 or end + 1 >= len(port) or port[end + 1] != ":":
            return port, ""
        return port[: end + 1], port[end + 2:]
    if ":" not in port:
        return None, port
    host, _, rest = port.partition(":")
    if host.isdigit():
        return None, port
    return host, rest


violations = []
files = sorted(ext_dir.glob("*/compose.yaml"))
for path in files:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    for name, service in (document.get("services") or {}).items():
        for port in (service or {}).get("ports") or []:
            where = f"{path.relative_to(ext_dir.parent.parent.parent)} [{name}]"
            if isinstance(port, dict):
                host_ip = str(port.get("host_ip", ""))
                if port.get("published") and not is_loopback(host_ip):
                    violations.append(f"{where}: host_ip {host_ip or '(unset)'} is not a loopback default")
                continue
            text = str(port)
            host, _ = split_host(text)
            if host is None:
                violations.append(f"{where}: '{text}' has no host part, so it publishes on every interface")
            elif not is_loopback(host):
                violations.append(f"{where}: '{text}' does not default to 127.0.0.1")

if not files:
    print("  no community extension compose files found")
    sys.exit(1)
if violations:
    print("\n".join(violations))
    sys.exit(1)
print(f"  checked {len(files)} compose files")
PY
then
    echo -e "  ${RED}FAIL${NC} community extensions publish ports without a loopback default"
    echo "  Bind to 127.0.0.1, or to \${BIND_ADDRESS:-127.0.0.1} to follow the LAN opt-in."
    exit 1
fi

echo -e "  ${GREEN}PASS${NC} every community extension port defaults to loopback"
exit 0
