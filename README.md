# Bootstrap Toolkit

Self-contained scaffolding for spinning up a new "Groom Hub family" Android
app in seconds. Drop into any new directory, run one command, get a
ready-to-build repo with the release pipeline pre-wired.

## TL;DR

```bash
./bin/bootstrap-app.sh notes "Notes"
# → creates ../notes/ (sibling of this folder by default)
```

That's it. The output directory is a complete Android project that:

- Builds out of the box (`./gradlew :app:assembleDebug`).
- Has the same theme, splash, and launcher icon style as Groom Hub.
- Has `bin/changeset` ready to cut releases.
- Has `.github/workflows/release.yml` that signs APKs with your shared
  keystore and updates the central manifest at
  `https://matejgroombridge.github.io/personal-app-store/manifest.json`.

You then push the new directory to a fresh GitHub repo, add 5 secrets, and
let an AI agent fill in the actual app functionality.

## Layout

```
bootstrap/
├── README.md                          ← you're here
├── bin/
│   └── bootstrap-app.sh               ← the scaffolding script
├── docs/
└── templates/                          ← canonical file contents (one source of truth)
    ├── agent.md                           ← comprehensive ref for AI agents + humans
    ├── .github/workflows/release.yml.tmpl
    ├── .gitignore.tmpl
    ├── CHANGELOG.md.tmpl
    ├── README.md.tmpl
    ├── app/
    │   ├── build.gradle.kts.tmpl
    │   ├── proguard-rules.pro.tmpl
    │   └── src/main/
    │       ├── AndroidManifest.xml.tmpl
    │       ├── java/__PACKAGE_PATH__/
    │       │   ├── MainActivity.kt.tmpl
    │       │   └── ui/theme/{Theme,Type}.kt.tmpl
    │       └── res/
    │           ├── drawable/ic_launcher_foreground.xml.tmpl
    │           ├── mipmap-anydpi-v26/ic_launcher{,_round}.xml.tmpl
    │           ├── values/{strings,colors,themes}.xml.tmpl
    │           ├── values-night/themes.xml.tmpl
    │           └── xml/{backup_rules,data_extraction_rules}.xml.tmpl
    ├── bin/changeset.tmpl
    ├── build.gradle.kts.tmpl
    ├── gradle.properties.tmpl
    ├── gradle/
    │   ├── libs.versions.toml.tmpl
    │   └── wrapper/{gradle-wrapper.jar,gradle-wrapper.properties}
    ├── gradlew
    ├── gradlew.bat
    └── settings.gradle.kts.tmpl
```

## Usage

```bash
./bin/bootstrap-app.sh <slug> "<Display Name>" [output_dir]
```

| Argument | Required | Example | Notes |
|---|---|---|---|
| `slug` | yes | `notes`, `focus-timer` | Lowercase kebab-case. Becomes the repo name and (with dashes stripped) the Java package fragment. |
| `"<Display Name>"` | yes | `"Notes"`, `"Focus Timer"` | Shown in the Android launcher and the Groom Hub app. |
| `output_dir` | no | `~/Documents` | Defaults to the parent of this bootstrap folder. The new project goes into `<output_dir>/<slug>/`. |

**Worked example:**

```bash
./bin/bootstrap-app.sh focus-timer "Focus Timer"
```

Produces `../focus-timer/` with:
- `applicationId = "dev.matejgroombridge.focustimer"`
- `namespace = "dev.matejgroombridge.focustimer"`
- Java sources under `app/src/main/java/dev/matejgroombridge/focustimer/`
- `rootProject.name = "FocusTimer"` in `settings.gradle.kts`
- `app_name` string resource set to `"Focus Timer"`
- `DISPLAY_NAME: "Focus Timer"` baked into `.github/workflows/release.yml`

## Placeholders the script substitutes

The templates use these tokens; the script replaces them everywhere they
appear in file contents AND directory paths:

| Token | Substituted with | Example |
|---|---|---|
| `__SLUG__` | The slug arg | `focus-timer` |
| `__DISPLAY_NAME__` | The display name arg | `Focus Timer` |
| `__APPLICATION_ID__` | `dev.matejgroombridge.<slug-without-dashes>` | `dev.matejgroombridge.focustimer` |
| `__PACKAGE_PATH__` | Slash-separated form of the application ID | `dev/matejgroombridge/focustimer` |
| `__PACKAGE_FRAGMENT__` | The slug with dashes stripped | `focustimer` |
| `__PROJECT_NAME__` | Title-cased slug | `FocusTimer` |

If you ever need to change naming convention (e.g. switch the package prefix
from `dev.matejgroombridge` to something else), edit the substitution logic
in `bin/bootstrap-app.sh` once and every future bootstrap picks it up.

## Customising the templates

The whole point of this toolkit is one source of truth. To change the
default theme, the workflow, the splash screen, or any other shared
behaviour for *all future apps*:

1. Edit the relevant `.tmpl` file under `templates/`.
2. The next bootstrap picks up the change.
3. (Existing apps stay frozen — they're independent repos. To propagate a
   change retroactively, you'd diff manually or write a separate "upgrade"
   script.)

## Smoke testing

After modifying any template, verify the script still produces a buildable
project:

```bash
rm -rf /tmp/bs && mkdir /tmp/bs
yes "" | ./bin/bootstrap-app.sh smoketest "Smoke Test" /tmp/bs
cp ~/path/to/an/existing/local.properties /tmp/bs/smoketest/local.properties
cd /tmp/bs/smoketest && ./gradlew :app:assembleDebug
```

Should end in `BUILD SUCCESSFUL`.

## When to use this vs. the comprehensive doc

- **Use `bin/bootstrap-app.sh`** for the mechanical 90% of new-app setup
  (file tree, build files, workflow, theme).
- **Use `agent.md`** as the spec you feed to an AI agent so it
  understands the architecture and conventions deeply enough to write the
  actual app functionality on top of the scaffold.

The two are complementary, not redundant.
