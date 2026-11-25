#include <metal_stdlib>
using namespace metal;

// Weather mode constants
constant uint MODE_SNOW      = 0;
constant uint MODE_BLIZZARD  = 1;
constant uint MODE_RAIN      = 2;
constant uint MODE_STORM     = 3;
constant uint MODE_SAKURA    = 4;
constant uint MODE_AUTUMN    = 5;
constant uint MODE_FIREFLIES = 6;

constant float FIXED_SCALE = 100000.0;

struct WeatherParticle {
    float2 position;
    float2 velocity;
    float size;
    float depth;
    float phase;
    float alpha;
    float rotation;
    float spinSpeed;
    float colorVariant;
    float splashTimer;
};

struct ObstacleRect {
    float4 bounds; // x, y, width, height in pixel coords (top-left origin)
    float kind;    // 0 = window, 1 = Finder folder
    float pad1;
    float pad2;
    float pad3;
};

struct WeatherUniforms {
    float2 viewportSize;
    float2 mousePosition;
    float2 mouseVelocity;
    float deltaTime;
    float time;
    float windStrength;
    float cursorRadius;
    float cursorEnabled;
    float backingScale;
    float lightningFlash;
    float accumulationEnabled;
    uint particleCount;
    uint weatherMode;
    uint obstacleCount;
    uint heightmapBins;
};

static inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static inline float2 toNDC(float2 pixelPos, float2 viewportSize) {
    float2 ndc;
    ndc.x = (pixelPos.x / max(viewportSize.x, 1.0)) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / max(viewportSize.y, 1.0)) * 2.0;
    return ndc;
}

static inline void depositHeight(
    device atomic_uint *heightmap,
    uint bins,
    float normalizedX,
    float amount
) {
    if (bins == 0 || amount <= 0.0) return;
    int center = clamp(int(normalizedX * float(bins)), 0, int(bins) - 1);
    uint centerAdd = uint(amount * FIXED_SCALE);
    uint sideAdd = uint(amount * 0.52 * FIXED_SCALE);

    atomic_fetch_add_explicit(&heightmap[center], centerAdd, memory_order_relaxed);
    if (center > 0) {
        atomic_fetch_add_explicit(&heightmap[center - 1], sideAdd, memory_order_relaxed);
    }
    if (center + 1 < int(bins)) {
        atomic_fetch_add_explicit(&heightmap[center + 1], sideAdd, memory_order_relaxed);
    }
}

// MARK: - Compute Kernel 1: Particle Simulation

