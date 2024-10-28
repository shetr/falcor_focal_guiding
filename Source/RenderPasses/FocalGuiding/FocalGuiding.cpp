#include "FocalGuiding.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"
#include "FocalDensities.h"
#include "FocalViz.h"
#include "GuidedRayViz.h"
#include "GuidedRays.h"
#include "NodeSplitting.h"
#include "NodePruning.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, FocalGuiding>();
    registry.registerClass<RenderPass, FocalDensities>();
    registry.registerClass<RenderPass, FocalViz>();
    registry.registerClass<RenderPass, GuidedRayViz>();
    registry.registerClass<RenderPass, GuidedRays>();
    registry.registerClass<RenderPass, NodeSplitting>();
    registry.registerClass<RenderPass, NodePruning>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/FocalGuiding.rt.slang";

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

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
} // namespace

FocalGuiding::FocalGuiding(ref<Device> pDevice, const Properties& props)
    : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

void FocalGuiding::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces)
            mMaxBounces = value;
        else if (key == kComputeDirect)
            mComputeDirect = value;
        else if (key == kUseImportanceSampling)
            mUseImportanceSampling = value;
        else
            logWarning("Unknown property '{}' in FocalGuiding properties.", key);
    }
}

Properties FocalGuiding::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    return props;
}

RenderPassReflection FocalGuiding::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void FocalGuiding::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // Update refresh flag if options that affect the output have changed.
    Dictionary& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

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

    // Specialize program.
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    mTracer.pProgram->addDefine("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    mTracer.pProgram->addDefine("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    mNodes = dict["gNodes"];
    mGlobalAccumulator = dict["gGlobalAccumulator"];
    mNodesSize = dict["gNodesSize"];
    mMaxNodesSize = dict["gMaxNodesSize"];
    mMaxOctreeDepth = dict["gMaxOctreeDepth"];
    dict["gMaxBounces"] = mMaxBounces;
    dict["gGuidedRayProb"] = mGuidedRayProb;
    dict["gComputeDirect"] = mComputeDirect;
    dict["gUseImportanceSampling"] = mUseImportanceSampling;

    mTracer.pProgram->addDefine("MAX_OCTREE_DEPTH", std::to_string(mMaxOctreeDepth));
    mTracer.pProgram->addDefine("MAX_NODES_SIZE", std::to_string(mMaxNodesSize));

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
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    var["CB"]["gGuidedRayProb"] = mGuidedRayProb;

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

    auto nodes_var = mpNodesBlock->getRootVar();
    nodes_var["nodes"] = mNodes;

    var["gNodes"] = mpNodesBlock;
    var["gGlobalAccumulator"] = mGlobalAccumulator;

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

    mFrameCount++;
}

void FocalGuiding::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.slider("Max bounces", mMaxBounces, 0u, 5u);
    widget.tooltip("Maximum path length for indirect illumination.\n0 = direct only\n1 = one indirect bounce etc.", true);

    dirty |= widget.slider("Guided ray prob", mGuidedRayProb, 0.0f, 1.0f);
    widget.tooltip("Probability of selecting guided ray over scattered ray in one step of the path", true);

    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    widget.tooltip("Compute direct illumination.\nIf disabled only indirect is computed (when max bounces > 0).", true);

    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    widget.tooltip("Use importance sampling for materials", true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

void FocalGuiding::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
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
}

void FocalGuiding::prepareVars()
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
    mpSampleGenerator->bindShaderData(var);

}
