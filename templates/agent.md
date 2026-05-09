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

### 10.6 Settings — Quick Spec

A standardised Settings screen every app in the family should follow.

#### Entry point

A **Settings** icon (`Icons.Filled.Settings`) lives in the top-right of the home screen's `TopAppBar`, in `actions = { ... }`. Tap routes to `"settings"`.

```kotlin
TopAppBar(
    title = { Text(stringResource(R.string.app_name)) },
    actions = {
        IconButton(onClick = onOpenSettings) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings")
        }
    }
)
```

#### Settings screen structure

A `Scaffold` with its own `TopAppBar` (back arrow + "Settings" title), single scrollable `Column` of grouped sections separated by `Spacer`s + section headers (`titleSmall`, `colorScheme.primary`, all-caps).

#### Standard sections

| Section | Items |
|---|---|
| **Appearance** | Theme: System / Light / Dark (FilterChip row, persisted in DataStore) |
| **About** | App name (`bodyLarge`), `Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})` (`bodyMedium`, `onSurfaceVariant`) |

Add app-specific sections (Notifications, Sync, Data, etc.) **between** Appearance and About. Each section header is one line; each row is a `Surface(tonalElevation = 1.dp)` with rounded 16dp corners, 16dp internal padding, a label + optional supporting text + trailing control (chip/switch/chevron).

#### State

- All settings live in `SettingsRepository` (DataStore preferences, one `Preferences.Key<T>` per setting).
- Exposed as `Flow<Settings>` and consumed via `vm.settings.collectAsState()`.
- Writes go through ViewModel: `vm.setThemeMode(ThemeMode.Dark)`.

#### Conventions

- No nested settings screens — keep flat. If a section gets crowded, expand it inline.
- No "Save" button — every change persists immediately.
- Destructive actions (Clear cache, Reset, etc.) use `AlertDialog` confirmation.
- Padding: 20dp horizontal, 16dp between rows, 24dp between sections.

---

## 10.7 Design Language & Interaction Cookbook

> This section is the source of truth for the visual + interaction
> language any app in the family should adopt. It captures every
> learning from the Habit Tracker build so future apps feel like part
> of the same suite from day one. Treat each subsection as a checklist
> the AI agent should consult before introducing a new screen,
> control, dialog, or animation.

### 10.7.1 Foundational principles

- **Text-first, low-clutter rows.** Settings rows do **not** carry
  decorative leading icons. The label sits left, the trailing control
  (Switch, value, chevron, accent text) sits right. Icons are reserved
  for *identity* (a habit's accent badge) or *affordance* (a back
  arrow, a chevron). Cosmetic icons inside list rows are forbidden —
  they break consistency the moment some rows have one and others
  don't.
- **One control per row.** Mixing a Switch + a chevron + a value pill
  on the same row creates ambiguity about what the row does. If a
  setting needs more than one affordance, give it its own card or
  push it onto its own screen via a chevron `NavRow`.
- **Every visible row in a card has the same height.** Define a
  `private val SETTINGS_ROW_MIN_HEIGHT = 56.dp` and apply it via
  `Modifier.heightIn(min = SETTINGS_ROW_MIN_HEIGHT)`. Padding alone
  cannot guarantee row alignment because controls (Switch, chevron,
  Text) have different intrinsic heights.
- **Cards have `contentPadding = 0.dp`** and rows manage their own
  horizontal/vertical padding (`horizontal = 16.dp, vertical = 4.dp`
  is the unified value when a `heightIn(min = …)` is in play). Always
  use `Divider()` between rows inside a card — never `Arrangement.spacedBy`
  inside settings cards.
- **Group identity, not chronology.** Sections in Settings are
  ordered by *what mental concept they belong to*, not by when they
  were added: **Zen Mode → Appearance → Reminders → General → NFC
  scans → About**. The Zen Mode card sits first because it is a
  global mode switch.
- **No loading spinners on instant operations.** Persistence via
  DataStore is fast enough that you should never show a spinner;
  changes feel atomic. Reserve spinners for actual network I/O.

### 10.7.2 Colour & palette discipline

- **Curate, don't multiply.** A palette of 8 entries with strong hue
  separation reads better than 14 close ones.
- **Order palette entries along the colour wheel.** When a user picks
  a colour from a chip strip, the strip should flow
  `warm → green → cyan → blue → cool` so adjacent chips look
  related. The Habit Tracker order is:
  `Blush → Peach → Butter → Mint → Teal → Sky → Lavender → Fog`.
