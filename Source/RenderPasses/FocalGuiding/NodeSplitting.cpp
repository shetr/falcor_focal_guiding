#include "NodeSplitting.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/NodeSplitting.slang";

const char kMaxPassCount[] = "maxPasses";
const char kLimitedPasses[] = "limitedPasses";
const char kSamePassAsNarrowPass[] = "samePassAsNarrowPass";
const char kExecuteFromPass[] = "executeFromPass";
const char kExecuteEachNthPass[] = "executeEachNthPass";
} // namespace

NodeSplitting::NodeSplitting(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxPassCount)
            mMaxPassCount = value;
        else if (key == kLimitedPasses)
            mLimitedPasses = value;
        else if (key == kSamePassAsNarrowPass)
            mSamePassAsNarrowPass = value;
        else if (key == kExecuteFromPass)
            mExecuteFromPass = value;
        else if (key == kExecuteEachNthPass)
            mExecuteEachNthPass = value;
        else
            logWarning("Unknown property '{}' in NodeSplitting properties.", key);
    }

    mpProgram = Program::createCompute(mpDevice, kShaderFile, "computeMain");
    mpState = ComputeState::create(mpDevice);
}

Properties NodeSplitting::getProperties() const
{
    Properties props;
    props[kMaxPassCount] = mMaxPassCount;
    props[kLimitedPasses] = mLimitedPasses;
    props[kSamePassAsNarrowPass] = mSamePassAsNarrowPass;
    props[kExecuteFromPass] = mExecuteFromPass;
    props[kExecuteEachNthPass] = mExecuteEachNthPass;
    return props;
}

RenderPassReflection NodeSplitting::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    //addRenderPassInputs(reflector, kInputChannels);
    //addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void NodeSplitting::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpScene)
    {
        return;
    }
    Dictionary& dict = renderData.getDictionary();
    if (!dict.keyExists("gNodes") || !dict.keyExists("gNodesSize") || !dict.keyExists("gMaxNodesSize") ||
        !dict.keyExists("gMaxOctreeDepth") || !dict.keyExists("gPassCount"))
    {
        return;
    }
    mNodes = dict["gNodes"];
    mGlobalAccumulator = dict["gGlobalAccumulator"];
    mNodesSize = dict["gNodesSize"];
    mMaxNodesSize = dict["gMaxNodesSize"];
    mMaxOctreeDepth = dict["gMaxOctreeDepth"];
    mPassCount = dict["gPassCount"];

    if (mSamePassAsNarrowPass)
    {
        mLimitedPasses = dict["gLimitedPasses"];
        mMaxPassCount = dict["gMaxPassCount"];
        mExecuteFromPass = dict["gNarrowFromPass"];
        mExecuteEachNthPass = dict["gNarrowEachNthPass"];
    }

    if (!mUseSplitting || mLimitedPasses && mPassCount >= mMaxPassCount || mPassCount < mExecuteFromPass ||
        (mPassCount % mExecuteEachNthPass != 0))
    {
        return;
    }
    
    mpProgram->addDefine("MAX_OCTREE_DEPTH", std::to_string(mMaxOctreeDepth));
    mpProgram->addDefine("MAX_NODES_SIZE", std::to_string(mMaxNodesSize));

    if (!mpVars)
        prepareVars();

    mNodesSizeBuffer->setElement(0, mNodesSize);

    // Set constants.
    auto var = mpVars->getRootVar();
    var["CB"]["gSplittingThreshold"] = mSplittingThreshold;

    auto nodesVar = mpNodesBlock->getRootVar();
    nodesVar["nodes"] = mNodes;
    var["gNodes"] = mpNodesBlock;
    var["gGlobalAccumulator"] = mGlobalAccumulator;
    var["gNodesSize"] = mNodesSizeBuffer;

    uint3 numGroups = uint3(mNodesSize, 1, 1);
    mpState->setProgram(mpProgram);
    pRenderContext->dispatch(mpState.get(), mpVars.get(), numGroups);

    mNodesSize = mNodesSizeBuffer->getElement<uint>(0);
    dict["gNodesSize"] = mNodesSize;
}

void NodeSplitting::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Enabled", mUseSplitting);
    widget.slider("Splitting threshold", mSplittingThreshold, 0.0001f, 0.01f);
    widget.checkbox("Same pass as narrow pass", mSamePassAsNarrowPass);
    if (!mSamePassAsNarrowPass)
    {
        widget.checkbox("Limited passes", mLimitedPasses);
        widget.slider("Execute from pass", mExecuteFromPass, 0u, 50u);
        widget.slider("Execute each Nth pass", mExecuteEachNthPass, 1u, 50u);
        widget.slider("Max passes", mMaxPassCount, 0u, 50u);
    }
}

void NodeSplitting::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;
    DefineList defines;
    defines.add("DENSITY_NODES_BLOCK");
    auto pPass = ComputePass::create(mpDevice, "RenderPasses\\FocalGuiding\\DensityNode.slang", "main", defines);
    auto pReflector = pPass->getProgram()->getReflector()->getParameterBlock("gNodes");
    FALCOR_ASSERT(pReflector);
    // Bind resources to parameter block.
    mpNodesBlock = ParameterBlock::create(mpDevice, pReflector);
    auto nodesVar = mpNodesBlock->getRootVar();
    nodesVar["nodes"] = mNodes;
}

void NodeSplitting::prepareVars()
{
    FALCOR_ASSERT(mpProgram)

    mpVars = ProgramVars::create(mpDevice, mpProgram.get());

    ResourceBindFlags bindFlags = ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess;
    MemoryType memoryType = MemoryType::DeviceLocal;
    mNodesSizeBuffer = mpDevice->createBuffer(1 * sizeof(float), bindFlags, memoryType, &mNodesSize);
}
