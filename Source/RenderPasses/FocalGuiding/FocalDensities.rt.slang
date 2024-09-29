#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "Utils/NVAPI.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Geometry.IntersectionHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

import DensityNode;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;

cbuffer CB
{
    uint gNodesSize;
    float3 gSceneBoundsMin;
    float3 gSceneBoundsMax;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const uint kMaxOctreeDepth = MAX_OCTREE_DEPTH;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

/** Payload for scatter ray (up to 72B).
 */
struct ScatterRayData
{
    float3 radiance;  ///< Accumulated outgoing radiance from path.
    bool terminated;  ///< Set to true when path is terminated.
    float3 thp;       ///< Current path throughput. This is updated at each path vertex.
    uint pathLength;  ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;    ///< Next path segment origin.
    float3 direction; ///< Next path segment direction.
    //float pdf;

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).

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
        // this.pdf = 0.0;
    }
};

/** Payload for shadow ray.
 */
struct ShadowRayData
{
    bool visible;
};

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
    rayData.visible = false; // Set to true by miss shader if ray is not terminated before
    TraceRay( gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, ray, rayData );

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

    uint rayFlags = 0; // TODO: Set cull mode from the app
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
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
    if (mi.sample(sd, rayData.sg, bsdfSample, true))
    {
        rayData.origin = rayOrigin;
        if (!isCurveHit && bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeRayOrigin(false);
        }
        rayData.direction = bsdfSample.wo;
        rayData.thp = bsdfSample.weight;
        //rayData.pdf = bsdfSample.pdf;
        return any(rayData.thp > 0.f);
    }

    return false;
}

void storeDensities(
    float3 rayOrigin,
    float3 rayDir,
    float3 hitPos,
    float contribution,
    ParameterBlock<DensityNodes> nodes,
    uint nodesSize,
    RWByteAddressBuffer globalAccumulator
) {
    float maxDensity = 0.0;
    float3 hitDir = hitPos - rayOrigin;
    float hitDist = length(hitDir);
    float rayLength = length(rayDir);

    NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
    uint nodesStackSize = 0;
    // push first node
    nodesStack[nodesStackSize] = NodeTravRef(0);
    ++nodesStackSize;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    uint failsafe = 0;

    float2 nearFar;
    bool intersected = intersectRayAABB(rayOrigin, rayDir, box.minPoint, box.maxPoint, nearFar);
    if (intersected) {
        float near = length(rayDir * nearFar.x);
        float far = length(rayDir * nearFar.y);
        if (near < hitDist) {
            float length = (min(hitDist, far) - near) / rayLength;
            globalAccumulator.InterlockedAddF32(0, length * contribution);
        }
    }

    while (nodesStackSize > 0 && failsafe < 9 * nodesSize)
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
            DensityChild child = nodes.getChildNode(nodeIndex, childIndex);
            int3 axisIndices = unpackOctreeChildIndex(childIndex);
            AABB childBox = shrinkBox(box, axisIndices);

            float2 nearFar;
            bool intersected = intersectRayAABB(rayOrigin, rayDir, childBox.minPoint, childBox.maxPoint, nearFar);
            if (intersected) {
                float near = length(rayDir * nearFar.x);
                float far = length(rayDir * nearFar.y);
                if (near < hitDist) {
                    float length = (min(hitDist, far) - near) / rayLength;
                    nodes.addToChildAccumulator(nodeIndex, childIndex, length * contribution);
                    float parentAcc = 1;
                    if (nodesStackSize > 1) {
                        uint parentNodeIndex = nodesStack[topIndex - 1].node;
                        uint parentChildIndex = nodesStack[topIndex - 1].child - 1;
                        parentAcc = nodes.getChildAccumulator(parentNodeIndex, parentChildIndex);
                    } else {
                        parentAcc = globalAccumulator.Load<float>(0);
                    }
                    if (parentAcc <= 0) {
                        parentAcc = 1;
                    }
                    nodes.setChildDensity(nodeIndex, childIndex, nodes.getChildAccumulator(nodeIndex, childIndex) / parentAcc);
                    if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                    } else {
                        box = childBox;
                        // push node
                        nodesStack[nodesStackSize] = NodeTravRef(child.index);
                        ++nodesStackSize;
                    }
                }
            }

            ++nodesStack[topIndex].child;
        }
        ++failsafe;
    }

}

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

    if (rayData.pathLength > 0)
    {
        rayData.radiance += rayData.thp * mi.getProperties(sd).emission;
    }

    // Compute ray origin for new rays spawned from the hit.
    float3 nextRayOrigin = sd.computeRayOrigin();

    // Check whether to terminate based on max depth.
    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.origin = nextRayOrigin;
        rayData.terminated = true;
        return;
    }

    float contribution = dot(float3(0.299, 0.587, 0.114), rayData.radiance);
    storeDensities(rayData.origin, rayData.direction, nextRayOrigin, contribution, gNodes, gNodesSize, gGlobalAccumulator);

    // Generate scatter ray for the next path segment.
    // The raygen shader will continue the path based on the returned payload.
    if (!generateScatterRay(sd, mi, isCurveHit, nextRayOrigin, rayData))
    {
        rayData.terminated = true;
        return;
    }

    rayData.pathLength++;
}

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

        if (true)//kComputeDirect)
        {
            // Always output directly emitted light, independent of whether emissive materials are treated as light sources or not.
            outColor += mi.getProperties(sd).emission;
        }

        // Prepare ray payload.
        ScatterRayData rayData = ScatterRayData(sg);

        // Generate scatter ray.
        if (!generateScatterRay(sd, mi, false, rayOrigin, rayData)) rayData.terminated = true;

        float3 origins[MAX_BOUNCES + 2];
        float contributions[MAX_BOUNCES + 1];

        // Follow path into the scene and compute its total contribution.
        int depth = 0;
        for (; depth <= kMaxBounces && !rayData.terminated; depth++)
        {
            origins[depth] = rayData.origin;
            // Trace scatter ray. If it hits geometry, the closest hit shader samples
            // direct illumination and generates the next scatter ray.
            traceScatterRay(rayData);

            contributions[depth] = dot(float3(0.299, 0.587, 0.114), rayData.radiance);
        }
        int depthCount = depth;
        origins[depthCount] = rayData.origin;
        for (int depth = depthCount - 1; depth > 0; depth--) {
            contributions[depth] -= contributions[depth - 1];
        }
        for (int depth = depthCount - 2; depth >= 0; depth--) {
            contributions[depth] += contributions[depth + 1];
        }
        for (int depth = 0; depth < depthCount; depth++) {
            float3 origin = origins[depth];
            float3 hitPos = origins[depth + 1];
            float3 dir = normalizeSafe(hitPos - origin);
            storeDensities(origin, dir, hitPos, contributions[depth], gNodes, gNodesSize, gGlobalAccumulator);
        }

        // Store contribution from scatter ray.
        outColor += rayData.radiance;
    }
    else
    {
        // Background pixel.
        outColor = kDefaultBackgroundColor;
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
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f)) IgnoreHit();
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