- **Each entry has 4 channels:** `light`, `dark`, `accent`, `onColor`.
    - `light` = card background in light mode
    - `dark` = card background in dark mode
    - `accent` = stronger fill used for icon tiles, chips, and confetti
    - `onColor` = legible text/icon colour over `light`

  **Canonical 8-colour palette:**

  | Key | Label | Light | Dark | Accent | On colour |
  | --- | --- | --- | --- | --- | --- |
  | `blush` | Blush | `#FFE0E6` | `#5A3A42` | `#F7A6B5` | `#3A1F25` |
  | `peach` | Peach | `#FFE3D1` | `#5A3F30` | `#FFB48A` | `#3A2418` |
  | `butter` | Butter | `#FFF4C2` | `#55502B` | `#FFE066` | `#3A330A` |
  | `mint` | Mint | `#D1F0DA` | `#2E4D3A` | `#8DD6A4` | `#143222` |
  | `teal` | Teal | `#CFE8E4` | `#2F4D49` | `#8DCDC4` | `#143230` |
  | `sky` | Sky | `#D3E8F5` | `#2F4756` | `#8FC4E0` | `#12303F` |
  | `lavender` | Lavender | `#E3DAF5` | `#3F354F` | `#B7A5DD` | `#231A33` |
  | `fog` | Fog | `#E2E5EA` | `#40454D` | `#B6BCC6` | `#22262D` |

- **Persist by string key, not by enum/index.** Future palette edits
  must not invalidate stored data. Provide an `entry(key)` lookup that
  falls back to a `defaultEntry` if the key is unknown.
- **AMOLED override.** Add a `Boolean amoled` setting. When the
  resolved theme is dark and `amoled` is true, force the Material 3
  `background`, `surface`, and `surfaceContainer*` slots to pure
  black. Keep accents/primary at their normal value so the UI stays
  recognisable.

### 10.7.3 Iconography catalogue

- **Two distinct icon roles:**
    1. *Identity icons* — chosen by the user per habit/item. Visible
       everywhere that item is referenced. Stored as a string key into a
       curated catalogue. Icons should map to common nouns/verbs ("Run",
       "Read", "Drink", "Meds") so users find their concept fast.
    2. *Affordance icons* — back arrow, chevron, FAB plus, NFC, settings
       gear. Use Material outlined variants for consistency.
- **Catalogue size: ~25–35 entries.** Beyond that the picker becomes
  hard to scan. Group visually similar ideas under one icon.
- **Icon picker layout: equal-weight wrap-grid** of 56dp circular
  tiles, currently selected tile filled with the chosen accent.

### 10.7.4 Spacing, padding, sizes (the Habit Tracker tokens)

| Token | Value | Where used |
|---|---|---|
| Settings row min height | 56.dp | Toggles, nav rows, week-start row |
| Card corner radius | 20.dp | `SettingsCard`, in-app dialogs |
| Chip / small pill corner | 14.dp | NFC link copy pill, action chips |
| Inter-section gap | 20.dp | Between SectionCaption + previous card |
| Section caption padding | 16.dp h, 8.dp top, 8.dp bottom | `SectionCaption` |
| Editor dialog parent gap | 14.dp | `Arrangement.spacedBy` between groups |
| Editor sub-gap | 6.dp | Inside an `EditorSection` between header + body |
| Habit grid card | 1f weight, ~96.dp tall | 2-col grid on Today |
| Day-cell square | matches grid cell width | All Time + Past Week |
| FAB margin | 16.dp from edges | Standard Material 3 |

### 10.7.5 Component cookbook

The reusable widgets the Habit Tracker evolved. Re-use these names so
new apps feel familiar.

#### `SettingsCard`

Rounded surface-container card. Always pass `contentPadding = 0.dp`
and let the rows handle their own padding so heights stay aligned.

```kotlin
@Composable
private fun SettingsCard(
    contentPadding: Dp = 16.dp,
    content: @Composable () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier.fillMaxWidth(),
    ) { Box(Modifier.padding(contentPadding)) { content() } }
}
```

#### `SectionCaption`

Uppercase, primary-colour, `labelMedium`. Sits above each card. Never
add an icon — captions are pure typography.

#### Row family

- `CompactSwitchRow(label, checked, onCheckedChange)` — toggle row.
- `WeekStartNavRow` / `NavRow(icon, label, onClick)` — chevron rows.
  *Icon parameter is kept for source-compat with previous call sites
  but is intentionally not rendered.*
- `StepperRow(label, value, min, max, onChange)` — value with -/+
  stepper.
- `TimeRow(label, time, onPick)` — opens `TimePickerDialog`.
- `ChipChoice(label, selected, onClick)` — segmented chip used for
  3-way / 4-way picks (e.g. NFC action). Equal weight via
  `Modifier.weight(1f)` so labels of varying length still align.

