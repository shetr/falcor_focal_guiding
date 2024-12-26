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

const char kMaxPassCount[] = "maxPasses";
const char kLimitedPasses[] = "limitedPasses";
const char kUseRelativeContributions[] = "useRelativeContributions";
const char kUseNarrowing[] = "useNarrowing";
const char kNarrowFactor[] = "narrowFactor";
const char kNarrowFromPass[] = "narrowFromPass";
const char kNarrowEachNthPass[] = "narrowEachNthPass";
const char kMaxNodesSize[] = "maxNodesSize";
const char kInitOctreeDepth[] = "initOctreeDepth";
const char kMaxOctreeDepth[] = "maxOctreeDepth";
const char kDecay[] = "decay";
const char kUseAnalyticLights[] = "useAnalyticLights";
const char kIntegrateLastHits[] = "mIntegrateLastHits";
} // namespace

FocalDensities::FocalDensities(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxPassCount)
            mMaxPassCount = value;
        else if (key == kLimitedPasses)
            mLimitedPasses = value;
        else if (key == kUseRelativeContributions)
            mUseRelativeContributions = value;
        else if (key == kUseNarrowing)
            mUseNarrowing = value;
        else if (key == kNarrowFactor)
            mNarrowFactor = value;
        else if (key == kNarrowFromPass)
            mNarrowFromPass = value;
        else if (key == kNarrowEachNthPass)
            mNarrowEachNthPass = value;
        else if (key == kMaxNodesSize)
            mMaxNodesSize = value;
        else if (key == kInitOctreeDepth)
            mInitOctreeDepth = value;
        else if (key == kMaxOctreeDepth)
            mMaxOctreeDepth = value;
        else if (key == kDecay)
            mDecay = value;
        else if (key == kUseAnalyticLights)
            mUseAnalyticLights = value;
        else if (key == kIntegrateLastHits)
            mIntegrateLastHits = value;
        else
            logWarning("Unknown property '{}' in FocalDensities properties.", key);
    }

    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Properties FocalDensities::getProperties() const
{
    Properties props;
    props[kMaxPassCount] = mMaxPassCount;
    props[kLimitedPasses] = mLimitedPasses;
    props[kUseRelativeContributions] = mUseRelativeContributions;
    props[kUseNarrowing] = mUseNarrowing;
    props[kNarrowFactor] = mNarrowFactor;
    props[kNarrowFromPass] = mNarrowFromPass;
    props[kNarrowEachNthPass] = mNarrowEachNthPass;
    props[kMaxNodesSize] = mMaxNodesSize;
    props[kInitOctreeDepth] = mInitOctreeDepth;
    props[kMaxOctreeDepth] = mMaxOctreeDepth;
    props[kDecay] = mDecay;
    props[kUseAnalyticLights] = mUseAnalyticLights;
    props[kIntegrateLastHits] = mIntegrateLastHits;
    return props;
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
    mTracer.pProgram->addDefine("MAX_NODES_SIZE", std::to_string(mMaxNodesSize));
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
    var["CB"]["gUseRelativeContributions"] = mUseRelativeContributions;
    var["CB"]["gUseNarrowing"] = (mUseNarrowing && mNarrowFromPass <= mPassCount && (mPassCount % mNarrowEachNthPass == 0)) ? 1.0f : 0.0f;
    var["CB"]["gNarrowFactor"] = mNarrowFactor;
    var["CB"]["gSceneBoundsMin"] = mpScene->getSceneBounds().minPoint;
    var["CB"]["gSceneBoundsMax"] = mpScene->getSceneBounds().maxPoint;
    var["CB"]["gGuidedRayProb"] = mGuidedRayProb;
    var["CB"]["gUseAnalyticLights"] = mUseAnalyticLights;
    var["CB"]["gIntegrateLastHits"] = mIntegrateLastHits;

    Dictionary& dict = renderData.getDictionary();
    dict["gNodes"] = mNodes;
    if (!dict.keyExists("gNodesSize") || mPassCount == 0)
    {
        dict["gNodesSize"] = mNodesSize;
    }
    else
    {
        mNodesSize = dict["gNodesSize"];
    }
    dict["gGlobalAccumulator"] = mGlobalAccumulator;
    dict["gMaxNodesSize"] = mMaxNodesSize;
    dict["gMaxOctreeDepth"] = mMaxOctreeDepth;
    dict["gLimitedPasses"] = mLimitedPasses;
    dict["gPassCount"] = mPassCount;
    dict["gMaxPassCount"] = mMaxPassCount;
    dict["gNarrowFromPass"] = mNarrowFromPass;
    dict["gNarrowEachNthPass"] = mNarrowEachNthPass;
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

    if (!mPause && (!mLimitedPasses || mPassCount < mMaxPassCount))
    {
        {
            mTempLocalNodes.resize(mMaxNodesSize);
            mNodes->getBlob(mTempLocalNodes.data(), 0, mMaxNodesSize * sizeof(DensityNode));
            for (size_t i = 0; i < mTempLocalNodes.size(); i++)
            {
                for (size_t ch = 0; ch < 8; ch++)
                {
                    mTempLocalNodes[i].childs[ch].accumulator *= mDecay;
                }
            }
            mTempNodes->setBlob(mTempLocalNodes.data(), 0, mMaxNodesSize * sizeof(DensityNode));
            float globalAccumulator = mGlobalAccumulator->getElement<float>(0) * mDecay;
            mTempGlobalAccumulator->setElement(0, globalAccumulator);
        }

        auto nodes_var = mpNodesBlock->getRootVar();
        nodes_var["nodes"] = mNodes;
        auto temp_nodes_var = mpTempNodesBlock->getRootVar();
        temp_nodes_var["nodes"] = mTempNodes;

        var["gNodes"] = mpNodesBlock;
        var["gGlobalAccumulator"] = mGlobalAccumulator;
        var["gOutNodes"] = mpTempNodesBlock;
        var["gOutGlobalAccumulator"] = mTempGlobalAccumulator;

        // Get dimensions of ray dispatch.
        const uint2 targetDim = renderData.getDefaultTextureDims();
        FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

        // Spawn the rays.
        mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

        mNodes.swap(mTempNodes);
        mGlobalAccumulator.swap(mTempGlobalAccumulator);
        mpNodesBlock.swap(mpTempNodesBlock);

        dict["gNodes"] = mNodes;
        dict["gGlobalAccumulator"] = mGlobalAccumulator;

        mPassCount++;
    }
}

