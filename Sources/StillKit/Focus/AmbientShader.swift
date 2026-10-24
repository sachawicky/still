/// Original procedural artwork. Embedded MSL keeps SwiftPM, local installation and
/// the standalone review tool identical; there are no external wallpaper assets.
enum AmbientShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;
struct Uniforms { float4 viewport, phase, dark, cool, warm; };
struct Backdrop { float4 position [[position]]; float2 uv; };
struct Surface { float4 position [[position]]; float3 world; float3 normal; float2 uv; float layer; };
float2 rotate2(float2 p, float a) { float s = sin(a), c = cos(a); return float2(c*p.x-s*p.y, s*p.x+c*p.y); }
vertex Backdrop backdropVertex(uint id [[vertex_id]]) {
    float2 p = float2(id == 2 ? 3.0 : -1.0, id == 1 ? 3.0 : -1.0);
    return { float4(p, 0.999, 1), p * .5 + .5 };
}
fragment float4 backdropFragment(Backdrop in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2 - 1;
    float glow = exp(-1.6 * dot(p - float2(.55*sin(u.phase.z), .5), p - float2(.55*sin(u.phase.z), .5)));
    float3 color = mix(u.dark.rgb, mix(u.cool.rgb, u.warm.rgb, .5 + .3*sin(u.phase.w)), glow * .38);
    float vignette = smoothstep(.3, 1.5, length(p*float2(.7,1)));
    color = u.viewport.y > .5 ? mix(u.dark.rgb, mix(u.cool.rgb,u.warm.rgb,.4), glow*.12 + vignette*.08) : color * (.93 - .18*vignette);
    return float4(color, 1);
}
// A swept sheet with changing camber and torsion. The transverse direction turns
// through the light as the spine rolls in depth. All four phases evolve continuously.
float3 sheet(float s, float v, float layer, constant Uniforms &u) {
    float a = u.phase.x + layer * 1.47;
    float b = u.phase.y + layer * .93;
    float spine = .48*sin(s*.58 + a) + .14*sin(s*.92 - b);
    float width = .67 + .18*sin(s*.48 - b + layer);
    float twist = .92*sin(s*.49 + u.phase.x + layer*1.3) + .28*cos(b);
    float3 p = float3(s, spine + (layer-1.5)*.73 + v*width*cos(twist),
                     .52*cos(s*.57 + b) + (layer-1.5)*.42 + v*width*sin(twist)
                     + .68*(1-v*v)*(.8 + .2*cos(s*.63 - a)));
    p.xy = rotate2(p.xy, .36 + .12*sin(u.phase.z + layer*.2));
    p.xz = rotate2(p.xz, .14*sin(u.phase.w));
    p.y += .16*sin(u.phase.z + layer);
    return p;
}
vertex Surface ribbonVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]], constant uint &index [[buffer(1)]]) {
    const uint nx = 192, ny = 32;
    const float2 corners[6] = {float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
    uint cell = id/6;
    float2 uv = (float2(cell%nx, cell/nx) + corners[id%6])/float2(nx,ny);
    float s = (uv.x*2-1)*5.8, v = uv.y*2-1, layer = float(index);
    float3 p = sheet(s, v, layer, u);
    float3 ds = sheet(s+.004, v, layer, u) - sheet(s-.004, v, layer, u);
    float3 dv = sheet(s, v+.004, layer, u) - sheet(s, v-.004, layer, u);
    float3 normal = normalize(cross(ds,dv));
    float w = 7.4-p.z;
    // A separate depth slice per sheet resolves its own folds while preserving
    // back-to-front transparency between sheets, without intersection cutouts.
    float depth = .84 - layer*.2 + w*.006;
    return {float4(p.x*3.4/u.viewport.x, p.y*3.4, depth*w, w), p, normal, float2(s,v), layer};
}
fragment float4 ribbonFragment(Surface in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.normal);
    float3 eye = normalize(float3(0,0,7.4) - in.world);
    n = faceforward(n, -eye, n);
    float3 light = normalize(float3(-.5,.8,1.4));
    float diffuse = max(0.0, dot(n,light));
    float rim = pow(1-abs(dot(n,eye)), 2.4);
    float sheen = pow(max(0.0,dot(n,normalize(light+eye))), 16.0);
    float across = in.uv.y;
    float edge = pow(abs(across), 10.0);
    float tint = clamp(.5 + .38*sin(in.uv.x*.43 + in.layer*1.9 + u.phase.z) + .22*across, 0.0, 1.0);
    float3 pigment = mix(u.cool.rgb, u.warm.rgb, tint);
    float shade = .06 + .88*pow(diffuse, 2.8);
    float3 color = mix(u.dark.rgb*.7, pigment, shade);
    // Light stays within the original palette gamut: no white/neon highlight tint.
    color = mix(color, mix(u.cool.rgb,u.warm.rgb,tint*.7), min(.95, sheen*.82 + rim*.7 + edge*.42));
    // Broad satin highlights, a fine edge and a darker underside produce volume.
    // Light uses silver body shading; it is not an inverted night palette.
    if (u.viewport.y > .5) {
        float body = .22 + .40*diffuse;
        color = mix(pigment*.78, u.dark.rgb, body);
        color = mix(color, float3(.985), min(.8, sheen*.48 + rim*.28 + edge*.18));
    } else {
        color = mix(color, mix(u.cool.rgb,u.warm.rgb,.3)*1.24, sheen*.28);
    }
    // Soft transmitting edges and a denser central volume, with no screen-space blur.
    float feather = 1-smoothstep(.965,1.0,abs(across));
    float alpha = smoothstep(0.0,.7,5.8-abs(in.uv.x))*feather*(.82 + .14*(1-abs(across)))*smoothstep(.015,.09,abs(dot(n,eye)));
    if (alpha < .002) discard_fragment();
    return float4(color, alpha);
}
"""#
}