All of the above respect `SETTINGS_ROW_MIN_HEIGHT` and use
`padding(horizontal = 16.dp, vertical = 4.dp)`.

#### `Divider()`

Wrap M3's `HorizontalDivider` with a softer alpha:

```kotlin
@Composable
private fun Divider() {
    HorizontalDivider(
        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}
```

#### `HabitCard` (= "ItemCard" pattern)

A 2-col grid card with: large coloured `IconBadge` (top-left), title
(`titleMedium`, max 1 line, ellipsis), subtitle pill row showing
state (e.g. `📅 1 of 3`, `🔄 in 3 days`, "Done this week"). The whole
card is `combinedClickable` (tap = primary action, long-press =
overview dialog). Background = the habit's `containerColor()`,
foreground text = its `contentColor()`.

#### `HabitOverviewDialog` (= "Item Overview" pattern)

Long-press on any list item opens a polished overview dialog that:

- Header row: large IconBadge → title (`titleMedium`, **single line,
  ellipsis** so long names never push the icon row down) +
  `FrequencyChip` underneath → trailing icon row of state actions
  (Skip, Pause) + an Edit pencil. *No `X` close button — tap-outside
  dismisses.*
- Optional one-line description.
- 3 stat tiles (e.g. Current 🔥 / Best 🏆 / Total ✅) in equal-weight
  weight=1f Surfaces.
- 7-day mini-strip (or N-day) with Mon–Sun labels. Use the same
  `DayCellShape` enum as the equivalent grid view (`Completed`,
  `Skipped`, `Paused`) so visual language is shared.
- Footer with "Tracking for N days" + "X% completion".

The dialog **re-reads the underlying item from the live state** every
frame, so external mutations (NFC scan, widget tap, notification
action) reflect instantly while the dialog is open.

#### `HabitEditorDialog` (= "Editor" pattern)

`AlertDialog` body with:

- Identity card: 56dp `IconBadge` button (opens icon+colour picker
  combo) + title `OutlinedTextField` + multi-line description field.
- `EditorSection("FREQUENCY") { 2x2 grid of FrequencyOption cards }`
  using equal `Modifier.weight(1f)` so labels line up.
- A `CompactStepper` with `(Int) -> String` lambda label so the row
  reads naturally ("Every 3 days", "1 time per week").
- `EditorSection("NFC TAG LINK") { CopyShareWriteRow }` — never show
  the URL itself; offer Copy / Share / Write actions only. A `?` icon
  in the section header opens a Material popover with the explanation.
- **No delete button in the editor.** Deletion is only possible from
  the Archived screen, gated behind archive-first → delete. This
  prevents accidental loss of streak history.
- Save sits bottom-right, Cancel bottom-left.

### 10.7.6 Navigation pattern

- **Single Activity, NavHost, three top-level pages in a `HorizontalPager`.**
  Pages are 0-indexed; pin the user-facing landing page to the middle
  (`TODAY_PAGE_INDEX = 1`) so swipes reach it from either side.
- **Two-way bottom nav ↔ pager sync.** Bottom-bar `selected` reads
  `pagerState.currentPage`; tab tap calls
  `pagerState.animateScrollToPage(index)`. Tapping the already-selected
  tab fires a small confirmation haptic.
- **`beyondViewportPageCount = 1`** — adjacent page composed for
  instant swipes, but never all three at once.
- **`userScrollEnabled = settings.swipeToNavigate && !settings.zenMode`**
  — make pager swipe a user setting, and force off in any "lockdown"
  mode.
- **Detail screens push onto NavHost as separate destinations.** Their
  bottom bar disappears (Settings, Archive, Reorder, etc.).
- **Deep links / NFC URLs** use a dedicated `app://host/<entityId>`
  scheme with an `intent-filter` on the launcher activity. A separate
  `NfcCompletionActivity` handles the URL and dispatches according to
  the user's chosen behaviour (background / overlay / open app).

### 10.7.7 Haptics

Every meaningful tap should give physical feedback. Build a single
`Haptics` helper with three intensities:

```kotlin
class Haptics(private val view: android.view.View) {
    fun light()       = view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    fun completion()  = view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
    fun longPress()   = view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
}
```

| Interaction | Intensity |
|---|---|
| Habit tap → complete | `completion()` |
| FAB tap | `completion()` |
| Long-press to open overview | `longPress()` |
| Page swipe / tab change | `light()` *(suppress on initial composition)* |
| Tap already-selected tab | `light()` |
| Reorder up/down | `light()` |
| Theme/NFC chip change | `light()` |
| Reorder / Archived nav row | `light()` |

