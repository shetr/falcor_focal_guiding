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
                gGuidedRayLines[rayIndex].color = float3(prob);
            }
            else
            {
                float maxIntensity = 0.0;
                float3 maxRadiance = float3(0.0);
                int maxIntensityIndex = 0;
                for (int l = 0; l < gLinesPathLenght; l++)
                {
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].pos1 = rayData.origin;
                    traceScatterRay(rayData);
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].pos2 = rayData.origin;
                    float intensity = dot(float3(0.299, 0.587, 0.114), rayData.radiance);
                    if (intensity > maxIntensity)
                    {
                        maxIntensity = intensity;
                        maxRadiance = rayData.radiance;
                        maxIntensityIndex = l;
                    }
                }

                for (int l = 0; l < gLinesPathLenght; l++)
                {
                    float3 storeRadiance = float3(0.0);
                    if (l <= maxIntensityIndex)
                    {
                        storeRadiance = maxRadiance;
                    }
                    gGuidedRayLines[rayIndex * gLinesPathLenght + l].color = storeRadiance;
                }
            }
        }
    }

    float3 outColor = float3(0.0);

    float2 pixelSquareDimDist = float2(1.0, shrinkX) * sqr(float2(inPixel) / float2(frameDim) - gGuidedRaysPos);
    float pixelSquareDist = pixelSquareDimDist.x + pixelSquareDimDist.y;

    if (pixelSquareDist >  sqr(gGenRadius) && pixelSquareDist <  sqr(gGenRadius + 0.001))
    {
        outColor = float3(0.2);
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
    AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
    FocalShared focalShared = FocalShared(box, gGuidedRayProb, gNodes, gNodesSize, gGlobalAccumulator);
    focalShared.handleHit(HitInfo(triangleHit), rayData, false, true, true, false);
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
