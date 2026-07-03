# RohrPlan auf Mac & iPhone einrichten

Schritt-für-Schritt vom leeren Mac bis zur laufenden App auf dem iPhone.

## Voraussetzungen

| Was | Warum |
|---|---|
| Mac mit **Xcode 16+** (aus dem Mac App Store, kostenlos) | Bauen der App |
| **iPhone Pro** (12 Pro oder neuer) mit iOS 17+ | LiDAR-Scanner für Raum- und Leitungsscan |
| USB-Kabel | Erste Installation aufs iPhone |
| Apple-ID | Signieren — ein **kostenloses** Konto reicht, kein bezahltes Developer-Programm nötig |

Nach der Xcode-Installation einmalig im Terminal:

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
```

## 1. Repository holen

```sh
git clone https://github.com/splatfire/splatfire.git
cd splatfire
git checkout claude/polycam-heating-plumbing-app-zplhs6
```

## 2. Kompilierung prüfen (optional, ohne iPhone)

Baut die App ohne Signierung — zeigt sofort, ob alles kompiliert:

```sh
cd RohrPlan
xcodebuild -project RohrPlan.xcodeproj -scheme RohrPlan \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Endet die Ausgabe mit `** BUILD SUCCEEDED **`, ist alles gut. Bei
Fehlern: Fehlermeldungen kopieren und in die Claude-Session zurückgeben.

## 3. Projekt öffnen & signieren

```sh
open RohrPlan.xcodeproj
```

In Xcode:

1. Links im Navigator das blaue Projekt **RohrPlan** anklicken.
2. Target **RohrPlan** → Tab **Signing & Capabilities**.
3. **Automatically manage signing** aktivieren (sollte es schon sein).
4. Bei **Team** das eigene Team wählen. Ohne Team: *Add an Account…* und
   mit der Apple-ID anmelden — es entsteht ein „Personal Team".
5. Meldet Xcode, die Bundle-ID sei vergeben: bei **Bundle Identifier**
   `com.splatfire.rohrplan` durch etwas Eigenes ersetzen,
   z. B. `de.MEINNAME.rohrplan`.

## 4. iPhone vorbereiten

1. iPhone per Kabel anschließen, am iPhone **„Diesem Computer vertrauen"**
   bestätigen.
2. **Entwicklermodus** aktivieren: *Einstellungen → Datenschutz &
   Sicherheit → Entwicklermodus* → einschalten → Neustart bestätigen.
   (Der Menüpunkt erscheint erst, nachdem das iPhone einmal mit Xcode
   verbunden war.)

## 5. Auf dem iPhone starten

1. In Xcode oben in der Geräteleiste das iPhone als Ziel wählen
   (nicht den Simulator — ARKit/LiDAR laufen nur auf echter Hardware).
2. **⌘R** (Run). Der erste Build dauert ein paar Minuten.
3. Beim ersten Start blockiert iOS die App: *Einstellungen → Allgemein →
   VPN & Geräteverwaltung → Entwickler-App* → dem eigenen Zertifikat
   **vertrauen**. Danach App erneut öffnen.
4. Kamera-Zugriff erlauben, Projekt anlegen, scannen.

## Hinweise für kostenlose Apple-IDs

- Die Signatur läuft nach **7 Tagen** ab — danach die App einfach über
  Xcode neu installieren (⌘R). Projektdaten auf dem iPhone bleiben erhalten.
- Maximal 3 selbst signierte Apps gleichzeitig pro Gerät.
- Mit bezahltem Developer-Account (99 €/Jahr) entfallen beide Grenzen.

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| „Unable to open project" / Projekt öffnet nicht | `brew install xcodegen && cd RohrPlan && xcodegen generate` — erzeugt das Projekt neu aus `project.yml` |
| Compile-Fehler | Ausgabe von Schritt 2 kopieren und in die Claude-Session geben |
| iPhone erscheint nicht als Ziel | Kabel prüfen, iPhone entsperren, Entwicklermodus (Schritt 4), Xcode → *Window → Devices and Simulators* |
| „Untrusted Developer" beim App-Start | Schritt 5.3 (Zertifikat vertrauen) |
| Scan-Button meldet „kein LiDAR" | Gerät ist kein Pro-Modell — Raum-Scan braucht den LiDAR-Sensor |
| App nach 7 Tagen „beschädigt"/startet nicht | Signatur abgelaufen (kostenlose Apple-ID) — per Xcode neu installieren |