void FocalDensities::renderUI(Gui::Widgets& widget)
{
    widget.text(std::string("Nodes size: ") + std::to_string(mNodesSize));
    bool shouldPrintNodes = widget.button("Print nodes");
    if (shouldPrintNodes)
    {
        printNodes();
    }

    widget.checkbox("Pause", mPause);
    bool recomputeDensities = widget.button("Recompute");
    if (recomputeDensities)
    {
        setUniformNodes();
        mPassCount = 0;
    }
    widget.checkbox("Limited passes", mLimitedPasses);
    widget.slider("Max passes", mMaxPassCount, 0u, 50u);
    widget.checkbox("Use relative contributions", mUseRelativeContributions);
    widget.tooltip(
        "If true, then the contributions on the path are relative to the BSDF, if false, the they are all same along the path", true
    );
    widget.checkbox("Use narrowing", mUseNarrowing);
    widget.slider("Narrow factor", mNarrowFactor, 1.0f, 3.0f);
    widget.slider("Narrow from pass", mNarrowFromPass, 0u, 50u);
    widget.slider("Narrow each Nth pass", mNarrowEachNthPass, 1u, 50u);
    widget.slider("Decay", mDecay, 0.0f, 1.0f);
    widget.checkbox("Use analytic lights", mUseAnalyticLights);
    widget.checkbox("Integrate last hits", mIntegrateLastHits);
}

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

    DefineList defines;
    defines.add("DENSITY_NODES_BLOCK");
    auto pPass = ComputePass::create(mpDevice, "RenderPasses\\FocalGuiding\\DensityNode.slang", "main", defines);
    auto pReflector = pPass->getProgram()->getReflector()->getParameterBlock("gNodes");
    FALCOR_ASSERT(pReflector);
    // Bind resources to parameter block.
    mpNodesBlock = ParameterBlock::create(mpDevice, pReflector);
    auto nodes_var = mpNodesBlock->getRootVar();
    nodes_var["nodes"] = mNodes;

    
    mpTempNodesBlock = ParameterBlock::create(mpDevice, pReflector);
    auto temp_nodes_var = mpTempNodesBlock->getRootVar();
    temp_nodes_var["nodes"] = mTempNodes;
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
    std::vector<DensityNode> densityNodes = genUniformNodes(mInitOctreeDepth, false);
    //std::vector<DensityNode> densityNodes = genRandomNodes();
    mNodesSize = (uint)densityNodes.size();
    //mNodes = mpDevice->createStructuredBuffer(var["gNodes"], mNodesSize, bindFlags, memoryType, densityNodes.data());
    mNodes = mpDevice->createBuffer(mMaxNodesSize * sizeof(DensityNode), bindFlags | ResourceBindFlags::Shared, memoryType, nullptr);
    mNodes->setBlob(densityNodes.data(), 0, mNodesSize * sizeof(DensityNode));
    mTempNodes = mpDevice->createBuffer(mMaxNodesSize * sizeof(DensityNode), bindFlags | ResourceBindFlags::Shared, memoryType, nullptr);
    mTempNodes->setBlob(densityNodes.data(), 0, mNodesSize * sizeof(DensityNode));
    mpSampleGenerator->bindShaderData(var);

    float initAcc = 1.0f;
    mGlobalAccumulator = mpDevice->createBuffer(1 * sizeof(float), bindFlags | ResourceBindFlags::Shared, memoryType, &initAcc);
    mTempGlobalAccumulator = mpDevice->createBuffer(1 * sizeof(float), bindFlags | ResourceBindFlags::Shared, memoryType, &initAcc);
    
}

