#!/usr/bin/env bash
# bootstrap-app.sh — scaffold a new "Groom Hub family" Android app.
#
# Usage:
#   ./bootstrap/bin/bootstrap-app.sh <slug> "<Display Name>" [output_dir]
#
# Examples:
#   ./bootstrap/bin/bootstrap-app.sh notes "Notes"
#   ./bootstrap/bin/bootstrap-app.sh focus-timer "Focus Timer" ~/Documents
#
# The slug must be lowercase, kebab-case, and a valid Java package fragment
# after dashes are stripped (so "focus-timer" → applicationId
# "dev.matejgroombridge.focustimer"). The output directory defaults to the
# parent of the bootstrap repo.
#
# What it produces:
#   <output_dir>/<slug>/                ← the new app's repo root
#   ├── .github/workflows/release.yml   ← release pipeline (DISPLAY_NAME baked in)
#   ├── .gitignore
#   ├── CHANGELOG.md                    ← starter v0.1.0 entry
#   ├── README.md                       ← starter readme
#   ├── app/
#   │   ├── build.gradle.kts            ← applicationId, namespace pre-filled
#   │   ├── proguard-rules.pro
#   │   └── src/main/
#   │       ├── AndroidManifest.xml
#   │       ├── java/dev/matejgroombridge/<slug>/
#   │       │   ├── MainActivity.kt
#   │       │   └── ui/theme/{Theme,Type}.kt
#   │       └── res/...
#   ├── bin/changeset
#   ├── build.gradle.kts
#   ├── gradle.properties
#   ├── gradle/libs.versions.toml
#   └── settings.gradle.kts
#
# After running:
#   1. cd into the new directory
#   2. git init && git add . && git commit -m "Initial commit"
#   3. Create matching empty repo on GitHub
#   4. git remote add origin ... && git push
#   5. Add the 5 secrets (KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS,
#      KEY_PASSWORD, MANIFEST_REPO_TOKEN) in GitHub repo settings
#   6. Run ./bin/changeset to publish v0.1.0
#
# See agent.md in the bootstrapped repo for the full walkthrough.

set -euo pipefail

# ── Locate self ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$BOOTSTRAP_ROOT/templates"

[[ -d "$TEMPLATES_DIR" ]] || {
  echo "Error: templates directory not found at $TEMPLATES_DIR" >&2
  exit 1
}

# ── Colors ───────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); DIM=$(tput dim); RED=$(tput setaf 1); GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4); RESET=$(tput sgr0)
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