Use a `LaunchedEffect(pagerState.currentPage) { … }` with a
`firstFrame` flag to avoid haptics on launch.

### 10.7.8 Confetti / celebration overlays

For the "you did it" moment (e.g. completing the last outstanding
item of the day):

- ~500 particles, ~5.5s animation, fall through 100% of screen
  height before fading out.
- Stagger particle launch with `startDelay` so the burst feels like a
  real shower, not a wall.
- Apply a global tail-fade (`alpha *= (1f - (t - 0.88f) / 0.12f)`) so
  the animation never snaps to nothing — it fades smoothly over the
  last 12% of the timeline.
- Particle colours sample from the app's palette `accent` channel.
- Off-screen culling: skip drawing particles below `h + 40f`.

### 10.7.9 NFC architecture (only relevant if app uses NFC)

- One URL per *item* (e.g. per habit) using an app-private scheme
  (`appname://entity/<id>`) — never `https`, so scanning never opens a
  browser.
- A dedicated `NfcCompletionActivity` (`@android:theme/Theme.Translucent.NoTitleBar`)
  reads the URL, looks up the item, and dispatches one of:
    1. **Background** — mark complete, finish silently.
    2. **Overlay** — show a transparent fullscreen celebration overlay
       for ~2s.
    3. **Open app** — mark complete, start the launcher activity, finish.
- Overlay activity uses a fully transparent theme so the overlay
  floats over whatever app the user was in.
- Provide an in-app NFC writer screen (`HostApduService` not needed
  for tag-write; use `NfcAdapter.enableReaderMode` / `Ndef.writeNdefMessage`).
- Tag URL is *generated*, not user-typed. Surface Copy / Share / Write
  buttons in the editor; never show the raw URL.

### 10.7.10 Mode switches

Modes are global app states that lock or unlock entire feature sets.
Pattern: a single boolean in DataStore + a `setMode(Boolean)` method
+ defensive guards everywhere a mode-disabled feature is reached.

#### Implemented in Habit Tracker

| Mode | What it locks | What stays |
|---|---|---|
| `swipeToNavigate = false` | Pager swipe | Bottom-bar tabs |
| `allowSkips = false` | Skip icon in overview, Skip option in long-press | Skip data preserved |
| `allowPauses = false` | Pause icon, Pause option | Pause data preserved |
| `dailyHabitsOnly = true` | Non-daily frequency options in editor | Existing non-dailies prompted to archive via warning dialog |
| `zenMode = true` | Bottom nav, FAB, top-bar archive icon, every dialog, all non-Today pages, every Settings section except Zen toggle | Tap-to-complete on Today + ability to disable Zen via Settings |

Each mode flag should:

- Default to the previous behaviour (so upgrading users see no
  change).
- Be guarded with a `LaunchedEffect(flag) { if (flag) clearPendingState() }`
  to drop stale state when the mode flips.
- Use **early returns**, not deep `if` nests, when a mode strips a
  large portion of UI:

```kotlin
if (settings.zenMode) return@Column
```

### 10.7.11 Reminders / scheduled work

If the app needs daily/scheduled notifications:

- Use `AlarmManager.setExactAndAllowWhileIdle` for minute-perfect
  firing; fall back to `setAndAllowWhileIdle` on devices that don't
  grant `SCHEDULE_EXACT_ALARM`.
- Wrap exact-alarm scheduling in `runCatching { … }` and degrade
  silently to inexact on `SecurityException`.
- A receiver consults the repository at fire-time so it sees the
  latest state (don't pre-bake a list at scheduling time).
- Filter "outstanding items" through the same logic the UI uses
  (e.g. `isVisuallyCompletedOn(today, weekStart)`), so reminders
  respect frequency rules and the user's week-start.
- Provide both a **global** "Daily reminders" toggle and a **per-item**
  "Include in reminders" toggle. Surface the per-item toggle on its
  own dedicated `Reminders for <Items>` screen, **not** inside the
  item overview dialog (overview dialogs should stay focused on
  display, not configuration).
- Provide a `setOf("First reminder", "Last reminder")` time-pair when
  `timesPerDay > 1` and evenly distribute the rest.

### 10.7.12 Lists with reorder + archive + delete

- **Reorder lives on its own screen**, not on the main list. Up/down
  buttons per row + drag handle. Persist via a `Long ordering` column
  on the entity.
- **Archive** is a soft-delete. Archived items get their own screen;
  delete is only available from there.
- **Delete is always one tap behind a confirmation `AlertDialog`.**
  Title: "Delete `<Name>`?" — body explains what's lost (streaks,
  history). Destructive action uses `MaterialTheme.colorScheme.error`.

