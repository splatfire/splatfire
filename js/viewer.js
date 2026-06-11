import * as THREE from 'three';

const SPHERE_RADIUS = 500;

export function lonLatToVector(lon, lat, radius = SPHERE_RADIUS) {
  const phi = THREE.MathUtils.degToRad(90 - lat);
  const theta = THREE.MathUtils.degToRad(lon);
  return new THREE.Vector3(
    radius * Math.sin(phi) * Math.cos(theta),
    radius * Math.cos(phi),
    radius * Math.sin(phi) * Math.sin(theta),
  );
}

function vectorToLonLat(v) {
  const r = v.length();
  return {
    lat: 90 - THREE.MathUtils.radToDeg(Math.acos(v.y / r)),
    lon: THREE.MathUtils.radToDeg(Math.atan2(v.z, v.x)),
  };
}

/**
 * Renders one equirectangular panorama on the inside of a sphere with
 * drag-to-look / wheel-to-zoom controls, plus DOM hotspots projected onto it.
 */
export class PanoViewer {
  constructor(container) {
    this.container = container;
    this.lon = 0;
    this.lat = 0;
    this.onSphereClick = null; // set while placing a hotspot

    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    container.appendChild(this.renderer.domElement);

    this.camera = new THREE.PerspectiveCamera(75, 1, 1, 1100);
    this.scene = new THREE.Scene();

    const geometry = new THREE.SphereGeometry(SPHERE_RADIUS, 64, 48);
    geometry.scale(-1, 1, 1); // view the texture from the inside
    this.material = new THREE.MeshBasicMaterial({ color: 0x14161a });
    this.sphere = new THREE.Mesh(geometry, this.material);
    this.scene.add(this.sphere);

    this.lineLayer = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.lineLayer.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;pointer-events:none;';
    container.appendChild(this.lineLayer);
    this.lines = []; // { a, b: Vector3, el: SVGLine, labelEl }

    this.lineLabelLayer = document.createElement('div');
    this.lineLabelLayer.style.cssText = 'position:absolute;inset:0;pointer-events:none;';
    container.appendChild(this.lineLabelLayer);

    this.hotspotLayer = document.createElement('div');
    this.hotspotLayer.style.cssText = 'position:absolute;inset:0;pointer-events:none;';
    container.appendChild(this.hotspotLayer);
    this.hotspots = []; // { el, position: Vector3 }

    this.raycaster = new THREE.Raycaster();
    this.fadeEl = document.createElement('div');
    this.fadeEl.style.cssText =
      'position:absolute;inset:0;background:#14161a;opacity:0;pointer-events:none;transition:opacity .25s;z-index:6;';
    container.appendChild(this.fadeEl);

    this._bindControls();
    new ResizeObserver(() => this._resize()).observe(container);
    this._resize();

    this.renderer.setAnimationLoop(() => this._render());
  }

  _bindControls() {
    const el = this.renderer.domElement;
    let down = null;

    el.addEventListener('pointerdown', (e) => {
      down = { x: e.clientX, y: e.clientY, lon: this.lon, lat: this.lat, moved: false };
      el.setPointerCapture(e.pointerId);
    });

    el.addEventListener('pointermove', (e) => {
      if (!down) return;
      const dx = e.clientX - down.x;
      const dy = e.clientY - down.y;
      if (Math.abs(dx) + Math.abs(dy) > 5) down.moved = true;
      const speed = 0.12 * (this.camera.fov / 75);
      this.lon = down.lon - dx * speed;
      this.lat = THREE.MathUtils.clamp(down.lat + dy * speed, -85, 85);
    });

    el.addEventListener('pointerup', (e) => {
      const wasClick = down && !down.moved;
      down = null;
      if (wasClick && this.onSphereClick) {
        const hit = this._pick(e.clientX, e.clientY);
        if (hit) this.onSphereClick(hit);
      }
    });

    el.addEventListener('wheel', (e) => {
      e.preventDefault();
      this.camera.fov = THREE.MathUtils.clamp(this.camera.fov + e.deltaY * 0.05, 30, 100);
      this.camera.updateProjectionMatrix();
    }, { passive: false });
  }

  _pick(clientX, clientY) {
    const rect = this.renderer.domElement.getBoundingClientRect();
    const ndc = new THREE.Vector2(
      ((clientX - rect.left) / rect.width) * 2 - 1,
      -((clientY - rect.top) / rect.height) * 2 + 1,
    );
    this.raycaster.setFromCamera(ndc, this.camera);
    const hit = this.raycaster.intersectObject(this.sphere)[0];
    return hit ? vectorToLonLat(hit.point) : null;
  }

  _resize() {
    const { clientWidth: w, clientHeight: h } = this.container;
    if (!w || !h) return;
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(w, h);
  }

