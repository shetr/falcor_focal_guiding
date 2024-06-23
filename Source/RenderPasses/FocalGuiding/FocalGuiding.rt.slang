#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Geometry.IntersectionHelpers;
import Rendering.Lights.LightHelpers;

import DensityNode;

ParameterBlock<DensityNodes> gNodes;

cbuffer CB
{
    uint gNodesSize;
    float3 gSceneBoundsMin;
    float3 gSceneBoundsMax;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.
    float gGuidedRayProb;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

/** Payload for shadow ray.
*/
struct ShadowRayData
{
    bool visible;
};

/** Payload for scatter ray (up to 72B).
*/
struct ScatterRayData
{
    float3  radiance;       ///< Accumulated outgoing radiance from path.
    bool    terminated;     ///< Set to true when path is terminated.
    float3  thp;            ///< Current path throughput. This is updated at each path vertex.
    uint    pathLength;     ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3  origin;         ///< Next path segment origin.
    float3  direction;      ///< Next path segment direction.

    SampleGenerator sg;     ///< Per-ray state for the sample generator (up to 16B).

    /** Initializes ray payload with default parameters.
    */
    __init(SampleGenerator sg)
    {
        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
        this.sg = sg;
    }
};

struct SpatialRayData
{
    float3 radiance;
    float3 thp;       ///< Current path throughput. This is updated at each path vertex.
    float3 origin;    ///< Next path segment origin.
    float3 direction; ///< Next path segment direction.
    float3 hitPos;

    __init()
    {
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
        this.hitPos = float3(0, 0, 0);
    }
}

/** Setup ShadingData based on loaded vertex/material attributes for a hit point.
    \param[in] hit Hit information.
    \param[in] rayOrigin Ray origin.
    \param[in] rayDir Normalized ray direction.
    \param[in] lod Method for computing texture level-of-detail.
    \return ShadingData struct.
*/
ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData v = {};
    uint materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

/** Returns the primary ray's direction.
*/
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
    if (is_valid(gViewW))
    {
        // If we have the view vector bound as a buffer, just fetch it. No need to compute anything.
        return -gViewW[launchIndex].xyz;
    }
    else
    {
        // Compute the view vector. This must exactly match what the G-buffer pass is doing (jitter etc.).
        // Note that we do not take depth-of-field into account as it would require exactly matching the
        // sample generator between the passes, which is error prone. The host side will issue a warning instead.
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
    }
}

/** Traces a shadow ray towards a light source.
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \return True if light is visible, false otherwise.
*/
bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false;    // Set to true by miss shader if ray is not terminated before
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, ray, rayData);

    return rayData.visible;
}

/** Traces a scatter ray based on ray parameters stored in the ray payload.
    \param[in] rayData Describes the ray parameters. The struct is modified based on the result.
*/
void traceScatterRay(inout ScatterRayData rayData)
{
    RayDesc ray;
    ray.Origin = rayData.origin;
    ray.Direction = rayData.direction;
    ray.TMin = 0.f;
    ray.TMax = kRayTMax;

    uint rayFlags = 0;      // TODO: Set cull mode from the app
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
}

void traceSpatialRay(inout SpatialRayData rayData)
{
    RayDesc ray;
    ray.Origin = rayData.origin;
    ray.Direction = rayData.direction;
    ray.TMin = 0.f;
    ray.TMax = kRayTMax;

    uint rayFlags = 0; // TODO: Set cull mode from the app
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 2 /* hitIdx */, rayTypeCount, 2 /* missIdx */, ray, rayData);
}

float3 samplePointByDensities(out float pdf, inout SampleGenerator sg)
{
    uint nodeIndex = 0;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    pdf = 1 / box.volume();

    uint depth = 0;
    while (depth < MAX_OCTREE_DEPTH)
    {
        float r = sampleNext1D(sg);
        float acc = 0;
        uint childIndex = 0;
        DensityChild child;
        for (childIndex = 0; childIndex < 8; ++childIndex) {
            child = gNodes.getChildNode(nodeIndex, childIndex);
            acc += child.density;
            if (r < acc) {
                break;
            }
        }
        if (childIndex >= 8) {
            childIndex = uint(r * 8);
        }
        pdf *= child.density;
        int3 axisIndices = unpackOctreeChildIndex(childIndex);
        AABB childBox = shrinkBox(box, axisIndices);
        nodeIndex = child.index;
        box = childBox;
        if (child.isLeaf()) {
            break;
        }
        ++depth;
    }
    float3 rPos = sampleNext3D(sg);
    return box.minPoint + rPos * box.extent();
}

float3 sampleDirectionByDensities(float3 origin, inout SampleGenerator sg)
{
    float pointPdf;
    float3 samplePoint = samplePointByDensities(pointPdf, sg);
    return normalize(samplePoint - origin);
}

