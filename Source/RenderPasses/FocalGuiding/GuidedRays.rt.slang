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
import FocalShared;
import GuidedRayLine;

ParameterBlock<DensityNodes> gNodes;
RWStructuredBuffer<GuidedRayLine> gGuidedRayLines;
RWByteAddressBuffer gGlobalAccumulator;

cbuffer CB
{
    uint gNodesSize;
    float2 gGuidedRaysPos;
    uint gGuidedRayLinesSize;
    uint gLinesPathLenght;
    float gGenRadius;
    float3 gSceneBoundsMin;
    float3 gSceneBoundsMax;
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gPRNGDimension; // First available PRNG dimension.
    float gGuidedRayProb;
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
    if (USE_EMISSIVE_LIGHTS && (COMPUTE_DIRECT || rayData.pathLength > 0))
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
    if (rayData.pathLength >= gLinesPathLenght)
    {
        rayData.terminated = true;
        return;
    }

    // Compute ray origin for new rays spawned from the hit.
    float3 rayOrigin = sd.computeRayOrigin();

#ifndef VIZ_DIR
    // Add contribution of direct light from analytic lights.
    if (USE_ANALYTIC_LIGHTS)
    {
        float3 Lr = evalDirectAnalytic(sd, mi, rayData.sg);
        rayData.radiance += rayData.thp * Lr;
    }
#endif

    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    FocalShared focalShared = FocalShared(box, gGuidedRayProb, gNodes, gNodesSize, gGlobalAccumulator);
    float pdf = 0;
    // Generate scatter ray for the next path segment.
    // The raygen shader will continue the path based on the returned payload.
    if (!focalShared.generateRay(sd, mi, rayOrigin, rayData, pdf))
    {
        rayData.terminated = true;
        return;
    }

    rayData.pathLength++;
}

float3 tracePath(const uint2 inPixel, const uint2 frameDim)
{
    uint rayIndex = inPixel.x + inPixel.y * frameDim.x;

    // Create sample generator.
    SampleGenerator sg = SampleGenerator(inPixel, gFrameCount);

    float radius = sampleNext1D(sg) * gGenRadius;
    float theta = sampleNext1D(sg) * 2 * M_PI;
    float shrinkX = ((float)frameDim.y) / ((float)frameDim.x);
    float2 rayOffset = float2(radius * shrinkX * cos(theta), radius * sin(theta));
    uint2 rayStartPixel = uint2((gGuidedRaysPos + rayOffset) * float2(frameDim));

    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(rayStartPixel, frameDim, gScene.camera);

    const HitInfo hit = HitInfo(gVBuffer[rayStartPixel]);
    if (hit.isValid())
    {
        // Pixel represents a valid primary hit. Compute its contribution
        let lod = ExplicitLodTextureSampler(0.f);

        // Load shading data.
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        // Create material instance at shading point.
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // Advance the generator to the first available dimension.
        // TODO: This is potentially expensive. We may want to store/restore the state from memory if it becomes a problem.
        for (uint i = 0; i < gPRNGDimension; i++) sampleNext1D(sg);

        // Compute ray origin for new rays spawned from the G-buffer.
        float3 rayOrigin = sd.computeRayOrigin();

        if (COMPUTE_DIRECT)
        {
            // Always output directly emitted light, independent of whether emissive materials are treated as light sources or not.
            outColor += mi.getProperties(sd).emission;

            // Add contribution of direct light from analytic lights.
            // Light probe and mesh lights are handled by the scatter ray hit/miss shaders.
            outColor += USE_ANALYTIC_LIGHTS ? evalDirectAnalytic(sd, mi, sg) : float3(0.f);
        }

        if (rayIndex < gGuidedRayLinesSize / gLinesPathLenght)
        {
            AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
            FocalShared focalShared = FocalShared(box, gGuidedRayProb, gNodes, gNodesSize, gGlobalAccumulator);
            // Prepare ray payload.
            ScatterRayData rayData = ScatterRayData(sg);
            float prob = 0;
            if (!focalShared.generateRay(sd, mi, rayOrigin, rayData, prob))
            {
                rayData.terminated = true;
            }
            if (gLinesPathLenght == 1)
            {
                gGuidedRayLines[rayIndex].pos1 = rayData.origin;
                gGuidedRayLines[rayIndex].pos2 = rayData.origin + rayData.direction * prob;
                gGuidedRayLines[rayIndex].color = rayData.radiance;

                rayData = ScatterRayData(rayData.sg);
            }
            else
            {
                for (int l = 0; l < gLinesPathLenght; l++)
                {
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].pos1 = rayData.origin;
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].color = rayData.radiance;
                    traceScatterRay(rayData);
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].pos2 = rayData.origin;
                }
                rayData = ScatterRayData(rayData.sg);
            }
        }


        // Follow path into the scene and compute its total contribution.
        //for (uint depth = 0; depth <= MAX_BOUNCES && !rayData.terminated; depth++)
        //{
        //    // Trace scatter ray. If it hits geometry, the closest hit shader samples
        //    // direct illumination and generates the next scatter ray.
        //    traceScatterRay(rayData);
        //}
    }

    return float3(1);
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
    if (USE_ENV_LIGHT && (COMPUTE_DIRECT || rayData.pathLength > 0))
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
