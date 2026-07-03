# Splatfire — 360° Room Tours

> **Neu:** [RohrPlan](RohrPlan/README.md) — eine native iOS-App (LiDAR +
> RoomPlan) für Heizungs- und Sanitärplaner: Räume scannen und Rohrleitungen
> als dauerhafte Plandaten erfassen. Siehe `RohrPlan/`.

A web app for building and walking through virtual tours of real rooms,
functionally modeled on Immersight-style 3D room viewers (written entirely
from scratch — no Immersight code or assets are used).

Upload 360° panorama photos of rooms, link the rooms together with
navigation hotspots, pin notes onto the panoramas, and share the finished
tour as a single file.

## Features

- **360° panorama viewer** — drag to look around, scroll to zoom, fullscreen.
- **Room capture (erfassen)** — capture a room with the device camera: snap
  overlapping photos while turning in a circle and the app stitches them into
  a panorama (uses the gyroscope for alignment when available). For best
  quality, upload images from a real 360° camera instead.
- **Multi-room tours** — add any number of equirectangular panoramas (JPG/PNG),
  e.g. straight from a Ricoh Theta or Insta360 camera.
- **Measurement (vermessen)** — enter the camera height once per room, then
  click two floor points to measure a distance, or a floor point plus a point
  straight above it to measure a height. Dimension lines with live labels are
  drawn into the panorama.
- **Room links** — place navigation hotspots in a panorama that jump to other
  rooms, so visitors can walk through the space.
- **Notes** — pin info hotspots with a title and text anywhere in a room.
- **Edit / View modes** — build the tour in Edit mode, experience it in View mode.
- **Start views** — set the tour's starting room and each room's initial viewing
  direction.
- **Autosave** — the working tour persists in the browser (IndexedDB) across
  reloads.
- **Project link** — download the tour as a single self-contained HTML page
  (viewer and images embedded) that opens in any browser with no server or
  install: send it to a customer like a project link.
- **Export / Import** — download the whole tour (including images) as one
  editable `.json` file and open it on any other machine.
- **Demo tour** — three generated rooms with links, a note, and a measurement,
  so you can try everything without real 360° photos.

## Running

It's a static site — serve the repo root with any web server:

```sh
npx serve .
# or
python3 -m http.server 8000
```

Then open the printed URL in a browser. (Opening `index.html` directly from
disk won't work because the app uses ES modules.)

Room capture needs camera access, which browsers only allow in a secure
context — `localhost` works, but on another device the page must be served
over HTTPS.

The only dependency is [three.js](https://threejs.org/) (MIT licensed),
vendored in `vendor/` and loaded via an import map — no build step,
`npm install`, or internet connection needed.

## Usage

1. **Add rooms** — click *+ Add rooms* and pick one or more 360° panorama
   images (or click *Demo tour*).
2. **Link rooms** — in Edit mode, click *+ Room link*, click a spot in the
   panorama (e.g. a doorway), and choose which room it leads to.
3. **Add notes** — click *+ Note*, click a spot, and enter a title and text.
4. **Set views** — look in the direction visitors should face first, then click
   *Set start view*. Mark the starting room with ★ in the room list.
5. **Walk through** — switch to View mode and click the orange arrows to move
   between rooms.
6. **Share** — *Export* downloads the tour as a single file; *Import* opens it
   anywhere.