kernel void updateWeather(
    device WeatherParticle *particles [[buffer(0)]],
    constant WeatherUniforms &u [[buffer(1)]],
    const device ObstacleRect *obstacles [[buffer(2)]],
    device atomic_uint *bottomHeightmap [[buffer(3)]],
    device atomic_uint *obstacleCaps [[buffer(4)]],
    const device float *smoothedBottom [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) return;

    WeatherParticle p = particles[id];
    float dt = clamp(u.deltaTime, 0.0001, 0.05);
    float s = max(u.backingScale, 1.0);
    uint mode = u.weatherMode;

    // Handle active splash burst (for rain/storm droplets)
    if (p.splashTimer > 0.0) {
        p.splashTimer -= dt * 3.8;
        p.position += p.velocity * dt;
        p.velocity.y += 420.0 * s * dt;
        if (p.splashTimer <= 0.0) {
            float seed = float(id) * 1.73 + u.time * 19.3;
            p.position.x = hash11(seed) * u.viewportSize.x;
            p.position.y = -20.0 * s - hash11(seed + 4.1) * 90.0 * s;
            p.splashTimer = 0.0;
            p.velocity = float2(u.windStrength * 95.0 * s, mix(580.0, 1150.0, p.depth) * s);
        }
        particles[id] = p;
        return;
    }

    // Target physics per weather mode
    float targetVx = 0.0;
    float targetVy = 0.0;
    float relaxRate = 2.4;

    if (mode == MODE_SNOW) {
        float sway = sin(u.time * mix(0.8, 2.0, p.depth) + p.phase) * mix(18.0, 46.0, p.depth) * s;
        targetVx = sway + u.windStrength * mix(28.0, 95.0, p.depth) * s;
        targetVy = mix(32.0, 108.0, p.depth) * s;
        p.rotation += p.spinSpeed * 0.45 * dt;
    } else if (mode == MODE_BLIZZARD) {
        float gust = 1.0 + 0.45 * sin(u.time * 1.45 + p.position.y * 0.003);
        float sway = sin(u.time * mix(2.2, 4.4, p.depth) + p.phase) * mix(40.0, 95.0, p.depth) * s;
        targetVx = sway + (u.windStrength * gust + 0.55) * mix(85.0, 220.0, p.depth) * s;
        targetVy = mix(75.0, 210.0, p.depth) * s;
        relaxRate = 3.2;
        p.rotation += p.spinSpeed * 1.2 * dt;
    } else if (mode == MODE_RAIN || mode == MODE_STORM) {
        float stormBoost = (mode == MODE_STORM) ? 1.32 : 1.0;
        float gust = (mode == MODE_STORM) ? (1.0 + 0.35 * sin(u.time * 2.1)) : 1.0;
        targetVx = u.windStrength * gust * mix(55.0, 145.0, p.depth) * s * stormBoost;
        targetVy = mix(540.0, 1080.0, p.depth) * s * stormBoost;
        relaxRate = 6.5;
    } else if (mode == MODE_SAKURA) {
        float flutter = sin(u.time * mix(1.5, 2.9, p.depth) + p.phase);
        float drift = cos(u.time * 0.9 + p.phase * 1.7);
        targetVx = (flutter * 54.0 + u.windStrength * mix(40.0, 115.0, p.depth)) * s;
        targetVy = (mix(24.0, 72.0, p.depth) + drift * 12.0) * s;
        relaxRate = 2.0;
        p.rotation += (p.spinSpeed + flutter * 1.4) * dt;
    } else if (mode == MODE_AUTUMN) {
        float glide = sin(u.time * mix(1.1, 2.2, p.depth) + p.phase);
        float dip = abs(cos(u.time * 1.4 + p.phase));
        targetVx = (glide * 72.0 + u.windStrength * mix(45.0, 120.0, p.depth)) * s;
        targetVy = (mix(28.0, 82.0, p.depth) * (0.65 + 0.55 * dip)) * s;
        relaxRate = 1.9;
        p.rotation += (p.spinSpeed * 1.25 + glide * 1.6) * dt;
    } else {
        // MODE_FIREFLIES
        float wanderX = sin(u.time * mix(0.45, 1.05, p.depth) + p.phase) * 34.0 * s;
        float wanderY = cos(u.time * mix(0.38, 0.92, p.depth) + p.phase * 1.37) * 24.0 * s;
        targetVx = wanderX + u.windStrength * 18.0 * s;
        targetVy = wanderY - mix(6.0, 20.0, p.depth) * s;
        relaxRate = 1.6;
        p.rotation += p.spinSpeed * 0.3 * dt;
    }

    float relax = 1.0 - exp(-relaxRate * dt);
    p.velocity.x = mix(p.velocity.x, targetVx, relax);
    p.velocity.y = mix(p.velocity.y, targetVy, relax);

    // Cursor interaction
    if (u.cursorEnabled > 0.5 && u.cursorRadius > 1.0) {
        float2 toP = p.position - u.mousePosition;
        float distSq = dot(toP, toP);
        float radius = (mode == MODE_RAIN || mode == MODE_STORM) ? u.cursorRadius * 0.82 : u.cursorRadius;
        float radiusSq = radius * radius;

        if (distSq < radiusSq && distSq > 0.0001) {
            float dist = sqrt(distSq);
            float influence = 1.0 - (dist / radius);
            float falloff = influence * influence;
            float2 dir = toP / dist;
            float depthScale = mix(0.55, 1.25, p.depth);

            if (mode == MODE_RAIN || mode == MODE_STORM) {
                // Invisible umbrella dome above/around cursor!
                if (toP.y < radius * 0.35) {
                    float sideSign = (toP.x >= 0.0) ? 1.0 : -1.0;
                    p.velocity.x += (dir.x * 900.0 + sideSign * 380.0) * falloff * s * dt;
                    p.velocity.y *= (1.0 - 0.55 * falloff);
                    if (dist < radius * 0.52 && hash11(float(id) + u.time * 47.0) > 0.72) {
                        p.splashTimer = 1.0;
                        p.velocity = float2(dir.x * 160.0 * s, -120.0 * s);
                    }
                }
            } else if (mode == MODE_FIREFLIES) {
                // Fireflies swirl gently around the cursor
                float2 tangent = float2(-dir.y, dir.x);
                p.velocity += (tangent * 180.0 * falloff + dir * 90.0 * falloff) * s * dt;
                p.velocity += u.mouseVelocity * (0.22 * falloff);
            } else {
                // Snow, blizzard, sakura, autumn: push + directional wind wake
                p.velocity += dir * (780.0 * falloff * depthScale * s) * dt;
                p.velocity += u.mouseVelocity * (0.48 * falloff * depthScale);
                p.rotation += length(u.mouseVelocity) * 0.0015 * falloff * dt;
            }
        }
    }

    float2 prevPos = p.position;
    p.position += p.velocity * dt;

    // Obstacle top-edge collision (Finder folders & window tops)
    if (u.accumulationEnabled > 0.5 && mode != MODE_FIREFLIES && u.obstacleCount > 0 && p.velocity.y > 0.0) {
        float hitThreshold = (mode == MODE_RAIN || mode == MODE_STORM) ? 26.0 * s : 12.0 * s;
        for (uint i = 0; i < u.obstacleCount; i++) {
            float4 b = obstacles[i].bounds;
            if (p.position.x >= b.x && p.position.x <= (b.x + b.z)) {
                float topY = b.y;
                if (prevPos.y <= topY + 4.0 * s && p.position.y >= topY - 2.0 * s && p.position.y <= topY + hitThreshold) {
                    // Depth filter so background flakes still drift behind while mid/front flakes land
                    if (p.depth > 0.42) {
                        float deposit = (mode == MODE_RAIN || mode == MODE_STORM) ? 0.014 : 0.0095;
                        atomic_fetch_add_explicit(&obstacleCaps[i], uint(deposit * FIXED_SCALE), memory_order_relaxed);

                        if (mode == MODE_RAIN || mode == MODE_STORM) {
                            p.position.y = topY - 1.0 * s;
                            p.splashTimer = 1.0;
                            float spread = (hash11(float(id) * 3.1 + u.time * 17.0) - 0.5) * 2.0;
                            p.velocity = float2(spread * 140.0 * s, -mix(80.0, 175.0, p.depth) * s);
                        } else {
                            float seed = float(id) * 1.91 + u.time * 15.7;
                            p.position.x = hash11(seed) * u.viewportSize.x;
                            p.position.y = -24.0 * s - hash11(seed + 5.7) * 50.0 * s;
                            p.velocity = float2(targetVx, targetVy);
                        }
                        particles[id] = p;
                        return;
                    }
                }
            }
        }
    }

    // Horizontal wrap-around
    float margin = max(p.size * 3.0, 24.0 * s);
    if (p.position.x < -margin) {
        p.position.x = u.viewportSize.x + margin;
    } else if (p.position.x > u.viewportSize.x + margin) {
        p.position.x = -margin;
    }

    // Bottom boundary & accumulation
    if (mode == MODE_FIREFLIES) {
        if (p.position.y < -margin) {
            p.position.y = u.viewportSize.y + margin * 0.5;
        } else if (p.position.y > u.viewportSize.y + margin) {
            p.position.y = -margin * 0.5;
        }
    } else {
        float normX = clamp(p.position.x / max(u.viewportSize.x, 1.0), 0.0, 0.9999);
        uint bin = min(uint(normX * float(u.heightmapBins)), max(u.heightmapBins, 1u) - 1u);
        float maxDriftPx = (mode == MODE_SNOW || mode == MODE_BLIZZARD) ? 54.0 * s : 24.0 * s;
        float groundOffset = (u.accumulationEnabled > 0.5) ? smoothedBottom[bin] * maxDriftPx : 0.0;
        float floorY = u.viewportSize.y - groundOffset;

        if (p.position.y >= floorY) {
            if (u.accumulationEnabled > 0.5) {
                float depositAmt = (mode == MODE_SNOW || mode == MODE_BLIZZARD)
                    ? 0.0055
                    : ((mode == MODE_RAIN || mode == MODE_STORM) ? 0.012 : 0.0075);
                depositHeight(bottomHeightmap, u.heightmapBins, normX, depositAmt);
            }

            if (mode == MODE_RAIN || mode == MODE_STORM) {
                p.position.y = u.viewportSize.y - 2.0 * s;
                p.splashTimer = 1.0;
                float spread = (hash11(float(id) * 2.3 + u.time * 23.0) - 0.5) * 2.0;
                p.velocity = float2(spread * 165.0 * s, -mix(90.0, 195.0, p.depth) * s);
            } else {
                float seed = float(id) * 1.37 + u.time * 13.7;
                p.position.x = hash11(seed) * u.viewportSize.x;
                p.position.y = -margin - hash11(seed + 7.13) * 45.0 * s;
                p.velocity = float2(targetVx, targetVy);
            }
        } else if (p.position.y < -margin * 4.5) {
            p.position.y = -margin;
            p.velocity.y = abs(p.velocity.y) * 0.25;
        }
    }

    particles[id] = p;
}

