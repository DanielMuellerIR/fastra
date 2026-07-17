# Fastra — SwiftPM-Package

Produktüberblick und Screenshots stehen im
[README des Repositories](../README.md). Der vollständige Build-, Paketierungs-
und Testweg steht in [docs/BUILD-AND-TEST.md](../docs/BUILD-AND-TEST.md);
bekannte Fallen der Editor-Abhängigkeiten dokumentiert
[LESSONS-LEARNED.md](LESSONS-LEARNED.md).

## Bauen und Starten

Die Dependencies (`CodeEditSourceEditor`, `CodeEditLanguages`) laufen aus reiner
CommandLineTools-Umgebung nicht durch `swift build` — deshalb das Wrapper-Skript:

```bash
cd app
swift test
./localization-audit.sh
./build.sh
./selftest.sh
```

`./build.sh release` erzeugt zusätzlich den Release-Build. `build.sh` löst die
Abhängigkeiten über die Xcode-Toolchain auf, wendet die dokumentierten lokalen
Patches auf `.build/checkouts/` an und verifiziert sie. Nach
`swift package update` muss `build.sh` deshalb erneut laufen.

Zum Lesen und Navigieren lässt sich das Package mit
`open -a Xcode Package.swift` in Xcode öffnen. Der unterstützte,
reproduzierbare Buildweg bleibt `build.sh`, weil nur er die benötigten
Checkout-Patches anwendet und prüft.
