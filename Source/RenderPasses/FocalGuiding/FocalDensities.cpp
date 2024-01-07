#include "FocalDensities.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/FocalDensities.rt.slang";

// Ray tracing settings that affect the traversal stack size.
// These should be set as small as possible.
const uint32_t kMaxPayloadSizeBytes = 72u;
const uint32_t kMaxRecursionDepth = 2u;

const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    {"vbuffer", "gVBuffer", "Visibility buffer in packed format"},
    {kInputViewDir, "gViewW", "World-space view direction (xyz float format)", true /* optional */},
};

const ChannelList kOutputChannels = {
    {"color", "gOutputColor", "Output color (sum of direct and indirect)", false, ResourceFormat::RGBA32Float},
};
} // namespace

FocalDensities::FocalDensities(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Properties FocalDensities::getProperties() const
{
    return {};
}

RenderPassReflection FocalDensities::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void FocalDensities::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged))
    {
        throw RuntimeError("DirectRayTracer: This render pass does not support scene geometry changes.");
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    // Configure depth-of-field.
    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    mTracer.pProgram->addDefine("MAX_OCTREE_DEPTH", std::to_string(mMaxOctreeDepth));
    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    // TODO: This should be moved to a more general mechanism using Slang.
    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.
    if (!mTracer.pVars)
        prepareVars();
    FALCOR_ASSERT(mTracer.pVars);

    // Set constants.
    auto var = mTracer.pVars->getRootVar();
    var["CB"]["gNodesSize"] = mNodesSize;
    var["CB"]["gSceneBoundsMin"] = mpScene->getSceneBounds().minPoint;
    var["CB"]["gSceneBoundsMax"] = mpScene->getSceneBounds().maxPoint;

    Dictionary& dict = renderData.getDictionary();
    dict["gNodes"] = mNodes;
    dict["gNodesSize"] = mNodesSize;
    dict["gMaxOctreeDepth"] = mMaxOctreeDepth;
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);

    var["gNodes"] = mNodes;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));
}

void FocalDensities::renderUI(Gui::Widgets& widget)
{}

void FocalDensities::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;

    // Set new scene.
    mpScene = pScene;

    if (mpScene)
    {
        if (pScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("DirectRayTracer: This render pass does not support custom primitives.");
        }

        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        auto& sbt = mTracer.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("scatterMiss"));
        sbt->setMiss(1, desc.addMiss("shadowMiss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(
                0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit")
            );
            sbt->setHitGroup(
                1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", "shadowTriangleMeshAnyHit")
            );
        }

        mTracer.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());
    }
}

void FocalDensities::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    // Configure program.
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);

    auto var = mTracer.pVars->getRootVar();
    ResourceBindFlags bindFlags = ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess;
    MemoryType memoryType = MemoryType::DeviceLocal;
    DensityNode initDensities[1] = {DensityNode{
        {{0, 0.0f, 0.5f},
         {0, 0.0f, 0.9f},
         {0, 0.0f, 0.5f},
         {0, 0.0f, 0.9f},
         {0, 0.0f, 0.5f},
         {0, 0.0f, 0.9f},
         {0, 0.0f, 0.5f},
         {0, 0.0f, 1.0f}}}};
    std::vector<DensityNode> densityNodes = genUniformNodes(mMaxOctreeDepth, false);
    mNodesSize = (uint)densityNodes.size();
    mNodes = mpDevice->createStructuredBuffer(var["gNodes"], mNodesSize, bindFlags, memoryType, densityNodes.data());
    mpSampleGenerator->bindShaderData(var);
}

float genRand()
{
    return 0.1f + 0.9f*static_cast<float>(rand()) / static_cast<float>(RAND_MAX);
}

DensityNode randNode()
{
    return DensityNode{
        {{0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()},
         {0, 0.0f, genRand()}}};
}

DensityNode emptyNode()
{
    return DensityNode{
        {{0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f},
         {0, 0.0f, 0.0f}}};
}

std::vector<DensityNode> FocalDensities::genUniformNodes(uint depth, bool random) const
{
    std::vector<DensityNode> nodes;
    uint ni = 0;
    uint nc = 1;
    if (depth == 1)
    {
        if (random)
        {
            nodes.push_back(randNode());
        }
        else
        {
            nodes.push_back(emptyNode());
        }
    }
    else
    {
        nodes.push_back(emptyNode());
    }
    for (uint d = 0; d < depth - 1; ++d)
    {
        for (uint i = ni; i < ni + nc; ++i)
        {
            for (int ch = 0; ch < 8; ++ch)
            {
                nodes[i].childs[ch].index = (uint)nodes.size();
                if (d < depth - 2)
                {
                    nodes.push_back(emptyNode());
                }
                else
                {
                    if (random)
                    {
                        nodes.push_back(randNode());
                    }
                    else
                    {
                        nodes.push_back(emptyNode());
                    }
                }
            }
        }
        ni += nc;
        nc *= 8;
    }
    return nodes;
}

std::vector<DensityNode> FocalDensities::genRandomNodes() const
{
    std::vector<DensityNode> nodes;
    const size_t max_nodes = 30;
    nodes.push_back(randNode());
    for (int ni = 0; nodes.size() < max_nodes && ni < nodes.size(); ++ni)
    {
        DensityNode& node = nodes[ni];
        for (DensityChild& child : node.childs)
        {
            if (genRand() < 0.5f && nodes.size() < max_nodes)
            {
                child.index = (uint)nodes.size();
                nodes.push_back(randNode());
            }
        }
    }
    return nodes;
}