// MARK: - Compute Kernel 2: Smooth Snowdrifts, Melt & Cursor Brush

kernel void smoothAccumulation(
    device atomic_uint *bottomHeightmap [[buffer(0)]],
    device float *smoothedBottom [[buffer(1)]],
    device atomic_uint *obstacleCaps [[buffer(2)]],
    device float *smoothedCaps [[buffer(3)]],
    const device ObstacleRect *obstacles [[buffer(4)]],
    constant WeatherUniforms &u [[buffer(5)]],
    uint id [[thread_position_in_grid]]
) {
    float dt = clamp(u.deltaTime, 0.0001, 0.05);
    float s = max(u.backingScale, 1.0);
    uint mode = u.weatherMode;

    // 1. Update bottom screen heightmap bins
    if (id < u.heightmapBins) {
        uint raw = atomic_load_explicit(&bottomHeightmap[id], memory_order_relaxed);
        float val = min(float(raw) / FIXED_SCALE, 1.0);

        uint leftRaw = atomic_load_explicit(&bottomHeightmap[id > 0 ? id - 1 : id], memory_order_relaxed);
        uint rightRaw = atomic_load_explicit(&bottomHeightmap[id + 1 < u.heightmapBins ? id + 1 : id], memory_order_relaxed);
        float avgNeighbors = (float(leftRaw) + float(rightRaw)) * 0.5 / FIXED_SCALE;

        // Organic pillowy diffusion so snowdrifts stay soft and rounded
        float diffuseRate = (mode == MODE_RAIN || mode == MODE_STORM) ? 2.5 : 0.75;
        val = mix(val, avgNeighbors, clamp(diffuseRate * dt, 0.0, 0.45));

        // Gentle decay (fast for rain mist/splashes, very slow natural melt for snow/petals)
        float decayRate = (mode == MODE_RAIN || mode == MODE_STORM)
            ? 1.9
            : ((u.accumulationEnabled > 0.5 && mode != MODE_FIREFLIES) ? 0.012 : 1.8);
        val *= exp(-decayRate * dt);

        // Cursor brush: sweeping mouse near bottom clears snowdrifts & petals!
        if (u.cursorEnabled > 0.5 && u.mousePosition.y > u.viewportSize.y - 120.0 * s) {
            float binX = (float(id) + 0.5) / float(u.heightmapBins) * u.viewportSize.x;
            float dx = abs(binX - u.mousePosition.x);
            float brushRadius = u.cursorRadius * 0.65;
            if (dx < brushRadius) {
                float brush = 1.0 - (dx / brushRadius);
                float speedBoost = 1.0 + min(length(u.mouseVelocity) / (450.0 * s), 3.0);
                val = max(0.0, val - brush * 1.4 * speedBoost * dt);
            }
        }

        val = clamp(val, 0.0, 1.0);
        atomic_store_explicit(&bottomHeightmap[id], uint(val * FIXED_SCALE), memory_order_relaxed);
        smoothedBottom[id] = mix(smoothedBottom[id], val, clamp(10.0 * dt, 0.0, 1.0));
    }

    // 2. Update obstacle snow caps (Finder folders & window tops)
    if (id < u.obstacleCount) {
        uint raw = atomic_load_explicit(&obstacleCaps[id], memory_order_relaxed);
        float cap = min(float(raw) / FIXED_SCALE, 1.0);

        float decayRate = (mode == MODE_RAIN || mode == MODE_STORM)
            ? 2.2
            : ((u.accumulationEnabled > 0.5 && mode != MODE_FIREFLIES) ? 0.016 : 2.0);
        cap *= exp(-decayRate * dt);

        // Cursor brushing over a folder/window top clears its snow cap!
        if (u.cursorEnabled > 0.5) {
            float4 b = obstacles[id].bounds;
            float2 capCenter = float2(b.x + b.z * 0.5, b.y);
            float dx = max(abs(u.mousePosition.x - capCenter.x) - b.z * 0.5, 0.0);
            float dy = abs(u.mousePosition.y - b.y);
            float dist = sqrt(dx * dx + dy * dy);
            if (dist < u.cursorRadius * 0.45) {
                float speedBoost = 1.0 + min(length(u.mouseVelocity) / (350.0 * s), 4.0);
                cap = max(0.0, cap - 1.8 * speedBoost * dt);
            }
        }

        cap = clamp(cap, 0.0, 1.0);
        atomic_store_explicit(&obstacleCaps[id], uint(cap * FIXED_SCALE), memory_order_relaxed);
        smoothedCaps[id] = mix(smoothedCaps[id], cap, clamp(8.0 * dt, 0.0, 1.0));
    }
}

