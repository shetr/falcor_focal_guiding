#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Scene/SceneBuilder.h"

#include "GuidedRayLine.h"

using namespace Falcor;

class GuidedRayViz : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(GuidedRayViz, "GuidedRayViz", "ray vizulalisation");

    static ref<GuidedRayViz> create(ref<Device> pDevice, const Properties& props) { return make_ref<GuidedRayViz>(pDevice, props); }

    GuidedRayViz(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    void prepareVars();
    void generateRaysGeometry();
    void createLine(SceneBuilder::ProcessedMesh& mesh, GuidedRayLine rayLine, int& index);
    void createQuad(
        SceneBuilder::ProcessedMesh& mesh,
        int& index,
        float3 x11, float3 x12, float3 x21, float3 x22, float3 n11, float3 n12, float3 n21, float3 n22
    );
    float3 getPerpendicualrTo(float3 dir);

    uint mGuidedRaysSize = 10;
    ref<Buffer> mGuidedRays;
    bool mComputeRays = true;

    // Internal state
    ref<Scene> mpScene;

    ref<Scene> mpRayScene;

    ref<Program> mpProgram;
    ref<GraphicsState> mpGraphicsState;
    ref<RasterizerState> mpRasterState;
    ref<ProgramVars> mpVars;
};
