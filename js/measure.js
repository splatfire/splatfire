import { lonLatToVector } from 'viewer';

// Treat rays this close to the horizon as unusable for floor intersection.
const FLOOR_EPS = -0.05;

export function isFloorPoint(p) {
  return lonLatToVector(p.lon, p.lat, 1).y < FLOOR_EPS;
}

/**
 * Computes the real-world size of a measurement taken inside a panorama,
 * given the height of the camera above the floor when it was captured.
 *
 * - Both points on the floor → distance between the two floor points.
 * - First point on the floor, second above it → vertical height above the
 *   floor at that spot (e.g. floor to window sill).
 *
 * Returns { kind: 'floor'|'height', meters } or null if not measurable.
 */
export function solveMeasurement(a, b, cameraHeight) {
  const da = lonLatToVector(a.lon, a.lat, 1);
  const db = lonLatToVector(b.lon, b.lat, 1);
  if (da.y >= FLOOR_EPS) return null; // first point must be on the floor

  // Floor plane is at y = -cameraHeight; intersect the first ray with it.
  const pa = da.clone().multiplyScalar(cameraHeight / -da.y);

  if (db.y < FLOOR_EPS) {
    const pb = db.clone().multiplyScalar(cameraHeight / -db.y);
    return { kind: 'floor', meters: pa.distanceTo(pb) };
  }

  // Second point is at/above the horizon: measure up the vertical line
  // standing on the first floor point.
  const horizontal = Math.hypot(db.x, db.z);
  if (horizontal < 1e-6) return null;
  const t = Math.hypot(pa.x, pa.z) / horizontal;
  const meters = t * db.y + cameraHeight;
  return meters > 0 ? { kind: 'height', meters } : null;
}

export function formatMeters(meters) {
  return meters < 1 ? `${Math.round(meters * 100)} cm` : `${meters.toFixed(2)} m`;
}

export function measurementLabel(m, cameraHeight) {
  const solved = solveMeasurement(m.a, m.b, cameraHeight);
  if (!solved) return '—';
  return (solved.kind === 'height' ? '↕ ' : '') + formatMeters(solved.meters);
}