float getDirectionPdf(float3 origin, float3 dir)
{
    float pdf = 0;
    NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
    float parentDensities[MAX_OCTREE_DEPTH];
    uint nodesStackSize = 0;
    // push first node
    nodesStack[nodesStackSize] = NodeTravRef(0);
    parentDensities[nodesStackSize] = 1;
    ++nodesStackSize;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);

    uint failsafe = 0;
    while (nodesStackSize > 0 && failsafe < 9 * gNodesSize)
    {
        uint topIndex = nodesStackSize - 1;
        if (nodesStack[topIndex].child >= 8) {
            // pop node
            --nodesStackSize;
            // correct the box
            if (nodesStackSize > 0) {
                topIndex = nodesStackSize - 1;
                uint currChildIndex = nodesStack[topIndex].child - 1;
                int3 axisIndices = unpackOctreeChildIndex(currChildIndex);
                box = extendBox(box, axisIndices);
            }
        }
        else
        {
            uint nodeIndex = nodesStack[topIndex].node;
            uint childIndex = nodesStack[topIndex].child;
            float parentDensity = parentDensities[topIndex];
            DensityChild child = gNodes.getChildNode(nodeIndex, childIndex);
            int3 axisIndices = unpackOctreeChildIndex(childIndex);
            AABB childBox = shrinkBox(box, axisIndices);

            float2 nearFar;
            bool intersected = intersectRayAABB(origin, dir, childBox.minPoint, childBox.maxPoint, nearFar);
            if (intersected) {
                float near = length(dir * nearFar.x);
                float far = length(dir * nearFar.y);
                float density = parentDensity * child.density;
                if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                    // pdf += (pow(nearFar.y, 3) - pow(nearFar.x, 3)) * density / 3;
                    // pdf += (pow(nearFar.y, 3) - pow(nearFar.x, 3)) * density / (3 * childBox.volume());
                    // pdf += (nearFar.y - nearFar.x) * density;
                    pdf += (nearFar.y - nearFar.x) * density / childBox.volume();
                } else {
                    box = childBox;
                    // push node
                    nodesStack[nodesStackSize] = NodeTravRef(child.index);
                    parentDensities[nodesStackSize] = density;
                    ++nodesStackSize;
                }
            }

            ++nodesStack[topIndex].child;
        }
        ++failsafe;
    }
    return pdf;
}

SpatialRayData generateSpatialRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout SampleGenerator sg, float3 thp)
{
    SpatialRayData rayData;
    float3 dir = sampleDirectionByDensities(rayOrigin, sg);
    float pdf = getDirectionPdf(rayOrigin, dir);
    pdf += mi.evalPdf(sd, dir, true);
    float invPdf = 1 / pdf;

    rayData.origin = rayOrigin;
    rayData.direction = dir;
    rayData.radiance = float3(0, 0, 0);
    rayData.thp = thp * mi.eval(sd, dir, sg) * invPdf;

    return rayData;
}

/** Evaluates the direct illumination from analytic lights.
    This function samples Falcor's light list uniformly with one shadow ray.
    \param[in] sd Shading data.
    \param[in] mi Material instance.
    \param[in,out] sg SampleGenerator object.
    \return Outgoing radiance in view direction.
*/
float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0) return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

    // Sample local light source.
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls)) return float3(0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    float NdotL = dot(sd.getOrientedFaceNormal(), ls.dir);
    if ((NdotL <= kMinCosTheta && !hasTransmission) || (NdotL >= -kMinCosTheta && !hasReflection))
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Test visibility by tracing a shadow ray.
    bool V = traceShadowRay(origin, ls.dir, ls.distance);
    if (!V) return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

void generateGuidedRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData)
{
    float3 dir = sampleDirectionByDensities(rayOrigin, rayData.sg);

    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    float NdotL = dot(sd.getOrientedFaceNormal(), dir);
    // if ((NdotL <= kMinCosTheta && !hasTransmission) || (NdotL >= -kMinCosTheta && !hasReflection))
    //     return false;

    rayOrigin = computeRayOrigin(sd.posW, dot(sd.faceN, dir) >= 0.f ? sd.faceN : -sd.faceN);

    float pdf = getDirectionPdf(rayOrigin, dir);
    // maybe MIS in the future
    // pdf += mi.evalPdf(sd, dir, true);
    float invPdf = 1 / pdf;

    rayData.origin = rayOrigin;
    rayData.direction = dir;
    rayData.thp *= mi.eval(sd, dir, rayData.sg) * invPdf;
}

