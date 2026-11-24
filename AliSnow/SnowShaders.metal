#include <metal_stdlib>
using namespace metal;

struct Snowflake {
    float2 position;
    float2 velocity;
    float size;
    float depth;
    float phase;
    float alpha;
};

struct SnowUniforms {
    float2 viewportSize;
    float2 mousePosition;
    float2 mouseVelocity;
    float deltaTime;
    float time;
    float windStrength;
    float cursorRadius;
    float cursorEnabled;
    uint particleCount;
};

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float alpha;
    float depth;
};

static inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

kernel void updateSnow(
    device Snowflake *flakes [[buffer(0)]],
    constant SnowUniforms &u [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= u.particleCount) {
        return;
    }

    Snowflake f = flakes[id];
    float dt = clamp(u.deltaTime, 0.0001, 0.05);

    // Target falling speed and gentle horizontal sway scaled by depth
    float targetFallSpeed = mix(42.0, 145.0, f.depth);
    float sway = sin(u.time * mix(0.8, 2.2, f.depth) + f.phase) * mix(16.0, 42.0, f.depth);
    float targetVx = sway + u.windStrength * mix(20.0, 75.0, f.depth);

    // Smoothly relax velocity toward natural falling + wind
    float relax = 1.0 - exp(-2.4 * dt);
    f.velocity.x = mix(f.velocity.x, targetVx, relax);
    f.velocity.y = mix(f.velocity.y, targetFallSpeed, relax);

    // Cursor wind & repulsion interaction
    if (u.cursorEnabled > 0.5 && u.cursorRadius > 1.0) {
        float2 toFlake = f.position - u.mousePosition;
        float distSq = dot(toFlake, toFlake);
        float radiusSq = u.cursorRadius * u.cursorRadius;

        if (distSq < radiusSq && distSq > 0.0001) {
            float dist = sqrt(distSq);
            float influence = 1.0 - (dist / u.cursorRadius);
            float falloff = influence * influence;
            float2 dir = toFlake / dist;

            // Radial push away from cursor + directional wake from cursor motion
            float depthScale = mix(0.6, 1.3, f.depth);
            f.velocity += dir * (950.0 * falloff * depthScale) * dt;
            f.velocity += u.mouseVelocity * (0.55 * falloff * depthScale);
        }
    }

    // Integrate position (origin at top-left in pixel coordinates)
    f.position += f.velocity * dt;

    // Horizontal wrap-around
    float margin = f.size * 2.0 + 12.0;
    if (f.position.x < -margin) {
        f.position.x = u.viewportSize.x + margin;
    } else if (f.position.x > u.viewportSize.x + margin) {
        f.position.x = -margin;
    }

    // Respawn at the top when falling past bottom edge
    if (f.position.y > u.viewportSize.y + margin) {
        float seed = float(id) * 1.37 + u.time * 13.7;
        f.position.x = hash11(seed) * u.viewportSize.x;
        f.position.y = -margin - hash11(seed + 7.13) * 40.0;
        f.velocity = float2(targetVx, targetFallSpeed);
    } else if (f.position.y < -margin * 4.0) {
        f.position.y = -margin;
        f.velocity.y = abs(f.velocity.y) * 0.3;
    }

    flakes[id] = f;
}

vertex VertexOut snowVertex(
    const device Snowflake *flakes [[buffer(0)]],
    constant SnowUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    Snowflake f = flakes[vid];

    // Convert pixel coordinates (top-left origin) to NDC (-1..1, bottom-left origin)
    float2 ndc;
    ndc.x = (f.position.x / max(u.viewportSize.x, 1.0)) * 2.0 - 1.0;
    ndc.y = 1.0 - (f.position.y / max(u.viewportSize.y, 1.0)) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.pointSize = f.size * 2.0;
    out.alpha = f.alpha;
    out.depth = f.depth;
    return out;
}

fragment float4 snowFragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    float2 centered = pointCoord - float2(0.5);
    float dist = length(centered) * 2.0;
    if (dist > 1.0) {
        discard_fragment();
    }

    // Soft glowing core with gentle feathered halo
    float core = 1.0 - smoothstep(0.0, 0.55, dist);
    float halo = 1.0 - smoothstep(0.25, 1.0, dist);
    float shape = mix(halo, core, 0.35);

    // Subtle cool-white tint based on depth
    float3 color = mix(float3(0.86, 0.93, 1.0), float3(1.0, 1.0, 1.0), in.depth);
    float alpha = shape * in.alpha;

    // Premultiplied alpha output
    return float4(color * alpha, alpha);
}
