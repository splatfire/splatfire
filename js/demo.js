import { uid } from './store.js';
import { DEFAULT_CAMERA_HEIGHT } from 'measure';

/**
 * Draws a synthetic equirectangular panorama so the app can be tried
 * without real 360° photos: sky/ceiling, striped walls with the room
 * name repeated around the horizon, and a floor band.
 */
function renderPanorama({ name, wallHue }) {
  const W = 2048;
  const H = 1024;
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d');

  const sky = ctx.createLinearGradient(0, 0, 0, H * 0.35);
  sky.addColorStop(0, `hsl(${wallHue}, 18%, 88%)`);
  sky.addColorStop(1, `hsl(${wallHue}, 22%, 72%)`);
  ctx.fillStyle = sky;
  ctx.fillRect(0, 0, W, H * 0.35);

  ctx.fillStyle = `hsl(${wallHue}, 30%, 52%)`;
  ctx.fillRect(0, H * 0.35, W, H * 0.35);
  ctx.fillStyle = `hsla(${wallHue}, 35%, 40%, 0.55)`;
  for (let x = 0; x < W; x += 256) {
    ctx.fillRect(x, H * 0.35, 12, H * 0.35);
  }

  const floor = ctx.createLinearGradient(0, H * 0.7, 0, H);
  floor.addColorStop(0, `hsl(${wallHue}, 18%, 32%)`);
  floor.addColorStop(1, `hsl(${wallHue}, 14%, 16%)`);
  ctx.fillStyle = floor;
  ctx.fillRect(0, H * 0.7, W, H * 0.3);

  ctx.strokeStyle = 'rgba(255,255,255,0.12)';
  ctx.lineWidth = 2;
  for (let x = 0; x < W; x += 128) {
    ctx.beginPath();
    ctx.moveTo(x, H * 0.7);
    ctx.lineTo(x, H);
    ctx.stroke();
  }

  ctx.fillStyle = 'rgba(255,255,255,0.9)';
  ctx.font = 'bold 64px system-ui, sans-serif';
  ctx.textAlign = 'center';
  for (let i = 0; i < 4; i++) {
    ctx.fillText(name, W * (0.125 + i * 0.25), H * 0.53);
  }

  return new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.85));
}

export async function createDemoTour() {
  const rooms = [
    { name: 'Showroom', wallHue: 18 },
    { name: 'Office', wallHue: 210 },
    { name: 'Workshop', wallHue: 120 },
  ];

  const scenes = await Promise.all(
    rooms.map(async (room) => ({
      id: uid(),
      name: room.name,
      image: await renderPanorama(room),
      view: { lon: 0, lat: 0 },
      hotspots: [],
      measurements: [],
      cameraHeight: DEFAULT_CAMERA_HEIGHT,
    })),
  );

  const [showroom, office, workshop] = scenes;
  const link = (target, lon) => ({
    id: uid(), type: 'link', lon, lat: -8, targetSceneId: target.id,
  });

  showroom.hotspots.push(
    link(office, 40),
    link(workshop, 140),
    {
      id: uid(), type: 'info', lon: -60, lat: 5,
      title: 'Welcome to the demo',
      text: 'Drag to look around, scroll to zoom, and click the orange arrows to walk between rooms. Switch to Edit mode to add your own links and notes.',
    },
  );
  showroom.measurements.push({
    id: uid(),
    a: { lon: 95, lat: -35 },
    b: { lon: 128, lat: -30 },
  });
  office.hotspots.push(link(showroom, 220));
  workshop.hotspots.push(link(showroom, 320), link(office, 20));

  return {
    id: uid(),
    name: 'Demo tour',
    startSceneId: showroom.id,
    scenes,
  };
}
