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

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)

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
    ray.TMax = FLT_MAX;

    uint rayFlags = 0; // TODO: Set cull mode from the app
    TraceRay(gScene.rtAccel, rayFlags, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
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

struct FocalShared
{
    AABB sceneBox;
    float guidedRayProb;
    ParameterBlock<DensityNodes> nodes;
    uint nodesSize;
    RWByteAddressBuffer globalAccumulator;

    __init(
        AABB _sceneBox,
        float _guidedRayProb,
        ParameterBlock<DensityNodes> _nodes,
        uint _nodesSize,
        RWByteAddressBuffer _globalAccumulator
    )
    {
        sceneBox = _sceneBox;
        guidedRayProb = _guidedRayProb;
        nodes = _nodes;
        nodesSize = _nodesSize;
        globalAccumulator = _globalAccumulator;
    }

    float3 samplePointByDensities(out float pdf, inout SampleGenerator sg)
    {
        AABB box = sceneBox;
        uint nodeIndex = 0;
        pdf = 1 / box.volume();

        float globalAcc = globalAccumulator.Load<float>(0);
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
                child = nodes.getChildNode(nodeIndex, childIndex);
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
        AABB box = sceneBox;
        float pdf = 0;
        NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
        uint nodesStackSize = 0;
        // push first node
        nodesStack[nodesStackSize] = NodeTravRef(0);
        ++nodesStackSize;

        float totalVolume = box.volume();
        float invGlobalAcc = 1 / globalAccumulator.Load<float>(0);

        uint failsafe = 0;
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

    float getMisPdf(const ShadingData sd, const IMaterialInstance mi, float3 origin, float3 dir)
    {
        float bsdfPdf = mi.evalPdf(sd, dir, true);
        float guidedPdf = getDirectionPdf(origin, dir);
        return guidedRayProb * guidedPdf + (1 - guidedRayProb) * bsdfPdf;
    }

    void generateGuidedRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData, out float pdf)
    {
        float3 dir = sampleDirectionByDensities(rayOrigin, rayData.sg);

        rayOrigin = computeRayOrigin(sd.posW, dot(sd.faceN, dir) >= 0.f ? sd.faceN : -sd.faceN);

        rayData.origin = rayOrigin;
        rayData.direction = dir;

        pdf = getMisPdf(sd, mi, rayOrigin, dir);
        rayData.thp *= mi.eval(sd, dir, rayData.sg) / pdf;
    }

    /** Generate a new scatter ray or terminate.
        \param[in] sd Shading data.
        \param[in] mi Material instance.
        \param[in] rayOrigin Ray origin for the new ray.
        \param[in,out] rayData Ray payload.
        \return True if the path continues.
    */
    bool generateBsdfRay( const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData, bool enableGuidedRays, out float pdf)
    {
        BSDFProperties miProps = mi.getProperties(sd);
        pdf = 0;
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
            if (!enableGuidedRays)
            {
                pdf = bsdfSample.pdf;
                rayData.thp *= bsdfSample.weight;
            }
            else
            {
                pdf = getMisPdf(sd, mi, rayOrigin, rayData.direction);
                rayData.thp *= mi.eval(sd, rayData.direction, rayData.sg) / pdf;
            }
            return any(rayData.thp > 0.f);
        }

        return false;
    }

    bool enableGuidedRaysForMaterial(const ShadingData sd, const IMaterialInstance mi)
    {
        BSDFProperties miProps = mi.getProperties(sd);
        return miProps.roughness > 0.1 && dot(miProps.diffuseTransmissionAlbedo, float3(1)) == 0 && dot(miProps.specularTransmissionAlbedo, float3(1)) == 0;
    }

    bool generateRay(const ShadingData sd, const IMaterialInstance mi, float3 rayOrigin, inout ScatterRayData rayData, out float pdf)
    {
        bool enableGuidedRays = enableGuidedRaysForMaterial(sd, mi);
        if (enableGuidedRays && sampleNext1D(rayData.sg) < guidedRayProb) {
            generateGuidedRay(sd, mi, rayOrigin, rayData, pdf);
            return true;
        } else {
            return generateBsdfRay(sd, mi, rayOrigin, rayData, enableGuidedRays, pdf);
        }
    }

    // spherical ray sampling

    float3 sampleSpherical(float3 normal, float3 tangent, out bool isOut, out float pdf, inout SampleGenerator sg)
    {
        float3 X = tangent;
        float3 Y = cross(normal, tangent);
        float3 Z = normal;
        float phi = sampleNext1D(sg) * 2 * M_PI;
        float theta = sampleNext1D(sg) * M_PI;
        isOut = theta <= M_PI * 0.5;
        float sinTheta = sin(theta);
        pdf = getSphericalPdfSinTheta(sinTheta);
        return
            X * cos(phi) * sinTheta +
            Y * sin(phi) * sinTheta +
            Z * cos(theta)
        ;
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
        bool isOut;
        float3 dir = sampleSpherical(sd.faceN, normalize(sd.tangentW.xyz), isOut, pdf, rayData.sg);
        float invPdf = 1 / pdf;

        rayOrigin = computeRayOrigin(sd.posW, isOut ? sd.faceN : -sd.faceN);

        rayData.origin = rayOrigin;
        rayData.direction = dir;
        rayData.thp *= mi.eval(sd, dir, rayData.sg) * invPdf;
    }

    /** Process a hit.
        Loads the shading data, samples analytic lights and samples a new scatter ray.
        Terminates the path if maximum number of bounces is reached.
        \param[in] hit Hit info.
        \param[in,out] rayData Ray payload.

    */
    void handleHit(const HitInfo hit, inout ScatterRayData rayData, bool useAnalyticLights, bool useEmissiveLights, bool computeDirect, bool stopOnEmissive)
    {
        let lod = ExplicitLodTextureSampler(0.f);

        // Load shading data.
        ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);

        // Create material instance.
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // Compute ray origin for new rays spawned from the hit.
        float3 rayOrigin = sd.computeRayOrigin();

        // Add emitted light.
        if (useEmissiveLights && (computeDirect || rayData.pathLength > 0))
        {
            float3 emission = mi.getProperties(sd).emission;
            rayData.radiance += rayData.thp * emission;
            if (stopOnEmissive && dot(emission, float3(1)) > 0.001)
            {
                rayData.terminated = true;
                rayData.origin = rayOrigin;
                return;
            }
        }

        // Check whether to terminate based on max depth.
        if (rayData.pathLength >= MAX_BOUNCES)
        {
            rayData.terminated = true;
            rayData.origin = rayOrigin;
            return;
        }

        // Add contribution of direct light from analytic lights.
        if (useAnalyticLights)
        {
            float3 Lr = evalDirectAnalytic(sd, mi, rayData.sg);
            rayData.radiance += rayData.thp * Lr;
        }

        float pdf = 0;
        // Generate scatter ray for the next path segment.
        // The raygen shader will continue the path based on the returned payload.
        if (!generateRay(sd, mi, rayOrigin, rayData, pdf))
        {
            rayData.terminated = true;
            rayData.origin = rayOrigin;
            return;
        }

        rayData.pathLength++;
    }
}
