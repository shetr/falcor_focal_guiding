#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Geometry.IntersectionHelpers;
import Rendering.Lights.LightHelpers;

import DensityNode;

// StructuredBuffer<DensityNode> gNodes;
ParameterBlock<DensityNodes> gNodes;
RWByteAddressBuffer gGlobalAccumulator;

cbuffer CB
{
    uint gFrameCount;
    uint gNodesSize;
    float3 gSceneBoundsMin;
    float3 gSceneBoundsMax;
    float gMinDensity;
    float gMaxDensity;
    // colors
    float3 gVizColors[VIZ_COLORS_COUNT];
    bool gBlendFromScene;
    bool gNormalsViz;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxOctreeDepth = MAX_OCTREE_DEPTH;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;
// static const float3 kMinColor = float3(0.5, 0.5, 0);
static const float3 kMinColor = float3(1, 1, 0);
static const float3 kMaxColor = float3(1, 0, 0);

float3 getVizColor(float t)
{
    float scaled = t * (VIZ_COLORS_COUNT - 1);
    for (int i = 0; i < VIZ_COLORS_COUNT - 1; i++)
    {
        if (scaled >= i && scaled <= i + 1)
        {
            t = scaled - (float)i;
            return (1 - t) * gVizColors[i] + t * gVizColors[i + 1];
        }
    }
    return gVizColors[VIZ_COLORS_COUNT - 1];
}

struct ScatterRayData
{
    float3 radiance;  ///< Accumulated outgoing radiance from path.
    bool terminated;  ///< Set to true when path is terminated.
    float3 thp;       ///< Current path throughput. This is updated at each path vertex.
    uint pathLength;  ///< Path length in number of path segments (0 at origin, 1 at first secondary hit, etc.). Max 2^31.
    float3 origin;    ///< Next path segment origin.
    float3 direction; ///< Next path segment direction.

    /** Initializes ray payload with default parameters.
     */
    __init()
    {
        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.thp = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
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

        // Compute ray origin for new rays spawned from the G-buffer.
        float3 rayOrigin = sd.computeRayOrigin();

        //outColor += mi.getProperties(sd).emission;
        //outColor += mi.getProperties(sd).diffuseReflectionAlbedo;
        float cosTheta = abs(dot(sd.V, sd.faceN));
        outColor += float3(cosTheta);

        float globlaAcc = gGlobalAccumulator.Load<float>(0);

        MaxDensityAccumulator densityAcc;
        //BoundedDensityAccumulator densityAcc = BoundedDensityAccumulator(gMinDensity, gMaxDensity);
        float3 hitDir = rayOrigin - primaryRayOrigin;
        float hitDist = length(hitDir);
        float nodeMultiplier = 1.0;

        NodeTravRef nodesStack[MAX_OCTREE_DEPTH];
        float parentDensities[MAX_OCTREE_DEPTH];
        uint nodesStackSize = 0;
        // push first node
        nodesStack[nodesStackSize] = NodeTravRef(0);
        parentDensities[nodesStackSize] = 1;
        ++nodesStackSize;
        AABB box = AABB(gSceneBoundsMin, gSceneBoundsMax);
        uint failsafe = 0;
        // TODO: make the execution order from front or back, to make it possible to visualize with additive transparency
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
                    nodeMultiplier *= 0.125;
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
                bool intersected = intersectRayAABB(primaryRayOrigin, primaryRayDir, childBox.minPoint, childBox.maxPoint, nearFar);
                if (intersected) {
                    float near = length(primaryRayDir * nearFar.x);
                    float far = length(primaryRayDir * nearFar.y);
                    if (near < hitDist || !gBlendFromScene) {
                        //float density = parentDensity * child.density;
                        float density = nodeMultiplier * child.accumulator / globlaAcc;
                        if (child.isLeaf() || nodesStackSize >= MAX_OCTREE_DEPTH) {
                            //densityAcc.addDensity(density / (float)gFrameCount);
                            densityAcc.addDensity(density);
                        } else {
                            box = childBox;
                            // push node
                            nodesStack[nodesStackSize] = NodeTravRef(child.index);
                            parentDensities[nodesStackSize] = density;
                            nodeMultiplier *= 8.0;
                            ++nodesStackSize;
                        }
                    }
                }

                ++nodesStack[topIndex].child;
            }
            ++failsafe;
        }

        float t = densityAcc.getResult();
        t = (clamp(t, gMinDensity, gMaxDensity) - gMinDensity) / (gMaxDensity - gMinDensity);
        //float3 densityVizColor = kMinColor * (1 - t) + kMaxColor * t;
        float3 densityVizColor = getVizColor(t);

        if (gBlendFromScene)
        {
            outColor = outColor * (1 - t) + densityVizColor * t;
        }
        else
        {
            outColor = densityVizColor;
        }

        if (gNormalsViz)
        {
            outColor = (sd.getOrientedFaceNormal() + float3(1)) * 0.5;
        }
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
}

[shader("closesthit")]
void scatterTriangleMeshClosestHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
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