// MARK: - Render Pass 1: Instanced Weather Particles

struct ParticleVertexOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float depth;
    float colorVariant;
    float splashTimer;
    float flutterPhase;
    uint mode;
};

vertex ParticleVertexOut particleVertex(
    const device WeatherParticle *particles [[buffer(0)]],
    constant WeatherUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    // 2 triangles forming a centered quad (-1..1)
    const float2 quadOffsets[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };

    WeatherParticle p = particles[iid];
    float2 local = quadOffsets[vid];
    uint mode = u.weatherMode;
    float s = max(u.backingScale, 1.0);

    float2 halfExtent;
    float angle = p.rotation;

    if (p.splashTimer > 0.0) {
        float expand = (1.0 - p.splashTimer) * 1.35 + 0.5;
        halfExtent = float2(p.size * 1.45 * expand);
        angle = 0.0;
    } else if (mode == MODE_RAIN || mode == MODE_STORM) {
        float speed = length(p.velocity);
        float streakLen = clamp(speed * 0.019, 10.0 * s, 32.0 * s) * mix(0.6, 1.15, p.depth);
        float thickness = mix(0.85, 1.65, p.depth) * s;
        halfExtent = float2(thickness, streakLen * 0.5);
        angle = atan2(p.velocity.x, -p.velocity.y);
    } else if (mode == MODE_SAKURA) {
        float flip = 0.38 + 0.62 * abs(cos(u.time * 2.2 + p.phase));
        halfExtent = float2(p.size * 1.75, p.size * 1.35 * flip);
    } else if (mode == MODE_AUTUMN) {
        float flip = 0.42 + 0.58 * abs(cos(u.time * 1.7 + p.phase));
        halfExtent = float2(p.size * 2.1, p.size * 1.7 * flip);
    } else if (mode == MODE_FIREFLIES) {
        float pulse = 0.65 + 0.45 * sin(u.time * mix(1.6, 3.2, p.colorVariant) + p.phase);
        halfExtent = float2(p.size * 2.6 * pulse);
        angle = 0.0;
    } else {
        // Snow / Blizzard
        halfExtent = float2(p.size * 1.25);
        angle = p.rotation;
    }

    float c = cos(angle);
    float sn = sin(angle);
    float2 scaled = local * halfExtent;
    float2 rotated = float2(scaled.x * c - scaled.y * sn, scaled.x * sn + scaled.y * c);
    float2 worldPos = p.position + rotated;

    ParticleVertexOut out;
    out.position = float4(toNDC(worldPos, u.viewportSize), 0.0, 1.0);
    out.uv = local;
    out.alpha = p.alpha;
    out.depth = p.depth;
    out.colorVariant = p.colorVariant;
    out.splashTimer = p.splashTimer;
    out.flutterPhase = u.time * 2.4 + p.phase;
    out.mode = mode;
    return out;
}

