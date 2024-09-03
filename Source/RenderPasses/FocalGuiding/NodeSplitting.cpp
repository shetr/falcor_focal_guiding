#include "NodeSplitting.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/NodeSplitting.slang";

const char kMaxPassCount[] = "maxPasses";
const char kLimitedPasses[] = "limitedPasses";
} // namespace

NodeSplitting::NodeSplitting(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxPassCount)
            mMaxPassCount = value;
        else if (key == kLimitedPasses)
            mLimitedPasses = value;
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
    Dictionary& dict = renderData.getDictionary();
    mNodes = dict["gNodes"];
    mNodesSize = dict["gNodesSize"];
    mMaxOctreeDepth = dict["gMaxOctreeDepth"];

    // Set constants.
    auto var = mpVars->getRootVar();
    var["CB"]["gNodesInSize"] = mNodesSize;
    var["CB"]["gSplittingThreshold"] = mSplittingThreshold;

    auto nodesVar = mpNodesBlock->getRootVar();
    nodesVar["nodes"] = mNodes;
    auto nodesTempVar = mpNodesTempBlock->getRootVar();
    nodesTempVar["nodes"] = mNodesTemp;
    var["gNodesIn"] = mpNodesBlock;
    var["gNodesOut"] = mpNodesBlock;
    var["gNodesOutSize"] = mNodesTempSizeBuffer;

    uint3 numGroups = uint3(1, 1, 1);
    mpState->setProgram(mpProgram);
    pRenderContext->dispatch(mpState.get(), mpVars.get(), numGroups);
    
}

void NodeSplitting::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("limited passes", mLimitedPasses);
    widget.slider("max passes", mMaxPassCount, 0u, 50u);
}

void NodeSplitting::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    DefineList defines;
    defines.add("DENSITY_NODES_BLOCK");
    auto pPass = ComputePass::create(mpDevice, "RenderPasses\\FocalGuiding\\DensityNode.slang", "main", defines);
    auto pReflector = pPass->getProgram()->getReflector()->getParameterBlock("gNodes");
    FALCOR_ASSERT(pReflector);
    // Bind resources to parameter block.
    mpNodesBlock = ParameterBlock::create(mpDevice, pReflector);
    auto nodesVar = mpNodesBlock->getRootVar();
    nodesVar["nodes"] = mNodes;
    mpNodesTempBlock = ParameterBlock::create(mpDevice, pReflector);
    auto nodesTempVar = mpNodesTempBlock->getRootVar();
    nodesTempVar["nodes"] = mNodesTemp;
}

void NodeSplitting::prepareVars()
{
    FALCOR_ASSERT(mpProgram)

    auto var = mpVars->getRootVar();
    ResourceBindFlags bindFlags = ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess | ResourceBindFlags::Shared;
    MemoryType memoryType = MemoryType::DeviceLocal;
    mNodesTempSize = 1;
    mNodesTemp = mpDevice->createBuffer(mNodesTempSize * sizeof(DensityNode), bindFlags, memoryType);

    mNodesTempSizeBuffer = mpDevice->createBuffer(1 * sizeof(float), bindFlags, memoryType, &mNodesTempSize);
}
