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

    float getMisWeight(const ShadingData sd, const IMaterialInstance mi, float3 origin, float3 dir)
    {
        float bsdfPdf = mi.evalPdf(sd, dir, USE_IMPORTANCE_SAMPLING);
        float guidedPdf = getDirectionPdf(origin, dir);
        return 1 / (guidedRayProb * guidedPdf + (1 - guidedRayProb) * bsdfPdf);
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

        float misWeight = getMisWeight(sd, mi, rayOrigin, dir);
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
    bool generateScatterRay(const ShadingData sd, const IMaterialInstance mi, bool isCurveHit, float3 rayOrigin, inout ScatterRayData rayData, bool enableGuidedRays)
    {
        BSDFProperties miProps = mi.getProperties(sd);
        // Sample material.
        BSDFSample bsdfSample;
        if (mi.sample(sd, rayData.sg, bsdfSample, USE_IMPORTANCE_SAMPLING))
        {
            rayData.origin = rayOrigin;
            if (bsdfSample.isLobe(LobeType::Transmission))
            {
                rayData.origin = sd.computeRayOrigin(false);
            }
            rayData.direction = bsdfSample.wo;
            //float guidedPdf = getDirectionPdf(rayData.origin, rayData.direction);
            //rayData.thp *= mi.eval(sd, rayData.direction, rayData.sg) / mi.evalPdf(sd, rayData.direction, USE_IMPORTANCE_SAMPLING);
            // float3 fwiwo_dotwon = bsdfSample.weight * bsdfSample.pdf;
            // rayData.thp *= fwiwo_dotwon / bsdfSample.pdf;
            if (!enableGuidedRays)
            {
                rayData.thp *= bsdfSample.weight;
            }
            else
            {
                float misWeight = getMisWeight(sd, mi, rayOrigin, rayData.direction);
                rayData.thp *= mi.eval(sd, rayData.direction, rayData.sg) * misWeight;
            }
            return any(rayData.thp > 0.f);
        }

        return false;
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

}
