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
import FocalShared;

ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;

ParameterBlock<DensityNodes> gOutNodes;
RWByteAddressBuffer gOutGlobalAccumulator;

cbuffer CB
{
    uint gNodesSize;
    float gUseNarrowing;
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
static const uint kMaxOctreeDepth = MAX_OCTREE_DEPTH;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

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

void storeDensitiesNoNarrowing(
    float3 rayOrigin,
    float3 rayDir,
    float3 hitPos,
    float contribution,
    uint nodesSize,
    ParameterBlock<DensityNodes> nodes,
    RWByteAddressBuffer globalAccumulator,
    ParameterBlock<DensityNodes> outNodes,
    RWByteAddressBuffer outGlobalAccumulator
) {
    if (contribution <= 0)
    {
        return;
    }

    float3 hitDir = hitPos - rayOrigin;
    float hitDist = length(hitDir);
    float rayLength = length(rayDir);
    float invGlobalAccumulator = 1 / globalAccumulator.Load<float>(0);

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
            float lengthWeight = (min(hitDist, far) - near) / rayLength;
            outGlobalAccumulator.InterlockedAddF32(0, lengthWeight * contribution);
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
                    float lengthWeight = (min(hitDist, far) - near) / rayLength;
                    outNodes.addToChildAccumulator(nodeIndex, childIndex, lengthWeight * contribution);
                    outNodes.setChildDensity(nodeIndex, childIndex, lengthWeight);
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

void storeDensitiesWithNarrowing(
    float3 rayOrigin,
    float3 rayDir,
    float3 hitPos,
    float contribution,
    uint nodesSize,
    ParameterBlock<DensityNodes> nodes,
    RWByteAddressBuffer globalAccumulator,
    ParameterBlock<DensityNodes> outNodes,
    RWByteAddressBuffer outGlobalAccumulator
) {
    if (contribution <= 0)
    {
        return;
    }

    float3 hitDir = hitPos - rayOrigin;
    float hitDist = length(hitDir);
    float rayLength = length(rayDir);
    float invGlobalAccumulator = 1 / globalAccumulator.Load<float>(0);

    NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
    uint nodesStackSize = 0;
    // push first node
    nodesStack[nodesStackSize] = NodeTravRef(0);
    ++nodesStackSize;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    uint failsafe = 0;

    float weightsSum = 0.0;
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
                    if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                        float lengthWeight = (min(hitDist, far) - near) / rayLength;
                        float densityTimesVolume = child.accumulator * invGlobalAccumulator / childBox.volume();
                        weightsSum += lengthWeight * densityTimesVolume;
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

    float weightStack[MAX_OCTREE_DEPTH];
    for (int i = 0; i < MAX_OCTREE_DEPTH; i++)
    {
        weightStack[i] = 0;
    }
    nodesStackSize = 0;
    // push first node
    nodesStack[nodesStackSize] = NodeTravRef(0);
    ++nodesStackSize;
    box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    failsafe = 0;

    float2 nearFar;
    bool intersected = intersectRayAABB(rayOrigin, rayDir, box.minPoint, box.maxPoint, nearFar);
    if (intersected) {
        float near = length(rayDir * nearFar.x);
        float far = length(rayDir * nearFar.y);
        if (near < hitDist) {
            outGlobalAccumulator.InterlockedAddF32(0, contribution);
        }
    }

    while (nodesStackSize > 0 && failsafe < 9 * nodesSize)
    {
        uint topIndex = nodesStackSize - 1;
        if (nodesStack[topIndex].child >= 8) {
            float weight = weightStack[topIndex];
            // pop node
            --nodesStackSize;
            // correct the box
            if (nodesStackSize > 0) {
                topIndex = nodesStackSize - 1;
                uint currChildIndex = nodesStack[topIndex].child - 1;
                int3 axisIndices = unpackOctreeChildIndex(currChildIndex);
                AABB childBox = box;
                box = extendBox(box, axisIndices);

                uint nodeIndex = nodesStack[topIndex].node;
                weightStack[topIndex] += weight;
                outNodes.addToChildAccumulator(nodeIndex, currChildIndex, weight * contribution / weightsSum);
                outNodes.setChildDensity(nodeIndex, currChildIndex, weight);
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
                    if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                        float lengthWeight = (min(hitDist, far) - near) / rayLength;
                        float densityTimesVolume = child.accumulator * invGlobalAccumulator / childBox.volume();
                        float weight = lengthWeight * densityTimesVolume;
                        outNodes.addToChildAccumulator(nodeIndex, childIndex, weight * contribution / weightsSum);
                        weightStack[topIndex] += weight;
                        // just for debug
                        outNodes.setChildDensity(nodeIndex, childIndex, weight);
                    } else {
                        box = childBox;
                        // push node
                        nodesStack[nodesStackSize] = NodeTravRef(child.index);
                        weightStack[nodesStackSize] = 0;
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

    // Add emitted light.
    if (rayData.pathLength > 0)
    {
        rayData.radiance += rayData.thp * mi.getProperties(sd).emission;
    }

    // Check whether to terminate based on max depth.
    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.terminated = true;
        return;
    }

    // Compute ray origin for new rays spawned from the hit.
    float3 rayOrigin = sd.computeRayOrigin();

    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    FocalShared focalShared = FocalShared(box, gGuidedRayProb, gNodes, gNodesSize, gGlobalAccumulator);
    float pdf = 0;
    if (!focalShared.generateRay(sd, mi, rayOrigin, rayData, pdf))
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

        AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
        FocalShared focalShared = FocalShared(box, gGuidedRayProb, gNodes, gNodesSize, gGlobalAccumulator);

        // Prepare ray payload.
        ScatterRayData rayData = ScatterRayData(sg);
        float pdf = 0;
        if (!focalShared.generateRay(sd, mi, rayOrigin, rayData, pdf))
        {
            rayData.terminated = true;
        }

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
            if (gUseNarrowing == 0)
            {
                storeDensitiesNoNarrowing(origin, dir, hitPos, contributions[depth], gNodesSize, gNodes, gGlobalAccumulator, gOutNodes, gOutGlobalAccumulator );
            }
            else
            {
                storeDensitiesWithNarrowing(origin, dir, hitPos, contributions[depth], gNodesSize, gNodes, gGlobalAccumulator, gOutNodes, gOutGlobalAccumulator );

            }
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