void FocalDensities::printNodes()
{
    float globalAccumulator = mGlobalAccumulator->getElement<float>(0);
    std::vector<DensityNode> densityNodes = mNodes->getElements<DensityNode>(0, mNodesSize);

    float sceneVolume = mpScene->getSceneBounds().volume();

    uint realNodeCount = 1;
    for (uint i = 1; i < mNodesSize; ++i)
    {
        uint parentNodeIndex = densityNodes[i].parentIndex;
        uint parentOffset = densityNodes[i].parentOffsetAndDepth & PARENT_OFFSET_BITS;
        if (!densityNodes[parentNodeIndex].childs[parentOffset].isLeaf())
        {
            realNodeCount++;
        }
    }
    printf("node count:         %d\n", mNodesSize);
    printf("real node count:    %d\n", realNodeCount);
    printf("global accumulator: %f\n", globalAccumulator);

    for (uint i = 0; i < mNodesSize; ++i)
    {
        uint parentNodeIndex = densityNodes[i].parentIndex;
        uint parentOffset = densityNodes[i].parentOffsetAndDepth & PARENT_OFFSET_BITS;

        if (i > 0 && densityNodes[parentNodeIndex].childs[parentOffset].isLeaf())
        {
            continue;
        }

        printf("  node: %d\n", i);
        printf("    parentIndex : %d\n", parentNodeIndex);
        printf("    parentOffset: %d\n", densityNodes[i].parentOffsetAndDepth & PARENT_OFFSET_BITS);
        uint depth = densityNodes[i].parentOffsetAndDepth >> PARENT_OFFSET_BIT_COUNT;
        printf("    depth       : %d\n", depth);
        float relVolume = powf(1.0f / 8.0f, depth);
        printf("    relVolume   : %f\n", relVolume);
        float volume = sceneVolume * relVolume;
        printf("    volume      : %f\n", volume);
        for (int ch = 0; ch < 8; ++ch)
        {
            DensityChild child = densityNodes[i].childs[ch];
            printf("    child: %d\n", child.index);
            printf("      is leaf       : %d\n", (int)child.isLeaf());
            printf("      accumulator   : %f\n", child.accumulator);
            float densityTimesVolume = child.accumulator / globalAccumulator;
            printf("      density*volume: %f\n", densityTimesVolume);
            float relDensity = densityTimesVolume / (relVolume / 8.0f);
            printf("      relDensity    : %f\n", relDensity);
            float density = densityTimesVolume / (volume / 8.0f);
            printf("      density       : %f\n", density);
            printf("      debug value   : %f\n", child.density);
        }
    }

    printf("node count:         %d\n", mNodesSize);
    printf("real node count:    %d\n", realNodeCount);
    printf("global accumulator: %f\n", globalAccumulator);
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
         {0, 0.0f, genRand()}},
        0,
        0
    };
}

DensityNode emptyNode(float acc)
{
    return DensityNode{
        {{0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f},
         {0, acc, 1.0f / 8.0f}},
         0,
         0
    };
}

void FocalDensities::setUniformNodes()
{
    std::vector<DensityNode> uniformNodes = genUniformNodes(mInitOctreeDepth, false);
    mNodes->setBlob(uniformNodes.data(), 0, uniformNodes.size() * sizeof(DensityNode));
    mNodesSize = (uint)uniformNodes.size();

    float initAcc = 1.0f;
    mGlobalAccumulator->setBlob(&initAcc, 0, sizeof(float));
    mTempGlobalAccumulator->setBlob(&initAcc, 0, sizeof(float));
}

std::vector<DensityNode> FocalDensities::genUniformNodes(uint depth, bool random) const
{
    std::vector<DensityNode> nodes;
    uint ni = 0;
    uint nc = 1;
    nodes.push_back(emptyNode(1.0 / 8.0));
    for (uint d = 0; d < depth - 1; ++d)
    {
        for (uint i = ni; i < ni + nc; ++i)
        {
            for (int ch = 0; ch < 8; ++ch)
            {
                nodes[i].childs[ch].index = (uint)nodes.size();
                nodes.push_back(emptyNode(1.0 / ((float)nc * 64.0)));
                nodes[nodes.size() - 1].parentIndex = i;
                nodes[nodes.size() - 1].parentOffsetAndDepth = ch | ((d + 1) << PARENT_OFFSET_BIT_COUNT);
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
