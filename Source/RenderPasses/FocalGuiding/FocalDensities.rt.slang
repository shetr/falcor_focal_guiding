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

float3 samplePointByDensities(out float pdf, inout SampleGenerator sg)
{
    uint nodeIndex = 0;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    pdf = 1 / box.volume();

    float globalAcc = gGlobalAccumulator.Load<float>(0);
    float parentAcc = globalAcc;

    uint depth = 0;
    while (depth < MAX_OCTREE_DEPTH)
    {
        float r = sampleNext1D(sg);
        float stop = r * parentAcc;
        float acc = 0;
        uint childIndex = 0;
        DensityChild child;
        for (childIndex = 0; childIndex < 8; ++childIndex) {
            child = gNodes.getChildNode(nodeIndex, childIndex);
            acc += child.accumulator;
            if (stop < acc) {
                break;
            }
        }
        if (childIndex >= 8) {
            childIndex = uint(r * 8);
        }
        int3 axisIndices = unpackOctreeChildIndex(childIndex);
        AABB childBox = shrinkBox(box, axisIndices);
        nodeIndex = child.index;
        box = childBox;
        if (child.isLeaf()) {
            pdf *= child.accumulator / globalAcc;
            break;
        }
        parentAcc = child.accumulator;
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
    uint nodesStackSize = 0;
    // push first node
    nodesStack[nodesStackSize] = NodeTravRef(0);
    ++nodesStackSize;
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);

    float totalVolume = box.volume();
    float invGlobalAcc = 1 / gGlobalAccumulator.Load<float>(0);

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
            DensityChild child = gNodes.getChildNode(nodeIndex, childIndex);
            int3 axisIndices = unpackOctreeChildIndex(childIndex);
            AABB childBox = shrinkBox(box, axisIndices);

            float2 nearFar;
            bool intersected = intersectRayAABB(origin, dir, childBox.minPoint, childBox.maxPoint, nearFar);
            if (intersected) {
                float near = length(dir * nearFar.x);
                float far = length(dir * nearFar.y);
                float densityTimesVolume = child.accumulator * invGlobalAcc;
                if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                    // TODO: maybe divide the volume by total volume
                    pdf += (pow(nearFar.y, 3) - pow(nearFar.x, 3)) * densityTimesVolume / (3 * childBox.volume());
                } else {
                    box = childBox;
                    // push node
                    nodesStack[nodesStackSize] = NodeTravRef(child.index);
                    ++nodesStackSize;
                }
            }

            ++nodesStack[topIndex].child;
        }
        ++failsafe;
    }
    return pdf;
}

float getMisWeight(const ShadingData sd, const IMaterialInstance mi, float3 origin, float3 dir, out float guidedPdf)
{
    float bsdfPdf = mi.evalPdf(sd, dir, true);
    guidedPdf = getDirectionPdf(origin, dir);
    return 1 / (gGuidedRayProb * guidedPdf + (1 - gGuidedRayProb) * bsdfPdf);
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
    // rayOrigin = sd.computeRayOrigin(dot(dir, sd.faceN) >= 0.f);
    // if ((sd.frontFacing && dot(dir, sd.faceN) <= 0.f) || (!sd.frontFacing && dot(dir, sd.faceN) <= 0.f)) {
    //    rayOrigin = sd.computeRayOrigin(false);
    //}

    rayData.origin = rayOrigin;
    rayData.direction = dir;

    // float pdf = getDirectionPdf(rayOrigin, dir);
    // float invPdf = 1 / pdf;
    // rayData.thp *= mi.eval(sd, dir, rayData.sg) * invPdf;

    float guidedPdf;
    float misWeight = getMisWeight(sd, mi, rayOrigin, dir, guidedPdf);
    rayData.thp *= mi.eval(sd, dir, rayData.sg) * misWeight;
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
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeRayOrigin(false);
        }
        rayData.direction = bsdfSample.wo;
        float guidedPdf;
        float misWeight = getMisWeight(sd, mi, rayData.origin, rayData.direction, guidedPdf);
        rayData.thp *= mi.eval(sd, rayData.direction, rayData.sg) * misWeight;
        return any(rayData.thp > 0.f);
    }

    return false;
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

    if (sampleNext1D(rayData.sg) < gGuidedRayProb) {
        // Generate scatter ray for the next path segment.
        // The raygen shader will continue the path based on the returned payload.
        generateGuidedRay(sd, mi, rayOrigin, rayData);
        // generateSphericalRay(sd, mi, rayOrigin, rayData);
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

        if (sampleNext1D(rayData.sg) < gGuidedRayProb) {
            // Generate scatter ray for the next path segment.
            // The raygen shader will continue the path based on the returned payload.
            generateGuidedRay(sd, mi, rayOrigin, rayData);
        } else {
            // Generate scatter ray.
            if (!generateScatterRay(sd, mi, false, rayOrigin, rayData)) rayData.terminated = true;
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