fragment float4 particleFragment(ParticleVertexOut in [[stage_in]]) {
    float2 uv = in.uv;
    float r = length(uv);

    // Rain / Storm Splash Burst
    if (in.splashTimer > 0.0) {
        if (r > 1.0) discard_fragment();
        float ring = 1.0 - smoothstep(0.0, 0.35, abs(r - (1.0 - in.splashTimer) * 0.85));
        float dotCore = 1.0 - smoothstep(0.0, 0.45, r);
        float shape = max(ring * 0.85, dotCore * in.splashTimer);
        float3 col = float3(0.76, 0.90, 1.0);
        float a = shape * in.splashTimer * 0.72;
        return float4(col * a, a);
    }

    // 1. Snow & Blizzard
    if (in.mode == MODE_SNOW || in.mode == MODE_BLIZZARD) {
        if (r > 1.0) discard_fragment();
        float core = 1.0 - smoothstep(0.0, 0.52, r);
        float halo = 1.0 - smoothstep(0.18, 1.0, r);
        // Subtle 6-point crystalline glint on close flakes
        float theta = atan2(uv.y, uv.x);
        float star = pow(abs(cos(theta * 3.0)), 6.0) * (1.0 - smoothstep(0.15, 0.95, r)) * smoothstep(0.55, 1.0, in.depth);
        float shape = clamp(mix(halo, core, 0.40) + star * 0.32, 0.0, 1.0);
        float3 col = mix(float3(0.82, 0.91, 1.0), float3(1.0, 1.0, 1.0), in.depth);
        float a = shape * in.alpha;
        return float4(col * a, a);
    }

    // 2. Rain & Storm streaks
    if (in.mode == MODE_RAIN || in.mode == MODE_STORM) {
        float xFade = 1.0 - smoothstep(0.15, 1.0, abs(uv.x));
        // Brighter droplet head at the bottom (uv.y near +1), tapered trail at top
        float yHead = smoothstep(-1.0, 0.75, uv.y) * (1.0 - smoothstep(0.75, 1.0, uv.y));
        float shape = xFade * yHead;
        if (shape < 0.01) discard_fragment();
        float3 baseCol = (in.mode == MODE_STORM)
            ? mix(float3(0.62, 0.74, 0.96), float3(0.88, 0.94, 1.0), in.depth)
            : mix(float3(0.64, 0.82, 1.0), float3(0.92, 0.97, 1.0), in.depth);
        float a = shape * mix(0.28, 0.74, in.depth);
        return float4(baseCol * a, a);
    }

    // 3. Sakura Cherry Blossom Petals
    if (in.mode == MODE_SAKURA) {
        // Stylized soft teardrop/heart-notched petal silhouette
        float2 p = uv;
        p.x *= 1.18;
        float notch = smoothstep(0.35, 1.0, p.y) * 0.24 * (1.0 - smoothstep(0.0, 0.32, abs(p.x)));
        float d = length(float2(p.x, (p.y + 0.08) * 0.92)) + notch;
        if (d > 0.92) discard_fragment();
        float edge = 1.0 - smoothstep(0.70, 0.92, d);
        float innerGlow = 1.0 - smoothstep(0.0, 0.85, d);
        float3 palePink = float3(1.0, 0.91, 0.95);
        float3 deepBlush = float3(0.99, 0.64, 0.78);
        float3 col = mix(deepBlush, palePink, clamp(in.colorVariant * 0.55 + innerGlow * 0.55, 0.0, 1.0));
        float a = edge * mix(0.58, 0.94, in.depth);
        return float4(col * a, a);
    }

    // 4. Autumn Leaves
    if (in.mode == MODE_AUTUMN) {
        // Pointed oval/maple-inspired leaf with subtle central vein
        float2 p = uv;
        float widthProfile = max(0.05, 1.0 - p.y * p.y);
        float lobe = 1.0 + 0.18 * sin(p.y * 7.5);
        float normX = abs(p.x) / (widthProfile * 0.72 * lobe);
        float dist = max(normX, abs(p.y));
        if (dist > 1.0) discard_fragment();

        float edge = 1.0 - smoothstep(0.78, 1.0, dist);
        float vein = 1.0 - smoothstep(0.0, 0.06, abs(p.x));

        float3 gold = float3(0.98, 0.76, 0.22);
        float3 amber = float3(0.94, 0.44, 0.14);
        float3 crimson = float3(0.78, 0.18, 0.16);
        float3 col = (in.colorVariant < 0.5)
            ? mix(gold, amber, in.colorVariant * 2.0)
            : mix(amber, crimson, (in.colorVariant - 0.5) * 2.0);
        col = mix(col, col * 0.74, vein * 0.35);

        float a = edge * mix(0.62, 0.95, in.depth);
        return float4(col * a, a);
    }

    // 5. Fireflies (dreamy warm bokeh glow)
    if (r > 1.0) discard_fragment();
    float pulse = 0.45 + 0.55 * sin(in.flutterPhase);
    float core = exp(-r * r * 14.0);
    float halo = exp(-r * r * 3.2) * 0.65;
    float shape = (core + halo) * pulse;
    float3 warmGold = float3(1.0, 0.90, 0.42);
    float3 softMint = float3(0.68, 0.98, 0.58);
    float3 col = mix(warmGold, softMint, smoothstep(0.68, 1.0, in.colorVariant));
    col = mix(col, float3(1.0, 1.0, 0.92), core * 0.65);
    float a = clamp(shape * mix(0.45, 0.95, in.depth), 0.0, 1.0);
    return float4(col * a, a);
}

