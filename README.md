# Quill

SwiftUI-App zum Signieren und Installieren von IPAs direkt auf dem iPhone – mit eigenem
Zertifikat oder mit der Apple-ID, ohne Rechner. Ab **iOS 27**; ältere Versionen werden
nicht unterstützt.

## Stand

| Teil | Zustand |
| --- | --- |
| Rust-Kern `QuillCore` | baut ohne Warnungen (auch Clippy), 10 Tests grün, C-Schnittstelle aus C und Swift aufgerufen |
| Swift-Brücke (`Core.swift`, `AppleAccountService`, `DeviceLink`) | Typprüfung gegen den echten Header bestanden (Linux-Swift mit Platzhaltern für UIKit) |
| Übrige Swift-Dateien | Syntaxprüfung bestanden, **noch nie mit Xcode kompiliert** |
| Auf dem Gerät | **ungetestet** |

Beim ersten Build in Xcode ist mit einzelnen Compilerfehlern zu rechnen, vor allem in den
SwiftUI-Ansichten und bei SwiftData.

## Bauen

Voraussetzungen: macOS mit Xcode 26 oder neuer (iOS-27-SDK), Homebrew, Rust (rustup).

```sh
brew install xcodegen
curl https://sh.rustup.rs -sSf | sh   # falls Rust fehlt
./setup.sh                             # Zsign holen, Rust-Kern bauen, Projekt erzeugen
open Quill.xcodeproj
```

`setup.sh` ruft `scripts/build-core.sh` auf; das baut `QuillCore` für iPhone und
Simulator und legt `Vendor/QuillCore.xcframework` an. Nach Änderungen am Rust-Kern:
`REBUILD_CORE=1 ./setup.sh`.

In Xcode unter *Signing & Capabilities* das eigene Team wählen und die Bundle-ID
(`com.example.quill`) anpassen.

## Einrichtung auf dem iPhone

1. **Entwicklermodus** einschalten (Einstellungen → Datenschutz & Sicherheit).
2. **LocalDevVPN** aus dem App Store installieren. Darüber erreicht Quill die
   Gerätedienste des eigenen iPhones unter `10.7.0.1:49152`.
3. In Quill **Wireless Pair** starten, in Einstellungen → Datenschutz & Sicherheit →
   Entwicklermodus „Quill auf …“ wählen und den angezeigten Code eingeben. Zügig
   zurückkehren: Im Hintergrund hat Quill nur begrenzt Zeit.
4. LocalDevVPN verbinden. Die Statuszeile zeigt „Gekoppelt ✓ • Dev Mode ✓“.
5. Entweder **mit Apple-ID anmelden** oder ein **.p12 mit Profil importieren**.

## Funktionen

| Bereich | Inhalt |
| --- | --- |
| Signer (Start) | Statuszeile, UDID erkennen/kopieren, Pick & Sign aus Dateien, Sign & Install von URL, LiveContainer-Assistent, Protokoll |
| Installierte Apps | Restlaufzeit mit Ampel, Refresh (Daten bleiben), Refresh All, Entfernen, Erinnerung 24 h vor Ablauf, Hintergrund-Refresh als Versuch |
| Apple-Account | Anmeldung mit 2FA (Code, SMS, Geräte), Team, Gerät registrieren, App-IDs mit Kontingent, Zertifikat und Profile automatisch, „+RAM“, Zertifikate bei Apple widerrufen |
| Kopplung | Wireless Pair ohne Rechner (iOS 27), Import einer Remote-Pairing-Datei, `quill://pairing?data=…` mit Bestätigung |
| Zertifikat | Import .p12 / .mobileprovision / .cer / .zip mit automatischer Zuordnung, Export .p12 (Face ID, neues Passwort, optional mit Profilen als .zip), CSR erzeugen, Reset, Widerrufsprüfung (OCSP) |
| Signieren | Name, Bundle-ID (Erweiterungen ziehen mit), Version, Icon, Mindest-iOS; Erweiterungen/Watch-App/Gerätebeschränkung/URL-Schemata entfernen; Dateifreigabe; .dylib/.framework einbinden; eigene Entitlements |
| Kurzbefehle | „Apps erneuern“ (Hintergrund), „Quill öffnen und Apps erneuern“, „Quill-Status“, „Tage bis zum nächsten Ablauf“; Anleitung für die tägliche Automation in der App |
| Widget | Home-Bildschirm klein/mittel (Resttage, Refresh per Tipp), Sperrbildschirm (rund, rechteckig, Zeile), Steuerzentrale-Schalter „Quill Refresh“ |
| Ohne Kopplung | UDID per Safari-Profil (wie AirSign), von Hand oder aus Profil; Installation über itms-services, z. B. mit bezahltem Account |
| Bisher schon | Dateibrowser, Bibliothek, Quellen (AltStore-Format), Downloads, WLAN-Übertragung, Installation per `itms-services` als Rückfall ohne Kopplung |

## Automatisch erneuern

Zuverlässig ist eine persönliche Automation in der Kurzbefehle-App (täglich, „Sofort ausführen“):

1. „VPN festlegen“ → LocalDevVPN → Verbinden
2. „Warten“ 3 Sekunden
3. „Apps erneuern“ (Quill)
4. optional „VPN festlegen“ → Trennen

