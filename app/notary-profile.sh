#!/usr/bin/env bash
# Gemeinsame, public-safe Verwaltung des lokalen notarytool-Profils.
# Credential-Werte bleiben ausschließlich im macOS-Schlüsselbund; im Repo und
# in Git-Konfigurationen wird höchstens der nicht geheime Profilname abgelegt.

fastra_require_notary_profile() {
  local profile="${NOTARY_PROFILE:-}"

  if [ -z "$profile" ]; then
    profile="$(git config --local --get fastra.notaryProfile 2>/dev/null || true)"
  fi

  if [ -z "$profile" ]; then
    if [ ! -t 0 ]; then
      echo "✗ Kein lokales Notary-Profil konfiguriert." >&2
      echo "  Einmalig interaktiv ausführen oder public-safe nur für diesen Clone setzen:" >&2
      echo "  git config --local fastra.notaryProfile <profil>" >&2
      return 1
    fi

    printf "Notary-Profilname für diesen Mac [notary]: " >&2
    IFS= read -r profile
    profile="${profile:-notary}"
  fi

  # Notarytool-Profil über `history` prüfen; `security find-generic-password`
  # erkennt gültige Profile nicht immer. Bis zu fünf Versuche tolerieren die
  # gelegentliche falsche Meldung „No Keychain password item found“.
  # Ein tatsächlich fehlendes Profil scheitert weiterhin.
  local attempt profile_ok=0
  for attempt in 1 2 3 4 5; do
    if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
      profile_ok=1
      break
    fi
    sleep 3
  done
  if [ "$profile_ok" = 0 ]; then
    echo "✗ Notary-Profil '$profile' ist auf diesem Mac nicht verwendbar." >&2
    echo "  Keychain-Profile werden von iCloud nicht zwischen Macs synchronisiert." >&2

    if [ ! -t 0 ]; then
      echo "  In einer lokalen GUI-Terminalsitzung einmalig einrichten:" >&2
      echo "  xcrun notarytool store-credentials '$profile' --apple-id '<apple-id>' --team-id '<team-id>'" >&2
      echo "  Das App-Passwort nur an der interaktiven Abfrage eingeben, nie als Argument." >&2
      return 1
    fi

    printf "Profil jetzt interaktiv im Schlüsselbund einrichten? [j/N] " >&2
    local answer
    IFS= read -r answer
    case "$answer" in
      j|J|ja|Ja|JA|y|Y|yes|Yes|YES) ;;
      *) return 1 ;;
    esac

    local apple_id team_id
    printf "Apple-ID: " >&2
    IFS= read -r apple_id
    printf "Team-ID: " >&2
    IFS= read -r team_id
    if [ -z "$apple_id" ] || [ -z "$team_id" ]; then
      echo "✗ Apple-ID und Team-ID dürfen nicht leer sein." >&2
      return 1
    fi

    # Absichtlich kein --password: notarytool fragt das App-spezifische
    # Passwort verdeckt ab und speichert es direkt im lokalen Schlüsselbund.
    xcrun notarytool store-credentials "$profile" \
      --apple-id "$apple_id" --team-id "$team_id"
    xcrun notarytool history --keychain-profile "$profile" >/dev/null
  fi

  # Nur der Profilname landet clone-lokal in .git/config. Diese Datei kann
  # weder committed noch zu GitHub gepusht werden.
  git config --local fastra.notaryProfile "$profile"
  NOTARY_PROFILE="$profile"
  export NOTARY_PROFILE
}
