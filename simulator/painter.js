/*
 * LED painter — turns an engine framebuffer into what a lit LED matrix
 * looks like behind smoked glass.
 *
 * Everything here uses operations SwiftUI's GraphicsContext also has
 * (nearest and bilinear image scaling, multiply and additive blending),
 * so the Mac app can paint the same way.
 */
(function (root) {
  'use strict';

  const DEFAULTS = {
    ledFill: 0.80,        // LED width as a fraction of pitch; the rest is gap
    ledRadius: 0.22,      // corner radius as a fraction of the LED
    unlit: [0.055, 0.052, 0.054],   // an off LED behind the diffuser: visible, barely
    bloomNear: 0.32,      // tight halo strength
    bloomFar: 0.30,       // wide glow strength
    bloomFrom: 0.35,      // only LEDs brighter than this give off glow
    gamma: 1.25,          // monitor transfer: lets dim LEDs recede as they do in a room
    glass: 0.05           // top reflection strength
  };

  function LedPainter(canvas, cols, rows, options) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.cols = cols; this.rows = rows;
    this.o = Object.assign({}, DEFAULTS, options || {});

    this.tiny = document.createElement('canvas');
    this.tiny.width = cols; this.tiny.height = rows;
    this.tctx = this.tiny.getContext('2d');
    this.img = this.tctx.createImageData(cols, rows);

    // lit light only, no unlit floor — what the bloom is made from
    this.glow = document.createElement('canvas');
    this.glow.width = cols; this.glow.height = rows;
    this.gctx = this.glow.getContext('2d');
    this.gimg = this.gctx.createImageData(cols, rows);

    // half-resolution copy: upscaling it gives the wide glow for free
    this.half = document.createElement('canvas');
    this.half.width = Math.ceil(cols / 2); this.half.height = Math.ceil(rows / 2);
    this.hctx = this.half.getContext('2d');

    this.maskPitch = 0;
    this.mask = null;
  }

  /* One LED's worth of mask: a rounded emitter, slightly hotter in the middle. */
  LedPainter.prototype.buildMask = function (pitch) {
    const size = Math.max(2, Math.round(pitch));
    const c = document.createElement('canvas');
    c.width = size; c.height = size;
    const x = c.getContext('2d');
    x.fillStyle = '#000'; x.fillRect(0, 0, size, size);
    const led = size * this.o.ledFill, off = (size - led) / 2, r = led * this.o.ledRadius;
    const g = x.createRadialGradient(size / 2, size / 2 - led * 0.08, led * 0.08, size / 2, size / 2, led * 0.72);
    g.addColorStop(0, '#ffffff');
    g.addColorStop(0.75, '#e4e4e4');
    g.addColorStop(1, '#b8b8b8');
    x.fillStyle = g;
    x.beginPath();
    if (x.roundRect) x.roundRect(off, off, led, led, r); else x.rect(off, off, led, led);
    x.fill();
    this.mask = this.ctx.createPattern(c, 'repeat');
    this.maskPitch = size;
  };

  LedPainter.prototype.resize = function (width, height) {
    this.canvas.width = Math.round(width);
    this.canvas.height = Math.round(height);
    this.maskPitch = 0;
  };

  LedPainter.prototype.paint = function (frame, dim) {
    const o = this.o, cols = this.cols, rows = this.rows;
    const W = this.canvas.width, H = this.canvas.height;
    const pitch = W / cols;
    if (Math.round(pitch) !== this.maskPitch) this.buildMask(pitch);
    const k = dim === undefined ? 1 : dim;

    // 1. framebuffer -> tiny image, with the unlit floor mixed in
    const d = this.img.data, gd = this.gimg.data, px = frame.px, u = o.unlit;
    for (let i = 0, j = 0; i < cols * rows; i++, j += 3) {
      const r = Math.pow(px[j] * k, o.gamma), g = Math.pow(px[j + 1] * k, o.gamma), b = Math.pow(px[j + 2] * k, o.gamma);
      const lum = Math.max(r, g, b);
      const w = Math.min(1, Math.max(0, (lum - o.bloomFrom) / (1 - o.bloomFrom)));
      d[i * 4]     = Math.round(255 * (u[0] + r * (1 - u[0])));
      d[i * 4 + 1] = Math.round(255 * (u[1] + g * (1 - u[1])));
      d[i * 4 + 2] = Math.round(255 * (u[2] + b * (1 - u[2])));
      d[i * 4 + 3] = 255;
      gd[i * 4] = Math.round(255 * r * w); gd[i * 4 + 1] = Math.round(255 * g * w); gd[i * 4 + 2] = Math.round(255 * b * w);
      gd[i * 4 + 3] = 255;
    }
    this.tctx.putImageData(this.img, 0, 0);
    this.gctx.putImageData(this.gimg, 0, 0);
    this.hctx.imageSmoothingEnabled = true;
    this.hctx.clearRect(0, 0, this.half.width, this.half.height);
    this.hctx.drawImage(this.glow, 0, 0, this.half.width, this.half.height);

    const ctx = this.ctx;
    ctx.save();
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, W, H);

    // 2. hard-edged blocks, one per LED
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(this.tiny, 0, 0, W, H);

    // 3. cut them into rounded emitters
    ctx.globalCompositeOperation = 'multiply';
    ctx.fillStyle = this.mask;
    ctx.fillRect(0, 0, W, H);

    // 4. light spilling into the gaps and onto the glass
    ctx.globalCompositeOperation = 'lighter';
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.globalAlpha = o.bloomNear;
    ctx.drawImage(this.glow, -pitch * 0.15, -pitch * 0.15, W + pitch * 0.3, H + pitch * 0.3);
    ctx.globalAlpha = o.bloomFar;
    ctx.drawImage(this.half, -pitch * 1.2, -pitch * 1.2, W + pitch * 2.4, H + pitch * 2.4);

    // 5. the glass: a faint reflection across the top
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
    const gl = ctx.createLinearGradient(0, 0, 0, H);
    gl.addColorStop(0, 'rgba(255,255,255,' + o.glass + ')');
    gl.addColorStop(0.38, 'rgba(255,255,255,0)');
    gl.addColorStop(1, 'rgba(0,0,0,0.12)');
    ctx.fillStyle = gl;
    ctx.fillRect(0, 0, W, H);
    ctx.restore();
  };

  root.LedPainter = LedPainter;
})(typeof window !== 'undefined' ? window : globalThis);
