# Splatfire — 360° Room Tours

A web app for building and walking through virtual tours of real rooms,
functionally modeled on Immersight-style 3D room viewers (written entirely
from scratch — no Immersight code or assets are used).

Upload 360° panorama photos of rooms, link the rooms together with
navigation hotspots, pin notes onto the panoramas, and share the finished
tour as a single file.

## Features

- **360° panorama viewer** — drag to look around, scroll to zoom, fullscreen.
- **Multi-room tours** — add any number of equirectangular panoramas (JPG/PNG),
  e.g. straight from a Ricoh Theta or Insta360 camera.
- **Room links** — place navigation hotspots in a panorama that jump to other
  rooms, so visitors can walk through the space.
- **Notes** — pin info hotspots with a title and text anywhere in a room.
- **Edit / View modes** — build the tour in Edit mode, experience it in View mode.
- **Start views** — set the tour's starting room and each room's initial viewing
  direction.
- **Autosave** — the working tour persists in the browser (IndexedDB) across
  reloads.
- **Export / Import** — download the whole tour (including images) as one
  `.json` file and open it on any other machine.
- **Demo tour** — three generated rooms with links and a note, so you can try
  everything without real 360° photos.

## Running

It's a static site — serve the repo root with any web server:

```sh
npx serve .
# or
python3 -m http.server 8000
```

Then open the printed URL in a browser. (Opening `index.html` directly from
disk won't work because the app uses ES modules.)

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
