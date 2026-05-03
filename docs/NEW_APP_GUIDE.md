# New App Guide

> **Audience:** an AI coding agent (or human developer) tasked with building a
> new Android app that fits into the personal "Groom Hub" app suite. This
> document is the single source of truth for how these apps are structured,
> built, signed, released, and distributed.
>
> If you only need the mechanical scaffolding, run `./bootstrap/bin/bootstrap-app.sh`
> and skip to **§ 9 (Working on the App)**. The rest is reference material for
> when something needs explaining or fixing.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [The App Family Convention](#2-the-app-family-convention)
3. [Repository Layout](#3-repository-layout)
4. [Build Configuration](#4-build-configuration)
5. [Signing & Keystore](#5-signing--keystore)
6. [The Release Workflow](#6-the-release-workflow)
7. [The Manifest Repository](#7-the-manifest-repository)
8. [The `bin/changeset` Helper](#8-the-binchangeset-helper)
9. [Working on the App](#9-working-on-the-app)
10. [The Theme System](#10-the-theme-system)
11. [Common Patterns & Conventions](#11-common-patterns--conventions)
12. [Adding Dependencies](#12-adding-dependencies)
13. [Bootstrapping Checklist](#13-bootstrapping-checklist)
14. [Troubleshooting](#14-troubleshooting)
15. [Glossary & Quick Reference](#15-glossary--quick-reference)

---

## 1. System Overview

The personal app store is a small ecosystem of three pieces:

```
┌─────────────────┐  push tag    ┌──────────────────┐    upload    ┌──────────────────┐
│   App repo(s)   │ ───────────▶ │  GitHub Actions  │ ───────────▶ │ GitHub Releases  │
│ (one per app)   │              │   build & sign   │              │   (host APKs)    │
└─────────────────┘              └──────────────────┘              └──────────────────┘
                                          │ rewrite                          ▲
                                          ▼                                  │ poll
                                ┌──────────────────────┐    fetch JSON   ┌────┴──────┐
                                │ manifest.json        │ ──────────────▶ │ Groom Hub │
                                │ (personal-app-store) │                 │ (phone)   │
                                └──────────────────────┘                 └───────────┘
```

### The three components

| Component | What it is | Where it lives |
|---|---|---|
| **Groom Hub** | The Android "store" app that lists every personal app, polls for updates, downloads + verifies APKs, and hands them to the system installer. | `github.com/MatejGroombridge/personal-app-store-frontend` |
| **App repos** | One GitHub repo per app (e.g. `notes`, `focus-timer`). Each is a self-contained Android project with the same release pipeline. | `github.com/MatejGroombridge/<app-slug>` |
| **Manifest repo** | A GitHub Pages site whose `manifest.json` lists every published app version. Each app's release pipeline updates its own entry. | `github.com/MatejGroombridge/personal-app-store` (Pages serves `/docs/`) |

### The release flow

When you tag an app repo with `vX.Y.Z`:

1. The repo's `release.yml` workflow runs.
2. It decodes the shared keystore from a GitHub secret.
3. Builds & signs `app-release.apk`.
4. Renames it to `dev.matejgroombridge.<slug>-X.Y.Z.apk`.
5. Attaches it to a GitHub Release on the same repo.
6. Checks out the manifest repo.
7. Reads `docs/manifest.json`, removes any existing entry with this app's
   `package_name`, appends the new one (with the latest CHANGELOG section).
8. Sorts apps alphabetically, bumps `generated_at`, commits + pushes.
9. GitHub Pages serves the updated file at
   `https://matejgroombridge.github.io/personal-app-store/manifest.json`.
10. The Groom Hub app on your phone polls that URL (every 6 hours by
    default), notices the new `version_code`, and offers an update
    notification. Tapping it deep-links into the in-app detail screen,
    where one tap downloads + verifies + installs.

Total wall-clock: ~3 minutes from `git push --tags` to "update available
notification on phone".

### Why this architecture

- **No central server.** Everything is GitHub-hosted (free for public repos),
  uses GitHub's CDN, and survives indefinitely without a credit card.
- **Each app owns its release pipeline.** The Groom Hub doesn't need to know
  any specifics about an individual app — it just reads the manifest. New
  apps "register" themselves the first time their workflow runs.
- **Signing identity is shared across all apps.** Same keystore, so updates
  always work and the user sees them as "from the same trusted developer".
- **Forward-compatible manifest schema.** Unknown JSON fields are ignored by
  the Groom Hub client, so you can add metadata without breaking anything.

---

## 2. The App Family Convention

Every app in the suite follows these conventions. Deviating from any of them
will break something downstream, so don't unless you understand the
implications.

### 2.1 Naming

| Thing | Convention | Example |
|---|---|---|
| Repo name | `<slug>` (lowercase kebab-case) | `focus-timer` |
| Display name | Human-readable, title-cased | `Focus Timer` |
| Application ID | `dev.matejgroombridge.<slug-with-dashes-stripped>` | `dev.matejgroombridge.focustimer` |
| Java package | Same as application ID | `dev.matejgroombridge.focustimer` |
| Source root | `app/src/main/java/dev/matejgroombridge/<slug-stripped>/` | `app/src/main/java/dev/matejgroombridge/focustimer/` |
| Gradle project name | Title-cased camel | `FocusTimer` |
| APK filename (CI output) | `<applicationId>-<versionName>.apk` | `dev.matejgroombridge.focustimer-1.0.0.apk` |
| Tag format | `vX.Y.Z` (semver, lowercase v) | `v1.0.0` |
| Initial version | `versionName = "0.1.0"`, `versionCode = 1` | — |

### 2.2 Application ID is immutable

Once an app has been published, **never change its `applicationId`**.
Android treats a different package name as a different app entirely; users
would see the "old" version side-by-side with the "new" one and the upgrade
chain would be broken forever.

If you absolutely must change it (e.g. you typo'd the slug), the only clean
path is: bump version, ship one final release of the old applicationId with
a `Toast` saying "please install <new app>", then ship the new applicationId
as a brand new app.

### 2.3 Version code must monotonically increase

Android refuses to install an APK whose `versionCode` is ≤ what's currently
installed. The `bin/changeset` script enforces this by always
incrementing by 1. Don't manually edit `versionCode` to a lower number.

### 2.4 Branch convention

`main` is the release branch. The `bin/changeset` script warns when run on
any other branch. Feature branches are fine for development but should be
merged to `main` before tagging.

### 2.5 Same signing identity for all apps

All apps share `release.jks` (the same keystore, same key alias, same
passwords). Stored in:

- **CI:** as 5 GitHub secrets per repo (see § 5.2).
- **Local dev:** as `keystore.properties` at the repo root (gitignored).

If you ever rotate the keystore, every app needs the new secret values
**and** must increment its `applicationId` (because Android won't accept an
upgrade signed with a different key). In practice: don't rotate.

---

## 3. Repository Layout

What the bootstrap script produces, annotated:

```
<slug>/
├── .github/
│   └── workflows/
│       └── release.yml             ← Tag-triggered CI: build, sign, publish, manifest update
├── .gitignore                       ← Standard Android + signing material excludes
├── CHANGELOG.md                     ← Human + machine consumed (see § 8.2)
├── README.md                        ← Generated stub; rewrite for the specific app
├── app/
│   ├── build.gradle.kts             ← Per-app Gradle config: ID, signing, dependencies
│   ├── proguard-rules.pro           ← R8 keep rules for kotlinx.serialization
│   └── src/main/
│       ├── AndroidManifest.xml      ← Permissions, application/activity registrations
│       ├── java/dev/matejgroombridge/<slug>/
│       │   ├── MainActivity.kt      ← Single-Activity host; replace body with real screens
│       │   └── ui/theme/
│       │       ├── Theme.kt         ← AppTheme composable (Material You + fallbacks)
│       │       └── Type.kt          ← AppTypography type scale
│       └── res/
│           ├── drawable/ic_launcher_foreground.xml   ← Default 9-dot grid
│           ├── mipmap-anydpi-v26/ic_launcher.xml     ← Adaptive icon wiring
│           ├── mipmap-anydpi-v26/ic_launcher_round.xml
│           ├── values/colors.xml                     ← Splash + icon background
│           ├── values/strings.xml                    ← app_name = "<Display Name>"
│           ├── values/themes.xml                     ← Splash theme + main theme
│           ├── values-night/themes.xml               ← Dark variant
│           └── xml/
│               ├── backup_rules.xml                  ← Exclude DataStore + cache from backup
│               └── data_extraction_rules.xml
├── bin/
│   └── changeset                    ← Interactive release script (executable)
├── build.gradle.kts                 ← Top-level: declares plugin versions
├── gradle.properties                ← JVM args, parallel/cache flags, Kotlin code style
├── gradle/
│   ├── libs.versions.toml           ← Version catalog: every dependency + plugin version
│   └── wrapper/
│       ├── gradle-wrapper.jar       ← Bundled wrapper (~45KB) — committed
│       └── gradle-wrapper.properties
├── gradlew                          ← Unix wrapper script (executable)
├── gradlew.bat                      ← Windows wrapper script
└── settings.gradle.kts              ← rootProject.name, includes :app
```

### Files an AI agent will most often modify when building app functionality

- `app/src/main/java/dev/matejgroombridge/<slug>/...` — all Kotlin source.
  Add new packages here for `data/`, `ui/screens/`, `ui/components/`,
  `domain/`, etc. as the app grows.
- `app/src/main/res/...` — string resources, drawables, etc.
- `app/src/main/AndroidManifest.xml` — declare new activities/services, add
  `<uses-permission>` lines.
- `app/build.gradle.kts` — add dependencies in the `dependencies { }` block.
- `gradle/libs.versions.toml` — declare new library coordinates and version
  refs (always preferred over inline `implementation("...")` strings).

### Files that should rarely or never change after bootstrap

- `.github/workflows/release.yml` — only edit if the release pipeline itself
  needs to change. The `DISPLAY_NAME` env var is the one common edit, and
  `bin/bootstrap-app.sh` writes it correctly the first time.
- `bin/changeset` — drop in updated copies from the bootstrap toolkit if
  the script itself improves. Don't fork per-app.
- `app/proguard-rules.pro` — only add new keep rules if you add reflective
  libraries (e.g. Room migrations, custom Gson adapters).
- `gradle/wrapper/*` — the bundled wrapper is committed deliberately; don't
  delete or version-bump unless intentionally adopting a newer Gradle.
- `gradlew`, `gradlew.bat` — never edit by hand.

---

## 4. Build Configuration

### 4.1 Versions

The bootstrap pins specific tested versions in `gradle/libs.versions.toml`.
At time of writing:

| Component | Version | Why this version |
|---|---|---|
| Android Gradle Plugin (`agp`) | `8.7.3` | Stable AGP 8.x; matches Gradle 8.7 wrapper |
| Kotlin | `2.0.21` | Required for K2 + Compose plugin (mandatory in Kotlin 2.x) |
| Compose BOM | `2024.12.01` | Latest stable BOM at scaffold time |
| Material 3 | (via BOM) | Material 3 components — `material3:material3` |
| AndroidX Activity Compose | `1.9.3` | enableEdgeToEdge() lives here |
| AndroidX Lifecycle | `2.8.7` | viewmodel-compose helper |
| AndroidX Navigation | `2.8.5` | `NavHost`, `composable("route")` |
| Coil | `2.7.0` | Async image loading (only used if your app needs it) |
| Ktor | `3.0.2` | HTTP client (only if your app needs it) |
| kotlinx.serialization | `1.7.3` | Plugin + runtime, JSON support |
| DataStore preferences | `1.1.1` | Persisted settings |
| WorkManager | `2.10.0` | Background tasks |
| SplashScreen compat | `1.0.1` | `installSplashScreen()` API |

The version catalog convention is **never** to inline a version string in a
`build.gradle.kts`. Always declare in `libs.versions.toml` first, then
reference as `libs.foo.bar`.

### 4.2 SDK targets

```kotlin
android {
    compileSdk = 35       // Android 15 — required for latest APIs
    defaultConfig {
        minSdk = 26       // Android 8.0+ — covers ~95% of devices
        targetSdk = 35    // Android 15 — match compileSdk
    }
}
```

`minSdk = 26` is intentional:
- Drops the need for `coreLibraryDesugaring` for `java.time` and most modern APIs.
- Above the Android 8 threshold means you can use adaptive icons, notification channels, etc. without compatibility shims.
- ~95% of active Android devices in 2026 are SDK 26+.

### 4.3 Build types

```kotlin
buildTypes {
    debug {
        applicationIdSuffix = ".debug"   // → dev.matejgroombridge.notes.debug
        versionNameSuffix = "-debug"      // → 0.1.0-debug
    }
    release {
        isMinifyEnabled = true            // R8
        isShrinkResources = true
        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        signingConfig = signingConfigs.getByName("release")
    }
}
```

The `applicationIdSuffix = ".debug"` lets debug and release builds coexist
on the same device — useful for testing self-update flows in the Groom Hub
without uninstalling the production version.

### 4.4 Compose & Kotlin compiler

```kotlin
compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlinOptions { jvmTarget = "17" }
buildFeatures {
    compose = true
    buildConfig = true   // Generates BuildConfig.* fields (used for any build-time constants)
}
```

JVM 17 is required by AGP 8.7. The bootstrap workflow uses Temurin 17 in CI
to match.

### 4.5 The Gradle wrapper

`gradle/wrapper/gradle-wrapper.jar` is **committed to the repo**. This is
intentional and correct — it lets `./gradlew` work on a fresh clone with
nothing more than a JDK installed. Do not delete or `.gitignore` this file.

The wrapper's Gradle version is set in `gradle-wrapper.properties`. The
bootstrap toolkit ships a known-good version; don't bump unless intentional.

---

## 5. Signing & Keystore

### 5.1 The shared keystore

All apps in the family are signed with the same `release.jks`. This keystore
contains a single private key with alias `main` (or whatever you chose at
`keytool` time).

You should have:
- The keystore file backed up in your password manager and at least one
  other secure location.
- The keystore password, key alias, and key password recorded alongside it.
- The SHA-256 certificate fingerprint noted somewhere for verification.
  (Get it via `keytool -list -keystore release.jks`.)

If you lose the keystore, every app signed with it can never be updated
again. Treat backup as non-optional.

### 5.2 GitHub secrets per repo

Each app repo needs these 5 secrets (Settings → Secrets and variables →
Actions → New repository secret):

| Secret name | What it is | How to get |
|---|---|---|
| `KEYSTORE_BASE64` | Base64-encoded `release.jks` | `base64 -i release.jks \| pbcopy` (macOS) |
| `KEYSTORE_PASSWORD` | Keystore password | From your password manager |
| `KEY_ALIAS` | Key alias (e.g. `main`) | What you used with `keytool -alias` |
| `KEY_PASSWORD` | Key password | From your password manager |
| `MANIFEST_REPO_TOKEN` | Fine-grained PAT scoped to `personal-app-store` with Contents: Read and Write | GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens |

The `MANIFEST_REPO_TOKEN` PAT can be reused across every app repo — same
value, copy-pasted. Don't broaden it to all repositories; scope it to
`personal-app-store` only.

### 5.3 Local signing config

For local release builds (e.g. ad-hoc debugging), create
`keystore.properties` at the repo root:

```properties
storeFile=/Users/you/Documents/release.jks
storePassword=...
keyAlias=main
keyPassword=...
```

This file is in `.gitignore` — never commit it.

`app/build.gradle.kts` reads either:
- The CI env vars (`KEYSTORE_PATH`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`,
  `KEY_PASSWORD`) — set by the workflow's "Decode keystore" + "Assemble
  release APK" steps.
- Or the local `keystore.properties`.

If neither is present, `assembleRelease` fails clearly rather than
silently signing with the debug key (which would break upgrades from the
real release-signed installs).

### 5.4 Debug builds need no signing config

Debug builds use Android's auto-generated debug keystore (different on
every machine). That's fine — debug APKs have a different `applicationId`
suffix (`.debug`) so they never collide with release-signed installs.

---

## 6. The Release Workflow

`.github/workflows/release.yml` is the heart of the system. Here's what each
phase does and why.

### 6.1 Trigger

```yaml
on:
  push:
    tags: ['v*.*.*']
```

Only tag pushes matching `vX.Y.Z` semver fire the workflow. Branch pushes,
PRs, etc. don't trigger anything (no debug-build workflow by default — add
one if you want CI on every commit).

### 6.2 Decode keystore

```yaml
- name: Decode keystore
  run: |
    echo "${{ secrets.KEYSTORE_BASE64 }}" | base64 -d > $RUNNER_TEMP/release.jks
    echo "KEYSTORE_PATH=$RUNNER_TEMP/release.jks" >> $GITHUB_ENV
```

Decodes the base64 secret to a file in the runner's temp dir, then exports
the path as an env var that the next step reads.

### 6.3 Build signed release APK

```yaml
- name: Assemble release APK
  env:
    KEYSTORE_PATH:     ${{ env.KEYSTORE_PATH }}
    KEYSTORE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
    KEY_ALIAS:         ${{ secrets.KEY_ALIAS }}
    KEY_PASSWORD:      ${{ secrets.KEY_PASSWORD }}
  run: ./gradlew :app:assembleRelease --no-daemon
```

The env var names here **must exactly match** what `app/build.gradle.kts`
reads in the `signingConfigs { create("release") { ... } }` block. If you
change one, change both. `--no-daemon` keeps the runner clean.

### 6.4 Extract metadata

Uses `aapt dump badging` to read the package name, version code, version
name, and min SDK *out of the built APK*. This is more reliable than
re-parsing `build.gradle.kts` because the APK is the actual ground truth
and would catch a mismatch.

Then:
- Computes SHA-256 (verified by Groom Hub before installing).
- Computes file size (shown in the UI).
- Renames the APK to `<package>-<versionName>.apk` so the URL is
  human-readable.
- Writes everything to `$GITHUB_OUTPUT` for downstream steps.

### 6.5 Create GitHub Release

```yaml
- uses: softprops/action-gh-release@v2
  with:
    files: ${{ steps.meta.outputs.apk_path }}
    generate_release_notes: true
```

Creates a Release on this repo, attaches the APK as a downloadable asset,
and auto-generates release notes from commit messages. The Release's tag
matches the one you pushed.

### 6.6 Update the central manifest

```yaml
- name: Checkout manifest repo
  uses: actions/checkout@v4
  with:
    repository: matejgroombridge/personal-app-store
    ref: main
    token: ${{ secrets.MANIFEST_REPO_TOKEN }}
    path: manifest-repo
```

Clones `personal-app-store` into a sibling directory using the
`MANIFEST_REPO_TOKEN` PAT (which has write access to that repo).

The `Patch manifest.json` step then runs an embedded Python script that:
1. Reads `manifest-repo/docs/manifest.json` (creates `{"apps": []}` if missing).
2. Removes any existing entry with the same `package_name` (so re-releases
   replace, never duplicate).
3. Reads the most recent CHANGELOG.md section (everything between the
   first `## ` heading and the next).
4. Appends a new entry with all the metadata.
5. Sorts apps alphabetically by `display_name`.
6. Bumps `generated_at` to current UTC.
7. Writes back as pretty-printed JSON.

Then `Commit & push manifest update` commits + pushes. Includes a no-op
guard: if the manifest content is unchanged (e.g. you re-ran a workflow
without bumping the version), it skips the commit instead of erroring.

### 6.7 What you customise per app

In the entire workflow, exactly **three lines** are app-specific:

```yaml
DISPLAY_NAME: "Focus Timer"
DESCRIPTION:  "Focus Timer — part of the personal app suite."
CATEGORY:     "Personal"
```

`bin/bootstrap-app.sh` writes these correctly the first time. Edit by hand
later if you want to change the description or assign a more specific
category (e.g. "Productivity", "Utility").

Everything else in the workflow is identical across all apps.

---

## 7. The Manifest Repository

### 7.1 What it is

A separate GitHub repo (`MatejGroombridge/personal-app-store`) whose only
job is to host the JSON file the Groom Hub app polls.

- **Repo:** `https://github.com/MatejGroombridge/personal-app-store`
- **File path within repo:** `docs/manifest.json`
- **Public URL (via GitHub Pages):** `https://matejgroombridge.github.io/personal-app-store/manifest.json`
- **Pages config:** Deploy from branch `main`, folder `/docs`

### 7.2 Schema

```jsonc
{
  "generated_at": "2026-05-03T20:55:00Z",   // ISO-8601 UTC, when the file was last rewritten
  "apps": [
    {
      "package_name":   "dev.matejgroombridge.notes",   // REQUIRED, unique, immutable
      "display_name":   "Notes",                         // REQUIRED, shown in UI
      "description":    "Markdown notes",                // optional
      "icon_url":       "https://…/icon.png",            // optional (square PNG/WebP)
      "screenshots":    ["https://…/1.png"],             // optional list

      "version_code":   7,                               // REQUIRED, monotonic
      "version_name":   "1.3.0",                         // REQUIRED, human-readable

      "apk_url":        "https://…/notes-1.3.0.apk",     // REQUIRED, direct download
      "apk_sha256":     "abc123…",                       // REQUIRED, lowercase hex
      "apk_size_bytes": 8421337,                         // optional but recommended

      "min_sdk":        26,                              // optional, default 26
      "released_at":    "2026-05-03T20:55:00Z",          // optional ISO-8601
      "changelog":      "## v1.3.0 — …\n\nAdded X",      // optional, raw markdown
      "source_url":     "https://github.com/…",          // optional
      "category":       "Productivity"                   // optional free-text tag
    }
  ]
}
```

Field rules:
- `package_name` is **immutable**. Once shipped, never rename it.
- `version_code` must **strictly increase** between releases of the same package.
- `apk_sha256` is verified before install. A mismatch aborts with "Checksum mismatch".
- Unknown fields are ignored by the Groom Hub client (forward-compatible).

### 7.3 GitHub Pages caching

The Pages CDN (Fastly) caches `manifest.json` for ~10 minutes by default.
After a workflow pushes a new manifest, you may not see the update on your
phone for up to 10 minutes. Bust manually with a query string:

```bash
curl "https://matejgroombridge.github.io/personal-app-store/manifest.json?nocache=$(date +%s)"
```

The Groom Hub adds its own cache-busting query string per fetch, so this
isn't a problem in practice.

### 7.4 Don't edit `manifest.json` by hand

Every release workflow run rewrites the file. Manual edits will be
clobbered. If you need a permanent metadata change (e.g. fix a typo in
`display_name`), edit the workflow's `DISPLAY_NAME:` env value in that
app's repo, then re-run the most recent release.

---

## 8. The `bin/changeset` Helper

### 8.1 What it does

`bin/changeset` is a 200-line bash script in every app repo. Run it to cut
a new release without manually editing `versionCode`, `versionName`, or the
changelog.

```bash
./bin/changeset
```

Interactive flow:
1. Reads current `versionName` + `versionCode` from `app/build.gradle.kts`.
2. Asks: patch / minor / major bump? Previews the resulting semver.
3. Asks for a one-line description.
4. Bumps `versionName` + `versionCode` in `app/build.gradle.kts`.
5. Prepends a new `## vX.Y.Z — YYYY-MM-DD` section to `CHANGELOG.md`.
6. Commits as `Release vX.Y.Z — <description>` (only the two changed files).
7. Tags `vX.Y.Z` with the description as the annotation.
8. Asks if you want to push now. If yes: `git push && git push origin vX.Y.Z`.

The push of the tag triggers `release.yml`. ~3 minutes later the Groom Hub
on your phone offers the update.

### 8.2 The CHANGELOG → manifest pipeline

The release workflow reads the most recent CHANGELOG.md section and stores
it in the manifest entry's `changelog` field. The Groom Hub renders that
markdown (headings + paragraphs + lists) on the app's detail screen.

Concretely:

```markdown
# Changelog

## v0.2.0 — 2026-05-03

Added a settings screen.

## v0.1.0 — 2026-05-02

Initial release.
```

→ Workflow extracts `## v0.2.0 — 2026-05-03\n\nAdded a settings screen.`
→ Manifest entry gets `"changelog": "## v0.2.0 — 2026-05-03\n\nAdded a settings screen."`
→ Groom Hub renders it as a small heading + paragraph in the detail screen.

### 8.3 Safety checks

The script aborts (with a clear message) if:
- `app/build.gradle.kts` doesn't exist (you ran from the wrong directory).
- `versionName` doesn't parse as `X.Y.Z`.
- The description is empty.

It warns (and asks for confirmation) if:
- The working tree has uncommitted changes (the release commit only stages
  the version bump + CHANGELOG, but other in-flight work would still get
  pushed alongside the tag).
- You're not on `main` or `master`.

### 8.4 What gets pushed vs. what gets committed

The release commit explicitly stages only:
- `app/build.gradle.kts` (version bump)
- `CHANGELOG.md` (new entry)

The push however pushes **all** unpushed commits on the current branch, plus
the new tag. So if you have other in-flight work committed but not pushed,
it goes out with the release. Either commit + push tooling changes
separately *before* running `./bin/changeset`, or use the dirty-tree warning
to bail out and clean up first.

---

## 9. Working on the App

After bootstrap, the directory builds and runs but does nothing useful — it
shows a centred "<Display Name>" label. That's intentional. The app's
actual functionality is what an AI agent (or human) writes next.

### 9.1 The starter MainActivity

```kotlin
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AppTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    AppContent()
                }
            }
        }
    }
}
```

This is intentionally minimal. The pattern to extend it:
1. Replace `AppContent` with a proper navigation host using
   `androidx.navigation.compose`.
2. Add a `ui/screens/` package with one composable per screen.
3. Add a `ui/components/` package for reusable bits.
4. Add a `data/` package for repositories, network, persistence.
5. Use `viewModel()` from `lifecycle-viewmodel-compose` for state holders.

### 9.2 Recommended package layout (for non-trivial apps)

```
dev/matejgroombridge/<slug>/
├── App.kt                          ← Application subclass (only if needed for init)
├── MainActivity.kt
├── data/
│   ├── model/                      ← @Serializable data classes
│   ├── network/                    ← Ktor client (if used)
│   ├── repository/                 ← Single source of truth per data domain
│   └── settings/                   ← DataStore-backed prefs (if used)
├── domain/                         ← Pure-Kotlin business logic (if useful)
└── ui/
    ├── components/                 ← Reusable composables
    ├── screens/                    ← One file per screen
    │   ├── HomeScreen.kt
    │   └── SettingsScreen.kt
    ├── theme/
    │   ├── Theme.kt                ← Always present
    │   └── Type.kt                 ← Always present
    └── HomeViewModel.kt            ← One ViewModel per screen, colocated
```

This is the layout the Groom Hub itself uses. It's not mandated — if your
app is one screen with no networking, all that ceremony is overkill. But
once an app gets non-trivial, leaning into this structure keeps things
findable.

### 9.3 State management

- **Per-screen state:** `ViewModel` + `StateFlow` exposed as
  `collectAsState()` in the composable. The Groom Hub uses this throughout.
- **Cross-screen state:** lift to a shared `ViewModel` scoped to the
  navigation graph, or to a singleton repository injected through the
  Application class.
- **Persisted preferences:** `androidx.datastore.preferences` with one
  `Preferences.Key<T>` per setting, exposed as `Flow<T>` via
  `dataStore.data.map { it[key] ?: default }`.

No DI framework is wired up by default. Add Hilt or Koin per app if you
want — they're not in `libs.versions.toml` because most personal apps don't
need them.

### 9.4 Networking (if needed)

If the app fetches anything from the internet:

1. Add the INTERNET permission to `AndroidManifest.xml`:
   ```xml
   <uses-permission android:name="android.permission.INTERNET" />
   ```
2. Add Ktor dependencies to `app/build.gradle.kts` (already declared in
   `libs.versions.toml`):
   ```kotlin
   implementation(libs.ktor.client.core)
   implementation(libs.ktor.client.okhttp)
   implementation(libs.ktor.client.content.negotiation)
   implementation(libs.ktor.serialization.kotlinx.json)
   implementation(libs.kotlinx.serialization.json)
   ```
3. Create a single `HttpClient` in a `data/network/HttpClientProvider.kt`
   and inject it into repositories — don't construct one per call site.

### 9.5 Background work (if needed)

If the app needs a periodic background task:

1. Add `implementation(libs.androidx.work.runtime.ktx)` to dependencies.
2. Subclass `CoroutineWorker`.
3. Schedule from your `Application.onCreate()` with
   `WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(...)`.
4. If the worker posts notifications, request `POST_NOTIFICATIONS` runtime
   permission in `MainActivity` on Android 13+. (See the Groom Hub's
   `MainActivity` for the pattern.)

---

## 10. The Theme System

### 10.1 What's shared

Every app uses an identical `Theme.kt` and `Type.kt` under `ui/theme/`.
Only the package declaration differs.

`AppTheme` resolves the colour scheme this way:

```
                 isSystemInDarkTheme()
                          │
                          ▼
          ┌─────────────────────────────┐
          │ Android 12+? (SDK_INT >= S) │
          └────────────┬────────────────┘
                       │
                ┌──────┴──────┐
              yes              no
                │               │
                ▼               ▼
   dynamicDarkColorScheme()    darkColorScheme()
   dynamicLightColorScheme()   lightColorScheme()
```

So Android 12+ users get wallpaper-derived Material You colours
automatically; older OS users get baseline Material 3 defaults.

### 10.2 Typography

`AppTypography` is a hand-tuned `Typography` with slightly larger sizes
than Material 3 defaults to enforce a "spacious" look. Every app inherits
this same scale via `MaterialTheme(typography = AppTypography, ...)`.

If a particular app needs a custom font (e.g. a brand display face), add it
to `app/src/main/res/font/`, declare it in that app's `Type.kt`, and leave
the rest of the family untouched.

### 10.3 System bars

`AppTheme` has a `SideEffect` that syncs the status + nav bar icon colours
with the chosen scheme's background luminance. Combined with
`enableEdgeToEdge()` in `MainActivity`, this gives you transparent system
bars that always have legible icons regardless of theme.

### 10.4 The launcher icon

By default, every app uses the same 9-dot grid foreground on a `#1B1B1F`
background. To customise per-app:

1. Replace `app/src/main/res/drawable/ic_launcher_foreground.xml` with your
   own vector. Keep it within the centre 48x48 region of the 108x108
   viewport for adaptive-icon safe zone compliance.
2. Optionally change `<color name="ic_launcher_background">` in
   `values/colors.xml` for a different tile colour.
3. The same drawable is wired up as the monochrome layer for themed icons
   on Android 13+.

### 10.5 The splash screen

The splash is just the app background colour (`splash_background`, also
`#1B1B1F` by default) — no icon. This gives a clean, brand-neutral launch
transition. If you want a glyph, add
`<item name="windowSplashScreenAnimatedIcon">@drawable/...</item>` to both
`values/themes.xml` and `values-night/themes.xml`.

---

## 11. Common Patterns & Conventions

### 11.1 Compose only

No XML layouts. Every UI is Compose. The legacy `appcompat` library is
*not* in `libs.versions.toml` — don't add it.

### 11.2 Single Activity

Every app uses a single `ComponentActivity` (`MainActivity`) and Compose
Navigation for screen transitions. Adding more activities is rarely
justified — only if you genuinely need a separate process or a different
launch mode.

### 11.3 Edge-to-edge

`enableEdgeToEdge()` is called in every app's `MainActivity.onCreate`.
Pair it with `Scaffold` so content respects system bars automatically via
the `padding: PaddingValues` it supplies.

### 11.4 Material 3, not Material 2

Every app imports from `androidx.compose.material3.*`. Never
`androidx.compose.material.*` (M2). The bootstrap doesn't include the M2
artifact at all.

### 11.5 String resources

Use string resources (`stringResource(R.string.xxx)`) for any
user-facing text the app might want to localise eventually. For one-off
labels in personal projects this is overkill; use string literals where
fine, but keep the `app_name` resource (it's referenced by
`AndroidManifest.xml`).

### 11.6 No DI by default

The default scaffold uses constructor injection by hand and `viewModel { }`
factories. Adding Hilt or Koin to a specific app is fine; doing it
prophylactically across all apps adds setup overhead and APK weight for
limited gain.

---

## 12. Adding Dependencies

### 12.1 The version catalog convention

Always declare in `gradle/libs.versions.toml` first, then reference. This
keeps versions consistent and makes upgrades a single-line change.

```toml
[versions]
room = "2.6.1"

[libraries]
androidx-room-runtime = { group = "androidx.room", name = "room-runtime", version.ref = "room" }
androidx-room-ktx     = { group = "androidx.room", name = "room-ktx",     version.ref = "room" }
androidx-room-compiler = { group = "androidx.room", name = "room-compiler", version.ref = "room" }

[plugins]
ksp = { id = "com.google.devtools.ksp", version = "2.0.21-1.0.28" }
```

Then in `app/build.gradle.kts`:

```kotlin
plugins {
    alias(libs.plugins.ksp)
}

dependencies {
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)
}
```

### 12.2 Common additions and their version refs

| Need | Library | Version (current as of 2026-05-03) |
|---|---|---|
| Local database | `androidx.room` (runtime + ktx + compiler via KSP) | `2.6.1` |
| Image loading | `io.coil-kt:coil-compose` | `2.7.0` (already in catalog) |
| HTTP | `io.ktor:ktor-client-*` | `3.0.2` (already in catalog) |
| JSON | `org.jetbrains.kotlinx:kotlinx-serialization-json` | `1.7.3` (already in catalog) |
| Background | `androidx.work:work-runtime-ktx` | `2.10.0` (already in catalog) |
| Persisted prefs | `androidx.datastore:datastore-preferences` | `1.1.1` (already in catalog) |
| DI | `com.google.dagger:hilt-*` | `2.51.1` (add per app) |
| Markdown rendering | `io.github.jeziellago:compose-markdown` | `0.5.4` (alternative to inline parser) |
| Charts/graphs | `co.yml:ycharts` | `2.1.0` |
| Camera | `androidx.camera:camera-camera2` + `camera-lifecycle` + `camera-view` | `1.4.1` |

### 12.3 Avoiding bloat

Each new dependency adds compile time, methods, and APK size. Defaults to
keep in mind:

- Don't add Hilt unless you have ≥3 things that need scoping.
- Don't add Retrofit if Ktor (already declared) suffices.
- Don't add Glide/Picasso if Coil suffices.
- Don't add Moshi if kotlinx.serialization suffices.

---

## 13. Bootstrapping Checklist

End-to-end checklist for going from "I have an idea" to "the app is in
Groom Hub on my phone." Times are realistic estimates assuming nothing
goes wrong.

### A. Scaffold (1 minute)

```bash
cd path/to/bootstrap-toolkit
./bin/bootstrap-app.sh <slug> "<Display Name>"
```

Verify the new directory was created at the expected location.

### B. Initial git setup (2 minutes)

```bash
cd ../<slug>
git init
git add .
git commit -m "Initial commit"
git branch -M main
```

### C. Create the GitHub repo (1 minute)

On github.com → New repository:
- Owner: `MatejGroombridge`
- Name: `<slug>` (must match the directory name)
- Visibility: your choice (public is simpler; private requires the same
  PAT to have access)
- Do NOT initialize with README, .gitignore, or license — the local repo
  has them already.

Then locally:

```bash
git remote add origin git@github.com:MatejGroombridge/<slug>.git
git push -u origin main
```

### D. Add the 5 secrets (5 minutes the first time, 1 minute thereafter)

GitHub repo → Settings → Secrets and variables → Actions → New repository
secret. Add each:

- `KEYSTORE_BASE64` — `base64 -i release.jks | pbcopy`, paste
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`
- `MANIFEST_REPO_TOKEN` — same value you used for every other app repo

If you store these in a password manager note titled "Groom Hub family
secrets", subsequent apps take ~1 minute total.

### E. Build the actual app functionality (variable)

This is where the AI agent (or you) earns its keep. Open the new
directory in your editor, point an AI agent at it with this guide as
context, describe what the app should do.

Recommended prompt template for an AI agent:

```
You are working on a new Android app in my personal app suite.
Read bootstrap/docs/NEW_APP_GUIDE.md for the full architecture and
conventions — especially sections 9, 10, 11, and 12.

The app is called "<Display Name>". It should:
  - <feature 1>
  - <feature 2>
  - <feature 3>

Replace MainActivity's AppContent with the real UI. Add data
classes, repositories, ViewModels, and screens as needed under
the dev.matejgroombridge.<slug> package. Add new dependencies via
gradle/libs.versions.toml first, never inline. Verify with
./gradlew :app:assembleDebug.
```

### F. Verify locally (2 minutes)

```bash
./gradlew :app:assembleDebug
```

Should end with `BUILD SUCCESSFUL`. Optionally install to a connected
device:

```bash
./gradlew :app:installDebug
```

### G. Cut the first release (3 minutes)

```bash
./bin/changeset
# choose: minor (0.1.0 → 0.2.0) or just patch from 0.1.0 to 0.1.1
# description: e.g. "First working build"
# proceed: Y
# push:     Y
```

Watch the Actions tab. Should go green in ~3 minutes. After that, the
manifest will be updated and your phone's Groom Hub will offer the
download on the next refresh (pull-to-refresh, or wait up to 6h).

### H. Self-document (optional, 5 minutes)

Update the auto-generated `README.md` with:
- A real description of what the app does.
- Any non-obvious build/runtime requirements.
- Screenshots if you fancy.

---

## 14. Troubleshooting

Common failure modes and what to do.

### `Input required and not supplied: token` in the manifest checkout step

`MANIFEST_REPO_TOKEN` secret is missing or misnamed. Check the spelling
exactly (no trailing whitespace, exact case). Also verify the PAT hasn't
expired.

### `Not Found - https://docs.github.com/rest/repos/repos#get-a-repository`

The PAT can't see `personal-app-store`. Either:
- The PAT is scoped to a different repo. Edit it on GitHub → Settings →
  Developer settings → Fine-grained tokens → your PAT → Repository
  access → add `personal-app-store`.
- Or the manifest repo doesn't exist at that exact slug. Check the
  workflow's `repository:` line matches the actual repo name.

### `Keystore was tampered with, or password was incorrect`

`KEYSTORE_BASE64` got corrupted (extra whitespace, partial paste) or
`KEYSTORE_PASSWORD` is wrong. Re-encode:

```bash
base64 -i release.jks | pbcopy
```

Then paste *only* into the secret value field (avoid manual line breaks).

### "App not installed" when self-updating in Groom Hub

Signature mismatch: the installed APK was signed with a different
keystore than the new one. Causes:

- The app was originally installed from `./gradlew installDebug` (debug
  keystore) and the new one is release-signed (your real keystore).
  → Uninstall, install the release APK from GitHub Releases, future
  self-updates will work.
- Two of your app repos accidentally use different `KEYSTORE_BASE64`
  values. Verify all 5 secrets are identical across repos.

Verify the cert by running locally:

```bash
keytool -list -keystore release.jks
```

The SHA-256 fingerprint should match what `apksigner verify --print-certs <apk>`
shows for the installed APK.

### `versionCode '0' is less than current version '1'`

Android refuses to install because the new APK's `versionCode` is ≤ what's
installed. Bump `versionCode` in `build.gradle.kts` (or just run
`./bin/changeset` which always bumps).

### Gradle: `SDK location not found`

Local builds need either:
- An `ANDROID_HOME` environment variable, or
- A `local.properties` file at the repo root with `sdk.dir=...`.

Android Studio writes `local.properties` automatically on first open.
For headless dev, set `ANDROID_HOME` in your shell profile.

### CI build fails with `assembleRelease` but `assembleDebug` succeeds

Almost certainly a signing-config issue. Confirm:
- All 4 keystore env vars are exported in the workflow's
  "Assemble release APK" step.
- The names match `app/build.gradle.kts`'s `signingConfigs` block exactly
  (`KEYSTORE_PATH`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`).

### Manifest update step succeeds but `manifest.json` doesn't change

Two possibilities:
- The Python script generated identical content (e.g. you re-ran the same
  release). The `git diff --cached --quiet` guard skips the commit. This
  is correct behaviour.
- The script wrote to `manifest-repo/manifest.json` instead of
  `manifest-repo/docs/manifest.json`. Confirm the path in the embedded
  Python matches your Pages config (`/docs` is the canonical setup).

### Manifest update wiped out other apps' entries

The script preserves entries by `package_name`, so this shouldn't happen
unless the workflow ran against a stale checkout of the manifest. Check
the git log of `personal-app-store` — if `release-bot` made multiple
recent commits, look for an out-of-order push. Worst case: re-add the
missing entry by hand once, then any subsequent release of the affected
app will repair it automatically.

### Pull-to-refresh in Groom Hub doesn't show new versions

GitHub Pages cache. Wait up to 10 minutes, or hit
`https://matejgroombridge.github.io/personal-app-store/manifest.json?nocache=$(date +%s)`
in a browser and confirm the new entry is present.

### Android Studio shows "Module not found" or sync errors

After bootstrapping, open the *project root* directory in Android Studio
(the directory containing `settings.gradle.kts`), not the `app/` subfolder.
Let it sync once — first sync takes ~3 minutes.

### Compose preview doesn't render

Ensure `@Preview` composables are inside `@Composable` functions and that
`debugImplementation(libs.androidx.ui.tooling)` is in the dependency list
(it is by default in the bootstrap).

---

## 15. Glossary & Quick Reference

### URLs

| What | URL |
|---|---|
| Groom Hub repo | `https://github.com/MatejGroombridge/personal-app-store-frontend` |
| Manifest repo | `https://github.com/MatejGroombridge/personal-app-store` |
| Manifest JSON (live) | `https://matejgroombridge.github.io/personal-app-store/manifest.json` |
| Each app's repo | `https://github.com/MatejGroombridge/<slug>` |
| Each app's releases | `https://github.com/MatejGroombridge/<slug>/releases` |
| Each app's APK URL | `https://github.com/MatejGroombridge/<slug>/releases/download/v<X.Y.Z>/dev.matejgroombridge.<slug-stripped>-<X.Y.Z>.apk` |

### Conventions

| Concept | Convention |
|---|---|
| Slug | lowercase kebab-case, `[a-z][a-z0-9-]*[a-z0-9]` |
| Application ID | `dev.matejgroombridge.<slug-with-dashes-stripped>` |
| Tag format | `vX.Y.Z` (lowercase v, semver) |
| Initial version | `versionName "0.1.0"`, `versionCode 1` |
| Branch | `main` is canonical |
| Compile/target SDK | 35 (Android 15) |
| Min SDK | 26 (Android 8.0) |
| JVM | 17 |

### Commands

| Task | Command |
|---|---|
| Scaffold a new app | `./bootstrap/bin/bootstrap-app.sh <slug> "<Display Name>"` |
| Build debug locally | `./gradlew :app:assembleDebug` |
| Build release locally | `./gradlew :app:assembleRelease` (requires `keystore.properties`) |
| Install debug to device | `./gradlew :app:installDebug` |
| Cut a release | `./bin/changeset` |
| Tag manually (alternative) | `git tag vX.Y.Z && git push origin vX.Y.Z` |
| Verify keystore | `keytool -list -keystore release.jks` |
| Re-encode keystore for CI | `base64 -i release.jks \| pbcopy` |

### Files an AI agent will likely touch most

- `app/src/main/java/dev/matejgroombridge/<slug>/...` — Kotlin source
- `app/src/main/res/values/strings.xml` — UI strings
- `app/src/main/AndroidManifest.xml` — permissions, service registrations
- `app/build.gradle.kts` — dependencies
- `gradle/libs.versions.toml` — version refs

### Files an AI agent should not touch unless explicitly asked

- `bin/changeset` — release helper, drop-in identical across apps
- `.github/workflows/release.yml` — release pipeline; only edit
  `DISPLAY_NAME`, `DESCRIPTION`, `CATEGORY` if needed
- `gradle/wrapper/*` — Gradle wrapper, deliberately committed
- `gradlew`, `gradlew.bat` — wrapper entry points
- `app/proguard-rules.pro` — only add new keep rules for new reflective libraries

### Checklist for "is this app ready to ship?"

- [ ] `./gradlew :app:assembleDebug` succeeds locally.
- [ ] App actually does what it's supposed to do (manual smoke test on
      device or emulator).
- [ ] All 5 GitHub secrets are set.
- [ ] Repo exists at `github.com/MatejGroombridge/<slug>` and `main` is
      pushed.
- [ ] CHANGELOG.md has a meaningful description for the upcoming release
      (auto-handled by `./bin/changeset`).
- [ ] No personal data, secrets, or paths are hardcoded in the source.
- [ ] If the app uses INTERNET, the permission is in AndroidManifest.xml.

---

## Appendix: Differences between Groom Hub and the bootstrap template

The Groom Hub itself was built before this bootstrap toolkit existed, so a
few details diverge from what the template now produces. None of these
matter for new apps; included here so an AI agent reading both isn't
confused.

| Aspect | Groom Hub | Bootstrap template |
|---|---|---|
| Application class | `StoreApplication.kt` (subclass) | None by default |
| Theme name | `GroomHubTheme` | `AppTheme` |
| App name in `strings.xml` | `Groom Hub` | `<Display Name>` |
| Theme styles in `themes.xml` | `Theme.GroomHub`, `Theme.GroomHub.Main` | `Theme.App`, `Theme.App.Main` |
| User-Agent header | `GroomHub/1.0 (Android)` | None (no networking by default) |
| Manifest repo update step | Identical | Identical |
| Signing config | Identical | Identical |
| `bin/changeset` | Identical | Identical |
| Launcher icon | 9-dot grid | 9-dot grid (same) |
| Splash screen | Background only, no glyph | Background only, no glyph (same) |

If you want to make the Groom Hub itself fully bootstrap-template-compliant,
rename `Theme.GroomHub*` → `Theme.App*` and `GroomHubTheme` → `AppTheme`.
Not required, just for consistency.