// MARK: - Render Pass 2: Bottom Screen Drifts / Petal Carpet / Rain Mist

struct BottomDriftOut {
    float4 position [[position]];
    float2 uv; // x: 0..1 across screen, y: 0 at bottom edge -> 1 at strip top
};

vertex BottomDriftOut bottomDriftVertex(
    constant WeatherUniforms &u [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };
    float2 uv = corners[vid];
    float stripHeight = 82.0 * max(u.backingScale, 1.0);

    float2 pixelPos;
    pixelPos.x = uv.x * u.viewportSize.x;
    pixelPos.y = u.viewportSize.y - uv.y * stripHeight;

    BottomDriftOut out;
    out.position = float4(toNDC(pixelPos, u.viewportSize), 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 bottomDriftFragment(
    BottomDriftOut in [[stage_in]],
    const device float *smoothedBottom [[buffer(0)]],
    constant WeatherUniforms &u [[buffer(1)]]
) {
    if (u.accumulationEnabled < 0.5 || u.weatherMode == MODE_FIREFLIES || u.heightmapBins == 0) {
        discard_fragment();
    }

    float fBin = clamp(in.uv.x, 0.0, 0.9999) * float(u.heightmapBins - 1);
    uint b0 = uint(floor(fBin));
    uint b1 = min(b0 + 1, u.heightmapBins - 1);
    float t = fract(fBin);
    float h = mix(smoothedBottom[b0], smoothedBottom[b1], t);

    if (h < 0.008) discard_fragment();

    uint mode = u.weatherMode;

    if (mode == MODE_SNOW || mode == MODE_BLIZZARD) {
        // Gentle sculpted wave contour + pillowy highlight
        float wave = 0.03 * sin(in.uv.x * 28.0) + 0.015 * cos(in.uv.x * 61.0);
        float surface = clamp(h * 0.72 + wave * h, 0.0, 0.92);
        float distFromTop = surface - in.uv.y;
        if (distFromTop < -0.04) discard_fragment();

        float mask = smoothstep(-0.04, 0.05, distFromTop);
        float topHighlight = 1.0 - smoothstep(0.0, 0.18, max(distFromTop, 0.0));
        float3 shadowSnow = float3(0.78, 0.88, 0.98);
        float3 brightSnow = float3(0.98, 0.99, 1.0);
        float3 col = mix(shadowSnow, brightSnow, clamp(topHighlight * 0.75 + 0.25, 0.0, 1.0));
        float a = mask * 0.88 * smoothstep(0.0, 0.08, h);
        return float4(col * a, a);
    }

    if (mode == MODE_RAIN || mode == MODE_STORM) {
        // Subtle wet mist shimmer at the bottom edge
        float mist = exp(-in.uv.y * 5.2) * h * 0.42;
        float shimmer = 0.85 + 0.15 * sin(in.uv.x * 90.0 + u.time * 5.0);
        float3 col = float3(0.72, 0.86, 1.0);
        float a = clamp(mist * shimmer, 0.0, 0.38);
        if (a < 0.005) discard_fragment();
        return float4(col * a, a);
    }

    // Sakura petals or Autumn leaves carpet
    float surface = h * 0.34;
    float distFromTop = surface - in.uv.y;
    if (distFromTop < -0.05) discard_fragment();

    float mask = smoothstep(-0.05, 0.06, distFromTop);
    float dapple = 0.5 + 0.5 * sin(in.uv.x * 140.0 + in.uv.y * 42.0);
    float3 col = (mode == MODE_SAKURA)
        ? mix(float3(0.98, 0.66, 0.80), float3(1.0, 0.90, 0.95), dapple)
        : mix(float3(0.86, 0.34, 0.16), float3(0.98, 0.74, 0.24), dapple);
    float a = mask * 0.78 * smoothstep(0.0, 0.06, h);
    return float4(col * a, a);
}

// MARK: - Render Pass 3: Obstacle Caps (Finder Folders & Window Tops)

struct ObstacleCapOut {
    float4 position [[position]];
    float2 uv; // x: 0..1 across width, y: 0 at ledge surface -> 1 at cap top
    float fullness;
    float kind;
    uint mode;
};

vertex ObstacleCapOut obstacleCapVertex(
    const device ObstacleRect *obstacles [[buffer(0)]],
    const device float *smoothedCaps [[buffer(1)]],
    constant WeatherUniforms &u [[buffer(2)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    ObstacleRect obs = obstacles[iid];
    float capFullness = smoothedCaps[iid];
    float2 uv = corners[vid];
    float s = max(u.backingScale, 1.0);

    float maxCapH = (obs.kind > 0.5 ? 16.0 : 14.0) * s;
    float capH = maxCapH * clamp(capFullness, 0.0, 1.0);

    float2 pixelPos;
    pixelPos.x = obs.bounds.x + uv.x * obs.bounds.z;
    // Slight 2pt lip resting right onto the top edge of the folder/window
    pixelPos.y = (obs.bounds.y + 2.0 * s) - uv.y * (capH + 3.0 * s);

    ObstacleCapOut out;
    out.position = float4(toNDC(pixelPos, u.viewportSize), 0.0, 1.0);
    out.uv = uv;
    out.fullness = capFullness;
    out.kind = obs.kind;
    out.mode = u.weatherMode;
    return out;
}

fragment float4 obstacleCapFragment(ObstacleCapOut in [[stage_in]]) {
    if (in.fullness < 0.02 || in.mode == MODE_FIREFLIES) discard_fragment();

    // Rounded pillow dome tapering smoothly to 0 at both left/right edges
    float arch = sin(clamp(in.uv.x, 0.0, 1.0) * 3.14159265);
    float dome = pow(max(arch, 0.0), 0.52);
    float dist = dome - in.uv.y;
    if (dist < -0.08) discard_fragment();

    float mask = smoothstep(-0.08, 0.10, dist);
    float bottomSoft = smoothstep(0.0, 0.15, in.uv.y);

    float3 col;
    float baseAlpha;
    if (in.mode == MODE_SNOW || in.mode == MODE_BLIZZARD) {
        float topHighlight = 1.0 - smoothstep(0.0, 0.35, max(dist, 0.0));
        col = mix(float3(0.82, 0.90, 0.98), float3(1.0, 1.0, 1.0), 0.4 + 0.6 * topHighlight);
        baseAlpha = 0.90;
    } else if (in.mode == MODE_RAIN || in.mode == MODE_STORM) {
        col = float3(0.76, 0.90, 1.0);
        baseAlpha = 0.42;
    } else if (in.mode == MODE_SAKURA) {
        col = mix(float3(0.99, 0.68, 0.82), float3(1.0, 0.92, 0.96), in.uv.y);
        baseAlpha = 0.82;
    } else {
        col = mix(float3(0.88, 0.38, 0.16), float3(0.98, 0.74, 0.24), in.uv.y);
        baseAlpha = 0.82;
    }

    float a = mask * mix(0.72, 1.0, bottomSoft) * baseAlpha * smoothstep(0.02, 0.15, in.fullness);
    return float4(col * a, a);
}

// MARK: - Render Pass 4: Atmospheric Storm Lightning Glow

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    const float2 pos[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    FullscreenOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 atmosphereFragment(
    FullscreenOut in [[stage_in]],
    constant WeatherUniforms &u [[buffer(0)]]
) {
    if (u.lightningFlash < 0.005) discard_fragment();

    // Soft atmospheric vignette flash concentrated near top sky & edges so screen content stays readable
    float topSky = smoothstep(0.15, 1.0, in.uv.y);
    float edgeDist = length((in.uv - float2(0.5, 0.45)) * float2(1.1, 1.0));
    float vignette = smoothstep(0.25, 0.95, edgeDist);
    float glow = mix(vignette, topSky, 0.55) * u.lightningFlash;

    float3 col = float3(0.82, 0.88, 1.0);
    float a = clamp(glow * 0.34, 0.0, 0.34);
    return float4(col * a, a);
}
