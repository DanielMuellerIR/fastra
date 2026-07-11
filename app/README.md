# Fastra — App-Package (SwiftPM)

Dies ist das SwiftPM-Package der App. Produktüberblick und Screenshots →
[README im Repo-Root](../README.md). Build-, Test- und QA-Details →
[CLAUDE.md](../CLAUDE.md). Build-Gotchas und Pattern-Bewertungen →
[LESSONS-LEARNED.md](LESSONS-LEARNED.md).

## Bauen und Starten

Die Dependencies (`CodeEditSourceEditor`, `CodeEditLanguages`) laufen aus reiner
CommandLineTools-Umgebung nicht durch `swift build` — deshalb das Wrapper-Skript:

```bash
cd app
./build.sh                       # debug-build
./build.sh release               # release-build (Bundle in dist/)
./selftest.sh                    # In-App-Selbsttests (holt die App kurz nach vorn)
```

`build.sh` löst Dependencies über die **Xcode-Toolchain** auf und wendet eine
Reihe lokaler, nicht-invasiver Patches auf `.build/checkouts/` an (Details:
[CLAUDE.md](../CLAUDE.md) und LESSONS-LEARNED Sektion F). Die Patches werden bei
jedem `swift package update` zurückgesetzt — dann einfach `./build.sh` erneut
laufen lassen.

> **In Xcode öffnen:** `open -a Xcode Package.swift`. Xcode bringt seine eigene
> SourceKit-Toolchain mit, da werden die Patches nicht gebraucht.
