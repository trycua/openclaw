#!/usr/bin/env bash
# lint-nix-systemd-congruence.sh
#
# Checks NixOS service definitions for divergent deployment patterns.
# Services with ExecStart pointing to runtime paths (outside /nix/store)
# must have restartTriggers or version tracking to ensure deploys take effect.
#
# Usage:
#   ./scripts/lint-nix-systemd-congruence.sh [directory]
#
# Exit codes:
#   0 - All services are congruent
#   1 - Found services with divergent deployment risk

set -euo pipefail

SEARCH_DIR="${1:-.}"
VIOLATIONS=0
CHECKED=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

echo "Checking NixOS service definitions for deployment congruence..."
echo ""

# Find all .nix files
while IFS= read -r -d '' file; do
  # Skip if not a nix file with service definitions
  if ! grep -q 'systemd\.services\.' "$file" 2>/dev/null; then
    continue
  fi

  ((CHECKED++)) || true

  # Check for ExecStart with runtime paths
  # Runtime paths: /var/, /tmp/, /run/, /home/ (not in nix store)
  if grep -E 'ExecStart\s*=.*(/var/|/tmp/|/run/|/home/)' "$file" >/dev/null 2>&1; then
    # Found runtime path in ExecStart - check for mitigations

    # Mitigation 1: restartTriggers
    if grep -q 'restartTriggers' "$file"; then
      echo -e "${GREEN}[OK]${NC} $file - has restartTriggers"
      continue
    fi

    # Mitigation 2: Version/hash in environment
    if grep -qE 'environment\.(VERSION|APP_VERSION|BUILD_HASH|PACKAGE_VERSION)\s*=' "$file"; then
      echo -e "${GREEN}[OK]${NC} $file - has version tracking in environment"
      continue
    fi

    # Mitigation 3: restartIfChanged with dynamic config
    if grep -qE 'restartIfChanged\s*=\s*true' "$file" && \
       grep -qE 'environment\.\w+\s*=.*\$\{' "$file"; then
      echo -e "${YELLOW}[WARN]${NC} $file - has restartIfChanged but verify derivation is tracked"
      continue
    fi

    # No mitigations found - this is a violation
    echo -e "${RED}[FAIL]${NC} $file"
    echo "       ExecStart uses runtime path without restartTriggers or version tracking"
    echo "       Fix: Add restartTriggers = [ <derivation> ]; or reference store path directly"
    echo ""

    # Show the problematic lines
    echo "       Problematic lines:"
    grep -n -E 'ExecStart\s*=.*(/var/|/tmp/|/run/|/home/)' "$file" | head -3 | while read -r line; do
      echo "         $line"
    done
    echo ""

    ((VIOLATIONS++)) || true
  fi

done < <(find "$SEARCH_DIR" -name '*.nix' -type f -print0 2>/dev/null)

echo ""
echo "Summary: Checked $CHECKED files with service definitions"

if [[ $VIOLATIONS -gt 0 ]]; then
  echo -e "${RED}Found $VIOLATIONS services with divergent deployment risk${NC}"
  echo ""
  echo "To fix, use one of these patterns:"
  echo ""
  echo "  # Pattern 1: Direct store path reference (recommended)"
  echo "  ExecStart = \"\${myApp}/bin/server\";"
  echo ""
  echo "  # Pattern 2: Explicit restartTriggers"
  echo "  restartTriggers = [ myApp configFile ];"
  echo ""
  echo "  # Pattern 3: Version in environment"
  echo "  environment.APP_VERSION = \"\${myApp}\";"
  echo ""
  exit 1
else
  echo -e "${GREEN}All services are deployment-congruent${NC}"
  exit 0
fi
