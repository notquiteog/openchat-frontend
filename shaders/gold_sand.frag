// Gold sand particle background — Flutter fragment shader
//
// Reproduces the Gemini-style point-sprite effect as a fullscreen shader:
// 400 + particles spread across a dark background, drifting slowly with the
// same layered sinusoidal motion as the WebGL vertex shader, twinkling with
// the same rhythmic formula, coloured with the same goldMid / goldBright
// palette.  Four grid layers give depth (coarse = large foreground particles,
// fine = small background dust).
//
// Uniforms (set in order via FragmentShader.setFloat):
//   0  uTime   — elapsed seconds
//   1  uSize.x — canvas width  in logical pixels
//   2  uSize.y — canvas height in logical pixels

#include <flutter/runtime_effect.glsl>

uniform float uTime;
uniform vec2  uSize;
out vec4 fragColor;

// 2-D → 2-D hash (returns values in [0, 1)²)
vec2 h22(vec2 p) {
  float n = sin(dot(p, vec2(41.3, 289.1)));
  return fract(vec2(262144.0, 32768.0) * n);
}

void main() {
  vec2 fc  = FlutterFragCoord().xy;
  // Centred coordinate system: y spans −1..1, x spans −aspect..aspect
  vec2 uvN = (fc * 2.0 - uSize) / uSize.y;

  // Dark charcoal base — matches the WebGL clearColor(0.06, 0.06, 0.06)
  vec3 col = vec3(0.06);

  // ── Four particle layers ────────────────────────────────────────────────
  // Each layer has a DIRECTIONAL flow so particles actually travel across
  // the screen rather than oscillating:
  //   L=0  large,  slow  → upward   + drift right
  //   L=1  medium, mid   → downward + drift left
  //   L=2  small,  slow  → upward   + drift left
  //   L=3  dust,   slow  → downward + drift right
  //
  // Technique: subtract the cumulative flow offset from uvN before gridding.
  // The grid then slides past the viewport, so gid changes over time and
  // particles stream continuously — seamlessly wrapping because hash(gid)
  // gives each integer cell a fixed identity regardless of where the grid is.
  // A gentle sinusoidal wobble is added on top for organic wavering.

  for (int L = 0; L < 4; L++) {
    float fL = float(L);
    float sc  = 5.0 + fL * 2.5;    // grid density: coarse (L=0) → fine (L=3)

    // Directional flow in uvN/s — upward layers use negative Y
    float flowY = (L == 0 || L == 2) ? -0.018 : 0.015;   // up or down
    float flowX = (L == 0 || L == 3) ?  0.007 : -0.005;  // slight lateral

    // Per-layer speed variation so they don't lock step
    float spd = 0.8 + fL * 0.15;
    vec2 flow = vec2(flowX, flowY) * spd;

    // Shift the grid by the accumulated flow — this is what makes particles
    // actually travel rather than oscillate
    vec2 g   = (uvN - flow * uTime) * sc;
    vec2 gid = floor(g);
    vec2 gf  = fract(g) - 0.5;

    for (int gy = -1; gy <= 1; gy++)
    for (int gx = -1; gx <= 1; gx++) {
      vec2 nb   = vec2(float(gx), float(gy));
      vec2 rnd  = h22(gid + nb + fL * 37.1);

      // ~30 % cell occupancy — sparse, airy feel
      float present = step(0.70, rnd.x);

      vec2  rnd2 = h22(rnd + 0.5);
      float ph   = rnd.x;
      float szN  = rnd.y;
      float spN  = rnd2.x;

      // Sinusoidal wobble layered on top of the directional flow —
      // keeps each grain's path organic rather than arrow-straight
      float wt = uTime * 0.022 * (0.5 + spN * 0.5);
      vec2 wobble = vec2(
        sin(wt + ph * 12.5) * 0.08,
        cos(wt + ph *  8.3) * 0.06
      );

      vec2  centre = nb + (rnd2 - 0.5) * 0.30 + wobble;
      float dist   = length(gf - centre);

      // Lazy twinkle — slow fade in/out like glinting sand catching light
      float spin    = sin(uTime * (0.25 + spN * 0.35) + ph * 50.0);
      float twinkle = smoothstep(0.0, 0.9, abs(spin));

      float pxR   = 1.5 + szN * 4.5;
      float cellR = pxR / uSize.y * sc;
      float disc  = smoothstep(cellR, cellR * 0.2, dist);

      vec3 goldBright = vec3(1.00, 0.91, 0.68);
      vec3 goldMid    = vec3(0.76, 0.57, 0.20);

      col += mix(goldMid, goldBright, twinkle) * disc * twinkle * 0.85 * present;
    }
  }

  // Soft tonemap — prevents overlapping particles from clipping to white
  col = col / (1.0 + col * 0.5);

  fragColor = vec4(col, 1.0);
}
