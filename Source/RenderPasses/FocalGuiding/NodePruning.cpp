#include "NodePruning.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/NodePruning.slang";

const char kRunInFrame[] = "runInFrame";
const char kRunAfterLastIter[] = "runAfterLastIter";
const char kUsePruning[] = "usePruning";
const char kPruneFactor[] = "pruneFactor";
} // namespace

NodePruning::NodePruning(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kRunInFrame)
            mRunInFrame = value;
        else if (key == kRunAfterLastIter)
            mRunAfterLastIter = value;
        else if (key == kUsePruning)
            mUsePruning = value;
        else if (key == kPruneFactor)
            mPruneFactor = value;
        else
            logWarning("Unknown property '{}' in NodePruning properties.", key);
    }

    mpProgram = Program::createCompute(mpDevice, kShaderFile, "computeMain");
    mpState = ComputeState::create(mpDevice);
}

Properties NodePruning::getProperties() const
{
    Properties props;
    props[kRunInFrame] = mRunInFrame;
    props[kRunAfterLastIter] = mRunAfterLastIter;
    props[kUsePruning] = mUsePruning;
    props[kPruneFactor] = mPruneFactor;
    return props;
}

RenderPassReflection NodePruning::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    // addRenderPassInputs(reflector, kInputChannels);
    // addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void NodePruning::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

    if (mRunAfterLastIter)
    {
        uint densitiesMaxPassCount = dict["gMaxPassCount"];
        mRunInFrame = densitiesMaxPassCount + 1;
    }

    mpProgram->addDefine("MAX_OCTREE_DEPTH", std::to_string(mMaxOctreeDepth));
    mpProgram->addDefine("MAX_NODES_SIZE", std::to_string(mMaxNodesSize));

    if (!mpVars)
        prepareVars();

    mNodesSizeBuffer->setElement(0, mNodesSize);

    // Set constants.
    auto var = mpVars->getRootVar();

    auto nodesVar = mpNodesBlock->getRootVar();
    nodesVar["nodes"] = mNodes;
    var["gNodes"] = mpNodesBlock;
    var["gGlobalAccumulator"] = mGlobalAccumulator;
    var["gNodesSize"] = mNodesSizeBuffer;
    var["gMaxDensities"] = mMaxDensitiesBuffer;
    var["gAvgDensities"] = mAvgDensitiesBuffer;


    if (mPassCount == mRunInFrame && mUsePruning)
    {
        for (uint depth = mMaxOctreeDepth; depth > 0; depth--)
        {
            var["CB"]["gPruneDepth"] = depth;
            var["CB"]["gPruneFactor"] = mPruneFactor;
            uint3 numGroups = uint3(mNodesSize, 1, 1);
            mpState->setProgram(mpProgram);
            pRenderContext->dispatch(mpState.get(), mpVars.get(), numGroups);
        }

        mNodesSize = mNodesSizeBuffer->getElement<uint>(0);
        dict["gNodesSize"] = mNodesSize;
    }
}

void NodePruning::renderUI(Gui::Widgets& widget)
{
    widget.checkbox("Enabled", mUsePruning);
    widget.slider("Prune factor", mPruneFactor, 1.0f, 4.0f);
    widget.checkbox("Run after last iter", mRunAfterLastIter);
    if (!mRunAfterLastIter)
    {
        widget.slider("Run in frame", mRunInFrame, 0u, 50u);
    }
}

void NodePruning::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
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

void NodePruning::prepareVars()
{
    FALCOR_ASSERT(mpProgram)

    mpVars = ProgramVars::create(mpDevice, mpProgram.get());

    ResourceBindFlags bindFlags = ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess;
    MemoryType memoryType = MemoryType::DeviceLocal;
    mNodesSizeBuffer = mpDevice->createBuffer(1 * sizeof(float), bindFlags, memoryType, &mNodesSize);

    mMaxDensitiesBuffer = mpDevice->createBuffer(mMaxNodesSize * sizeof(float), bindFlags, memoryType, nullptr);
    mAvgDensitiesBuffer = mpDevice->createBuffer(mMaxNodesSize * sizeof(float), bindFlags, memoryType, nullptr);
}
