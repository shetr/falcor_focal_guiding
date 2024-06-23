#include "GuidedRayViz.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

namespace
{
const char kShaderFile[] = "RenderPasses/FocalGuiding/GuidedRayViz.slang";

} // namespace

GuidedRayViz::GuidedRayViz(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    mpProgram = Program::createGraphics(mpDevice, kShaderFile, "vsMain", "psMain");
    RasterizerState::Desc wireframeDesc;
    wireframeDesc.setFillMode(RasterizerState::FillMode::Wireframe);
    wireframeDesc.setCullMode(RasterizerState::CullMode::None);
    mpRasterState = RasterizerState::create(wireframeDesc);

    mpGraphicsState = GraphicsState::create(mpDevice);
    mpGraphicsState->setProgram(mpProgram);
    mpGraphicsState->setRasterizerState(mpRasterState);
}

Properties GuidedRayViz::getProperties() const
{
    return {};
}

RenderPassReflection GuidedRayViz::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    reflector.addOutput("output", "Lines");
    return reflector;
}

void GuidedRayViz::execute(RenderContext* pRenderContext, const RenderData& renderData)
{

    //Dictionary& dict = renderData.getDictionary();
    //mNodes = dict["gNodes"];
    //mNodesSize = dict["gNodesSize"];
    //mMaxOctreeDepth = dict["gMaxOctreeDepth"];


    auto pTargetFbo = Fbo::create(mpDevice, {renderData.getTexture("output")});
    const float4 clearColor(0, 0, 0, 1);
    pRenderContext->clearFbo(pTargetFbo.get(), clearColor, 1.0f, 0, FboAttachmentType::All);
    mpGraphicsState->setFbo(pTargetFbo);

    if (mpScene)
    {
        auto var = mpVars->getRootVar();
        var["PerFrameCB"]["gColor"] = float4(0, 1, 0, 1);

        mpScene->rasterize(pRenderContext, mpGraphicsState.get(), mpVars.get(), mpRasterState, mpRasterState);
    }
}

void GuidedRayViz::renderUI(Gui::Widgets& widget)
{
    
}

void GuidedRayViz::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    mpScene = pScene;

    if (mpScene)
        mpProgram->addDefines(mpScene->getSceneDefines());
    mpVars = ProgramVars::create(mpDevice, mpProgram->getReflector());
}

void GuidedRayViz::prepareVars()
{
    
}
