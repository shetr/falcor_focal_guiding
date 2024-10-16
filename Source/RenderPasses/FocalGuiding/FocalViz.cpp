#include "FocalViz.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/FocalViz.rt.slang";

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
const char kMinDensity[] = "minDensity";
const char kMaxDensity[] = "maxDensity";
const char kBlendFromScene[] = "blendFromScene";
const char kMinBlendAlpha[] = "minBlendAlpha";
const char kNormalsViz[] = "normalsViz";
} // namespace

FocalViz::FocalViz(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);
    setColors();
}

void FocalViz::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kBlendFromScene)
            mBlendFromScene = value;
        else if (key == kNormalsViz)
            mNormalsViz = value;
        else if (key == kMinDensity)
            mMinDensity = value;
        else if (key == kMaxDensity)
            mMaxDensity = value;
        else if (key == kMinBlendAlpha)
            mMinBlendAlpha = value;
        else
            logWarning("Unknown property '{}' in FocalGuiding properties.", key);
    }
}

Properties FocalViz::getProperties() const
{
    Properties props;
    props[kMinDensity] = mMinDensity;
    props[kMaxDensity] = mMaxDensity;
    props[kBlendFromScene] = mBlendFromScene;
    props[kMinBlendAlpha] = mMinBlendAlpha;
    props[kNormalsViz] = mNormalsViz;
    return props;
}

RenderPassReflection FocalViz::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void FocalViz::execute(RenderContext* pRenderContext, const RenderData& renderData)
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

    Dictionary& dict = renderData.getDictionary();
    mNodes = dict["gNodes"];
    mGlobalAccumulator = dict["gGlobalAccumulator"];
    mNodesSize = dict["gNodesSize"];
    mMaxNodesSize = dict["gMaxNodesSize"];
    mMaxOctreeDepth = dict["gMaxOctreeDepth"];

    mTracer.pProgram->addDefine("MAX_OCTREE_DEPTH", std::to_string(mMaxOctreeDepth));
    mTracer.pProgram->addDefine("MAX_NODES_SIZE", std::to_string(mMaxNodesSize));
    mTracer.pProgram->addDefine("VIZ_COLORS_COUNT", std::to_string(VIZ_COLORS_COUNT));

    mTracer.pProgram->addDefine("DENSITY_ACC_TYPE_MAX", std::to_string(mDensityAccType == FocalViz::DensityAccType::Max));
    mTracer.pProgram->addDefine("DENSITY_ACC_TYPE_AVG", std::to_string(mDensityAccType == FocalViz::DensityAccType::Avg));

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
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gNodesSize"] = mNodesSize;
    var["CB"]["gSceneBoundsMin"] = mpScene->getSceneBounds().minPoint;
    var["CB"]["gSceneBoundsMax"] = mpScene->getSceneBounds().maxPoint;
    var["CB"]["gMinDensity"] = mMinDensity;
    var["CB"]["gMaxDensity"] = mMaxDensity;

    for (int i = 0; i < VIZ_COLORS_COUNT; i++)
    {
        var["CB"]["gVizColors"][i] = mVizColors[i];
    }
    var["CB"]["gBlendFromScene"] = mBlendFromScene;
    var["CB"]["gMinBlendAlpha"] = mMinBlendAlpha;
    var["CB"]["gNormalsViz"] = mNormalsViz;
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

void FocalViz::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    dirty |= widget.var("Max slider density", mMaxSliderDensity, 0u, 1000000u);
    widget.tooltip("Maximum value for Max density slider.", true);

    dirty |= widget.slider("Min density", mMinDensity, 0.0f, mMaxDensity);
    widget.tooltip("Minimum visualized density.", true);

    dirty |= widget.slider("Max density", mMaxDensity, mMinDensity, (float)mMaxSliderDensity);
    widget.tooltip("Maximum visualized density.", true);

    if (widget.dropdown("Color palette", mColorPalette))
    {
        setColors();
    }

    dirty |= widget.dropdown("Density accumulator type", mDensityAccType);
    
    dirty |= widget.checkbox("Blend from scene", mBlendFromScene);

    dirty |= widget.slider("Min blend alpha", mMinBlendAlpha, 0.0f, 1.0f);

    dirty |= widget.checkbox("Viz normals", mNormalsViz);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}

void FocalViz::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
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

void FocalViz::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    // Configure program.
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);
}

float3 FocalViz::rgb(int r, int g, int b)
{
    return float3(((float)r) / 255.0f, ((float)g) / 255.0f, ((float)b) / 255.0f);
}

void FocalViz::setColors()
{
    switch (mColorPalette)
    {
    case VizColorPalette::YellowToRed:
        setYellowToRedColors();
        break;
    case VizColorPalette::Viridis:
        mVizColors[6] = rgb(253, 231, 37);
        mVizColors[5] = rgb(144, 215, 67);
        mVizColors[4] = rgb(53, 183, 121);
        mVizColors[3] = rgb(33, 145, 140);
        mVizColors[2] = rgb(49, 104, 142);
        mVizColors[1] = rgb(68, 57, 131);
        mVizColors[0] = rgb(68, 1, 84);
        break;
    case VizColorPalette::Inferno:
        mVizColors[6] = rgb(252, 255, 164);
        mVizColors[5] = rgb(251, 182, 26);
        mVizColors[4] = rgb(237, 105, 37);
        mVizColors[3] = rgb(188, 55, 84);
        mVizColors[2] = rgb(120, 28, 109);
        mVizColors[1] = rgb(50, 10, 94);
        mVizColors[0] = rgb(0, 0, 4);
        break;
    case VizColorPalette::Magma:
        mVizColors[6] = rgb(252, 253, 191);
        mVizColors[5] = rgb(254, 176, 120);
        mVizColors[4] = rgb(241, 96, 93);
        mVizColors[3] = rgb(183, 55, 121);
        mVizColors[2] = rgb(114, 31, 129);
        mVizColors[1] = rgb(44, 17, 95);
        mVizColors[0] = rgb(0, 0, 4);
        break;
    case VizColorPalette::Plasma:
        mVizColors[6] = rgb(240, 249, 33);
        mVizColors[5] = rgb(253, 180, 47);
        mVizColors[4] = rgb(237, 121, 83);
        mVizColors[3] = rgb(204, 71, 120);
        mVizColors[2] = rgb(156, 23, 158);
        mVizColors[1] = rgb(92, 1, 166);
        mVizColors[0] = rgb(13, 8, 135);
        break;
    default:
        break;
    }
}

void FocalViz::setYellowToRedColors()
{
    for (int i = 0; i < VIZ_COLORS_COUNT; i++)
    {
        float t = ((float)i) / (VIZ_COLORS_COUNT - 1);
        mVizColors[i] = float3((1.0 - t), (1.0 - t), 0.0) + float3(t, 0.0, 0.0);
    }
}