Voraussetzung: Apple-ID-Passwort für den Refresh gemerkt. Verlangt Apple einen
Bestätigungscode, bricht die Aktion sofort ab und meldet das, statt zu hängen. Meldet
die Automation eine Zeitüberschreitung, „Quill öffnen und Apps erneuern“ verwenden.

## Widget und App Group

Widget und App teilen Daten über die App Group `group.com.example.quill`
(Build-Einstellung `APP_GROUP` in `project.yml`, bei eigener Bundle-ID anpassen). Das
Widget öffnet Quill für den Refresh; die Arbeit läuft in der App, weil nur sie
Zertifikate und Kopplung hat. Bietet dein Account in Xcode keine App Groups an, die
Zeile `entitlements:` beider Targets entfernen: Die App läuft dann normal, das Widget
zeigt nur einen Hinweis. Mit einem kostenlosen Account kostet das Widget eine
zusätzliche App-ID.

## Aufbau

```
QuillCore/          Rust-Kern (staticlib), C-Header in include/
  src/pairing.rs     iOS 27: Quill als „pairable host“, Code, Pairing-Datei
  src/device.rs      Remote Pairing → TLS-PSK-Tunnel → RSD → Lockdown, AFC, Installation
  src/account.rs     Apple-Anmeldung, 2FA, Team, App-IDs, Signieren (isideload)
  src/crypto.rs      CSR, .p12 bauen/umverschlüsseln/lesen
Quill/Services      Core (Brücke), DeviceLink + PairingService, AppleAccountService,
                     IdentityStore, SigningService (Vorbereiten + zsign), SigningPipeline,
                     RefreshService, LiveContainerService, InstallService (itms-services)
Quill/App           App-Einstieg, AppServices (gemeinsame Dienste), WidgetPublisher
Quill/Intents       Kurzbefehle (App Intents)
Quill/Shared        WidgetSnapshot, auch im Widget-Target
Quill/Features      Signer-Tab, Apps, Dateien, Quellen, Einstellungen
QuillWidget/        Widget und Steuerzentrale
```

Zwei Signierwege, ein Ablauf (`SigningPipeline`):

- **Apple-Account:** Quill passt die App an, isideload holt Zertifikat, App-IDs und
  Profile und signiert; installiert wird der `.app`-Ordner als Upgrade.
- **Eigenes Zertifikat:** Quill passt an, zsign signiert mit .p12 und dem besten
  passenden Profil (exakte App-ID vor Wildcard, dieses iPhone enthalten).

## Datenschutz

Schlüssel, Pairing-Datei und Zugangsdaten bleiben auf dem iPhone (Dateischutz,
Schlüsselbund „nur dieses Gerät“). Bei der Apple-Anmeldung spricht Quill mit Apple und
mit einem **Anisette-Server** (Standard `ani.iloader.app`, in den Einstellungen änderbar),
der Gerätekenndaten liefert, die eine App nicht selbst erzeugen kann. Dieser Server sieht
die IP-Adresse, nicht das Passwort. Exportierte .p12 landen nie automatisch im
Dokumente-Ordner, weil die WLAN-Übertragung diesen freigibt.

## Bekannte Grenzen

- Ab iOS 27; darunter lässt sich Quill nicht installieren.
- LocalDevVPN ist nötig. Ein eigenes VPN bräuchte eine Berechtigung, die kostenlose
  Accounts nicht bekommen.
- Kostenlose Apple-ID: 7 Tage Laufzeit, drei aktive Apps, wenige neue App-IDs pro Woche.
- Der Hintergrund-Refresh gelingt nur, wenn iOS ihn startet, LocalDevVPN verbunden ist und
  keine 2FA nötig ist. Verlässlich ist die Erinnerung.
- Die Kopplung als „pairable host“ ist neu; öffentlich belegt ist sie bisher durch wenige
  Nutzertests (PhonePair, StikDebug, SideInstaller).
- „Sample IPA“ aus dem Vorbild fehlt: Es gibt keine geeignete Beispiel-App mit klarer Lizenz.
- „Detect“ ohne Kopplung nutzt ein temporäres Safari-Profil, das Quill selbst über
  `http://127.0.0.1:8765` ausliefert. Ungetestet ist, ob iOS 27 diesen Rückweg über HTTP
  auf dem eigenen Gerät annimmt; sonst bleibt die Eingabe von Hand.

## Bewusst nicht übernommen

- „Permanente Installation“ über die CoreTrust-Lücke
- Abruf geteilter fremder Enterprise-Zertifikate
- Werbung und Tracking
- Code aus SideStore (AGPL) oder SideInstaller (nicht-kommerzielle Lizenz)

## Abhängigkeiten

- [idevice](https://github.com/jkcoxson/idevice) (MIT): Kopplung, Tunnel, Gerätedienste
- [isideload](https://github.com/nab138/isideload) (MIT): Apple-Account, Entwicklerdienste
- zsign (MIT) über `khcrysalis/Zsign-Package`, zieht OpenSSL (Apache 2.0)
- ZIPFoundation (MIT)
- Rust-Abhängigkeiten unter MIT/Apache-2.0, siehe `QuillCore/Cargo.lock`
