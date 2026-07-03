# RohrPlan — LiDAR-Aufmaß für Heizung & Sanitär

Eine native iOS-App nach dem Vorbild von Polycam, aber für **SHK-Betriebe und
Heizungsplaner** statt für Architekten: Räume mit dem iPhone-LiDAR-Scanner
erfassen **und** die Rohrleitungen gleich mit — als vollwertige Plandaten,
die im Grundriss, im 3D-Modell und in allen Exporten erhalten bleiben.

## Warum Leitungen bei Polycam verschwinden — und hier nicht

Polycams Room/Floorplan-Modus basiert auf Apples **RoomPlan**-API. RoomPlan
kennt nur einen festen Katalog: Wände, Türen, Fenster, Öffnungen und einige
Möbelkategorien. **Rohrleitungen kommen in diesem Katalog nicht vor** —
alles, was RoomPlan nicht klassifizieren kann, fällt aus dem Ergebnis heraus.
Deshalb sind gescannte Leitungen bei Polycam im fertigen Plan weg.

RohrPlan löst das mit einem **zweiphasigen Scan auf einer gemeinsamen
ARSession**:

1. **Raumphase** — RoomPlan erfasst die Raumhülle (Wände, Türen, Fenster)
   wie gewohnt.
2. **Leitungsphase** — die ARSession läuft weiter (`stop(pauseARSession:
   false)`), der Weltursprung bleibt erhalten. Der Nutzer setzt per
   LiDAR-Raycast Punkte entlang jeder Leitung. Weil beide Phasen dasselbe
   Koordinatensystem teilen, liegen die Leitungen exakt lagerichtig zur
   Raumhülle — als eigene, dauerhafte Datenobjekte, unabhängig davon, was
   RoomPlan erkennt.

## Funktionen

- **Raum-Scan** mit RoomPlan (Wände, Türen, Fenster, Öffnungen, Möbel).
- **Leitungserfassung** per Fadenkreuz + LiDAR-Raycast: Punkte entlang des
  Rohrverlaufs setzen, System und Nennweite wählen. Bereits erfasste Läufe
  bleiben als farbige 3D-Rohre im Kamerabild stehen.
- **Systeme**: Heizung Vor-/Rücklauf, Kalt-/Warmwasser, Zirkulation,
  Abwasser, Gas, Lüftung — feste Farben, Kurzcodes, eigene DXF-Layer.
- **Nennweiten** DN 12 – DN 100.
- **Anlagenmarker**: Heizkörper, Ventile, Verteiler, Pumpe, Speicher,
  Gastherme, Waschtisch, WC, Dusche, Badewanne, Spüle, Wasserzähler.
- **2D-Grundriss** (automatisch nach dominanter Wandrichtung ausgerichtet)
  mit farbcodierten Leitungen, gestricheltem Rücklauf,
  Steigleitungs-Symbolen (▲/▼), DN-Beschriftung, Legende mit Längen je
  System und Maßstabsbalken. Zoom & Pan per Geste.
- **3D-Modell**: halbtransparente Raumhülle + Leitungen, frei drehbar.
- **Materialliste**: Rohrlängen je System und Nennweite plus Stückliste.
- **Exporte**: DXF (CAD, Layer je Gewerk, mm), USDZ (parametrisches
  Raummodell), CSV (Materialliste), JSON (komplette Rohdaten).
- **Projekte** werden lokal als JSON gespeichert (Documents/Projekte).

## Voraussetzungen

- iPhone Pro / iPad Pro **mit LiDAR** (iPhone 12 Pro oder neuer), iOS 17+.
- Mac mit **Xcode 16** zum Bauen.

## Bauen & aufs iPhone bringen

Ausführliche Anleitung (inkl. Signierung, Entwicklermodus, Fehlerbehebung):
**[SETUP-MAC.md](SETUP-MAC.md)**. Kurzfassung:

1. `RohrPlan.xcodeproj` in Xcode öffnen.
2. Unter *Signing & Capabilities* das eigene Team wählen.
3. iPhone anschließen, als Ziel wählen, **Run**.

Falls das Projektfile in einer älteren Xcode-Version nicht öffnet, gibt es
zwei Alternativen:

- `brew install xcodegen && xcodegen generate` (nutzt `project.yml`), oder
- in Xcode ein neues iOS-App-Projekt „RohrPlan“ anlegen und den Ordner
  `RohrPlan/` (Quellcode) hineinziehen.

> Hinweis: Dieses Repository wurde in einer Linux-Umgebung erstellt — der
> Code ist gegen die dokumentierten iOS-17-APIs geschrieben, konnte hier
> aber nicht mit Xcode kompiliert werden. Kleinere Anpassungen beim ersten
> Build sind möglich.

## Architektur

```
RohrPlan/
├── Models/        Datenmodell (Codable): PipeSystem, PipeRun, RoomShell,
│                  ScanProject, ProjectStore (JSON-Persistenz)
├── Scanning/      ScanCoordinator (geteilte ARSession, Phasen-Statemachine),
│                  RoomCaptureViewRepresentable (RoomPlan),
│                  PipeScanARView (ARSCNView + Raycast),
│                  PipeNodeFactory (3D-Rohre), Scan-UI
├── Plan/          FloorPlanModel (3D→2D-Projektion, Steigleitungserkennung),
│                  FloorPlanView (Canvas-Rendering)
├── Viewer3D/      Model3DView (SceneKit-Szene aus Raum + Leitungen)
├── Export/        ProjectExporter (DXF, USDZ, CSV, JSON)
└── UI/            Projektliste, Projektdetail, Materialliste, Export
```

Kernidee im Code: `ScanCoordinator` besitzt die `ARSession` und reicht sie
erst an `RoomCaptureView(frame:arSession:)`, dann an die `ARSCNView` der
Leitungsphase weiter. `PipeRun`-Punkte sind Weltkoordinaten dieser Session
und damit deckungsgleich mit den RoomPlan-Flächen (`CapturedRoom`).

## Roadmap-Ideen

- IFC-/gbXML-Export für TGA-Planungssoftware.
- Relokalisierung (`ARWorldMap`), um ein Projekt später im selben Raum um
  weitere Leitungen zu ergänzen.
- Automatische Rohr-Erkennung aus dem LiDAR-Mesh (Zylinder-Fitting).
- Foto-Anhänge und Notizen pro Leitung/Marker.
- Mehrere Räume/Geschosse pro Projekt mit Verbindungsleitungen.