/** Generate a new scatter ray or terminate.
    \param[in] sd Shading data.
    \param[in] mi Material instance.
    \param[in] isCurveHit True if on curve hit.
    \param[in] rayOrigin Ray origin for the new ray.
    \param[in,out] rayData Ray payload.
    \return True if the path continues.
*/
bool generateScatterRay(const ShadingData sd, const IMaterialInstance mi, bool isCurveHit, float3 rayOrigin, inout ScatterRayData rayData)
{
    // Sample material.
    BSDFSample bsdfSample;
    if (mi.sample(sd, rayData.sg, bsdfSample, kUseImportanceSampling))
    {
        rayData.origin = rayOrigin;
        if (!isCurveHit && bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeRayOrigin(false);
        }
        rayData.direction = bsdfSample.wo;
        //float pdf = mi.evalPdf(sd, rayData.direction, kUseImportanceSampling);
        //float spatialPdf = getDirectionPdf(rayData.origin, rayData.direction);
        //float weight = pdf / (spatialPdf + pdf);
        //rayData.thp *= bsdfSample.weight * weight;
        rayData.thp *= bsdfSample.weight;
        return any(rayData.thp > 0.f);
    }

    return false;
}

float3 sampleSpherical(out float pdf, inout SampleGenerator sg)
{
    float phi = sampleNext1D(sg) * 2 * M_PI;
    float theta = sampleNext1D(sg) * M_PI;
    float sinTheta = sin(theta);
    pdf = getSphericalPdfSinTheta(sinTheta);
    return float3(
        cos(phi) * sinTheta,
        sin(phi) * sinTheta,
        cos(theta)
    );
}

float getSphericalPdfSinTheta(float sinTheta)
{
    return 1.0 / (2.0 * M_PI * M_PI * sinTheta);
}

// dir should be normalized
float getSphericalPdf(float3 dir)
{
    return getSphericalPdfSinTheta(acos(dir.z));
}

void generateSphericalRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData)
{
    float pdf;
    float3 dir = sampleSpherical(pdf, rayData.sg);
    float invPdf = 1 / pdf;

    rayData.origin = rayOrigin;
    rayData.direction = dir;
    rayData.thp *= mi.eval(sd, dir, rayData.sg) * invPdf;
}

// #define VIZ_DIR
#define VIZ_DIR_DEPTH 1

/** Process a hit.
    Loads the shading data, samples analytic lights and samples a new scatter ray.
    Terminates the path if maximum number of bounces is reached.
    \param[in] hit Hit info.
    \param[in,out] rayData Ray payload.

*/
void handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    const bool isCurveHit = hit.getType() == HitType::Curve;
    let lod = ExplicitLodTextureSampler(0.f);

    // Load shading data.
    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);

    // Create material instance.
    let mi = gScene.materials.getMaterialInstance(sd, lod);

#ifndef VIZ_DIR
    // Add emitted light.
    if (kUseEmissiveLights && (kComputeDirect || rayData.pathLength > 0))
    {
        rayData.radiance += rayData.thp * mi.getProperties(sd).emission;
        // rayData.radiance += mi.getProperties(sd).emission;
        // rayData.radiance = rayData.thp;
    }
#else
    if (rayData.pathLength == VIZ_DIR_DEPTH)
    {
        rayData.radiance = (rayData.direction + float3(1)) * 0.5;
    }
#endif

    // Check whether to terminate based on max depth.
    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.terminated = true;
        return;
    }

    // Compute ray origin for new rays spawned from the hit.
    float3 rayOrigin = sd.computeRayOrigin();

#ifndef VIZ_DIR
    // Add contribution of direct light from analytic lights.
    if (kUseAnalyticLights)
    {
        float3 Lr = evalDirectAnalytic(sd, mi, rayData.sg);
        rayData.radiance += rayData.thp * Lr;
    }
#endif

    // spatial ray sampling
    //if (kComputeDirect || rayData.pathLength > 0)
    //{
    //    SpatialRayData spatialRay = generateSpatialRay(sd, mi, rayOrigin, rayData.sg, rayData.thp);
    //    traceSpatialRay(spatialRay);
    //    bool v = traceShadowRay(rayOrigin, spatialRay.direction, length(spatialRay.hitPos - spatialRay.origin));
    //    if (v) {
    //        rayData.radiance += spatialRay.radiance;
    //    }
    //}

    if (sampleNext1D(rayData.sg) < gGuidedRayProb) {
        // Generate scatter ray for the next path segment.
        // The raygen shader will continue the path based on the returned payload.
        generateGuidedRay(sd, mi, rayOrigin, rayData);
        //generateSphericalRay(sd, mi, rayOrigin, rayData);
    } else {
        // Generate scatter ray for the next path segment.
        // The raygen shader will continue the path based on the returned payload.
        if (!generateScatterRay(sd, mi, isCurveHit, rayOrigin, rayData))
        {
            rayData.terminated = true;
            return;
        }

    }

    rayData.pathLength++;
}