  _render() {
    this.camera.lookAt(lonLatToVector(this.lon, this.lat));
    this.renderer.render(this.scene, this.camera);
    this._updateHotspots();
    this._updateLines();
  }

  _updateHotspots() {
    const { clientWidth: w, clientHeight: h } = this.container;
    const camDir = this.camera.getWorldDirection(new THREE.Vector3());
    const v = new THREE.Vector3();
    for (const { el, position } of this.hotspots) {
      if (position.dot(camDir) <= 0) {
        el.style.display = 'none';
        continue;
      }
      v.copy(position).project(this.camera);
      el.style.display = '';
      el.style.left = `${(v.x * 0.5 + 0.5) * w}px`;
      el.style.top = `${(-v.y * 0.5 + 0.5) * h}px`;
    }
  }

  _updateLines() {
    const { clientWidth: w, clientHeight: h } = this.container;
    const camDir = this.camera.getWorldDirection(new THREE.Vector3());
    const v = new THREE.Vector3();
    const toScreen = (pos) => {
      v.copy(pos).project(this.camera);
      return [(v.x * 0.5 + 0.5) * w, (-v.y * 0.5 + 0.5) * h];
    };
    for (const line of this.lines) {
      const visible = line.a.dot(camDir) > 0 && line.b.dot(camDir) > 0;
      line.el.style.display = visible ? '' : 'none';
      line.labelEl.style.display = visible ? '' : 'none';
      if (!visible) continue;
      const [x1, y1] = toScreen(line.a);
      const [x2, y2] = toScreen(line.b);
      line.el.setAttribute('x1', x1);
      line.el.setAttribute('y1', y1);
      line.el.setAttribute('x2', x2);
      line.el.setAttribute('y2', y2);
      line.labelEl.style.left = `${(x1 + x2) / 2}px`;
      line.labelEl.style.top = `${(y1 + y2) / 2}px`;
    }
  }

  /**
   * lines: [{ a: {lon,lat}, b: {lon,lat}, label, onClick }]
   * Used for measurements: a dashed line between two points with a label.
   */
  setLines(lines) {
    this.lineLayer.replaceChildren();
    this.lineLabelLayer.replaceChildren();
    this.lines = lines.map((l) => {
      const el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      el.setAttribute('class', 'measure-line');
      this.lineLayer.appendChild(el);

      const labelEl = document.createElement('div');
      labelEl.className = 'measure-label';
      labelEl.textContent = l.label;
      if (l.onClick) {
        labelEl.style.pointerEvents = 'auto';
        labelEl.addEventListener('click', (e) => {
          e.stopPropagation();
          l.onClick();
        });
      }
      this.lineLabelLayer.appendChild(labelEl);

      return {
        el,
        labelEl,
        a: lonLatToVector(l.a.lon, l.a.lat, SPHERE_RADIUS - 10),
        b: lonLatToVector(l.b.lon, l.b.lat, SPHERE_RADIUS - 10),
      };
    });
  }

  /** Replace the panorama texture with the given image Blob, fading over it. */
  async showPanorama(blob, view) {
    this.fadeEl.style.opacity = '1';
    await new Promise((r) => setTimeout(r, 250));

    const url = URL.createObjectURL(blob);
    try {
      const texture = await new THREE.TextureLoader().loadAsync(url);
      texture.colorSpace = THREE.SRGBColorSpace;
      this.material.map?.dispose();
      this.material.map = texture;
      this.material.color.set(0xffffff);
      this.material.needsUpdate = true;
    } finally {
      URL.revokeObjectURL(url);
    }

    if (view) {
      this.lon = view.lon;
      this.lat = view.lat;
    }
    this.fadeEl.style.opacity = '0';
  }

  clearPanorama() {
    this.material.map?.dispose();
    this.material.map = null;
    this.material.color.set(0x14161a);
    this.material.needsUpdate = true;
    this.setHotspots([]);
    this.setLines([]);
  }

  /**
   * hotspots: [{ lon, lat, type: 'link'|'info', label, onClick }]
   */
  setHotspots(hotspots) {
    this.hotspotLayer.replaceChildren();
    this.hotspots = hotspots.map((h) => {
      const el = document.createElement('div');
      el.className = `hotspot ${h.type}`;
      el.style.pointerEvents = 'auto';

      const dot = document.createElement('div');
      dot.className = 'dot';
      dot.textContent = h.type === 'link' ? '➜' : 'i';
      el.appendChild(dot);

      if (h.label) {
        const label = document.createElement('div');
        label.className = 'label';
        label.textContent = h.label;
        el.appendChild(label);
      }

      el.addEventListener('click', (e) => {
        e.stopPropagation();
        h.onClick?.();
      });
      this.hotspotLayer.appendChild(el);
      return { el, position: lonLatToVector(h.lon, h.lat, SPHERE_RADIUS - 10) };
    });
  }

  getView() {
    return { lon: this.lon, lat: this.lat };
  }
}
