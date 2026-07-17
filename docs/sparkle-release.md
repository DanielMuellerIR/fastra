# Sparkle-Updates veröffentlichen

Fastra bindet Sparkle 2.9.4 exakt gepinnt per SwiftPM ein. Die App prüft den
Feed unter `https://danielmuellerir.github.io/fastra/appcast.xml`, lädt das DMG
aus dem zugehörigen GitHub Release und installiert ausschließlich nach Zustimmung.
Anonyme Hardware- und Systemprofildaten sind deaktiviert.

Version 1.19.1 ist der einmalige Bootstrap: 1.18.x enthält noch keinen Updater,
und 1.19.0 verlor den sichtbaren Menüpunkt beim späten SwiftUI-Menüaufbau.
Bestehende Installationen müssen 1.19.1 einmal manuell per DMG installieren;
erst danach funktionieren Updates aus der App.

Zwei unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Sparkle-Ed25519-Signatur für Update-Archiv und Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Nur sein öffentlicher Gegenpart steht als `SUPublicEDKey` im App-Bundle.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle **GitHub Actions**
   wählen. Das Environment `github-pages` muss neben dem Branch `main` auch
   Tags vom Typ `v*` zulassen, weil der automatische Lauf auf dem veröffentlichten
   Release-Tag startet.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegen.
   Sparkles `generate_keys -x` exportiert ihn vorübergehend in eine lokale Datei;
   `gh secret set SPARKLE_PRIVATE_KEY < datei` liest sie über stdin. Die Datei
   danach sicher entfernen. Den Schlüssel nie auf stdout ausgeben.
3. Den Schlüssel zusätzlich verschlüsselt sichern. Geht er verloren, ist eine
   kontrollierte Rotation über ein Developer-ID-signiertes DMG nötig.

## Ablauf pro Release

1. `app/Info.plist` und `CHANGELOG.md` aktualisieren. `CFBundleVersion` muss
   monoton steigen.
2. Vom Repository-Root den Release bauen:

   ```bash
   FASTRA_SIGN_IDENTITY="<Developer ID Application …>" \
   NOTARY_PROFILE=<profil> ./release.sh
   ```

   Das Skript signiert Sparkles Helfer von innen nach außen, baut das DMG,
   notarisiert es und stapelt das Ticket.
3. Tests, Signaturen, Staple, Gatekeeper und das DMG bewusst prüfen.
4. Tag und GitHub Release mit genau einem DMG anlegen. Release Notes eintragen
   und erst danach veröffentlichen.
5. `.github/workflows/publish-appcast.yml` erzeugt mit Sparkles
   `generate_appcast` den signierten Feed und veröffentlicht ihn über GitHub Pages.
6. Workflow und Feed prüfen. Eine ältere, bereits Sparkle-fähige und notarisiert
   installierte Testversion muss das Release finden, installieren und neu starten.

Der Workflow kann für ein bestehendes Tag manuell gestartet werden. Er erwartet
genau ein `*.dmg`; der Feed enthält nur das aktuelle Vollupdate und keine Deltas.