### 10.7.13 Editor / picker layouts

- **Equal-weight cards beat FlowRow chips** for picks of 2–6 options.
  A 2×2 or 1×3 `Row { … weight(1f) … }` aligns labels of varying
  length cleanly.
- **Use `(Int) -> String` lambdas in steppers** so the value text
  reads naturally ("Every 3 days") instead of "3" with a separate
  suffix label.
- **Title-case every multi-word heading** ("All Time", "Past Week",
  "Edit Habit", "NFC Tag Link"). Articles like *a / an / the* stay
  lowercase ("Choose an Icon").

### 10.7.14 Per-cell long-press menus (grid editing)

For grids where each cell represents a state (e.g. day chips):

- Tap = primary toggle.
- Long-press = `DropdownMenu` of state choices (Completed / Skipped /
  Pause / Clear).
- Visual language for each state must match the canonical view
  (e.g. All Time grid). Define a single `enum class DayCellShape` and
  reuse it.
- A long-press that lands on an "Already in this state" toggle clears
  it instead.

### 10.7.15 Widgets (Glance)

If the app exposes a home-screen widget:

- Use Glance, declared in the version catalogue under
  `[libraries.glance]`.
- Configuration activity lets the user pick **which items** the
  widget shows; persisted per `appWidgetId`.
- Widget polls `repository.itemsFlow` and updates on every mutation
  via `GlanceAppWidgetManager.update`.
- Tap-to-act calls a `RemoteAction` that opens an `Activity` (or a
  `BroadcastReceiver` if the action is fully background-safe).
- **Glance has no long-press** — don't try to fake one. Only expose
  the primary action; rich detail stays in the app.
- Provide a curated XML/PNG `previewLayout` so the widget looks good
  in the picker.

### 10.7.16 Element of surprise — the "delight" budget

A single app should have ≤2 surprise/delight moments. Too many feels
gimmicky. The Habit Tracker uses:

1. **Confetti shower** when the user completes the last outstanding
   habit of the day.
2. **NFC overlay celebration** when an NFC scan succeeds with
   `Overlay` mode chosen.

Resist adding more. Reserve animations for state-transitions that
*confirm a meaningful action*; never decorate idle UI.

### 10.7.17 Defaults & data migration

- Every new field on a persisted model gets a default value so old
  serialised data stays loadable: `val newField: Boolean = true` and
  the JSON decoder must use `ignoreUnknownKeys = true`.
- Every new DataStore key gets a `?: defaultValue` in the read path.
- Never reorder serialisable enum values — append new ones.

### 10.7.18 Build hygiene

- Always finish a session with `./gradlew :app:assembleDebug` green.
- Add `@Suppress("UNUSED_PARAMETER") val unused = icon` rather than
  removing a parameter that other call sites still pass — keeps the
  diff tiny and source-compatible.
- Comments explain *why*, not *what*. Aim for short paragraphs above
  non-obvious blocks; no trailing line comments on every statement.
- The user manages versioning + the changelog via a script; **never**
  edit `app/build.gradle.kts` `versionCode` / `versionName` or
  `CHANGELOG.md`.

### 10.7.19 Settings page canonical structure

Apply this order in **every app**:

1. **Mode** card (e.g. Zen) — global mode switches that hide other UI.
2. **Appearance** — theme picker + AMOLED toggle.
3. **Reminders** — daily-reminder toggle + frequency + time pickers.
4. **General** — week-start, behaviour toggles, navigation rows
   (Reorder, Archive, Reminders-for-items, Export, Import).
5. **NFC tag scans** *(if app uses NFC)*.
6. **About** — app name + version pill.

Each section: `SectionCaption("Name")` followed by exactly one
`SettingsCard`. Inter-section gap is 20dp. Inside the card, every row
shares `SETTINGS_ROW_MIN_HEIGHT` and is separated from the next by a
`Divider()`.

### 10.7.20 Quick checklist for new apps

Before considering the first usable build done, verify:

- [ ] Settings screen follows the canonical structure.
- [ ] Zen-style global mode is at least *considered* (not always
  needed; document why if omitted).
- [ ] Haptics on every meaningful interaction; intensities match the
  table above.
- [ ] No icons inside settings rows.
- [ ] All multi-word headings are Title Case.
- [ ] No `X` close button on info modals — tap-outside only.
- [ ] Long item names use `maxLines = 1, overflow = Ellipsis` in
  title rows.
- [ ] Every persisted field defaults to legacy behaviour.
- [ ] `:app:assembleDebug` is green.
- [ ] No edits to `versionCode`, `versionName`, or `CHANGELOG.md`.

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