die()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }
info() { echo "${BLUE}›${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

# ── Args ─────────────────────────────────────────────────────────────────
[[ $# -ge 2 ]] || die "Usage: $0 <slug> \"<Display Name>\" [output_dir]
Example: $0 notes \"Notes\""

SLUG="$1"
DISPLAY_NAME="$2"
OUTPUT_PARENT="${3:-$(dirname "$(dirname "$BOOTSTRAP_ROOT")")}"

# ── Validate slug ────────────────────────────────────────────────────────
if ! [[ "$SLUG" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] && ! [[ "$SLUG" =~ ^[a-z]$ ]]; then
  die "Slug '$SLUG' must be lowercase, kebab-case, start with a letter,
     end with a letter or digit, and contain only [a-z0-9-]."
fi

# Strip dashes for the Java package fragment (Java identifiers can't contain dashes).
PACKAGE_FRAGMENT="${SLUG//-/}"
APPLICATION_ID="dev.matejgroombridge.${PACKAGE_FRAGMENT}"
PACKAGE_PATH="dev/matejgroombridge/${PACKAGE_FRAGMENT}"

# Title-cased Gradle project name (e.g. "focus-timer" → "FocusTimer").
PROJECT_NAME=$(echo "$SLUG" | awk -F'-' '{
  for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)
}')

OUTPUT_DIR="$OUTPUT_PARENT/$SLUG"

# ── Confirm ──────────────────────────────────────────────────────────────
echo
echo "${BOLD}About to scaffold a new app:${RESET}"
echo "  ${BOLD}Slug:${RESET}            $SLUG"
echo "  ${BOLD}Display name:${RESET}    $DISPLAY_NAME"
echo "  ${BOLD}Application ID:${RESET}  $APPLICATION_ID"
echo "  ${BOLD}Package path:${RESET}    $PACKAGE_PATH"
echo "  ${BOLD}Project name:${RESET}    $PROJECT_NAME"
echo "  ${BOLD}Output dir:${RESET}      $OUTPUT_DIR"
echo
if [[ -e "$OUTPUT_DIR" ]]; then
  die "Output directory $OUTPUT_DIR already exists. Refusing to overwrite."
fi
read -rp "Proceed? [Y/n] " ans
[[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] || die "Aborted."

# ── Substitution helper ──────────────────────────────────────────────────
# Replaces __SLUG__, __DISPLAY_NAME__, __APPLICATION_ID__, __PACKAGE_PATH__,
# __PACKAGE_FRAGMENT__, __PROJECT_NAME__ in stdin → stdout.
substitute() {
  # Use awk instead of sed for safer escaping of arbitrary strings.
  awk \
    -v slug="$SLUG" \
    -v display="$DISPLAY_NAME" \
    -v appid="$APPLICATION_ID" \
    -v pkgpath="$PACKAGE_PATH" \
    -v pkgfrag="$PACKAGE_FRAGMENT" \
    -v projname="$PROJECT_NAME" \
  '{
    gsub(/__SLUG__/, slug)
    gsub(/__DISPLAY_NAME__/, display)
    gsub(/__APPLICATION_ID__/, appid)
    gsub(/__PACKAGE_PATH__/, pkgpath)
    gsub(/__PACKAGE_FRAGMENT__/, pkgfrag)
    gsub(/__PROJECT_NAME__/, projname)
    print
  }'
}

# ── Copy + substitute every template file ────────────────────────────────
mkdir -p "$OUTPUT_DIR"
info "Created $OUTPUT_DIR"

# Walk every file under templates/. Files ending in .tmpl get processed
# through substitute(); everything else is copied verbatim.
# We also rewrite any "__PACKAGE_PATH__" segment in the destination path so
# Java source files land at the right per-app location.
find "$TEMPLATES_DIR" -type f | while IFS= read -r src; do
  rel="${src#$TEMPLATES_DIR/}"
  # Substitute path components (handles __PACKAGE_PATH__ in directory names).
  rel_substituted=$(echo "$rel" | substitute)
  # Strip trailing .tmpl from output filename (templates use .tmpl to keep
  # them from being treated as actual Kotlin/Gradle files in this repo).
  dest_rel="${rel_substituted%.tmpl}"
  dest="$OUTPUT_DIR/$dest_rel"
  mkdir -p "$(dirname "$dest")"

  if [[ "$src" == *.tmpl ]]; then
    substitute < "$src" > "$dest"
  else
    cp "$src" "$dest"
  fi
done
ok "Wrote project files."

# ── Make scripts executable ──────────────────────────────────────────────
[[ -f "$OUTPUT_DIR/bin/changeset" ]] && chmod +x "$OUTPUT_DIR/bin/changeset"

# ── Final guidance ───────────────────────────────────────────────────────
echo
ok "${BOLD}Done.${RESET} Next steps:"
cat <<EOF

  ${BOLD}1.${RESET} cd "$OUTPUT_DIR"
  ${BOLD}2.${RESET} git init && git add . && git commit -m "Initial commit"
  ${BOLD}3.${RESET} Create an empty repo at github.com/MatejGroombridge/$SLUG
  ${BOLD}4.${RESET} git branch -M main
     git remote add origin git@github.com:MatejGroombridge/$SLUG.git
     git push -u origin main
  ${BOLD}5.${RESET} On GitHub: Settings → Secrets and variables → Actions, add:
       - KEYSTORE_BASE64
       - KEYSTORE_PASSWORD
       - KEY_ALIAS
       - KEY_PASSWORD
       - MANIFEST_REPO_TOKEN
  ${BOLD}6.${RESET} Have an AI agent build out the app's actual functionality.
  ${BOLD}7.${RESET} ./bin/changeset to publish v0.1.0

See agent.md in this repo for the full reference.
EOF