/** This is the main entry point for the minimal path tracer.

    One path per pixel is generated, which is traced into the scene.
    The path tracer is written as a for-loop over path segments.

    Built-in light sources (point, directional) are sampled explicitly at each
    path vertex. The contributions from area lights (env map and mesh lights)
    are explicitly added by the scatter ray hit/miss shaders.

    \param[in] pixel Pixel to trace a path for.
    \param[in] frameDim Dimension of the frame in pixels.
    \return Returns the estimated color (radiance).
*/
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        // Pixel represents a valid primary hit. Compute its contribution
        let lod = ExplicitLodTextureSampler(0.f);

        // Load shading data.
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        // Create material instance at shading point.
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // Create sample generator.
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

        // Advance the generator to the first available dimension.
        // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
        for (uint i = 0; i < gPRNGDimension; i++) sampleNext1D(sg);

        // Compute ray origin for new rays spawned from the G-buffer.
        float3 rayOrigin = sd.computeRayOrigin();

        if (kComputeDirect)
        {
            // Always output directly emitted light, independent of whether emissive materials are treated as light sources or not.
            outColor += mi.getProperties(sd).emission;

            // Add contribution of direct light from analytic lights.
            // Light probe and mesh lights are handled by the scatter ray hit/miss shaders.
            outColor += kUseAnalyticLights ? evalDirectAnalytic(sd, mi, sg) : float3(0.f);
        }

        // spatial ray
        //if (kComputeDirect && kMaxBounces > 0)
        //{
        //    SpatialRayData spatialRay = generateSpatialRay(sd, mi, rayOrigin, sg, 1);
        //    traceSpatialRay(spatialRay);
        //    bool v = traceShadowRay(rayOrigin, spatialRay.direction, length(spatialRay.hitPos - spatialRay.origin));
        //    if (v) {
        //        outColor += spatialRay.radiance;
        //    }
        //}

        // Prepare ray payload.
        ScatterRayData rayData = ScatterRayData(sg);

        if (sampleNext1D(rayData.sg) < gGuidedRayProb) {
            // Generate scatter ray for the next path segment.
            // The raygen shader will continue the path based on the returned payload.
            generateGuidedRay(sd, mi, rayOrigin, rayData);
            //generateSphericalRay(sd, mi, rayOrigin, rayData);
        } else {
            // Generate scatter ray.
            if (!generateScatterRay(sd, mi, false, rayOrigin, rayData)) rayData.terminated = true;
        }

        // Follow path into the scene and compute its total contribution.
        for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
        {
            // Trace scatter ray. If it hits geometry, the closest hit shader samples
            // direct illumination and generates the next scatter ray.
            traceScatterRay(rayData);
        }

        // Store contribution from scatter ray.
        outColor += rayData.radiance;
        // test random gen
        // outColor = float3(sampleNext1D(sg), sampleNext1D(sg), sampleNext1D(sg));
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
}

//
// Shader entry points for miss shaders.
//

[shader("miss")]
void scatterMiss(inout ScatterRayData rayData)
{
    // Ray missed the scene. Mark the ray as terminated.
    rayData.terminated = true;

    // Add contribution from distant light (env map) in this direction.
    if (kUseEnvLight && (kComputeDirect || rayData.pathLength > 0))
    {
        float3 Le = gScene.envMap.eval(WorldRayDirection());
        rayData.radiance += rayData.thp * Le;
    }
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void scatterTriangleMeshAnyHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f)) IgnoreHit();
}

[shader("closesthit")]
void scatterTriangleMeshClosestHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    handleHit(HitInfo(triangleHit), rayData);
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f)) IgnoreHit();
}

// spatial rays

[shader("miss")]
void spatialMiss(inout SpatialRayData rayData)
{
    rayData.radiance = float3(0);
}

[shader("closesthit")]
void spatialTriangleMeshClosestHit(inout SpatialRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    HitInfo hit = HitInfo(triangleHit);

    let lod = ExplicitLodTextureSampler(0.f);

    // Load shading data.
    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);

    // Create material instance.
    let mi = gScene.materials.getMaterialInstance(sd, lod);

    rayData.hitPos = sd.computeRayOrigin();
    // rayData.radiance = float3(0);
    float distance2 = sqr(length(rayData.hitPos - rayData.origin));
    //rayData.radiance += (1 / distance2) * rayData.thp * mi.getProperties(sd).emission;
    rayData.radiance += rayData.thp * mi.getProperties(sd).emission;
}

[shader("anyhit")]
void spatialTriangleMeshAnyHit(inout SpatialRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    rayData.radiance = float3(0);
}

//
// Shader entry point for ray generation shader.
//

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;

    float3 color = tracePath(pixel, frameDim);

    gOutputColor[pixel] = float4(color, 1.f);
}
